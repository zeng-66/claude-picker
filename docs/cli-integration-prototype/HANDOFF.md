# 多 CLI 与工作区改造交接

## 分支现场

2026-11-19 暂停开发并交接。开发分支为 `codex/wt-20261119`，基线为 `63a3bbc`（创建 worktree 时的 `origin/test`）。首批源码、资产、测试和方案保存在该 worktree 的未提交改动中，包含未跟踪文件。接手时先运行 `git status --short --branch --untracked-files=all` 核对改动。重新从远端检出基线时，需要同时带上这份工作区改动。

原型来自 Codex 会话 `01a1f1a6-2874-71c1-942f-0594ad8f0ad9`。范围和待拍板事项以[多 CLI 开发方案](DEVELOPMENT.md)与[企微开发方案](WECOM-DEVELOPMENT.md)为准。继续开发和交付前先看[仓库分支契约](../../DEVELOPMENT.md#0-分支与交付契约)。

## 已落地并验证

| 模块 | 当前能力与入口 |
| --- | --- |
| 项目树、工作树与 Diff | 项目按分支和工作树分组，支持独立创建工作树、在指定工作树新建会话、复制原始 ID 和恢复命令。从工作树右键可直接读该检出目录的 Diff。普通分支切换遇到脏工作区时保留原分支和改动。入口为 [App.jsx](../../Web/src/shell/App.jsx)、[会话桥](../../Sources/ClaudeDeck/ThirdPane/BridgeHandlers+Session.swift)与 [GitService.swift](../../Sources/ClaudeDeck/Git/GitService.swift)。 |
| macOS CLI 与额度 | 保留 Claude 和 Antigravity，接入 Codex、DeepSeek 终端及本地历史读取。CLI 设置支持检测、启停和默认新建引擎。Claude 有基于最近完成回合的缓存估算。额度读取 Claude 和 Codex 的实际窗口。WorkBuddy 只在 CLI 引擎目录登记。入口为 [AgentProviders.swift](../../Sources/ClaudeDeck/AgentProviders.swift)、[TerminalPane.swift](../../Sources/ClaudeDeck/TerminalPane.swift)和 [CodexUsage.swift](../../Sources/ClaudeDeck/ThirdPane/CodexUsage.swift)。 |
| 逐会话打开方式与结构化聊天 | 打开方式记在 `tree.json` 的 `sessionModes`，取值终端、结构化聊天或 Swttch。全局与引擎覆盖只决定新会话，旧会话无记录时按全局解析。[SessionChatHub](../../Sources/ClaudeDeck/SessionChat.swift) 驱动 Claude stream-json、Antigravity ACP 与 [Codex App Server](../../Sources/ClaudeDeck/Work/CodexAppServerExecutor.swift)，界面为 [SessionChat.jsx](../../Web/src/shell/SessionChat.jsx)。右键切换时先中断回合、等执行器退出，再按原始 ID 接续，失败保留原界面。关闭视图不结束执行器，重新打开即挂接。 |
| TAPD MCP 批量接入 | [TapdMcp](../../Sources/ClaudeDeck/Work/TapdMcp.swift) 经 `uvx` 启动官方 `mcp-server-tapd==8.0.81`（stdio），令牌从钥匙串经 `TAPD_ACCESS_TOKEN` 传给子进程。一键配置拆分去重 ID，完成握手、工具发现和逐项目只读试读后一次保存，保留已有启停与仓库映射，按场景报告读写工具是否可用。MCP 模式的「我的待办」走 `get_todo`。 |
| 企微多机器人、隔离续聊与决策卡 | [WecomConfig](../../Sources/ClaudeDeck/Work/WecomConfig.swift) 定义 Bot 列表、凭据账户与三项交集授权；[WecomBot](../../Sources/ClaudeDeck/Work/WecomBot.swift) 每个 Bot 独立连接、被顶替不重连；[WecomClaudeChat](../../Sources/ClaudeDeck/Work/WecomClaudeChat.swift) 按六元组隔离续聊，可选 Claude、Codex、Antigravity；[WecomCards](../../Sources/ClaudeDeck/Work/WecomCards.swift) 负责拍板卡与任务确认卡的记录、回调校验与编号回退。 |
| Windows 新引擎与恢复 | [engines.cjs](../../Desktop/engines.cjs) 负责发现、启动与恢复参数、ID 校验、Codex 与 DeepSeek 历史扫描，[runtime.cjs](../../Desktop/runtime.cjs) 接入四个引擎、CLI 分配 ID 后回绑，并按会话记录的工作目录恢复。 |

2026-11-19 续作轮在本机完成以下验证：`bash scripts/test-git.sh`、`./scripts/check-session-regressions.sh`（新增结构化聊天的新建、发送、审批、运行中切到终端再切回、重复打开与关闭视图）、`bash scripts/test-work.sh`（277 项，新增 Codex 执行器、TAPD MCP 一键配置、企微多 Bot 授权隔离与决策卡替身回归）、`node Tests/DesktopRegression/main.cjs`、`node Tests/DesktopRegression/engines.cjs`、`npm --prefix Web run build`。`./scripts/build-app.sh --dev --with-chat` 产出的 `dist-dev/ClaudePickerDev.app` 签名校验通过，用隔离数据目录启动正常。Codex App Server 的握手、线程、流式回合协议用本机 codex-cli 0.170 实测；TAPD MCP 的服务形态与 44 个工具用 `mcp-server-tapd==8.0.81` 实测（未带令牌，只做工具发现）。

## 2026-11-19 桌面验收记录

开发包 `dist-dev/ClaudePickerDev.app`（`--dev --with-chat`），用 agent-desktop 在原生窗口操作，物理输入经用户同意使用 `--headed`。除企微联调外均使用隔离数据目录与内存钥匙串，项目为临时 Git 仓库。

| 路径 | 结果 |
| --- | --- |
| Claude 结构化聊天 | 通过。终端会话右键改用结构化聊天，以同一 ID 启动 `claude -p`；收发、工具记录、自动模式放行、手动模式下允许（文件生成）与拒绝（文件未生成）、中断；运行中右键改用终端时先确认、中断，再以 `claude --resume <原 ID>` 恢复并接上历史；切回聊天以 `--resume` 接续。重启后打开会载入本地历史，工具结果区分完成与出错。 |
| Codex 结构化聊天 | 通过（修复后）。收发、沙箱外提权审批（允许后文件生成，已清理）、中断；切到终端以 `codex resume <原 ID>` 恢复并显示全部历史。只建线程未发消息的会话 Codex 不写记录，重启后不出现在列表。 |
| Antigravity 结构化聊天 | 通过。收发、原始 ID 回绑、工具审批（允许后文件生成）、中断。 |
| DeepSeek 终端恢复 | App 侧通过：从历史以 `dsh-tui --backend dsh --resume <原 ID>` 启动。本机 dsh-tui 0.20.1 与 dsh 0.2.2-rc.5 插件版本不兼容且缺 `@deepseek-ai/dsh-hooks-claude-code`，普通终端同样报错，需本机处理（例如 `dsh plugin allow-version` 或升级）。 |
| 设置 → CLI 引擎 | 通过。默认打开方式写入设置；DeepSeek 的打开方式只提供终端。 |
| TAPD MCP 一键配置 | 通过。真实令牌（登录 shell 的 `TAPD_TOKEN`）、真实项目：混入无权限项目时整体不保存；非数字输入被拒；蓝马与方果ERP 两个项目试读通过后保存，重复 ID 去重，设置里没有令牌。「TAPD 待办」经 MCP 读到真实待办，状态名、迭代、处理人与创建时间补全。 |
| 多机器人设置页 | 通过。启用前未登记人员时报错；保存名称、Bot ID、使用者、发起人、拍板人、私聊与项目范围；未保存 Secret 时显示原因。 |
| 企微真机联调（「开发协作助手」） | 通过（修复后）。私聊回复、沿用旧会话历史、问题以编号文字发出、拍板卡推送、点击后卡片更新并回到原会话继续、重复点击不改结果、回复编号映射为选项。联调后已恢复 ClaudePickerTest 并重新连接。 |

验收中发现并修复的问题：Codex / Antigravity 回绑原始 ID 后聊天事件被丢弃（停在「正在连接」）；终端里 nvm 安装的 Node 脚本型 CLI 找不到 `node`；真实企微卡片回调字段嵌套在 `event.template_card_event` 下而未被识别；MCP 待办缺状态名、处理人、迭代与时间；结构化聊天标题被关闭按钮遮挡、打开时未停在底部、历史把中断标记当成用户消息、历史工具状态不分完成与出错。均已补回归或复测。

## 2026-11-19 第二轮：快捷切换、维护与企微群聊

- **结构化聊天快捷切换（参照官方桌面端）**：输入框下方依次是打开方式、权限模式、「模型 · 推理强度」合并选择器，菜单向上弹出；⌘⇧M / ⌘⇧I / ⌘⇧E 打开对应菜单（同 Claude Code 桌面端）。Claude 的权限模式与模型经 stream-json 控制请求即时切换，推理强度空闲时按原 ID 重启生效；Antigravity 的模式与模型取自 ACP 会话报告（手动 / 接受编辑 / 自动 / 规划），即时切换；Codex 的模型与各模型支持的推理强度取自 `model/list`，权限为「请求批准 / 替我批准 / 完全访问」（同 Codex 桌面端，替我批准对应 `approvalsReviewer: auto_review`），从下一回合起生效。发送键旁增加上下文占用环（Claude 读会话记录，Antigravity 读对话记录，Codex 读 `thread/tokenUsage/updated` 与 rollout 的 `token_count`）。终端右上角关闭按钮旁增加「终端 ↔ 结构化聊天」切换。引擎切换、新建会话与 Work 卡片统一使用各平台官方图标。
- **交接修复**：切到结构化聊天时等终端整棵进程树退出再交出会话（Codex 的 npm 启动器会拉起原生子进程，之前报 “already has an active writer”）；Codex 仍报占用时退避重试 5 次。
- **DeepSeek Harness 维护**：启动后 20 秒与每 6 小时只读巡检（`dsh-tui doctor` + `npm view`），有新版本或 ✗ 项时右上角提示，点「升级并对齐」执行 `dsh-tui update`；设置页可手动检查、关闭自动巡检，同一版本可忽略。本机已对齐到 0.20.2，原插件版本不兼容报错消失；`~/.dsh/cordis.patch.yml` 里 Orca 写入的 `orca-agent-hooks` 引用的包不存在，仍有一条不阻塞启动的警告，未改动。
- **Qoder CLI**：「可安装」目录登记 `curl -fsSL https://qoder.com/install | bash`（白名单，界面只能按 ID 触发，执行前确认）；本机已检测到 qodercli 1.1.92，会话入口待接入。
- **企微群聊联调（两个真实机器人）**：群聊回复、群聊与私聊分别续聊、群内拍板卡、两个机器人独立连接、私聊场景授权拒绝均通过。企微对同时 @ 多个机器人的群消息会分别投递，消息 ID 不同、到达间隔可达约 20 秒；不重复执行已验证，但「按列表顺序优先」只在 1.5 秒等待窗口内成立，超过时为先到先处理。每个机器人最近 20 条入站元数据记在设置 `robot.inbound.<id>`，便于排查。

## 已拍板（2026-11-19）

- 人员授权：应用内角色组。使用者可以对话；任务发起人可以创建、追加 Work（不设名单时所有使用者都可以）；拍板人与发起人都可以在决策卡上做决定。
- 同群多机器人：同一条消息同时 @ 了多个本机机器人时，1.5 秒内收齐各 Bot 的回调，按列表顺序由第一个有权限的处理，其余回复由谁处理。只有一个机器人覆盖该群时不等待。
- 卡片有效期：拍板卡 30 分钟，Work 确认卡 24 小时。
- 群内可见：群里完整显示问题、选项、选择结果与后续输出。

## 待验收与后续

1. **Windows 安装与运行。** 已在 macOS 交叉打包出 `dist-windows/ClaudePickerDev-1.0.0-windows-x64.exe`，包内含 `engines.cjs` 与 node-pty 的 win32-x64 原生模块；本机没有 Windows 环境，安装、四个引擎的检测、带空格路径与工作树的恢复、新会话 ID 回绑需在 Windows x64 上验收。Antigravity 在 Windows 的历史目录未确认，暂不扫描历史；Windows 只提供终端打开方式。
2. **企微未覆盖的真机场景。** 只有一个真实机器人，群聊、多 Bot 并存与同时 @ 的裁决、授权拒绝、Work 模式的任务确认卡只在本地替身回归覆盖。
3. **DeepSeek 本机环境。** 处理上面的插件版本问题后，复测历史恢复与新会话 ID 回绑。
4. **TAPD 回填与详情。** 详情、评论与状态流转仍走 tapd-cli；切到 MCP 前需按场景报告逐项核对返回结构与写权限。「在 MCP 服务列表登记 TAPD」未做，因为写入 CLI 配置需要明文令牌。
5. **结构化聊天的运行参数。** 聊天界面没有模式和模型选择，沿用终端运行参数里的当前值；Codex 与 Antigravity 使用各自 CLI 的默认模型与审批策略。

后续交付的本地入口为 `bash scripts/test-git.sh`、`./scripts/check-session-regressions.sh`、`bash scripts/test-work.sh`、`node Tests/DesktopRegression/main.cjs`、`node Tests/DesktopRegression/engines.cjs`、`npm --prefix Web run build` 和 `./scripts/build-app.sh --dev --with-chat`；Windows 包为 `npm --prefix Desktop run dist:win`（需先 `npm --prefix Desktop install`）。
