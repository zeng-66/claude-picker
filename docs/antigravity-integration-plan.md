# Antigravity CLI (`agy`) 集成技术方案与可行性评估

> 状态：**技术方案（待前置 PoC 核验后进入实施）**
> 日期：2026-11-18
> 基线分支：`codex/wt-20261118`（提交 `325e9f9`）
> 工作区：`/Users/zcl/project/claude-picker/.worktrees/codex-wt-20261118`
> 长期架构评估：[多智能体控制面架构深度评估（共用 Thread + Driver/Adapter + Turn Checkpoint）](multi-agent-architecture-evaluation.md)

---

## 1. 可行性总结：按本方案确实可以落地吗？

**明确结论：可以落地，且没有架构级死胡同；但需要按阶段落地，并接受个别能力的协议边界（不可跨 CLI 原生接管同一条底层会话、Swttch 图形模式只服务 Claude）。**

为什么敢确认「能落地」：
1. **底层能力已对齐**：已在本机 `agy --help` / `agy acp --help` 实测确认 `agy` 具备原生恢复（`--conversation <id>`）、模式/模型/强度参数（`--mode` / `--model` / `--effort`）、初始提示词（`-i`）、流式 JSON（`--input-format/output-format stream-json`）与标准宿主协议（`agy acp`）。
2. **本项目自身已经为多执行器留过口子**：
   - 终端区本就用 `Store.panes[key]` 按会话独立托管多个 `LocalProcessTerminalView`，把 `exec claude` 抽象为按 `provider` 派发几乎无阻力；
   - `WorkStore.swift` 的 `runs` 表建表时就已经带了 `executor TEXT NOT NULL DEFAULT 'claude'`，`WorkModels.swift` 的 `WorkRun.json` 也已有 `executor` 字段。
3. **4 项未知点均有兜底路径（不存在「验证失败就彻底做不了」的单点阻塞）**：
   - 最关键的 4 个未知点（索引位置、新建 UUID、OSC 忙闲序列、Work 协议）都已在第 6 节列出实机验证命令；即使出现最坏情况（如索引是二进制 `.pb`、或 `--conversation` 不能预生成新 UUID、或 `agy` 不发 OSC 7501），本方案在第 5 节也全部给出了可落地的替代方案。

| 阶段 | 范围 | 落地确定性 | 核心依据与前置约束 |
| --- | --- | --- | --- |
| **Phase 1 (P0)** | 多引擎会话树 + 原生终端启动/恢复 + 运行参数同步 + 设置页诊断 | **确定可落地（高把握）** | `agy` CLI 交互参数与 `transcript.jsonl` 已核实；第 6 节 PoC-1/2/3 只影响实现细节（直读索引 vs 回退扫描），不阻塞上线。 |
| **Phase 2 (P1)** | Work 中心多执行器支持 + 上下文占用 + MCP 配置管理 | **确定可落地（中工作量）** | `WorkStore` 已预留 `executor`；最稳路线是走官方 `agy acp`（JSON-RPC stdio），不依赖内部 `stream-json` 是否开放审批通道。 |
| **Phase 3 (P2)** | 图形聊天（Swttch）适配、用量额度、Windows Electron 同步 | **带边界落地** | Swttch 上游绑定 Claude Code，Antigravity 会话在图形模式下**自动降级回原生终端**；`agy` 无公开 HTTP 额度接口，不伪造 Claude 用量条；Windows 端在 macOS P0 稳定后同步补齐。 |

---

## 2. 已核实的事实基线

### 2.1 本项目当前架构与耦合点

| 层 | 现状源码位置 | 对 Claude Code 的强绑定点 |
| --- | --- | --- |
| 会话模型与扫描 | `Sources/ClaudeDeck/Models.swift` | `SessionScanner` 硬编码扫描 `~/.claude/projects/*/*.jsonl`；`Session` 无引擎字段；`Store.key(cwd:sid:)` 仅用 `cwd + sid` 拼键。 |
| 运行参数与配置 | `Sources/ClaudeDeck/Models.swift`、`main.swift` | `PermissionMode` / `ModelChoice` / `EffortChoice` 为 Claude 枚举；`ClaudeConfig` 读写 `~/.claude/settings.json`；热切换发送 `Shift+Tab`、`/model`、`/effort`、`/fast`。 |
| 原生终端 | `Sources/ClaudeDeck/TerminalPane.swift` | 拼接 `exec claude --resume/--session-id ...`；依赖 Claude 的 OSC 7501 与 OSC 0 spinner（`◐ ◑` / `✳`）判定忙闲。 |
| 上下文统计 | `Sources/ClaudeDeck/ThirdPane/ContextUsage.swift` | 读取 Claude jsonl 末尾 `type == "assistant"` 的 `message.usage`（`cache_read_input_tokens` 等）。 |
| 用量额度 | `Sources/ClaudeDeck/Models.swift`、`main.swift` | `UsageFetcher` 读 Keychain `Claude Code-credentials` 调 Anthropic OAuth usage 接口。 |
| 图形聊天 | `Sources/ClaudeDeck/ChatBackendManager.swift`、`ChatWebView.swift` | 拉起 `~/project/swttch` 的 Node backend，内部驱动 Claude CLI。 |
| Work 执行器 | `Sources/ClaudeDeck/Work/ClaudeExecutor.swift`、`WorkCore+Execution.swift`、`WorkModels.swift`、`WorkStore.swift` | `ClaudeProcess` 硬编码 `claude -p --output-format stream-json --input-format stream-json` 与 `control_request/can_use_tool`；但 `WorkStore.schemaV1` 的 `runs` 表已有 `executor TEXT NOT NULL DEFAULT 'claude'`，`WorkRun.json` 已有 `executor` 字段。 |
| MCP 管理 | `Sources/ClaudeDeck/ThirdPane/McpService.swift` | 直接读写 `~/.claude.json`（user / local）与 `<project>/.mcp.json`（project），自己走 stdio/HTTP `initialize -> tools/list` 探测。 |
| 网页外壳 | `Web/src/shell/Sidebar.jsx`、`Composer.jsx`、`Modals.jsx`、`work/WorkModals.jsx`、`work/SettingsModal.jsx` | 侧栏标题固定 `Claude Code`；`SessionModal` / `NewWorkModal` 无引擎选项；`Composer` / `RuntimeBar` 固定展示 `fast` 开关。 |
| Windows 桌面端 | `Desktop/runtime.cjs` | 同样只扫 `~/.claude/projects` 并以 Claude 会话格式解析。 |

