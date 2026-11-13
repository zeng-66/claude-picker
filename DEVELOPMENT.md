# ClaudePicker 开发文档

> 一个 macOS 原生小工具：左侧是可展开的会话树，右侧内嵌终端直接跑 `claude --resume <sid>`。
> 本文档面向后续迭代开发，记录架构、数据链路、状态文件、UI 常量、交互约定和已知坑。

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
./scripts/build-app.sh          # 编译 + 组装 dist/ClaudePicker.app + 图标 + 签名
pkill -x ClaudePicker; sleep 0.3
open -a dist/ClaudePicker.app
```

脚本做六件事：`swift build -c release` → 组装 `dist/ClaudePicker.app`（可执行文件从 `.build/release/ClaudeDeck` 复制并改名为 `ClaudePicker`）→ 用 `scripts/make_icon.py` 生成 `AppIcon.icns` → 写 `Info.plist` → `codesign --force --deep --sign -` → 可选 `--zip` / `--dmg`。

环境变量可覆盖打包参数：`VERSION`（默认 1.0.0）、`BUILD_NUMBER`（默认 1）、`MIN_MACOS`（默认 14.0）。

### 2.2 手写四步（脚本不适用时）

```bash
cd /Users/zcl/project/claude-picker
swift build -c release                                          # 1. 编译
cp .build/release/ClaudeDeck dist/ClaudePicker.app/Contents/MacOS/ClaudePicker   # 2. 换可执行文件
codesign --force --deep --sign - dist/ClaudePicker.app          # 3. cp 之后签名必然失效
pkill -x ClaudePicker; sleep 0.3; open -a dist/ClaudePicker.app # 4. 重启
```

一次完整 release 构建约 5~9 秒（增量更快）。构建成功会打印 `Build complete! (5.50秒)`。注意二进制产物名是 `ClaudeDeck`，bundle 里的名字是 `ClaudePicker`。

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
pgrep -x ClaudePicker                        # 拿到 pid
ls -l dist/ClaudePicker.app/Contents/MacOS/ClaudePicker   # 时间戳应该是刚刚
codesign -dv dist/ClaudePicker.app 2>&1 | head -3         # 签名状态
```

**不要把「编译通过」当成「已生效」**——忘记 cp 或忘记 pkill 都会让你以为改动没起作用。

### 2.6 工具链事实

```
swift-driver version: 1.168.6  Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)
Target: arm64-apple-macosx27.2.0
```

只用 CommandLineTools（没有完整 Xcode）。这带来一个硬约束，见 §10 第 1 条。

---

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
| 读取量 | 每个文件只读**前 128KB**（`head(_:bytes: 131072)`），截断到最后一个 `\n` 后再逐行解析 |
| `sid` | 文件名去掉 `.jsonl` |
| `date` | 文件 `contentModificationDate`（**不是**消息里的时间戳） |
| `cwd` | 第一条带 `cwd` 字段的记录 |
| 标题 | 只认 `type == "user"` ∧ `isSidechain != true` ∧ `origin.kind == "human"` 的消息，取 `message.content` 文本 → `summarize` |
| 总结 | `tailSummary`：另读文件**尾部 64KB**，取最后一条会话标题记录——新版 CLI 写 `{"type":"summary","summary":...}`，2.1.x 写 `{"type":"ai-title","aiTitle":...}`，两种都认；没有则 `summary == nil`，会话行只显示相对时间 |
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

两条通道，标题通道优先：

1. **OSC 0 标题 spinner（主通道）**。claude CLI 忙时每 ~960ms 通过 `ESC]0;<spinner><标题>BEL` 重写终端标题，spinner 前缀即状态：`◐ ◑ ◒ ◓`（VTE 系为 `>`）= 忙，`✳`（VTE 系为 `*`）= 空闲。`setTerminalTitle` 里 `parseSpinnerTitle` 剥前缀得干净标题 + `spin: Bool?`（无前缀 → nil，不动 busy）。见到 spinner 即置 `titleChannelActive = true`，并刷新 `titleFreshUntil = now + 5s`。用户刚输入过（`userInputUntil` 内）时忽略 spinner 帧——滚轮翻页会触发 claude 重绘标题带 spinner，误判成忙（Bug#1）。
2. **CPU 采样（兜底）**。`sampleCpu` 每 0.4s 用 `proc_pid_rusage` 取进程 CPU 增量，`delta ≥ 250_000ns` 连续 2 拍 → busy，连续 2 拍无增长 → 不忙。仅当标题通道没被确认（用户设了 `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`，标题 5s 不新鲜）时生效：`guard !titleChannelActive, now >= titleFreshUntil else { return }`。抑制期（`suppressUntil` 激活/切走 1.2s、`userInputUntil` 打字 0.8s）内**仍必须推进 `lastCpuNanos` 基线**再 return，否则窗口过后首拍会把攒下的 CPU 当爆发误判成忙（Bug#2）。

busy 的消费方：`onBusy(true)` → `Store.runningKeys` 加 key（会话行橙色转圈，`TimelineView` 驱动）；`onBusy(false)` 时若 pane 在后台且 `awayOutput == true` → `unreadKeys` 打绿点。前台终端另有左上角「工作中」胶囊（`terminalArea` 的 `.overlay(alignment: .topLeading)`）。

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
- [x] 忙闲指示（loading）：OSC 0 标题 spinner 主通道 + CPU 采样兜底，会话行转圈、终端「工作中」胶囊、后台绿点（见 §9.1）。
- [x] 会话总结：`Session.summary` 来自 jsonl 尾部 `ai-title`/`summary` 记录，会话行第二行显示「相对时间 · 总结」（见 §4.3）。
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
