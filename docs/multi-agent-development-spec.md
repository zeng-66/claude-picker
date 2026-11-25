# 多引擎共用会话架构开发规范（细化至全量交互与接口契约）

> 状态：**已实现并验收**
> 日期：2026-11-18
> 基线分支：`codex/wt-20261118`（提交 `325e9f9`）
> 前置文档：[Antigravity CLI 集成方案](antigravity-integration-plan.md) · [多智能体控制面架构深度评估](multi-agent-architecture-evaluation.md)
> 覆盖范围：**四维 Driver/Adapter 底座 + Antigravity CLI (`agy`) 全链路接入（终端 + ACP Work 执行器 + MCP）+ 共用 Thread 跨引擎无缝切换 + Turn Checkpoint 代码快照回退**

---

## 1. 本机实测固化的技术事实

本规范基于对本机 `/Users/zcl/.local/bin/agy`（ACP Server `1.5.10`）及 `~/.gemini/antigravity-cli/` 的实测结果制定，无猜测假设：

1. **Antigravity 会话索引**：
   - 主索引库：`~/.gemini/antigravity-cli/conversation_summaries.db`（表 `conversation_summaries`，主键 `conversation_id`，含 `title`、`preview`、`workspace_uris` JSON 数组如 `["file:///Users/zcl"]`、`status`、`not_fully_idle`、`parent_conversation_id`、`nesting_depth`、`killed`、`last_modified_time`）。过滤条件 `parent_conversation_id = '' AND nesting_depth = 0 AND killed = 0` 可精确剔除子代理与已销毁会话。
   - 辅助缓存：`~/.gemini/antigravity-cli/cache/conversation_metadata.json`（`conversations.<id>.summary`）。
   - 转录与 Token：`~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`（`USER_INPUT` / `PLANNER_RESPONSE`，含 `model`、`input_tokens`、`cache_read_tokens`、`output_tokens`）。
2. **新建会话 ID 规律**：
   - 实测 `agy --conversation <未知UUID>` 会输出 `warning: conversation "..." not found` 并由 CLI 自行分配新 UUID。因此原生终端新建 Antigravity 会话时**不传伪造 `--conversation`**，直接执行 `exec agy <flags> [-i <prompt>]`，由宿主通过扫描 `cwd` 下启动时间之后新出现的 `conversation_id` 自动回填绑定。
3. **模型与模式清单（`agy models` & `agy acp` 实测）**：
   - 模式（4 项）：`default`（默认询问）、`accept-edits`（自动接受编辑）、`auto`（自动执行安全命令）、`plan`（先规划）。CLI 启动参数 `--mode` 接受 `accept-edits | auto | plan`（`default` 不传 `--mode`）。
   - 模型（TSV `<modelId>\t<Name>`）：`gemini-4-carbon-high`（`Gemini 4 Carbon (High)`）、`gemini-4-carbon-medium`、`gemini-4-hydrogen-high`、`gemini-4-hydrogen-xhigh`、`gemini-3.8-flash-high`、`claude-sonnet-4-6`、`claude-opus-4-6-thinking`、`gpt-oss-120b-medium` 等；`~/.gemini/antigravity-cli/settings.json` 的 `"model"` 键存显示名称或模型 ID。
4. **ACP 协议（`agy acp` 实测）**：
   - 传输：JSON-RPC 2.0 NDJSON over `stdio`。
   - 建连：`initialize` (`protocolVersion: 1`) → 新建 `session/new` (`{cwd, mcpServers: []}`) 或恢复 `session/load` (`{sessionId, cwd, mcpServers: []}`)。
   - 对话与流式通知：`session/prompt` (`{sessionId, prompt: [{type: "text", text}]}`) 期间推送 `method: "session/update"`：
     - `sessionUpdate == "agent_message_chunk"` → 流式文本增量与最终助手回复；
     - `sessionUpdate == "tool_call"` / `"tool_call_update"` → 工具调用卡片与结果；
     - `sessionUpdate == "usage_update"` / `"session_info_update"` → 上下文用量与标题更新。
   - 权限审批：服务端下发 JSON-RPC 请求 `method: "session/request_permission"`（含 `toolCall` 与 `options`），客户端回包 `result: {outcome: {outcome: "selected", optionId: ...}}`。
   - 中断：客户端发送通知 `method: "session/cancel"` (`{sessionId}`)。

---

## 2. 后端与存储契约

### 2.1 四维 Driver / Adapter 代码结构

