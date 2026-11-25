# ClaudePicker 开发文档

> 一个 macOS 原生小工具：左侧是可展开的会话树，右侧内嵌终端直接跑 `claude --resume <sid>`。
> 本文档面向后续迭代开发，记录架构、数据链路、状态文件、UI 常量、交互约定和已知坑。

---

## 0. 分支与交付契约

本节是本项目分支用途和交付动作的权威约定，适用于人工开发与 Agent 执行。

### 0.1 分支与 App 对应关系

| 分支 | 用途 | 对应 App |
|---|---|---|
| `main` | 正式版 | 正式版 App |
| `master` | 预发布、功能内测 | 预发布内测 App |
| `test` | 测试验证 | 测试版 App |
| `dev` | 日常开发调试 | 开发调试 App |
| 其他所有分支 | 功能开发、修复与开发调试 | 开发调试 App |

按分支名称确定交付渠道。`codex/*`、`feat/*`、`backup/*` 等分支均归入开发分支。

### 0.2 用户指令与默认交付动作

| 用户指令 | 合并目标 | 必须完成的动作 |
|---|---|---|
| 功能内测、内测、预发布 | `master` | 提交当前功能及文档，合并到 `master`，验证、推送目标分支，构建并交付预发布内测 App |
| 上线、正式发布 | `main` | 提交本次上线范围及文档，合并到 `main`，验证、推送目标分支，构建并交付正式版 App |
| 打包测试、提交测试、提测 | `test` | 提交当前测试范围及文档，合并到 `test`，验证、推送目标分支，构建并交付测试版 App |
| 开发、调试 | `dev` 或当前开发分支 | 在开发分支修改、验证并使用开发调试 App |

上述交付指令已经授权本次交付所需的提交、目标分支合并、推送、打包和文档更新，执行时直接推进完整流程。用户明确指定的来源分支、范围、版本和产物格式优先。

### 0.3 执行顺序

1. 核对当前分支、工作区、远端和本次交付范围。将本次功能所需的代码、资源、测试与文档一起纳入提交，并保留其它工作的现场。需要切换分支时可使用独立 worktree。
2. 更新相关文档，包括受影响的功能文档、`DEVELOPMENT.md` 中的实现与验证说明，以及受影响的 `README.md` 使用说明。交付记录包含来源分支、目标分支、版本、变更摘要、验证结果、产物路径与待处理事项。
3. 运行与本次变更相关的构建和回归检查，提交本次交付内容，并按仓库已有方式推送来源分支。
4. 获取远端最新状态，在目标分支上整合远端更新，再合并本次交付来源分支。处理冲突时结合双方业务语义保留所需变更。
5. 在合并后的目标分支验证、构建对应渠道的 App。将集成阶段产生的修复和文档更新一起提交，推送目标分支，并核对远端提交与交付提交一致。
6. 根据交付需求安装或发布对应 App，检查实际运行的版本和关键路径。涉及界面与交互的变更，按 §2.7 使用 agent-desktop 执行桌面验收。最终反馈目标分支与提交、推送结果、验证结果、安装包位置和文档更新，明确尚待用户操作的系统授权或验证事项。

完成条件同时包括目标分支已合并并推送、对应 App 已构建交付、文档已同步，以及实际验证结果已记录。遇到远端权限、冲突语义或外部依赖阻塞时，保留已完成结果并报告具体阻塞。

### 0.4 当前构建入口

现有 `scripts/build-app.sh` 提供以下入口。

| 渠道 | 当前构建入口 | App 产物 |
|---|---|---|
| 正式版 | `./scripts/build-app.sh` | `dist/ClaudePicker.app` |
| 开发调试 | `./scripts/build-app.sh --dev` | `dist-dev/ClaudePickerDev.app` |
| 测试 | `./scripts/build-app.sh --test` | `dist-test/ClaudePickerTest.app` |
| 预发布内测 | 待补齐预发布构建入口 | 待实现对应渠道产物 |

首次执行功能内测交付时，应将预发布构建入口及其渠道标识纳入本次交付并验证。图形聊天资源使用 `--with-chat`，归档格式按交付需求使用 `--zip` 或 `--dmg`。当前测试包沿用开发包的数据目录，构建事实以脚本和运行验证为准。

---

## 1. 项目总览

### 1.1 它解决什么问题

`claude` CLI 每次都要 `cd` 到项目目录、再翻历史会话 ID。这个 App 把「打开某个历史会话」压缩成一次点击：

- 扫描 `~/.claude/projects/*/*.jsonl`，把历史会话按工作目录聚合成树；
- 点会话 → 内嵌终端里 `exec claude --resume <sid>`；
- 状态栏直接改 `~/.claude/settings.json`（模式 / 模型 / 推理强度 / fast），并同步到正在跑的 claude。

### 1.2 技术选型