### 2.2 本机 `agy`（Antigravity CLI）已实测事实

通过 `agy --help`、`agy acp --help`、`agy mcp --help`、内置技能文档及当前对话的本地转录文件，已确认以下能力：

1. **二进制位置**：`/Users/zcl/.local/bin/agy`。
2. **核心交互参数**（`agy --help` 实测）：
   - 会话恢复：`--conversation <id>`、`-c` / `--continue`
   - 工作区与目录：`--project <id|name>`、`--new-project`、`--add-dir <dir>`
   - 运行模式与参数：`--mode <accept-edits|auto|plan>`、`--model <model>`、`--effort <low|medium|high|xhigh|max>`、`--dangerously-skip-permissions`、`--sandbox`
   - 初始提示词：`-i` / `--prompt-interactive`
   - 非交互结构化：`--print` / `-p`、`--input-format <text|stream-json>`、`--output-format <text|json|stream-json>`、`--json-schema`
   - 子命令：`acp`（Agent Client Protocol stdio JSON-RPC 服务）、`models`、`agents`、`mcp`（`add/remove/list/enable/disable`）、`plugin`
3. **配置文件与本地数据路径**：
   - CLI 全局配置：`~/.gemini/antigravity-cli/settings.json`（项目级支持 `.antigravity/settings.json` 与 `.agents/`）
   - 全局 MCP 配置：`~/.gemini/config/mcp_config.json`（Schema 为 `mcpServers`，支持 stdio `command/args/env` 与 Streamable HTTP `url`）
   - 会话转录：`~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`，已确认每行包含字段：
     - `step_index`、`source`、`type`（`USER_INPUT` / `PLANNER_RESPONSE`）、`status`、`created_at`
     - `content`、`model`、`input_tokens`、`cache_read_tokens`、`output_tokens`、`tool_calls`

> **当前信息缺口说明**：受当前执行环境沙箱隔离限制，`ls ~/.gemini/antigravity-cli/` 与运行 `agy models` / `agy agents` 被系统拒绝（`operation not permitted` on `installation_id`）。因此本文列出 4 项必须在实施编码前完成的实机 PoC（见第 5 节）。

---

## 3. 核心架构设计

### 3.1 引入 `AgentProvider` 抽象（单一扩展点）

在 `Sources/ClaudeDeck/` 新增领域枚举与能力描述（建议拆出 `Sources/ClaudeDeck/Provider/` 目录），让多 CLI 差异收口在 Provider 层，而非在业务代码里堆砌分支：

```swift
enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case claude
    case antigravity

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        }
    }

    var cliCommand: String {
        switch self {
        case .claude: return "claude"
        case .antigravity: return "agy"
        }
    }
}
```

### 3.2 复合键与持久化向后兼容

1. **会话键**：`Store.key(provider:cwd:sid:)` 改为 `"\(provider.rawValue)|\(realpath(cwd))|\(sid)"`。
2. **`Session` 模型**：增加 `let provider: AgentProvider`（默认 `.claude`），用于前端徽标显示、终端启动命令分发与上下文解析路由。
3. **`tree.json` 兼容**：现有 `tree.json` 中的 `sessionOrder`、`hiddenSessions`、`customTitles`、`sessionBranches` 均以 `sessionId`（UUID）为键。Antigravity 的 `conversationId` 同为 UUID，天然不与 Claude UUID 碰撞，**旧版 `tree.json` 无需破坏性迁移**；若未来需要区分，可在 `sessionProviders: [String: String]` 中记录新建但尚未落盘的会话归属。

### 3.3 二进制探测（`CliLocator`）

将 `Work/ClaudeExecutor.swift` 中的 `ClaudeLocator` 上提到共用层 `CliLocator`：
- `CliLocator.find(.claude)`：沿用 `CLAUDE_PICKER_CLAUDE_BIN` → `~/.local/bin/claude` / `~/.claude/local/claude` / `/opt/homebrew/bin/claude` / nvm / login shell `PATH`。
- `CliLocator.find(.antigravity)`：检查 `CLAUDE_PICKER_AGY_BIN` → `~/.local/bin/agy` → `/opt/homebrew/bin/agy` → `/usr/local/bin/agy` → `LoginEnv.shared.find("agy", ...)`。