| 文件 | 职责 |
| --- | --- |
| `Sources/ClaudeDeck/AgentProviders.swift` | `AgentProvider` (`claude` / `antigravity`，预留 `codex` 扩展槽)、`ProviderCapabilities`、`CliLocator`、`AgyConfig`、`AgySessionScanner`、`AgyContextUsage`、四层 `<thread-handoff>` 交接信封生成器 `HandoffBuilder` |
| `Sources/ClaudeDeck/Work/ACPExecutor.swift` | 抽取统一 `AgentExecutorProcess` 协议；实现标准 `ACPProcess`（JSON-RPC 2.0 stdio 客户端，驱动 `agy acp` 及未来所有 ACP 兼容 CLI） |
| `Sources/ClaudeDeck/Work/WorkspaceService.swift` | 新增 `createCheckpoint`（临时 Index `write-tree` + `commit-tree` + `update-ref refs/claude-picker/checkpoints/<workId>/<seq>`）与 `revertToCheckpoint`（含 `undo` 备份、共享目录冲突校验、未跟踪文件清理） |
| `Sources/ClaudeDeck/Work/WorkStore.swift` | Schema `v1 → v2` 自动备份平滑迁移：扩展 `works`（`executor`、`reverted_notice`），新增 `thread_segments` 与 `checkpoints` 表 |

### 2.2 SQLite Schema v2 变更明细（`WorkStore.swift`）

```sql
-- 1. works 表新增当前执行引擎与回退幻觉修正通知
ALTER TABLE works ADD COLUMN executor TEXT NOT NULL DEFAULT 'claude';
ALTER TABLE works ADD COLUMN reverted_notice TEXT;

-- 2. 共用 Thread 的多段底层会话轨迹表
CREATE TABLE IF NOT EXISTS thread_segments(
    id TEXT PRIMARY KEY,
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL,
    provider TEXT NOT NULL,
    provider_session_id TEXT NOT NULL,
    cwd TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(work_id, seq)
);

-- 3. Turn Checkpoint 快照表（锚定隐藏 Git Ref 防 GC）
CREATE TABLE IF NOT EXISTS checkpoints(
    id TEXT PRIMARY KEY,
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    run_id TEXT,
    seq INTEGER NOT NULL,
    phase TEXT NOT NULL,             -- 'pre' | 'post' | 'undo'
    head_commit TEXT,
    tree_hash TEXT NOT NULL,
    git_ref TEXT NOT NULL,           -- refs/claude-picker/checkpoints/<workId>/<seq>
    label TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    UNIQUE(work_id, seq)
);
CREATE INDEX IF NOT EXISTS checkpoints_work ON checkpoints(work_id);
```

### 2.3 Bridge RPC 新增与扩展契约

| 方法 | 入参变更 / 新增参数 | 返回值 / 行为说明 |
| --- | --- | --- |
| `app.state` | 无 | `projects[].sessions[]` 增加 `provider` (`"claude"`\|`"antigravity"`), `handoffFrom`；`active` 增加 `provider`；新增 `providers` 引擎诊断列表；`runtime` 增加 `provider`, `supportsFast`, `hotSwitchable`, 并随激活会话或默认引擎动态切换 `modes`/`models`/`efforts` |
| `app.runtime` | `{ key, value, provider? }` | `key == "provider"` 时切换空闲态默认引擎；其余 `mode`/`model`/`effort`/`fast` 自动路由到当前会话引擎对应的 `ClaudeConfig` 或 `AgyConfig` |
| `app.settings` | 增加 `defaultProvider`, `scanAntigravity`, `providerFilter` | 持久化至 `~/.local/share/claude-picker/settings.json`，切换 `scanAntigravity` 时立即重扫项目树 |
| `session.open` | 增加可选 `provider` | 按 `provider\|cwd\|sid` 打开/复用终端；若 `interactionMode == "chat"` 且 `provider == "antigravity"`，自动降级为原生终端并推送 Toast 事件 |
| `session.create` | 增加可选 `provider` (`"claude"`\|`"antigravity"`) | 支持 `current` 与 `worktree` 模式启动对应 CLI |
| `session.handoff` | **新增** `{ sessionId, sourceProvider?, targetProvider, projectPath, cwd }` | 提取原会话四层 `<thread-handoff>` 信封，在同一 `cwd` 下以 `targetProvider` 启动接力新会话并自动打开 |
| `work.create` | 增加可选 `executor` (`"claude"`\|`"antigravity"`), `adoptProvider` | 创建指定执行引擎的 Work；纳管普通会话时自动继承原会话引擎 |
| `work.switchExecutor` | **新增** `{ workId, executor, model?, permissionMode? }` | 在非运行态切换该 Work 下一轮的执行引擎；下一轮自动开启新 `thread_segment` 并注入前情 `<thread-handoff>` |
| `checkpoint.list` | **新增** `{ workId }` | 返回该 Work 的全部有效代码检查点列表（按 `seq` 倒序） |
| `checkpoint.revert` | **新增** `{ workId, checkpointId, force? }` | 先打 `undo` 快照，再恢复工作区至目标 `checkpointId`；共享目录检测到外部未保存变更且 `force != true` 时返回冲突详情拒绝对齐；成功后设置 `works.reverted_notice` |
| `mcp.*` | 增加可选 `provider` (`"claude"`\|`"antigravity"`)，新增 `mcp.importFromClaude` | 支持管理 `~/.gemini/config/mcp_config.json`，拦截旧版 SSE，一键导入兼容服务 |