| 层 | 选择 | 原因 |
|---|---|---|
| 窗口/UI | SwiftUI + 少量 AppKit（`NSWindow` / `NSViewRepresentable` / `NSOpenPanel`） | SwiftUI 写树和状态栏最快；窗口生命周期和键盘拦截必须 AppKit |
| 终端 | vendored [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（`LocalProcessTerminalView`） | 纯 Swift、无外部依赖，CommandLineTools 下能编译 |
| 持久化 | 三个 JSON 文件（见 §5） | 无需数据库，肉眼可查、可改 |
| 构建 | Swift Package Manager（`swift-tools-version:6.2`） | 不需要 Xcode 工程文件 |

**目标是 `.macOS(.v14)`**，`Info.plist` 的 `LSMinimumSystemVersion` 是 `26.0`，开发机运行在 macOS 27 / arm64。

### 1.3 目录结构

```
/Users/zcl/project/claude-picker/          # 源码仓库（GitHub: zeng-66/claude-picker）
├── Package.swift               # SPM 清单
├── Package.resolved
├── Sources/ClaudeDeck/
│   ├── main.swift              # 1737 行：常量、Store、全部 SwiftUI 视图、AppDelegate、buildProjects
│   ├── Models.swift            #  465 行：Session/Project、SessionScanner、TreeOrder、ClaudeConfig、UsageFetcher
│   └── TerminalPane.swift      #   94 行：TerminalSession 包装 SwiftTerm
├── SwiftTerm/                  # vendored 依赖（HEAD c86e1d8，已删 .git/.build）
├── scripts/
│   ├── build-app.sh            # 构建 + 组装 app + 图标 + 签名 + 打包（--zip/--dmg）
│   └── make_icon.py            # 从 ClawdMark 的 cells 生成 AppIcon.icns
├── docs/icon.png               # README 用图标
├── dist/                       # 构建产物（.gitignore，不进仓库）
│   ├── ClaudePicker.app
│   ├── ClaudePicker-1.0.0.dmg
│   └── ClaudePicker-1.0.0.zip
├── README.md
├── DEVELOPMENT.md              # 本文件
└── .gitignore

~/.local/share/claude-picker/              # 仅运行态数据
├── settings.json               # App 自己的设置（字号、侧边栏宽度）
└── tree.json                   # 树顺序 + 隐藏记录
```

> 状态目录路径在 `Models.swift` 里硬编码为 `~/.local/share/claude-picker`，与源码位置无关。改代码不影响用户数据。

---

## 2. 构建与部署

### 2.1 日常开发（脚本一把梭）

```bash
cd /Users/zcl/project/claude-picker
./scripts/build-app.sh --dev    # 编译并组装开发调试 App
open dist-dev/ClaudePickerDev.app
```

日常调试使用开发调试 App。更新运行中的 App 后，退出并重新打开对应渠道的实例，再检查实际运行版本。分支合并与渠道选择遵循 §0。

脚本做六件事：`swift build -c release` → 组装 `dist/ClaudePicker.app`（可执行文件从 `.build/release/ClaudeDeck` 复制并改名为 `ClaudePicker`）→ 用 `scripts/make_icon.py` 生成 `AppIcon.icns` → 写 `Info.plist` → `codesign --force --deep --sign -` → 可选 `--zip` / `--dmg`。

环境变量可覆盖打包参数：`VERSION`（默认 1.0.0）、`BUILD_NUMBER`（默认 1）、`MIN_MACOS`（默认 14.0）。

### 2.2 手动更新开发调试包

先通过 `./scripts/build-app.sh --dev` 生成开发调试包。仅更新其可执行文件时，执行以下步骤。

```bash
cd /Users/zcl/project/claude-picker
swift build -c release
cp .build/release/ClaudeDeck dist-dev/ClaudePickerDev.app/Contents/MacOS/ClaudePickerDev
codesign --force --deep --sign - dist-dev/ClaudePickerDev.app
```

退出并重新打开 `dist-dev/ClaudePickerDev.app`，检查实际运行版本。涉及前端、资源或包配置变更时，使用完整构建脚本生成对应渠道的 App。

### 2.3 发布到 GitHub Releases

```bash
./scripts/build-app.sh --dmg
gh release create v1.0.1 --title "ClaudePicker 1.0.1" \
  --notes-file /tmp/relnotes.md \
  dist/ClaudePicker-1.0.1.dmg dist/ClaudePicker-1.0.1.zip
```

`dist/` 已在 `.gitignore` 里，安装包只走 Releases，不进仓库。

### 2.4 只编译不部署

```bash
swift build -c release 2>&1 | tail -20
```

改完代码先看编译是否过，再走部署。Swift 的报错行号直接对应 `Sources/ClaudeDeck/*.swift`。

### 2.5 验证部署真的生效

```bash
pgrep -x ClaudePickerDev                     # 开发调试包进程
ls -l dist-dev/ClaudePickerDev.app/Contents/MacOS/ClaudePickerDev   # 时间戳应该是刚刚
codesign -dv dist-dev/ClaudePickerDev.app 2>&1 | head -3         # 签名状态
```

**不要把「编译通过」当成「已生效」**——遗漏资源更新或重启会导致实际运行版本落后于构建产物。

### 2.6 工具链事实

```
swift-driver version: 1.168.6  Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)
Target: arm64-apple-macosx27.2.0
```

只用 CommandLineTools（没有完整 Xcode）。这带来一个硬约束，见 §10 第 1 条。

### 2.7 桌面调试与验收（agent-desktop）

涉及 App 界面、交互、设置、窗口、会话切换或连接状态的开发与修复，优先使用 `agent-desktop` 完成实际界面验证。开始前读取本机 `agent-desktop` 技能和平台说明，按本次改动选择相关操作路径。

#### 执行流程

1. 核对开发分支和交付渠道，按 §2.1 构建开发调试包。涉及图形聊天时加 `--with-chat`。前端迭代可连接 Vite 热更新，Swift 修改后重新编译并重启对应 App。
2. 检查 `agent-desktop status`，确认辅助功能权限，截图时确认屏幕录制权限。运行 `agent-desktop skills get platform` 读取当前平台规则。需要授权时向用户说明具体权限，由用户完成系统授权，同时继续可执行的构建、日志和回归检查。
3. 启动对应 App，核对实际运行的包路径和渠道。通过 `snapshot` 或 `find` 定位界面与控件，先读取当前值和错误提示。
4. 执行本次操作，随后重新读取相关区域，核对界面结果与预期。每次界面变化后使用新快照中的控件引用，异步变化使用 `wait` 等待可判断的条件，参数以命令帮助为准。
5. 遇到异常时，结合截图、Bridge 返回值、应用日志和持久化状态定位。Swift 崩溃、线程和内部变量使用 Debug 构建与 LLDB 辅助排查。修复后重新执行原始复现路径。
6. 运行相关回归脚本，记录操作路径、预期结果、实际结果和必要截图。涉及企微等外部渠道时，分别记录连接状态、消息进入 Claude、结果生成和用户端收到回复的验证情况。

#### 常用入口

```bash
agent-desktop status
agent-desktop skills get platform
agent-desktop snapshot --app local.zcl.claude-picker.dev --skeleton -i --compact
```

需要操作控件时，使用快照返回的完整引用。对命令返回的投递状态进行判断，仅在明确尚未投递且允许安全重试时重试。结果不确定时先重新观察实际状态。

默认使用辅助功能语义操作。需要鼠标、键盘等物理输入时，按技能要求取得用户授权后使用 `--headed`。权限或控件支持受限时，可用当前环境允许的桌面工具继续验证，并如实记录工具及未验证部分。

#### 回归范围与交付记录

| 改动范围 | 验证入口 |
|---|---|
| 设置、弹窗、项目与会话切换 | agent-desktop 操作与界面状态核对 |
| Work、Claude 执行与机器人 | `scripts/test-work.sh`，加受影响的真实交互路径 |
| Git 与文件操作 | `scripts/test-git.sh`，加受影响的界面路径 |
| 会话、终端与 Bridge | `scripts/check-session-regressions.sh`，加受影响的切换与输入路径 |

验收时记录构建版本或提交、App 路径、执行路径、验证结果与剩余事项。将编译结果、回归结果和实际界面结果分别记录，系统权限或外部条件未满足的步骤标记为待验证。

当前 `--dev` 使用 Release 编译配置，开发版包名和数据目录由渠道参数选择。测试包共用开发版数据目录，Claude 登录和部分配置也使用本机共享资源，准备测试数据时核对实际作用范围。

---

### 2.8 Windows 与 main 版本更新

Windows 桌面宿主位于 `Desktop/`，复用 `Web/` 的 React 界面，通过隔离的 Electron 桥接本地项目、Claude 终端、Git 和设置。Windows x64 开发包使用 `npm --prefix Desktop run dist:win` 构建，输出至 `dist-windows/`，分支对应的渠道、产品名和数据目录由 `scripts/prepare-desktop-build.cjs` 与 `Desktop/electron-builder.cjs` 选择。

设置中的「版本更新」通过 `update.status/check/download/install` 调用原生更新器。更新清单必须对应远端 main 的最新提交，包下载后验证大小与 SHA-256，安装时退出当前应用。macOS 的原生实现位于 `ThirdPane/BridgeHandlers+Update.swift`，Windows 实现位于 `Desktop/updater.cjs`。main 的构建与清单发布由 `.github/workflows/desktop-main.yml` 执行。

桌面发行范围、验证与剩余事项见 [DESKTOP_RELEASE.md](docs/DESKTOP_RELEASE.md)。Windows Work、TAPD、企微、图形聊天等服务移植和 Windows 实机验证仍待完成。当前远端尚未发布本轮安装包与清单。

H5 快照及批注入口保存在 [desktop-release-prototype](docs/desktop-release-prototype/README.md)，当前 v003 通过 `./docs/desktop-release-prototype/v003/preview.sh` 启动。模块切换、页签配置、浮窗缩放与界面清理见 [v003 开发说明](docs/desktop-release-prototype/v003/DEVELOPMENT.md)。Clawd 桌宠的状态、素材、浏览器验证与原生窗口接入规划见 [桌宠开发说明](docs/desktop-release-prototype/v003/DESKTOP_PET.md)。各版本目录、来源摘要、变更记录与批注 JSON 共同记录界面修改。

## 3. 源码地图（`main.swift`）

按行号索引，改代码前先定位。

### 3.1 常量与入口

| 行 | 内容 |
|---|---|
| `:6-18` | 全局常量（窗口/侧栏尺寸、会话折叠上限、终端留白、终端底色） |
| `:22` | `struct LaunchArgs` —— 启动参数 |
| `:31` | `func parseArgs()` —— 解析 `--out/--root/--home-label/--start/--resume`，其余位置参数进 `names` |
| `:49` | `enum TreeRow` —— 三种行：`.project(Int)` / `.session(Int, Int)` / `.more(Int)`，`key` 用于拖放身份比对 |
| `:66` | `final class Store: ObservableObject` —— **全局唯一状态源** |
| `:1607-1715` | `parseArgs()` 调用、`buildProjects()`、`Store(buildProjects())`、`app.run()` |

### 3.2 Store（`:66-528`）

| 行 | 方法 | 职责 |
|---|---|---|
| `:106/108/113` | `beginResize` / `resizeTo` / `endResize` | 侧栏宽度拖拽（夹紧到 250…560，结束写 `settings.json`） |
| `:130/138/147` | `canRemoveCurrent` / `removeProject` / `removeSession` | 删除（写 `tree.json` 的 hidden 集合） |
| `:158` | `rows`（计算属性） | 树拍平成行数组，超过 5 条插一个 `.more` |
| `:191-243` | `up/down/left/right/focusTerminal/focusTree/clampSel` | 键盘光标移动 |
| `:247/253` | `toggleExpand` / `toggleShowAll` | 展开项目 / 展开全部会话 |
| `:260` | `confirm()` | 回车：项目=展开，会话=打开，more=展开全部 |
| `:275` | `openNew(_:)` | 在项目目录起一个不带 `--resume` 的新会话 |
| `:281` | `open(cwd:sid:label:)` | **打开终端**（先 terminate 旧终端，只保留一个） |
| `:297` | `locateRow(cwd:sid:)` | 反查该会话在树里的行号，同时设 `activeRow` 高亮 |
| `:325` | `closeTerminal()` | 关终端回到树 |
| `:335-372` | `moveProject/pinProject/moveSession/pinSession/moveSessionToProject` | 拖拽排序（家目录恒在第一，不可移动） |
| `:376` | `persistTree()` | 把顺序/展开/隐藏写回 `tree.json` |
| `:395` | `addDirectory(_:)` | 校验目录存在后 append 一个项目 |
| `:417/429` | `toggleSidebar` / `revealProject` | 侧栏收起展开 |
| `:443/452` | `appFont(_:_:)` / `applyFonts` | 以 12.5 为基准缩放字体 |
| `:462/476` | `cycleTo(_:)` / `sendShiftTab(times:)` | 模式切换：往 PTY 发 `ESC [ Z` |
| `:490/498/505/512` | `setModel/setEffort/toggleFast/reloadClaudeOptions` | 状态栏四项，写 `~/.claude/settings.json` + 发斜杠命令 |
| `:520` | `refreshUsage()` | 拉用量 |

### 3.3 视图层

| 行 | 类型 | 说明 |
|---|---|---|
| `:533` | `BehindBlur` | `NSVisualEffectView`，`.hudWindow` / `.behindWindow` |
| `:547` | `ClawdMark` | 像素风吉祥物（`Canvas` 手绘，见 §7.4） |
| `:588` | `relativeText(_:)` | 「N 分钟前 / N 小时前 / N 天前」 |
| `:599` | `kTint` | 全局强调橙 `(0.95, 0.55, 0.35)` |
| `:602` | `usageColor(_:)` | 用量百分比 → 绿/黄/红三段插值 |
| `:618` | `UsageRing` | 用量圆环 + 5 小时/本周百分比 |
| `:671` | `RowDrop: DropDelegate` | 拖拽落点，分派到 `move*` 系列 |
| `:712` | `ProjectRowView` | 项目行（高 34） |
| `:795` | `SessionRowView` | 会话行（高 34） |
| `:872` | `MoreRowView` | 「展开其余 N 条」（高 26） |
| `:912` | `SettingsPanel` | 设置浮层（宽 420） |
| `:1011` | `StatusBarView` | 底部状态栏（高 30） |
| `:1118` | `PickerView` | 主视图：侧栏 + 分隔线 + 终端区 |
| `:1392` | `KeyableWindow` | 覆写 `canBecomeKey/canBecomeMain` |
| `:1398` | `AppDelegate` | 窗口生命周期、全局键盘监视器、用量定时器 |
| `:1611` | `buildProjects()` | **数据链路核心**，见 §4 |
| `:1718` | `HeaderIconButton` | 侧栏头部的圆形图标按钮 |

---

## 4. 数据链路

### 4.1 启动时序

```
main.swift:1609  let args = parseArgs()
        ↓
:1611  buildProjects()          ← 读磁盘 + 读 tree.json，产出 [Project]
        ↓
:1709  Store(buildProjects())   ← 组装状态源
        ↓
       NSApplication.shared / AppDelegate
        ↓
AppDelegate.applicationDidFinishLaunching
   ├─ setActivationPolicy(.regular)   ← 缺这行永远抢不到前台
   ├─ 建 KeyableWindow + NSHostingView(PickerView)
   ├─ 挂全局 keyDown 监视器
   ├─ centerWindow()
   ├─ 若 args.startDir 非空 → 自动 open（cc-open 兼容）
   ├─ refreshUsage() + 90s 定时器
   └─ alphaValue 0→1 淡入 + 每 0.08s 抢焦点（最多 40 次，4 秒）
```

### 4.2 `buildProjects()` 的九步

代码在 `main.swift:1611-1715`。

1. `SessionScanner.scan()` 得到 `[cwd: [Session]]`（**每次启动实时扫盘，没有缓存**）。
2. `TreeOrderStore.load()` 读出 `hiddenProjects` / `hiddenSessions`。
3. 过滤：路径被 `hiddenProjects` 命中的整目录丢弃；剩余会话里 sid 被 `hiddenSessions` 命中的单条丢弃；**丢完为空则整个目录也不显示**。
   > 这条规则是「删除项目」的实现方式——它同时清掉该项目下的所有 hiddenSessions。
4. `mk(path, title, isHome)` 生产 `Project`：家目录 `id = -1`，其他从 0 递增。
5. 家目录强制做第一项（标题用 `--home-label`，默认 `~`）。
6. 有会话的目录按**最近会话时间倒序**追加。
7. `tree.json.projects` 里记着但当前无会话的目录也补进来（校验 `fileExists`）。
8. `args.names`（cc-open 传的位置参数）逐个追加。
9. 若 `tree.json.projects` 非空：按它重排、家目录拉到首位、未列出的保序追加；每个项目的会话按 `tree.json.sessions[path]` 重排，`expanded` 按 `tree.json.expanded` 恢复。

### 4.3 `SessionScanner`（`Models.swift:12-116`）

| 步骤 | 细节 |
|---|---|
| 扫描范围 | `~/.claude/projects/<项目目录>/*.jsonl` |
| 读取量 | 工作目录和首条消息读取前 128KB，总结从尾部按 64KB 块倒序查找 |
| `sid` | 文件名去掉 `.jsonl` |
| `date` | 文件 `contentModificationDate`（**不是**消息里的时间戳） |
| `cwd` | 第一条带 `cwd` 字段的记录 |
| 标题 | 优先使用最后一条有效会话总结。没有总结时，从首条合格人类消息提炼标题 |
| 总结 | `tailSummary` 按完整 JSONL 行倒序查找 `summary.summary` / `ai-title.aiTitle`，跳过空白和未写完的记录。第一行显示总结，第二行显示相对时间。打开会话和任务结束后刷新元数据 |
| 兜底 | 无合格标题时：见过 `[Image` → `"图片对话"`，否则 `"空会话"` |
| 排序 | 同一 cwd 内按 `date` 倒序 |

`summarize`（`:77`）的噪声过滤规则：

- 以 `<local-command-` / `<command-name>` / `<command-message>` / `Caveat:` 开头 → 丢弃
- 含 `system-reminder` 的 `<...>` 块 → 丢弃
- `<pasted_content>` 块：剥掉标记，保留正文首行之后的内容
- 剥掉 markdown 链接尾巴 `[@File.java](file://...)`
- 折叠连续空白
- `cd ` 开头且长度 < 80、`claude` / `claude ...`、`1` / `status` / `继续` → 丢弃
- 纯图片占位符（`[Image ...]`、`[Image: source: ...]`、`[foo.png]`）→ 丢弃
- 超过 46 字符截断加 `…`

只要有一条返回 `nil`，就继续找下一行，直到找到可用标题。

### 4.4 打开终端

```
用户点会话行  →  SessionRowView.action
      ↓
store.sel = idx; store.open(cwd: ss.cwd, sid: ss.id, label: ss.title)
      ↓
active?.terminate()                     ← 只保留一个终端
locateRow(cwd:sid:)                     ← 反查行号，设 activeRow（橙色高亮），必要时自动展开项目
TerminalSession(cwd:resumeId:options:fontName:fontSize:)
pane = 1                                ← 键盘焦点交给终端
onFocusTerminal() → AppDelegate.focusTerminalSoon() → 0.12s 后 makeFirstResponder(terminalView)
```

命令拼装在 `TerminalPane.swift`：

```swift
// 有 sid
exec claude --resume '<sid>' --permission-mode <mode> --model <model> --effort <effort>
// 无 sid（新建）
exec claude --permission-mode <mode> --model <model> --effort <effort>
```

`<sid>` 用单引号包裹并转义（`shellQuote`）。**`fast` 不在命令行参数里**，它只按 `/fast` 斜杠命令切换。

---

## 5. 状态文件

### 5.1 `~/.local/share/claude-picker/settings.json` — App 自身设置

```json
{
  "appFontSize": 11,
  "appFontName": "",
  "termFontName": "SFMono-Regular",
  "termFontSize": 10,
  "sidebarCollapsed": false,
  "sidebarWidth": 250
}
```

读一次（`Store.init` 时），改一次写一次。`sidebarWidth` 在载入时会被夹紧到 250…560。

界面重构（2026-11-17）新增两个字段，均由网页外壳经 `app.settings` 写入：`navigation`（`[{id, visible}]`，顶部页签顺序与显示，只认 workspace / tapd / works / git，缺的补在后面）与 `pet`（`enabled`、`size` 96/128/160、`theme` dev-life/codex、`idleShows`、`wander`、`x`、`y`）。

### 5.2 `~/.local/share/claude-picker/tree.json` — 树状态

```json
{
  "projects": ["/Users/zcl/project/lm-global-java", "..."],
  "sessions": { "/Users/zcl/project/lanma-bankend": ["<sid>", "..."] },
  "expanded": ["/Users/zcl/project/lm-global-java"],
  "hiddenProjects": ["/Users/zcl/.local/bin", "/private/tmp", "..."],
  "hiddenSessions": []
}
```

- `projects` / `sessions` —— **只影响排序，不是数据源**。会话内容永远来自扫盘。
- `expanded` —— 哪些项目默认展开。
- `hiddenProjects` —— 被删掉的目录（绝对路径，比较时做 `resolvingSymlinksInPath`）。
- `hiddenSessions` —— 被删掉的会话 sid。

> **误删会话怎么恢复**：把该 sid 从 `hiddenSessions` 数组里删掉，重启 App 即回来。
> 因为数据源是实时扫盘，不存在「缓存里没有」的情况。
> **误删整个项目**：从 `hiddenProjects` 删掉路径即可（注意 `/tmp` 和 `/private/tmp` 在 macOS 上可能同时存在两条记录）。

### 5.3 `~/.claude/settings.json` — Claude Code 自己的配置（状态栏读写）

| UI | JSON 路径 | 备注 |
|---|---|---|
| 模式 | `permissions.defaultMode` | UI 的 `.manual` 对应 `"default"`；CLI 参数用 raw value，两者映射不同 |
| 模型 | `model` | 存别名（`opus` / `sonnet` / `haiku` / `fable`） |
| 推理强度 | `modelSettings["claude-<model>-5-5"].effortLevel` | **键必须是 canonical id**，用别名写入无效 |
| 快速模式 | `fastMode` | 布尔 |

App 在 `applicationDidBecomeActive` 时会 `reloadClaudeOptions()` 重新读一遍，所以外部手改也会同步。

---

## 6. 状态机与交互

### 6.1 两个核心状态

```
pane = 0   键盘焦点在树（方向键导航）
pane = 1   键盘焦点在终端（所有键都喂给 claude，除少数组合键）
```

```
active == nil      终端区显示空态（ClawdMark + 提示文字）
active != nil      终端区 = TerminalPane + StatusBarView
```

`activeRow` 独立于光标：它是「当前终端在跑哪个会话」。所以有**两种高亮**：

| 状态 | 视觉 |
|---|---|
| `isActive`（live，终端正在跑） | 橙底 `kTint.opacity(0.26)` + 1px 橙描边 `kTint.opacity(0.55)` |
| `isCursor`（光标停在这行） | 灰底 `.white.opacity(0.075)`，无描边 |

两者可同时为真（光标停在正在跑的会话上）。

### 6.2 键盘表

全局监视器在 `main.swift:1450-1490`，按顺序匹配，命中即 `return nil`（吞掉事件）。

**任何状态下：**

| 键 | 行为 |
|---|---|
| `Esc`（设置面板打开时） | 关闭设置面板 |
| `⌘B` (11) | 收起 / 展开侧边栏 |

**`pane == 1`（终端焦点）：**

| 键 | 行为 |
|---|---|
| `⌘Esc` | 关闭终端，回到树 |
| `⌥Esc` | 只退出终端焦点，终端继续跑 |
| `Tab`（无 Shift） | 退出终端焦点。**Shift+Tab 必须放行** —— 那是 claude 自己的模式切换键 |
| 其他所有键 | 透传给 claude |

**`pane == 0`（树焦点）：**

| 键 | 行为 |
|---|---|
| `↑` (126) / `↓` (125) | 上下移动光标 |
| `→` (124) | 项目行：展开 / 跳过标题进入第一条会话 |
| `←` (123) | 会话行：收起所属项目并跳回项目行 |
| `Return` (36) / `Enter` (76) | 打开（项目=展开，会话=开终端，more=展开全部） |
| `⌫` (51) / `⌦` (117) | 删除当前项目 / 会话 |
| `Esc` (53) | `onDone` |
| `Tab` (48) | 若有终端在跑 → 焦点切回终端 |

### 6.3 鼠标

| 操作 | 行为 |
|---|---|
| 点行 | `pane = 0` + 设光标 + 执行该行的默认动作 |
| 右键项目行 | 置顶 / 新建对话 / 从列表移除 |
| 右键会话行 | 置顶（首条禁用）/ 新建对话 / 从列表移除 |
| 拖拽行 | 排序（项目↔项目、会话↔会话、会话→别的项目即移动） |
| 拖分隔线 | 调整侧栏宽度（悬停时光标变成左右箭头） |
| 点侧栏头部图标收纳 | 收起侧栏（同 `⌘B`） |
| 点齿轮 | 打开设置 |

拖拽实现要点：`.onDrag` / `.onDrop` 挂在行的 `Button` label 上（在 `contentShape` 之后），不是在行容器上，否则命中区域会被按钮吞掉。

---

## 7. UI 布局与常量

### 7.1 全局常量（`main.swift:6-18`）

```swift
let kWindowW: CGFloat = 1180
let kWindowH: CGFloat = 700
let kSidebarW: CGFloat = 322       // 仅作为默认值，实际用 settings.sidebarWidth
let kSidebarMinW: CGFloat = 250
let kSidebarMaxW: CGFloat = 560
let kMaxVisibleSessions = 5        // 项目默认最多显示 5 条会话
let kTerminalTopPad: CGFloat = 12  // 终端内容距窗口顶部的留白
let kTermBg = Color(red: 0.055, green: 0.062, blue: 0.078)
let kTint  = Color(red: 0.95, green: 0.55, blue: 0.35)   // :599
```

### 7.2 主布局（`PickerView.body`，`:1125`）

```
ZStack（只用于设置浮层叠加）
└── HStack(spacing: 0)
    ├── sidebar.frame(width: store.sidebarW)   或    collapsedRail（宽 44）
    ├── divider（宽 7）
    └── terminalArea
```

`terminalArea` **必须是 `VStack`**：

```
VStack(spacing: 0)
├── TerminalPane(session:).id(ObjectIdentifier(t))
│       .padding(.top, kTerminalTopPad)
│       .background(kTermBg)
└── StatusBarView(store:)
```

用 `ZStack` 会让状态栏叠在终端上。`.id(ObjectIdentifier(t))` 保证换会话时重建 NSView 宿主。

### 7.3 尺寸一览

| 元素 | 尺寸 |
|---|---|
| 窗口 | 1180×700（含标题栏约 728），最小 900×520，启动居中（中心 +30pt 下移） |
| 侧栏收起条 | 宽 44 |
| 分隔线 | 宽 7，常态 1pt `white.opacity(0.10)`，悬停 2pt `0.20` |
| 侧栏头部 | 高 40（`ClawdMark` 30×30 + 标题 + 计数 + 两个 24×24 圆按钮） |
| 项目行 | 高 34 |
| 会话行 | 高 34（图标 15pt，`frame(width:17,height:21)`，左内边距 31；标题 10.8pt、时间 8.2pt） |
| More 行 | 高 26 |
| 状态栏 | 高 30 |
| 设置面板 | 宽 420，圆角 16，滑块 step 0.5 |

### 7.4 吉祥物 `ClawdMark`（`:547`）

`Canvas` 手绘的像素图，`viewBox = CGRect(x: 0, y: 3, width: 15, height: 15)`（等边，保证光学居中）。`cells` 数组定义每块 (x, y, w, h, kind)：

```
四条腿 (3,11) (5,11) (9,11) (11,11)  各 1×4
身体   (2,6) 11×7
双手   (0,9) (13,9)  各 2×2
双眼   (4,8) (10,8)  各 1×2
```

颜色：身体 `(0.843, 0.467, 0.341)`，眼 `(0.102, 0.102, 0.102)`。绘制时每块 `+0.5` 补缝，外层 `.drawingGroup()`。

> 想给 App 加图标时，这个 Canvas 就是现成的图形来源（目前 `Contents/Resources/` 是空的、`Info.plist` 没有 `CFBundleIconFile`）。

---

## 8. 状态栏 ↔ Claude Code 联调

四组控件都在 `StatusBarView`（`:1011`），点击后走 `Store` 的同名方法。

### 8.1 模式：靠发 Shift+Tab 实现

`claude` 没有「直接设成某个模式」的命令行开关能作用于运行中的进程，所以只能模拟按键：

```swift
static let modeCycle: [PermissionMode] = [.auto, .manual, .acceptEdits, .plan]
```

这是 PTY 里实测出来的循环顺序（不是文档里写的顺序）。`cycleTo(target)` 算出需要的步数，然后 `sendShiftTab(times:)` 连续发 `"\u{1b}[Z"`：

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { ... }   // 每步间隔 320ms
```

**间隔不能省**——连发太快会被 claude 吞掉，模式只前进一格。

发完再写 `~/.claude/settings.json` 的 `permissions.defaultMode`（下次启动才生效）。

### 8.2 模型 / 推理强度 / 快速模式

| 操作 | 对运行中的进程 | 对磁盘 |
|---|---|---|
| 换模型 | `send("/model <alias>\n")` | `model = <alias>` |
| 换强度 | `send("/effort <level>\n")` | `modelSettings[canonicalId].effortLevel = <level>` |
| 切 fast | `send("/fast\n")` | `fastMode = !fastMode` |

**推理强度的 canonical id 陷阱**：`modelSettings` 的键必须是 `claude-<model>-5-5`（例如 `claude-opus-5-5`），写 `opus` 无效——读不到就静默回落默认值。

`max` 强度在当前实现下会被 claude 静默降级成 `medium`，只有命令行 `--effort max` 才能真存住。

### 8.3 用量圆环

`UsageFetcher`（`Models.swift:400`）：

```
security find-generic-password -s "Claude Code-credentials" -w
   → 解析 JSON → claudeAiOauth.accessToken
   → GET https://api.anthropic.com/api/oauth/usage
     headers: Authorization: Bearer <token>
              anthropic-beta: oauth-2025-04-20
     timeout: 12s
   → five_hour / seven_day 的 utilization + resets_at
```

失败文案：`"无凭据"`（Keychain 里没有）/ `"无数据"`（返回体两个窗口都空）/ 其他错误。刷新间隔 90 秒（`usageTimer`）。

---

## 9. 终端集成（`TerminalPane.swift`）

```
TerminalSession           包装 LocalProcessTerminalView
├── view                  SwiftTerm 的 NSView
├── cwd                   启动目录
├── readyAt               启动后 1.6 秒内拒绝 send()（PTY 还没接管）
├── send(_:) -> Bool      直接往进程 stdin 写 UTF-8
├── terminate()           view.terminate()
└── applyFont(...)        空字名走 monospacedSystemFont
```

关键实现：

```swift
view.startProcess(executable: "/bin/zsh",
                  args: ["-lc", cmd],
                  environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                  execName: "claude",
                  currentDirectory: cwd)
```

- 走 `/bin/zsh -lc` 而不是直接 exec `claude`，是为了拿到用户的完整 PATH（`claude` 通常在 `~/.local/bin` 或 nvm 目录下）。
- `exec` 前缀让 zsh 被替换成 claude，进程树里少一层。
- `TerminalPane.makeNSView` **直接返回 `session.view`**，`updateNSView` 是空的——同一个 NSView 实例复用，靠外层 `.id(ObjectIdentifier)` 切换。
- 配色硬编码在 `configure`：底色 `(0.055, 0.062, 0.078)`、前景 `(0.90, 0.91, 0.93)`、光标 `(0.95, 0.55, 0.35)`。

### 9.1 忙闲判定（loading）

任务状态优先跟随 Claude CLI 的 OSC 7501 结构化报告。`programStatusChanged` 收到任一 `working` 记录时置忙，子代理仍在运行时保持忙状态。`blocked` 暂停指示并清除本次完成标记，`done` / `idle` / `error` 及记录清除在全部任务停止后置闲。

SwiftTerm 会向 CLI 声明支持 OSC 7501，新版 Claude 协商成功后会省略标题 spinner。收到结构化报告后持续以该通道为准。

旧版 CLI 使用 OSC 0 标题信号。忙帧 `◐ ◑ ◒ ◓`（VTE 系为 `>`）置忙，空闲帧 `✳`（VTE 系为 `*`）置闲。无状态前缀的标题只更新标题文本。

标题通道在空闲会话切换视图后的 1.2 秒、终端用户输入后的 0.8 秒内过滤重绘忙帧。结构化任务状态立即生效。键盘输入按第一响应者识别，鼠标操作包含终端子视图。空闲信号始终生效，已运行的任务在切换视图或输入期间保持状态。

`onBusy` 同步更新 `Store.runningKeys`，会话行橙色转圈跟随这个集合。切走后仍在执行或新开始执行的任务完成时才加入 `unreadKeys`，打开会话清除未读标记。空闲进程退出保持已读状态。

运行指示依赖 CLI 的任务状态或终端标题报告，设置 `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` 会停用这些报告。

终端滚轮灵敏度设为 `0.25`，通过独立的 `allowMouseWheelReporting` 使用 CLI 的鼠标滚动上报。普通滚轮在低灵敏度下累计不足一行的距离，避免最小一步抵消减速设置。

鼠标点击同样上报给 CLI（`allowMouseReporting = true`）。Claude Code 全屏界面里点击折叠的工具调用行（如「Searched for 1 pattern, read 1 file」）展开、点击「Jump to bottom」回到底部，都依赖这个上报。CLI 没开鼠标模式时，拖动仍由终端本地选中文字；开了以后按住 Shift 或 Option 拖动强制本地选中。右键由 `CopyableTerminalView.rightMouseDown` 固定弹出「复制 / 粘贴 / 全选」菜单，不发给 CLI。

链接使用 `linkHighlightMode = .hover`：鼠标悬停识别链接，普通单击打开，不需要按住 ⌘。打开前仍经过 SwiftTerm 的链接安全检查。

回归验证运行 `./scripts/check-session-regressions.sh`，覆盖总结解析、打开时刷新、忙闲切换和后台未读条件。测试子进程使用隔离的替身命令。

---

## 10. 已知坑（改代码前必读）

1. **`@State` / `@Observable` 用不了。** CommandLineTools 缺 `SwiftUIMacros`，报错：
   ```
   external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
   ```
   所有临时状态都塞进 `Store`（`ObservableObject` + `@Published`）。

2. **`terminalArea` 不能用 `ZStack`。** 状态栏会叠在终端上。必须 `VStack(spacing: 0)`。

3. **抢占前台需要两处一起改。** `NSApp.setActivationPolicy(.regular)` 和 `Info.plist` 的 `LSUIElement = false` 缺一不可。只改一个，窗口永远被别的 App 压着。

4. **`.onDrag` / `.onDrop` 必须挂在 `Button` 的 label 上**（`contentShape` 之后）。挂在行容器上会被按钮的命中区域吃掉。

5. **`ScrollView` 不能加 `.id(...)`。** 会让 selection 状态重置，表现为「按方向键列表跳回顶部」。

6. **`osascript ... set frontmost to true` 对这个 App 报 `-10006`。** 验证/自动化时改用：

   ```swift
   NSRunningApplication.runningApplications(withBundleIdentifier: "local.zcl.claude-picker")
       .first?.activate(options: [.activateAllWindows])
   ```

7. **截图验证必须确认缩放倍率。** 用 `CGWindowListCopyWindowInfo` 拿 window id，再 `screencapture -x -o -l <wid> out.png`。同一台机器上 Retina 有时给 1x 有时给 2x，每次先用 Pillow 读一下尺寸再算坐标，否则点击坐标全错。

8. **自动化点击需要发 `mouseMoved`。** 只发 down/up 时 SwiftUI 的 hover 状态不更新，按钮不响应。正确序列：`CGWarpMouseCursorPosition` → `mouseMoved` → 等 80ms → `leftMouseDown` → 等 90ms → `leftMouseUp`。另外桌面上常驻多个 `layer = 0` 的浮窗会抢点击，点击前先把目标 App 激活并等 0.7 秒。

9. **`NSEvent.mouseLocation` 是左下原点**，而点击事件用的是左上原点的屏幕坐标。换算时注意。

10. **`installTerminalKeyMonitor()` 必须在终端挂载后再注册。** SwiftTerm 自己注册了 keyDown 监视器，先注册的会被它吃掉。

11. **`StatusBarView` 的 `Menu` label 只能是单个 `Text`。** `.menuStyle(.borderlessButton)` 会把复合 label 当模板图渲染，文字消失。

12. **改完必须重新签名。** 无论是 `./scripts/build-app.sh` 还是手写 `cp`，覆盖 `Contents/MacOS/ClaudePicker` 之后旧签名必然失效，不重签会启动失败（`codesign` 校验不过直接被 Gatekeeper 拦）。

13. **`dist/` 不在仓库里。** `.gitignore` 挡掉了 `dist/`、`*.dmg`、`*.zip`。安装包只通过 GitHub Releases 分发；`git status` 干净就说明没误提交。

14. **`swift-tools-version:6.2` 要求 Swift 6.2+。** 老版本工具链会直接拒绝解析 `Package.swift`。`platforms: [.macOS(.v14)]` 是编译期下限，`Info.plist` 的 `LSMinimumSystemVersion` 由 `build-app.sh` 的 `MIN_MACOS` 控制，两者要对齐。

---

## 11. 迭代 checklist

### 11.1 改 UI 外观

1. 常量都在 `main.swift:6-18` 或对应视图的类型内部，先改常量再改视图。
2. 用 `git diff` 之外的方式确认改动点：`grep -n "kSidebarW\|kTerminalTopPad" Sources/ClaudeDeck/main.swift`。
3. `./scripts/build-app.sh` 部署。
4. 截图验证：`screencapture -x -o -l <wid>`，用 Pillow 确认尺寸后裁切放大关键区域。

### 11.2 加一个树上的新动作（例如「恢复误删会话」）

1. 数据在 `TreeOrder.hiddenSessions`，读写在 `Store.init` / `persistTree()`。
2. 加方法：从 `hiddenSessions` 移除 sid → `persistTree()` → 重建 `projects`（当前架构下最简单的做法是提示用户重启，或调 `buildProjects()` 重新赋值 `store.projects`）。
3. 挂入口：`SessionRowView` / `ProjectRowView` 的 `.contextMenu`，或侧栏头部加一个按钮。
4. 注意 `rows` 是计算属性，`projects` 变了之后 `sel` 可能越界，改完要 `clampSel()`。

### 11.3 加一个状态栏控件

1. 在 `Models.swift` 加类型 + `ClaudeConfig` 的读写方法。
2. 在 `Store` 加 `@Published` 字段和 setter（setter 里同时做「写盘」和「发斜杠命令」两件事）。
3. 在 `StatusBarView` 的 `HStack` 里插一个 `menu(label:value:)` 或按钮，注意前后加 `sep`（分隔符视图）。
4. `reloadClaudeOptions()` 里补上外部改动的同步。

### 11.4 加启动参数

`parseArgs()`（`:31`）里加一个 `case`，`LaunchArgs` 加字段，然后在 `applicationDidFinishLaunching` 里用。`--start` / `--resume` 就是这么接的（为兼容 `cc-open`）。

### 11.5 想做的事（还没做）

- [ ] 「恢复误删会话」UI 入口（见 §11.2）。
- [ ] 同时开多个终端（当前 `open()` 会先 `terminate()` 旧的）。做法：`active` 改成 `[TerminalSession]` + `selectedTab`，`TerminalPane` 按 tag 切换。
- [ ] 通用二进制：现在只出 arm64。可试 `./scripts/build-app.sh` 里加 `--arch arm64 --arch x86_64`，但 vendored SwiftTerm 也要能双架构编译。
- [ ] CI：现在构建和发版全在本地 `scripts/build-app.sh` + `gh release create`，可以接 GitHub Actions。

### 11.6 已完成（不要再做一遍）

- [x] App 图标：`scripts/make_icon.py` 从 `ClawdMark` 的 cells 生成，`Info.plist` 带 `CFBundleIconFile=AppIcon`。
- [x] 硬编码路径 `panel.directoryURL`：改为从 `FileManager.default.homeDirectoryForCurrentUser` 派生。
- [x] 遗留文件清理：根 `main.swift`、`order.json`、`main.swift.bak66` 已删除。
- [x] 忙闲指示（loading）：OSC 7501 任务状态及 OSC 0 标题兼容，会话行转圈、后台绿点（见 §9.1）。
- [x] 会话总结：`Session.summary` 来自 jsonl 尾部 `ai-title`/`summary` 记录，会话行第一行显示总结，第二行仅显示相对时间（见 §4.3）。
- [x] 滚轮翻页：vendored SwiftTerm 的 alternate buffer 滚轮改发 `cmdPageUp/PageDown`，不再发方向键（claude 会把 ↑ 当历史导航）。

---

## 12. 快速命令备忘

```bash
cd /Users/zcl/project/claude-picker

# 构建 + 打包
./scripts/build-app.sh              # 只出 app
./scripts/build-app.sh --zip        # app + zip
./scripts/build-app.sh --dmg        # app + dmg

# 本地部署并重启
pkill -x ClaudePicker; sleep 0.3; open -a "$PWD/dist/ClaudePicker.app"

# 装到 /Applications（用新版本时）
ditto dist/ClaudePicker.app /Applications/ClaudePicker.app

# 看状态文件
cat ~/.local/share/claude-picker/settings.json
python3 -m json.tool ~/.local/share/claude-picker/tree.json | head -40
python3 -m json.tool ~/.claude/settings.json

# 恢复被误删的会话：编辑 tree.json，把 sid 从 hiddenSessions 删掉
python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home()/".local/share/claude-picker/tree.json"
d = json.loads(p.read_text())
d["hiddenSessions"] = []
p.write_text(json.dumps(d, ensure_ascii=False, indent=2))
PY

# 找窗口 id 并截图（验证 UI）
/tmp/tools/widonly            # 自建小工具，CGWindowList 过滤 owner
screencapture -x -o -l <wid> /tmp/cp.png
```


### 2026-11-17 终端输入与图形聊天边界修复

原生终端（macOS 与 Electron）不再挂载外壳的 terminal-dock 输入框，直接由终端提供输入、选择及滚动交互；终端收起时只提供恢复入口。浏览器演示保留输入框。该调整不替换 main 的终端实现，仅移除外壳额外输入层。

图形聊天修改 Swttch ChatPage：消息滚动区使用 flex 剩余空间并允许缩小，输入/审批区域作为滚动区外的独立兄弟节点，从布局上阻止消息经过输入框后方。移除更新横幅和浏览器通知横幅，保留连接/认证错误提示。改动已保存到 patches/swttch/0002-composer-outside-transcript.patch；上游既有 TranscriptToolRun.tsx 改动未纳入该补丁。

验证：Swttch 布局用例修改前 2 项失败，修复后布局和顶部栏共 9 项通过；Web、v003 与 Swttch 前端生产构建通过，开发版使用 --dev --with-chat 构建。agent-desktop 辅助功能权限仍为 denied，通过 CUA 读取当前开发版确认旧版现场；未重启正在使用中的 App，修正版实际桌面交互尚待重启复验。

### 2026-11-17 界面重构（按 H5 原型 v003）

技术方案与逐个按钮的交互约定见 [docs/ui-refactor-v003.md](docs/ui-refactor-v003.md)，确认记录在其 §14。在当前分支直接开发。

| 模块 | 实现入口 |
|---|---|
| 顶部页签（显示、排序、拖拽、⌘1–⌘4）、第一栏切换与宽度 | `Web/src/shell/ModuleViews.jsx`、`App.jsx`、`modules.css`；原生 `AppSettings.navigation`、菜单「显示 → 切换到第 N 个页签」 |
| 工作空间侧栏 | `Sidebar.jsx`：移除「我的待办」「Work 中心」快捷入口与「执行队列」；第二栏右侧「工作台」竖条移除 |
| 变更模块 | `App.jsx` 的 `branchPicker`：变更页签下分支搜索与选择器放在第一栏 |
| TAPD 模块 | `work/TapdModule.jsx`（取代 `TapdPage.jsx`）；原生新增 `tapd.fields`、`tapd.related`、`tapd.comment`、`tapd.transition`，`tapd.todos` 增加 `scope:'created'`、迭代名、创建时间 / 创建人；写操作经 `TapdWriteOnce` 按 requestId 去重、不自动重试、结果不明时回读 |
| Work 模块 | 沿用 `work/BoardPage.jsx`（用户截图确认），新增 `category` 过滤列与 `focusId` 定位 |
| 悬浮终端 | `FloatingConsole.jsx`：尺寸达到阈值时渲染 `data-terminal-hole`，原生终端随浮窗移动；浮层自管位置时派发 `claude-picker:layout` 让外壳重新回报布局 |
| 桌宠 P1 | `pet/`：`themes.js`（Dev Life 读取素材自带 `theme.json`，Codex 像素版同语义映射）、`usePetSignals.js`（会话 + Work 汇总状态与一次性事件）、`DesktopPet.jsx`、`PetSettings.jsx`；素材在 `Web/src/assets/pet/` |
| 外部链接 | 原生 `app.openURL`（只接受 http / https），网页用 `openExternal()` |
| 原生终端运行参数条 | `Composer.jsx` 的 `RuntimeBar`：原生终端（macOS / Windows，非图形聊天）下方显示「模式 / 模型 / 推理强度 / 快速模式」快捷下拉，走 `app.runtime`；悬浮终端放大显示真实终端时同样挂在终端下方 |

浏览器预览：`cd Web && npx vite`，地址带 `?demo` 时 mock 提供演示 Work 与 TAPD 数据（不进入应用）。

验证：`vite build`、`swift build` 通过；`scripts/test-work.sh` 191 项、`scripts/test-git.sh`、`scripts/check-session-regressions.sh`（会话 / 终端 / 桥接）全部通过。用无头 Chrome 在 `?demo` 预览上逐项操作：页签拖拽排序、隐藏 / 只留工作空间 / 全部隐藏、第一栏宽度按模块记忆、变更第一栏分支控件、Work 分类计数与单列显示、TAPD 分组表格 / 项目过滤 / 详情 / 评论 / 流转同步列表 / 变更历史 / 创建任务默认名称 / 最近访问、悬浮终端打开 / 展开 / 缩放 / 跨模块保留、桌宠单击 / 右键菜单 / 打开当前会话，均无控制台错误。开发包 `--dev --with-chat` 已构建并启动，截图确认新布局与桌宠渲染。

待验证：原生窗口内的鼠标交互（悬浮终端承载真实终端时的拖动与缩放、桌宠盖在终端上时的点击）未做实机操作；TAPD 评论与流转尚未在真实工作项上写入（需要用户提供可修改的测试工作项 ID）。

### 2026-11-17 桌宠 P2：桌面悬浮窗

macOS 上桌宠改为整个桌面可见的透明悬浮窗（`Sources/ClaudeDeck/ThirdPane/PetPanel.swift`：`PetController`、`PetPanel`、`PetHandlers`），设计与交互见 [docs/ui-refactor-v003.md §16](docs/ui-refactor-v003.md)。网页侧入口 `Web/src/main.jsx`（`?pet=desktop` 只加载 `pet/PetWindow.jsx`），`DesktopPet` 增加 `desktop` 形态与头顶提示气泡，`usePetSignals` 输出状态提示（Work 编号、标题、进度说明、完成的会话）。`Bridge.emit` 同时推给 `Bridge.petWebView`。设置新增 `pet.desktopX / desktopY`。

同时修正：TAPD 缺陷列表与详情的状态显示内部键（new / status_2 …），改为按项目状态字段翻成显示名。

验证：`swift build`、`vite build` 通过；Work 回归 191 项、会话 / 终端 / 桥接回归通过；无头 Chrome 检查桌宠页面与窗口内气泡；开发包启动后用 CGWindowList 确认悬浮窗在 floating 层级显示于其它 App 之上、背景透明，主窗口不再显示窗口内桌宠。透明区域点击穿透、拖动跨屏、全屏 App 旁显示需要实机操作确认。

### 2026-11-18 多引擎共用会话架构与 Antigravity CLI 集成

围绕「Shared Thread + Driver/Adapter 分层 + Turn Checkpoint」完成双引擎接入与代码检查点回退，技术方案、架构深度评估与全量交互规范见 [docs/antigravity-integration-plan.md](docs/antigravity-integration-plan.md)、[docs/multi-agent-architecture-evaluation.md](docs/multi-agent-architecture-evaluation.md) 与 [docs/multi-agent-development-spec.md](docs/multi-agent-development-spec.md)。

| 模块 | 实现入口 |
|---|---|
| 引擎抽象与 Antigravity 扫描 / 配置 / Handoff | `Sources/ClaudeDeck/AgentProviders.swift`、`Models.swift`、`TerminalPane.swift`、`main.swift`、`ThirdPane/BridgeHandlers+Session.swift`：只读扫描 `~/.gemini/antigravity-cli/conversation_summaries.db` + `conversation_metadata.json` + `transcript.jsonl`（剔除子代理与已销毁会话、剥离 `<USER_REQUEST>` 标签、读取 1M 上下文窗口占用）；新建终端会话占位键自动晋升真实 `conversationId`；四层 `<thread-handoff>` 跨 CLI 接力信封；Swttch 图形模式打开 Antigravity 会话自动回退原生终端 |
| ACP 结构化执行器与共用 Thread 切换 | `Sources/ClaudeDeck/Work/ACPExecutor.swift`、`ClaudeExecutor.swift`、`WorkStore.swift`（Schema v1 → v2 自动备份迁移，新增 `works.executor`、`works.reverted_notice`、`thread_segments`、`checkpoints`）、`WorkCore.swift`、`WorkCore+Execution.swift`、`ThirdPane/BridgeHandlers+Work.swift`：对接 `agy acp`（JSON-RPC 2.0 stdio），支持流式增量、工具卡片、双向权限确认与取消；支持 Work 在非运行态通过 `work.switchExecutor` 无缝切换执行引擎并自动注入前情 `<thread-handoff>` |
| Turn Checkpoint 代码快照与外科回退 | `Sources/ClaudeDeck/Work/WorkspaceService.swift`、`WorkCore+Review.swift`：每轮前后用临时 index `write-tree` + `commit-tree` 锚定到隐藏引用 `refs/claude-picker/checkpoints/<workId>/<seq>`（防 `git gc` 回收且不污染分支与 `git status`）；`checkpoint.revert` 自动生成 `undo` 备份点、校验共享目录外部未保存修改冲突，并在下一轮向智能体注入 `<workspace-reverted-notice>` 消除上下文幻觉 |
| 双源 MCP 服务管理 | `Sources/ClaudeDeck/ThirdPane/McpService.swift`、`BridgeHandlers+Mcp.swift`、`Web/src/shell/Modals.jsx`：支持管理 `~/.gemini/config/mcp_config.json`，拦截旧版 SSE 传输，提供「从 Claude 导入」一键合并兼容的 `stdio` / `http` 服务 |
| 前端多引擎与回退交互 | `Web/src/shell/Sidebar.jsx`、`Composer.jsx`、`Modals.jsx`、`App.jsx`、`work/WorkModals.jsx`、`work/WorkChat.jsx`、`work/ContextPanel.jsx`、`work/SettingsModal.jsx`、`work/BoardPage.jsx`：侧栏引擎筛选与 `C`/`A` 徽标、会话右键与底部引擎胶囊接力续聊、新建会话引擎卡、Work 内引擎切换菜单、轮次分割线「↺ 回退到此轮前」与详情栏「撤销上次代码回退」、设置页 CLI 实时诊断 |

验证（分支 `codex/wt-20261118`，开发包 `dist-dev/ClaudePickerDev.app`）：
- 构建：`swift build`（Debug/Release）、`Web` `vite build`、`./scripts/build-app.sh --dev` 全部通过（签名 `ClaudePicker Local Dev` 校验有效）。
- 回归脚本：`./scripts/test-git.sh` 全部通过；`./scripts/check-session-regressions.sh`（Session / Terminal / Bridge，含 Antigravity SQLite 扫描、标签清洗、1M Token 统计、`<thread-handoff>`、`session.handoff`、Swttch 自动降级、Antigravity MCP 导入与 SSE 拦截）全部通过；`./scripts/test-work.sh`（含 `fake-agy-acp.py` ACP 协议替身、跨引擎 `claude → antigravity` 接力、隐藏 Git Ref 检查点回退、`undo` 备份、共享目录外部改动冲突保护与 `<workspace-reverted-notice>` 注入）**213 项全部通过，0 项失败**。
- 界面与运行验收：无头 Chrome CDP 在构建产物上逐项点击验证侧栏引擎筛选、底部接力切换、新建会话双引擎卡、设置页 CLI 状态、MCP Antigravity 页签与导入按钮、新建 Work 引擎选项，控制台 0 报错；启动 `dist-dev/ClaudePickerDev.app`（PID `54588`），通过 `CGWindowListCopyWindowInfo` 与只读 SQLite 校验确认主窗口（`1360×800`）、桌面悬浮窗（`layer=3`）正常挂载，开发库平滑迁移至 `user_version = 2`（含 `checkpoints`、`thread_segments` 表）。`agent-desktop status` / `snapshot` 当前因系统辅助功能与屏幕录制权限为 `denied` 返回 `PERM_DENIED`；授权后（运行 `agent-desktop permissions --guide`）可继续用 `agent-desktop` 做原生窗口 AX 交互复验。

### 2026-11-18 Antigravity 终端主题配色调整与 `test` 渠道提测交付

- **来源分支 → 目标分支**：`codex/wt-20261118` → `test`（版本 `1.0.0`）
- **变更摘要**：
  - `Sources/ClaudeDeck/TerminalPane.swift`：新增 `kAntigravityTerminalBackground`（`#212734`）与 `TerminalSession.backgroundColor(for:)` / `theme(for:)`；Antigravity 会话启用 `#212734` 底色、柔化前景色 `#c5cdd9` 及调色后的 ANSI 16 色（将过饱和深紫蓝 `#492ee1`/`#5833ff` 调整为浅蓝 `#73b8f2`/`#89c4f4` 并柔化高亮白 `#cfd7e3`），Claude 会话保持 `#202122` 原样。
  - `Sources/ClaudeDeck/ThirdPane/ShellView.swift`、`Sources/ClaudeDeck/main.swift`：通过 `Store.activeTerminalBackground` 与 `ShellView.showTerminal(_:backgroundColor:)` 同步更新窗口外壳与 `terminalHost` 图层底色，消除 `.terminal-hole` 四周留白处的底色接缝。
  - `Web/src/shell/App.jsx`、`Web/src/shell/style.css`、`Web/src/shell/DesktopTerminal.jsx`：为 `.terminal-pane` 增加 `is-antigravity` 状态类，使空白引导区与 Windows xterm 终端同步应用 `#212734` 与柔化配色。
  - `Tests/TerminalRegression/main.swift`：新增 Claude（`#202122`）与 Antigravity（`#212734` 及柔化前景）主题回归断言。
- **验证与产物**：
  - 回归与构建：`./scripts/check-session-regressions.sh`（Session / Terminal / Bridge）、`npm --prefix Web run build`、`swift build -c release --disable-sandbox` 均通过；开发包 `./scripts/build-app.sh --dev` 与测试包 `./scripts/build-app.sh --test` 均构建并签名通过。
  - 测试包产物：`dist-test/ClaudePickerTest.app`（`local.zcl.claude-picker.test.dev`）。
  - 待处理事项：`agent-desktop` 在当前沙盒环境返回 `PERM_DENIED`，测试版 App 启动后的实际界面交互与桌面验收待本机环境打开确认。


### 2026-11-19 macOS 测试包交付

- 从 `test` 的 `3500532` 构建 `1.0.0 (20261119)`。该提交已包含 `codex/agent-workspace-development-spec` 的桌宠和图形聊天调整，以及 `codex/wt-20261118` 的 Antigravity CLI 集成和终端配色。
- 使用 `./scripts/build-app.sh --test --with-chat --dmg` 生成 `dist-test/ClaudePickerTest-1.0.0.dmg`。图形聊天从 Swttch 基线 `3285a17` 应用仓库记录的四个补丁后重建。App 深度签名和 DMG 校验均通过。
- Git、会话、终端及桥接回归通过，Work 213 项和图形聊天定向回归 8 项通过。
- 从 `/Applications/ClaudePickerTest.app` 使用独立临时状态目录启动，确认测试渠道和主窗口显示。辅助功能权限未授予，使用系统窗口截图核对主界面，未执行控件级验收。
- 验收后退出测试版，移除本机发现的旧 App 副本。复查仅保留测试版 App，未发现相关进程或 launchd 任务。