---

## 4. 各模块详细技术方案

### 4.1 Phase 1：会话扫描、终端、运行参数与前端外壳

#### A. 会话扫描（`AgySessionScanner`）
- 与 `SessionScanner`（Claude）并行扫描并在 `Store.buildProjects()` 中按 `cwd` 合并聚合、按修改时间倒序排列。
- **解析逻辑**：
  1. 从索引中发现属于有效目录的 `conversationId` 与 `cwd`（具体索引路径由 PoC-1 确认）。
  2. 读取 `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`：
     - 头部取第一条 `type == "USER_INPUT"` 且 `source == "USER_EXPLICIT"` 的 `content`（剥离 `<USER_REQUEST>` / `<ADDITIONAL_METADATA>` 等包装标签）做回退标题。
     - 尾部取更新时间戳 `mtime`（若无标题索引，可按最后一条有效消息或 `customTitles` 显示）。
     - 若文件记录所属分支（需 PoC-1 核实是否有分支记录，否则 `lastGitBranch` 对 `agy` 返回 `nil`）。

#### B. 上下文占用（`ContextUsage.swift`）
- `ContextUsage.read(session: Session)` 按 `session.provider` 分发：
  - `.claude`：保持现状。
  - `.antigravity`：倒序扫描 `transcript.jsonl` 尾部，找到最后一条 `type == "PLANNER_RESPONSE"` 且 `input_tokens + cache_read_tokens + output_tokens > 0` 的行，映射为 `ContextUsage`（`used = input_tokens + cache_read_tokens + output_tokens`，`model` 取该行 `model` 字段）。窗口容量按模型名映射表或默认上下文上限推断。

#### C. 原生内嵌终端（`TerminalPane.swift`）
- `TerminalSession.init` 增加 `provider: AgentProvider` 参数及结构化启动规格 `TerminalLaunchSpec`：

| 操作 | `.claude` | `.antigravity` |
| --- | --- | --- |
| 恢复已有会话 | `exec claude --resume <sid> <flags>` | `exec agy --conversation <sid> <flags>` |
| 新建会话 | `exec claude --session-id <newId> <flags> [--name <name>] [-- <prompt>]` | `exec agy <flags> [-i <prompt>]`（若 PoC-2 验证 `--conversation <newId>` 可预设新会话则带上；否则启动后扫描关联） |
| `execName` | `"claude"` | `"agy"` |

- **参数映射（`--mode` 等差异）**：
  - Claude：`--permission-mode <auto|manual|plan|acceptEdits|bypassPermissions|dontAsk>`、`--model <opus|sonnet|haiku|fable>`、`--effort <medium|low|high|xhigh|max>`
  - Antigravity：`--mode <accept-edits|auto|plan>`、`--model <modelId>`、`--effort <low|medium|high|xhigh|max>`（`--dangerously-skip-permissions` 仅作为显式选项，不默认开启）
- **忙闲信号判定**：
  - 保留 OSC 7501 / OSC 0 监听；
  - 若 PoC-3 发现 `agy` 不输出同等 OSC 忙闲序列，则对 `.antigravity` 会话启用**组合兜底**：
    1. 终端数据输出窗口期（沿用现有防抖 + 用户输入抑制 `userInputUntil`）；
    2. 对应 `transcript.jsonl` 文件 `mtime` / 大小变化 + 子进程树活跃 CPU 采样（仅在 `.antigravity` 且无 OSC 7501 信号时激活）。

#### D. 运行参数与配置中心（`AgyConfig` + `Store.snapshot()`）
- 新增 `AgyConfig`，读写 `~/.gemini/antigravity-cli/settings.json`（保留未知键，采用原子写盘 `Data.write(..., options: .atomic)`，避免覆盖用户的其他配置）。
- `Store.snapshot()` 的 `runtime` 对象增加引擎上下文，使前端自动适配当前选中的会话引擎：
  ```json
  "runtime": {
    "provider": "antigravity",
    "mode": "auto",
    "model": "gemini-...",
    "effort": "high",
    "fast": false,
    "supportsFast": false,
    "runtimeSyncNote": "切换模式将在下次启动或重连时生效",
    "modes": [...],
    "models": [...],
    "efforts": [...]
  }
  ```
- **运行时热更新边界**：
  - `agy` 终端内支持斜杠命令（如 `/model`），但不具备 Claude 的 `Shift+Tab` 四态循环。对于终端内不支持无重启热切的选项（如 `--mode`），选择后立即写入 `settings.json`，并在状态栏/Toast 明确告知「已保存，将在新会话/重连时生效」，不做无效的按键模拟。
- **模型列表来源**：启动时异步执行一次 `agy models`（或从已知模型清单回退）缓存可用模型，避免每次切会话阻塞主线程。