---

## 3. 全量界面与交互细节规范（I-01 ～ I-07）

### I-01 工作空间 · 左侧项目与会话树（`Sidebar.jsx`）

1. **顶部标题与引擎筛选条**：
   - 标题主文案保持紧凑，副标题显示 `{projects.length} 个目录 · {rowCount} 行`。
   - 搜索按钮下方（当存在 Antigravity 会话或本机已安装 `agy` 时）渲染三段轻量筛选胶囊：`全部` | `Claude` | `Antigravity`。
   - 点击胶囊过滤各项目下的普通会话与 Work（项目本身若为已登记目录仍保留展示，会话计数随筛选实时变化；状态记忆在 `settings.providerFilter`）。
2. **会话行视觉与交互**：
   - 每条 `.session-row` 标题左侧或时间旁渲染引擎微徽标：
     - `claude`：`C` 暖橙色微标（tooltip：`Claude Code 会话`）；
     - `antigravity`：`A` 青蓝微标（tooltip：`Antigravity 会话`）。
   - 若该会话由跨引擎接力产生（`session.handoffFrom` 非空），副标题展示 `接力 · {session.time}`，hover tooltip 显示 `接力自：{session.handoffFrom}`。
   - **点击会话行**：调用 `session.open({ projectPath, cwd, sessionId, provider: session.provider })`。
   - **键盘导航**：`↑` `↓` `←` `→` `Enter` `Tab` 与拖拽排序完全兼容双引擎会话行。
3. **Work 行引擎标识**：
   - 项目下挂载的 `.work-row` 副标题显示 `{work.displayId} · {executorShortLabel} · {status.label}`，一眼区分哪个 Work 由 Claude 还是 Antigravity 驱动。
4. **底部额度条**：
   - 悬停文案明确标注 `Claude 额度：本 5 小时窗口...`，避免用户误以为包含 Antigravity 额度。

### I-02 会话右键菜单与跨引擎接力（`App.jsx` `treeContext`）

在 `.session-row` 上右键弹出菜单，按顺序包含：
1. `新建对话`：打开 `SessionModal`（预选当前项目）。
2. **`转到 Antigravity 继续`**（当前会话为 `claude` 时显示） / **`转到 Claude Code 继续`**（当前会话为 `antigravity` 时显示）：
   - 若目标 CLI 本机未安装：菜单项置灰，`title` 提示 `未检测到对应 CLI，请先安装`。
   - 点击后：立即关闭菜单，显示轻提示 `正在提取上下文并启动 Antigravity…`，调用 `session.handoff`：
     - 宿主从原会话 `.jsonl` 提取四层 `<thread-handoff>` 信封（最近 4 轮有效问答 + 摘要 + 当前分支状态 + 原转录文件路径指针）；
     - 在同一 `cwd` 启动目标引擎终端并注入该交接信封；
     - 新会话置入当前项目顶部并选中聚焦，原会话保留原样只读不修改。
3. `重命名`：打开 `RenameSessionModal`，对双引擎均生效（写入 `tree.json` `titles`）。
4. `作为 Work 继续`：打开 `NewWorkModal`，将 `{ sessionId, cwd, provider: session.provider, label, projectPath }` 传入 `adopt`——自动把 Work 的默认执行引擎设为该会话的 `provider`（若该会话仍在终端运行中，后端按既有互斥锁提示先关闭终端再纳管）。
5. `置顶` / `从列表移除`：保持既有交互。

### I-03 新建会话弹窗（`Modals.jsx` `SessionModal`）

1. **新增「执行 CLI」选择器**（位于「会话名称」输入框上方）：
   - 两张并排轻量选择卡：`Claude Code`（副文案：`claude · 支持终端与图形模式`）与 `Antigravity`（副文案：`agy · Google Antigravity CLI`）。
   - 默认选中 `settings.defaultProvider`；若检测到某个 CLI 不可执行，卡片右上角标 `未安装` 且选中时底部展示红色提示条并禁用「创建会话」按钮。