#### E. 网页外壳（`Web/src/shell/`）
1. **`Sidebar.jsx`**：
   - 会话行（`.session-row`）增加轻量引擎徽标（如 `C` / `A` 或独立 SVG 图标），`title` tooltip 标明引擎名。
   - 标题区或搜索栏支持按引擎快速过滤（全部 / Claude / Antigravity），默认「全部」混排按活跃时间排序。
   - **Usage 用量栏**：明确标注归属（Claude 额度），未检测到 Claude 凭据或当前全为 Antigravity 会话时保持不干扰或折叠提示，避免误导。
2. **`Modals.jsx`（`SessionModal`）**：
   - 新增「执行 CLI」二选一卡片/分段按钮：`Claude Code` vs `Antigravity`（若本机未检测到 `agy`，选项置灰并提示安装路径；记忆用户上次选择）。
   - Bridge `session.create` 入参新增可选 `provider`（默认 `"claude"`），新建分支与 `worktree` 逻辑完全复用，不重复造轮子。
3. **`Composer.jsx`（`RuntimeBar` / `Composer`）**：
   - 根据 `runtime.provider` 与 `runtime.supportsFast` 控制「快速模式」闪电按钮的显隐；弹窗菜单动态渲染当前 `runtime.modes` / `runtime.models` / `runtime.efforts`。
4. **`work/SettingsModal.jsx`**：
   - 在「界面与会话」或新增「CLI 引擎」区块展示 `claude` 与 `agy` 的探测路径与可用状态、默认新建会话引擎、以及「扫描 Antigravity 历史会话」开关。
5. **图形聊天降级（`Store.open`）**：
   - 若用户全局开启了 `interactionMode == .chat`（Swttch），但点击或新建的是 `.antigravity` 会话：自动以原生终端方式打开，并向网页发送轻提示 `chatFallbackForProvider`（「Antigravity 会话暂使用原生终端打开」），不破坏 Swttch 现有体验。

#### F. 不同 CLI 会话切换与跨 CLI「接力续聊」边界
1. **不同 CLI 会话在 UI 中自由切换：完全支持（Zero Risk）**
   - 每个历史会话归属一个原生 `provider`（`.claude` 或 `.antigravity`）。`Store` 使用复合键 `provider|cwd|sid` 缓存多终端 `panes`：
     - 点 Claude 会话 → `TerminalSession` 跑 `exec claude --resume <sid>`；
     - 点 Antigravity 会话 → `TerminalSession` 跑 `exec agy --conversation <sid>`；
     - 相互点击切换只切换右侧展示的终端视图，后台各自进程保持存活、互不干扰，状态栏也随当前激活会话自动切到对应引擎的参数列表。
2. **同一条会话跨 CLI 直接 `--resume` 续聊：原生协议不兼容（不能直接混用）**
   - Claude Code 会话存储在 `~/.claude/projects/<编码路径>/<sid>.jsonl`（Anthropic 消息结构 + `parentUuid` / `isSidechain`）；
   - Antigravity CLI 会话存储在 `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`（`step_index` / `USER_INPUT` / `PLANNER_RESPONSE` 等）及 CLI 内部会话状态；
   - 两个 CLI **只识别各自目录和格式**，直接把 Claude 的 `sessionId` 传给 `agy --conversation <claude-sid>` 会找不到会话（反之亦然），不能无损原生接管。
3. **跨 CLI 续聊的可行落地方案：显式「接力（Handoff / Fork）新建会话」**
   - 若需要把 Claude 聊到一半的任务转交给 Antigravity（或反向），可在会话右键菜单增加 **「转到 Antigravity 继续…」 / 「转到 Claude Code 继续…」**：
     1. **提取与压缩上下文**：宿主解析原会话 `.jsonl`（提取 `summary/ai-title`、最近 N 轮用户消息与助手结论、改动的文件列表 / 当前 `gitBranch`），拼成一段结构化交接上下文；
     2. **以新会话启动目标 CLI**：在相同 `cwd` 下以 `agy -i "<交接上下文>"`（或 `claude --session-id <newId> -- "<交接上下文>"`）创建一条**新的**目标引擎会话；
     3. **独立展示、不覆盖原会话**：原 Claude 会话保留原样只读可追溯，新创建的 Antigravity 会话作为一条独立节点出现在项目树下（可附带「接力自 `<原会话标题>`」标注）。

---

### 4.2 Phase 2：Work 中心支持 Antigravity 执行器