2. **目录模式联动**：
   - `当前分支` 与 `独立工作树（.worktrees/<slug>）` 对两种 CLI 完全一致可用。
   - 点击「创建会话」调用 `session.create({ projectPath, title, mode, branch, provider })`，创建成功后自动展开终端栏并聚焦。

### I-04 第二栏终端、底部运行参数条与输入框（`Composer.jsx` & `App.jsx`）

1. **空状态与引擎快速切换**：
   - 未打开任何会话时，`RuntimeBar` / `Composer` 最左侧显示当前待启动引擎切换按钮（`Claude` / `Antigravity` 下拉），修改后调用 `app.runtime({ key: 'provider', value })`，下一次在底部输入框直接回车发消息时即按所选引擎新建会话。
   - 已打开会话时，最左侧显示当前会话锁定的引擎徽标（如 `Antigravity`），点击弹出「在 Claude Code 中接力继续…」快捷菜单项。
2. **动态参数项**：
   - `模式`、`模型`、`推理强度` 三个下拉菜单完全渲染 `state.runtime.modes / models / efforts`。
   - `快速模式（⚡）`：仅当 `state.runtime.supportsFast === true` 时显示；切到 Antigravity 会话时自动隐藏。
   - **热切换反馈**：当 `state.runtime.hotSwitchable === false` 且当前有运行中的 Antigravity 终端时，切换 `模式` 后弹出非错误轻提示：`模式已保存，将在新会话或重连后生效`；切换 `模型` / `推理强度` 时同步写入 `~/.gemini/antigravity-cli/settings.json` 并向活跃终端发送 `/model <id>\n` 或 `/effort <id>\n`。
3. **图形模式（Swttch）自动降级交互**：
   - 若 `settings.interactionMode === 'chat'`：打开 Claude 会话照常显示 Swttch WebView；打开 Antigravity 会话时，第二栏自动切换为原生 `TerminalSession` 视图（显示底部 `RuntimeBar`），并弹出 Toast：`Antigravity 会话暂不支持 Swttch 图形页，已用原生终端打开`。

### I-05 Work 中心 · 共用会话与盘中无缝换引擎（`WorkModals.jsx` & `WorkChat.jsx`）

1. **新建 Work（`NewWorkModal` / `RunOptions`）**：
   - `RunOptions` 首项增加「执行引擎」下拉：`Claude Code` | `Antigravity`（纳管已有会话时锁定为被纳管会话的引擎，避免首次接管用错协议；创建后仍可在下一轮自由切换）。
   - 切换「执行引擎」时，「权限模式」与「模型」下拉列表实时切换为对应引擎的选项列表。
2. **Work 对话内中途切换引擎（`WorkChat.jsx` 共用 Thread 核心交互）**：
   - 顶部 `eyebrow` 显示当前执行引擎标签（`Claude Code` 或 `Antigravity`）。
   - 底部输入栏左下角渲染可交互的引擎选择器 **`引擎：{executorLabel} ▾`**：
     - 当 `work.status` 为 `running` 或 `waiting_user` 时：按钮禁用，`title` 提示 `当前轮次执行中，停止或本轮结束后可切换引擎`；
     - 当 `work.status` 为 `waiting_review`、`interrupted`、`failed` 或未启动的 `queued` 时：点击展开菜单，可切换为另一引擎（若目标 CLI 未安装则禁用并提示）。
   - **切换后的执行效果**：
     - 调用 `work.switchExecutor({ workId: work.id, executor: nextProvider })`，立即更新芯片显示，并在会话事件流追加一条状态记录：`已将下一轮执行引擎切换为 Antigravity（发送消息时将自动同步前情上下文）`；
     - 用户在输入框输入新指令并回车发送时：`WorkCore` 发现当前 `work.executor` 与上一轮 `thread_segment.provider` 不同（或尚无存活同引擎进程），自动启动目标引擎进程（`ACPProcess` 或 `ClaudeProcess`），从 `run_events` + 当前工作树 `git status/diff --stat` 构建 `<thread-handoff>` 前情包拼接在新指令之前投递，实现**同一条 Work 对话跨引擎无缝接力**。
3. **会话信息行（`session-note`）**：
   - 根据 `item.executor` 展示 `Antigravity ACP {cliVersion} · {model} · 模式 {permissionMode}` 或 `Claude Code ...`，不再写死 `Claude Code`。

### I-06 Work 中心 · Turn Checkpoint 代码快照与一键回退（`WorkChat.jsx` & `ContextPanel.jsx`）

1. **自动埋点**：
   - `WorkCore` 在每轮投递开始前创建 `pre` 快照（`第 #N 轮执行前`），在本轮进入 `waiting_review` / `interrupted` / `failed` 时创建 `post` 快照（`第 #N 轮结束后`），将快照元数据同时随 `turn_result` / `checkpoint` 事件下发给前端。
2. **`WorkChat.jsx` 轮次分割线交互**：
   - 每条 `.turn-divider`（「本轮结束 · 12 秒 · 14:30」）右侧，若关联了有效 `preCheckpointId` 且当前 Work 不在 `running` / `waiting_user` 状态，显示轻量按钮 **`↺ 回退到此轮前`**。
   - 点击 **`↺ 回退到此轮前`**：
     - 弹出 `confirmAction` 确认弹窗：
       - 标题：`回退代码至第 #N 轮执行前？`
       - 说明：`工作目录文件将恢复到本轮开始前的快照状态（回退前会自动备份当前代码为可恢复快照，且下一轮会自动通知智能体重读文件）。`
     - 确认后调用 `checkpoint.revert({ workId: work.id, checkpointId })`：
       - 若为非隔离 `project` 目录且返回外部修改冲突，再次弹出明确确认框询问是否强制覆盖（`force: true`）；
       - 回退成功后弹出 Toast `已回退代码至第 #N 轮前状态`，对话流插入一条醒目的回退记录卡片，右侧变更文件列表同步刷新。
3. **右侧 `ContextPanel.jsx` 快照列表与「撤销回退」**：
   - 在 `变更文件` 标签页顶部展示「代码检查点」折叠条（显示最近快照数量；若最近一次操作是回退且存在 `undo` 快照，直接提供 **`撤销上次代码回退`** 按钮，点一下即可无损恢复回退前的现场）。

### I-07 设置页与 MCP 管理（`SettingsModal.jsx` & `Modals.jsx`）

1. **设置 → 界面与会话（`SettingsModal.jsx`）**：
   - 新增「CLI 引擎」设置组：
     - 展示两行实时环境检测状态徽章：`Claude Code`（绿点 `已就绪 · <path>` 或黄点 `未检测到`）与 `Antigravity CLI`（绿点 `已就绪 · <path>` 或黄点 `未检测到`）；
     - 「默认新建会话引擎」分段按钮：`Claude Code` | `Antigravity`；
     - 「扫描 Antigravity 历史会话」开关（默认开启）。
2. **MCP 服务弹窗（`McpModal` in `Modals.jsx`）**：
   - 弹窗标题栏下方增加分段切换：`Claude Code 配置` | `Antigravity 配置`。
   - 切到 `Antigravity 配置` 时：
     - 读取/修改 `~/.gemini/config/mcp_config.json`；
     - 传输方式下拉提供 `stdio` 与 `HTTP (Streamable)`，下方说明提示 `Antigravity 仅支持 stdio 与 Streamable HTTP，不支持旧版 SSE`；
     - 顶部操作栏提供 **`从 Claude 导入`** 按钮：一键将 Claude 配置中兼容的 `stdio` / `http` 服务合并写入 Antigravity 配置（同名服务不覆盖，自动跳过 `sse` 并提示数量）。

---

## 4. 验证与回归清单

1. **脚本回归（全绿要求）**：
   - `./scripts/check-session-regressions.sh`：验证 Claude + Antigravity 双扫描器、标签清洗、参数持久化、终端命令拼接、Swttch 自动降级、跨引擎 `session.handoff`、双源 MCP 读写与导入。
   - `./scripts/test-work.sh`：验证 SQLite Schema `v1 → v2` 迁移、`ACPProcess`（使用本地 `fake-agy-acp.py` 替身验证初始化、流式 chunk、工具调用、权限审批卡片、中断取消）、Work 内中途切换引擎（`claude ↔ antigravity` 含 `<thread-handoff>` 注入）、Turn Checkpoint 创建与一键回退（含 `git gc` 安全性、共享目录外部修改保护、`<workspace-reverted-notice>` 注入）。
   - `./scripts/test-git.sh`：确保原有 Git 工作台回归全绿。
2. **构建与 `agent-desktop` 实机桌面验收**：
   - 执行 `./scripts/build-app.sh --dev` 产出 `dist-dev/ClaudePickerDev.app`；
   - 启动 `ClaudePickerDev.app`，通过 `agent-desktop` 逐项验证侧栏双引擎会话展示与筛选、新建会话引擎选择、Work 引擎切换与检查点回退控件、设置页 CLI 状态与 MCP 引擎切换。