`Work` 中心目前通过结构化进程驱动任务（[WorkCore+Execution.swift](file:///Users/zcl/project/claude-picker/.worktrees/codex-wt-20261118/Sources/ClaudeDeck/Work/WorkCore+Execution.swift)），要求支持：**会话建立、多轮发消息、流式文本增量、工具调用与结果、中断控制、权限/提问异步挂起与恢复**。

#### A. 执行器协议抽象
将 `ClaudeProcess` 抽象为统一接口（放在 `Sources/ClaudeDeck/Work/AgentExecutor.swift`）：

```swift
protocol AgentExecutorProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func start() throws
    @discardableResult func sendUserMessage(_ text: String) -> Bool
    @discardableResult func respondPermission(requestId: String, allow: Bool, updatedInput: JSONValue?, message: String?) -> Bool
    @discardableResult func interrupt(requestId: String) -> Bool
    func shutdown(grace: TimeInterval)
    func terminateAndWait(timeout: TimeInterval) -> Bool
}
```
`ClaudeProcess` 遵循该协议，输出现有 `ExecutorEvent`。`WorkCore` 只持有 `any AgentExecutorProcess`，不直接耦合具体 CLI 实现。

#### B. Antigravity 执行器两条候选技术路线对比

| 维度 | 路线 A：`agy -p --input-format stream-json --output-format stream-json` | 路线 B：`agy acp`（Agent Client Protocol, stdio JSON-RPC） |
| --- | --- | --- |
| 协议形态 | NDJSON 行流，类似 Claude `-p stream-json` | 官方公开标准化的 JSON-RPC 2.0 over stdio |
| 交互式权限/提问审批 | **待 PoC-4 确认**：需验证 `agy` 的 `stream-json` 是否支持双向 `control_request / can_use_tool` 握手；若仅单向输出，则无法满足 Work 的「待回答/审批挂起」 | **原生支持**：ACP 协议天然定义了 `session/request_permission`、流式通知、工具调用与 `session/cancel` |
| 长期稳定性 | 依赖 CLI 内部 `stream-json` 事件格式演进 | 官方承诺为 IDE/宿主稳定协议（Zed/Xcode/JetBrains 共用） |
| 实施成本 | 若与 Claude 同构则低；若缺失控制通道则无法支撑完整 Work 语义 | 需写一个约 250–350 行的 Swift JSON-RPC stdio 客户端 |

**建议选型**：优先验证路线 A 是否包含完整权限控制请求；若不包含或差异较大，**直接采用路线 B（`agy acp`）**，这是最稳妥、面向未来的官方接入方式。

#### C. SQLite Schema 迁移（`WorkStore.swift`）
- 当前 `schemaVersion = 1`，`runs` 表已有 `executor TEXT NOT NULL DEFAULT 'claude'`，但 `works` 表缺少默认执行器列。
- 升级 `schemaVersion = 2`（复用 `WorkStore.migrate` 内置的 `VACUUM INTO` 升级前备份机制）：
  - `ALTER TABLE works ADD COLUMN executor TEXT NOT NULL DEFAULT 'claude';`
  - 新建 Work 时记录 `work.executor`，创建 Run 时同步写入 `run.executor`；`NewWorkModal` / `RunOptions` 增加执行器下拉框。
  - 注意：`WecomClaudeChat`（企业微信机器人对话）Phase 2 可保持走 `.claude`，后续再按需配置默认引擎。

---

### 4.3 Phase 3：MCP 服务管理与跨平台同步

1. **MCP 服务（`McpService.swift` & `Modals.jsx`）**
   - `McpModal` 顶部增加作用域切换 Tab：`Claude Code` / `Antigravity`。
   - `McpService` 扩展 `McpProviderConfig`：
     - `.claude`：读写 `~/.claude.json` + `<project>/.mcp.json`（现状不变）。
     - `.antigravity`：读写 `~/.gemini/config/mcp_config.json`（`mcpServers` 对象）。注意 Antigravity 文档明确指出**不支持旧版 HTTP+SSE（2024-11-05）**，UI 添加 HTTP 服务时应给出对应提示。
   - 提供「从 Claude 导入到 Antigravity」辅助按钮（仅拷贝 `stdio` 与 Streamable HTTP 配置）。
2. **Windows Electron（`Desktop/runtime.cjs`）**
   - 在 macOS Phase 1 稳定并确定所有文件结构后，把 `AgySessionScanner` 与 `agy` 启动参数逻辑按 Node.js 复用到 `Desktop/runtime.cjs`。

---

## 5. 全量兼容性场景清单与解决方案

对仓库现有全部模块（[Models.swift](file:///Users/zcl/project/claude-picker/.worktrees/codex-wt-20261118/Sources/ClaudeDeck/Models.swift)、[main.swift](file:///Users/zcl/project/claude-picker/.worktrees/codex-wt-20261118/Sources/ClaudeDeck/main.swift)、[TerminalPane.swift](file:///Users/zcl/project/claude-picker/.worktrees/codex-wt-20261118/Sources/ClaudeDeck/TerminalPane.swift)、[ContextUsage.swift](file:///Users/zcl/project/claude-picker/.worktrees/codex-wt-20261118/Sources/ClaudeDeck/ThirdPane/ContextUsage.swift)、[McpService.swift](file:///Users/zcl/project/claude-picker/.worktrees/codex-wt-20261118/Sources/ClaudeDeck/ThirdPane/McpService.swift)、[WorkCore.swift](file:///Users/zcl/project/claude-picker/.worktrees/codex-wt-20261118/Sources/ClaudeDeck/Work/WorkCore.swift)、[Desktop/runtime.cjs](file:///Users/zcl/project/claude-picker/.worktrees/codex-wt-20261118/Desktop/runtime.cjs) 及网页外壳）做全量交叉排查后，共梳理出 **13 个兼容性场景** 及其落地解法：

### 5.1 兼容性总览表

| 编号 | 兼容性场景 | 潜在冲突 / 问题 | 解决方案 | 落地阶段 |
| --- | --- | --- | --- | --- |
| **C1** | 多引擎会话共存与界面切换 | `Store.key(cwd:sid:)` 未区分引擎；切换时状态栏与终端混串 | 键升级为 `provider\|cwd\|sid`；多 `TerminalSession` 各自保活；`snapshot().runtime` 随激活会话自动切换 | Phase 1 |
| **C2** | 跨 CLI 续聊（Claude 会话转由 `agy` 继续，或反之） | 两个 CLI 的存储目录与 JSONL 格式完全不兼容，不能直接用对方 ID `--resume` / `--conversation` | 禁止直接混传 ID；右键菜单提供「接力新建会话（Handoff）」，提取原对话摘要与分支并以 `agy -i` / `claude --` 派生新会话 | Phase 1 / 1.5 |
| **C3** | 「作为 Work 继续」（`adoptSession` 纳管会话） | `WorkCore.create` 的 `adoptSession` 目前只用 `ClaudeProcess` 拉起；把 `.antigravity` 会话转入 Work 会用错 CLI 并报错 | Phase 1 阶段在 UI/Bridge 显式拦截 `.antigravity` 会话的「作为 Work 继续」（提示原因或先转接力）；Phase 2 接入 `AgyExecutor` 后按 `session.provider` 继承为 `work.executor` | Phase 1 拦截 / Phase 2 支持 |
| **C4** | 图形聊天模式（`interactionMode == .chat` / Swttch）混用 | 全局开启图形聊天时，点击或新建 Antigravity 会话若走 `ChatHost` 会失败（Swttch 只驱动 Claude） | `Store.open` / `openNew` 按 `provider` 分流：`.antigravity` 强制走原生 `TerminalSession`，发轻提示告知原因，不影响 `.claude` 会话继续用 Swttch | Phase 1 |
| **C5** | 会话 ⇄ Git 分支绑定（`followSessionBranch` & `revealBranchSessions`） | Claude 每条 jsonl 自带 `gitBranch`；若 `agy` 的 `transcript.jsonl` 未记录分支，打开会话自动切分支和选分支定位会话会静默失效 | 复用 `Models.swift` 已有的 `sessionBranches` 映射：宿主在创建/打开/活跃 `.antigravity` 会话时记录当前 Git 分支；`lastGitBranch` 先查记录文件，缺失时回退读 `sessionBranches` | Phase 1 |
| **C6** | 模型上下文环与详情弹窗（`app.context` / `ContextUsage`） | Claude 的 `cache_creation_input_tokens` 与 `200k/1M` 推断逻辑不完全匹配 Antigravity；Gemini 等模型窗口可能是 1M/2M | `ContextUsage` 按 `provider` 解析 `transcript.jsonl` 的 `input_tokens + cache_read_tokens + output_tokens`；跳过值为 0 的分段；按模型表推断窗口上限，未知模型只展示已用 token 并标明「窗口容量未知」 | Phase 1 |
| **C7** | 运行参数差异与运行时热同步（模式 / 模型 / 强度 / `fast`） | Claude 6 种权限模式（`Shift+Tab` 4 态循环）+ `fastMode` 开关 vs `agy` 3 种 `--mode`（`accept-edits\|auto\|plan`）+ 完整模型 ID；`agy` 不一定支持无重启热切模式 | `snapshot().runtime` 下发当前引擎合法枚举与 `supportsFast` / `hotSwitchable` 能力位；`ClaudeConfig` 与 `AgyConfig` 各自独立写盘；对不支持热切的 `agy` 参数提示「已保存，将在新会话或重连时生效」 | Phase 1 |
| **C8** | 悬浮终端 / 输入框发送（`app.prompt` → `TerminalSession.submit`） | `submit()` 通过括号粘贴 + `\r` 往 PTY 注入提示词并硬编码 `readyAt = +1.6s`；`agy` 启动耗时或 TUI 对粘贴/回车的处理可能与 Claude 不同 | 按 `provider` 配置就绪检测（首帧提示符到达或独立缓冲时间），PoC 实测多行内容在 `agy` TUI 的括号粘贴行为；未启动会话直接新建时可走 `agy -i <prompt>` | Phase 1 |
| **C9** | 终端忙闲圆圈、后台未读点与桌宠联动 | `onBusy` 依赖 Claude 的 OSC 7501 / OSC 0 spinner；若 `agy` 不输出相同 OSC，侧栏橙色转圈、未读绿点与桌宠动作会集体失灵 | 保留 `userInputUntil` / `suppressUntil` 防抖抑制；PoC-3 核实 OSC 序列，若缺失则对 `.antigravity` 启用「`transcript.jsonl` 增量写入 + 子进程活跃 CPU 采样」组合判定 | Phase 1 |
| **C10** | 会话标题提取、标签清洗与自动刷新（`scheduleTitleRefresh`） | Claude 有 `ai-title` / `summary` 记录；`agy` 首条 `USER_INPUT` 可能包裹 `<USER_REQUEST>` / `<ADDITIONAL_METADATA>` 标签，直接截断展示会很难看 | 清洗包装标签（剥离 `<USER_REQUEST>`、`<ADDITIONAL_METADATA>` 等系统块）、压缩空白生成可读标题；若本地索引有标题优先采用，同时保留 `customTitles` 用户重命名优先级 | Phase 1 |
| **C11** | Worktree 隔离路径与符号链接匹配 | 在 `.worktrees/<branch>` 创建会话时，若 `agy` 内部保存的是主仓或未解析 symlink 的路径，会导致会话挂错项目或孤立 | 启动 `agy` 时强制设置子进程 `currentDirectory = realpath(cwd)`，避免传入冲突的全局 `--project` 别名；扫描汇聚统一走 `resolvingSymlinksInPath()` 匹配主项目 | Phase 1 |
| **C12** | 本机登录态、环境注入与 MCP 协议差异 | 用户可能只登录其中一个 CLI；Finder 启动缺失 PATH；`agy` 的 MCP 不支持旧版 HTTP+SSE；`UsageFetcher` 仅适用于 Anthropic OAuth | 设置页分别检测 `claude` / `agy` 可用性与登录提示；子进程统一注入 `LoginEnv.shared.environment`；MCP 导入自动识别并拦截旧版 SSE 提示改用 `mcp-remote`；Usage 条仅展示 Claude 额度 | Phase 1 / Phase 3 |
| **C13** | 双端实现同步（macOS Swift vs Windows Electron）与无 Xcode 构建 | 只改 Swift 层会让 `Desktop/runtime.cjs` 掉队；引入非 CommandLineTools 框架会破坏 `./scripts/build-app.sh` | Swift 侧仅依赖 Foundation / AppKit / SQLite3；`Web/src/shell` 对 `provider` 字段做向后兼容默认（`session.provider ?? 'claude'`），确保 `Desktop/runtime.cjs` 未改造前也不崩溃，Phase 3 再对齐 Windows 端 | Phase 1 兼容 / Phase 3 对齐 |

### 5.2 重点兼容场景细化说明

#### C2 & C3：会话归属与流转矩阵
为了避免用户对「哪条会话能直接点、哪条能接力、哪条能转 Work」产生困惑，明确四象限流转规则：

| 当前会话 | 目标操作 | 行为与结果 |
| --- | --- | --- |
| Claude 会话 | 点击打开 / 切换 | `exec claude --resume <sid>`（或 Swttch 图形模式） |
| Antigravity 会话 | 点击打开 / 切换 | `exec agy --conversation <sid>`（图形模式下自动回落原生终端并提示） |
| Claude 会话 ↔ Antigravity 会话 | 在跨 CLI 中接力续聊 | **右键「在另一 CLI 中继续」** → 提取摘要与分支，以新 UUID 派生一条新会话，原会话只读保留 |
| Antigravity 会话 | 「作为 Work 继续」（`adoptSession`） | **Phase 1**：按钮置灰提示需 Phase 2 支持；**Phase 2**：由 `AgyExecutor` 接管运行并同步写入 `works.executor = 'antigravity'` |

#### C7：运行参数映射规范
两组配置彻底隔离读写，防止污染彼此的 `settings.json`：

| 状态栏项 | Claude (`~/.claude/settings.json`) | Antigravity (`~/.gemini/antigravity-cli/settings.json`) |
| --- | --- | --- |
| 模式 | `auto` / `manual` (`default`) / `plan` / `acceptEdits` / `bypassPermissions` / `dontAsk` | `auto` / `accept-edits` / `plan` |
| 模型 | `opus` / `sonnet` / `haiku` / `fable` | 从 `agy models` 动态获取并缓存，支持配置回退列表 |
| 推理强度 | `low` / `medium` / `high` / `xhigh` / `max` | `low` / `medium` / `high` / `xhigh` / `max` |
| 快速模式 | `fastMode` 布尔开关 + `/fast` | 隐藏快速开关（`supportsFast = false`），避免误操作 |

---

## 6. 开工前必须先做的 4 项 PoC 验证清单

> 以下 4 项均因当前沙箱权限限制未能读取 `~/.gemini/antigravity-cli/` 而列为前置阻塞检查。确认这 4 项后，Phase 1/2 即可无歧义编码；即使其中某项得出受限结论，第 5 节已给出对应兜底方案。

### PoC-1：会话与工作目录（`cwd`）索引位置
- **要确认的问题**：`agy` 把每个 `<conversation-id>` 属于哪个项目目录（`cwd`）、会话标题/创建时间保存在 `~/.gemini/antigravity-cli/` 的哪个文件里？是 JSON、SQLite 还是 protobuf（`.pb`）？
- **核验命令**：
  ```bash
  ls -la ~/.gemini/antigravity-cli/
  find ~/.gemini/antigravity-cli -maxdepth 2
  ```
- **通过标准**：明确 `AgySessionScanner` 无需猜测路径即可准确还原每个 `conversationId` 对应的 `cwd` 与时间；若是 `.pb` 二进制而非 JSON，需确认是否可通过其他 JSON/SQLite 文件或读取 `transcript.jsonl` 元数据 / 宿主自建映射索引获取。

### PoC-2：新建会话 ID 与首次恢复机制
- **要确认的问题**：执行 `agy --conversation <新生成的UUID>` 时，`agy` 是否允许直接创建并绑定该 UUID，还是仅用于恢复已存在的会话？
- **核验命令**：
  ```bash
  agy --conversation "$(uuidgen | tr '[:upper:]' '[:lower:]')" -p "hi"
  ```
- **通过标准**：确认新建会话时 `Store.open` 是可以直接预生成 UUID 绑定侧边栏节点，还是需要先启动 `agy` 后通过 `brain/` 目录变更事件回填真实 `conversationId`。

### PoC-3：PTY 终端忙闲信号与标题行为
- **要确认的问题**：`agy` 在交互式 PTY 中运行时，是否会发送类似 Claude 的 OSC 0 spinner 或 OSC 7501 任务状态控制序列？以及多行括号粘贴（`\e[200~...\e[201~`）与 `\r` 提交表现如何？
- **核验方式**：用 `script -q /tmp/agy-pty.log agy` 跑一轮简单对话，检查日志中的 `\x1b]0;`、`\x1b]7501;` 等 OSC 序列，并测试粘贴多行文本后发送 `\r`。
- **通过标准**：确定 `TerminalPane.swift` 是直接复用 OSC 监听，还是启用 C9 的「`transcript.jsonl` + CPU 采样」组合判定，以及 C8 的就绪等待策略。

### PoC-4：结构化执行协议选型（`stream-json` vs `acp`）
- **要确认的问题**：
  1. `agy -p --input-format stream-json --output-format stream-json` 是否支持双向控制协议（`initialize` / 工具权限审批 / `interrupt`）？
  2. `agy acp` 的 `initialize` → `session/new` → `session/prompt` → `session/request_permission` JSON-RPC 报文样例。
- **核验命令**：
  ```bash
  agy models
  echo '{"type":"user","message":{"role":"user","content":"echo ok"}}' | agy -p --input-format stream-json --output-format stream-json
  ```
- **通过标准**：明确 Phase 2 的 `AgyExecutor` 采用路线 A 还是路线 B，并固化事件字段映射表。

---

## 7. 风险与应对

| 风险 | 影响 | 应对措施 |
| --- | --- | --- |
| `agy` 会话索引若为加密/专有 `.pb` 格式且无 CLI 列表命令 | Phase 1 会话树可能无法按项目列出历史会话 | PoC-1 优先检查是否存在明文索引或 `transcript.jsonl` 元数据；若缺失，退一步通过扫描 `brain/*/.system_generated/logs/transcript.jsonl` 中的路径线索 + 宿主持久化自己创建过的 `agy` 会话索引（`sessionProviders`）。 |
| `agy` 运行中不支持无重启切换 `--mode` | 用户在底部栏切换模式后对当前终端无效 | 不盲目模拟按键；立即持久化到 `settings.json` 并提示「将在下次启动会话生效」，或提供一键重连按钮。 |
| `agy` CLI 版本更新导致 `models` 列表或 `stream-json` 变化 | 状态栏模型下拉过期 / 解析失败 | 模型列表动态取 `agy models` + 本地兜底；Work 执行器优先选用标准化的 `agy acp` 协议。 |
| 同一个会话被终端与 Work 同时打开导致文件损坏 | 并发写同一对话 | 复用水印互斥锁 `SessionOwnership`，并将 key 升级为 `provider\|cwd\|sid` 统一管控。 |

---

## 8. 验收与回归测试规划

1. **单元测试（`Tests/`）**：
   - `SessionRegression`：补充 `AgySessionScanner` 解析 `transcript.jsonl`、`<USER_REQUEST>` 标签清洗、空会话/损坏行容错、与 Claude 会话混合按 `cwd` 聚合、以及 `sessionBranches` 回退分支绑定的用例。
   - `TerminalRegression`：覆盖 `.claude` / `.antigravity` 两套启动参数拼接、`AgyConfig` 读写 `~/.gemini/antigravity-cli/settings.json`（保留未知键）、`ContextUsage` 解析 `transcript.jsonl` token、以及 `interactionMode == .chat` 时对 `.antigravity` 的自动降级逻辑。
   - `WorkRegression`（Phase 2）：覆盖 `WorkStore` v1 → v2 迁移、`AgentExecutorProtocol` 的 Mock/回放事件流测试。
2. **构建与桌面验收**：
   - 执行 `swift build -c release`、`swift test`、`./scripts/build-app.sh --dev`；
   - 按 [DEVELOPMENT.md §2.7](file:///Users/zcl/project/claude-picker/.worktrees/codex-wt-20261118/DEVELOPMENT.md) 使用 `agent-desktop` 对 `ClaudePickerDev.app` 进行真实 UI 验收：侧栏混合显示、新建 Antigravity 会话、恢复已有 `agy` 对话、切换底部运行参数、切到 `chat` 模式时的安全降级提示，以及跨 CLI 接力新建会话。

---

## 9. 待确认事项

在执行 PoC 并进入开发前，需要你确认以下 3 个产品决策：

1. **首期交付范围**：先只落地 **Phase 1（会话树 + 原生终端 + 运行参数 + 设置诊断）**，还是 **Phase 1 + Phase 2（含 Work 中心执行器）** 一起做？
2. **侧边栏展示方式**：同一项目下，Claude 与 Antigravity 会话是 **混排（靠图标/角标区分）**，还是需要 **增加引擎筛选开关 / 分组折叠**？
3. **默认新建会话引擎**：在项目上直接点「+ 新建会话」时，默认使用哪个 CLI，还是在设置里可配置 + 弹窗记忆上次选择？
