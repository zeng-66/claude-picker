# Git 工作台接入：多智能体协作开发计划

> 基于 `docs/git-workbench-prototype/`（未提交的 H5 交互原型 + 规格文档）与当前 `master` 分支的 Swift 客户端代码制定。
> 目标：把原型里的**第三栏 Git 工作台 / 文件预览 / 会话创建**接入 ClaudePicker 本体，替换掉全部模拟数据。
> 本文件是排期与派发的唯一事实源；任务卡编号 T0–T12 与共享任务板一一对应。

---

## 0. 结论先行

- **承载形态选 WKWebView**（前端复用原型，Swift 只做能力层），不原生重写。理由见 D1。
- **不要一上来就 3 路并行**。当前有三处「单文件热点」会让并行 agent 互相踩死：
  `Sources/ClaudeDeck/main.swift`（1984 行）、`src/App.jsx`（97 行里塞了 9 个页面）、`src/FileBrowser.jsx`（910 行）。
  必须先做一次**单窗口的基础冲刺**（T0–T3，拆文件 + 定协议 + 起第三栏），之后才允许 3 路并行。
- **最大隐藏地雷**：`scripts/check-session-regressions.sh` 用字符串切片改写 `main.swift`，并断言 `TerminalPane.swift` 里 `executable: "/bin/zsh"` 恰好出现 1 次。任何碰这两个文件的任务都必须同步改回归脚本，否则 CI 直接红。

---

## 1. 事实基线

| 项 | 现状 |
|---|---|
| 分支 | `master`（`a8a3a89`），工作区干净，仅 `docs/git-prototype/`、`docs/git-workbench-prototype/` 未跟踪 |
| Swift 侧 | 3 个文件 / 2732 行：`main.swift` 1984、`Models.swift` 536、`TerminalPane.swift` 212；SwiftUI，`PickerView` 里是 `HStack{ sidebar, terminalArea }` 两栏 |
| 第三栏 | 不存在，需新增 |
| WebKit | 全仓未引用，需首次引入（系统框架，SwiftPM 直接 `import WebKit`，无需改依赖） |
| 沙盒 | 无 entitlements，`codesign --deep --sign -`（ad-hoc）。子进程 `git` 与任意路径读写可行，因此**路径校验必须自己做** |
| 进程 | 已通过 `/bin/zsh -lc` 起 claude（`TerminalPane.swift:76`），PATH 问题已有先例可复用 |
| 前端 | Vite 6 + React 19，`npm run build` → `dist/client`；另有 Sites 相关（`.openai/`、`worker/index.js`、`scripts/prepare-sites-build.mjs`、`tests/sites-worker.test.mjs`）Mac 端不需要 |
| 验证手段 | `swift build` + `scripts/check-session-regressions.sh` + 前端 `npm run build` + 手测截图；无 Swift 单测框架（Tests 是两个 main.swift 回归程序） |
| 规格 | 原型内 `DEVELOPMENT.md` 814 行已定义数据模型、按钮清单、GitAPI/FileAPI/SessionAPI、错误码、颜色尺寸、11 步实施顺序、测试清单 |

### 1.1 规格里已经定死、实现时不要重新发明的部分

- 三栏网格：`210px | minmax(220px,1fr) | minmax(570px,55%)`；终端收起为 `44px` 窄条。
- 状态色：未暂存 `#d4b56f`、已暂存 `#91bd9c`、删除 `#d78e8c`、未跟踪 `#7fadd4`，且**颜色必须配 A/M/D/? 字母**。
- Git 错误码：`NOT_A_REPOSITORY / DETACHED_HEAD / BRANCH_EXISTS / WORKTREE_PATH_EXISTS / DIRTY_WORKTREE / MERGE_CONFLICT / PERMISSION_DENIED / COMMAND_FAILED`，带 `recoverable`。
- Worktree 目录：`{projectPath}/.worktrees/{branchSlug}`，命令 `git worktree add <path> -b <branch> <current>`，执行前 6 项检查，执行后必须能「保留 Worktree / 重试会话 / 清理 Worktree」三选一。
- 破坏性操作（放弃修改、reset、clean、删除 worktree、终止合并、删除 stash）必须二次确认。

---

## 2. 三个架构决策

### D1 承载形态：WKWebView 承载原型，Swift 做能力层

| 方案 | 工作量 | 复用 | 风险 |
|---|---|---|---|
| **A. WKWebView + JS 桥（选）** | 中 | 原型 UI 全量复用（Diff / Mermaid / PDF / 编辑器 / 主题色） | WebKit 内存、键盘焦点冲突 |
| B. SwiftUI 原生重写第三栏 | 高（Mermaid、Markdown、PDF、代码高亮全要重做或再嵌 WebView） | 无 | 颜色/密度与原型两张皮，返工风险大 |
| C. 独立子进程 Web 服务 + 浏览器 | 低代码量 | 全量 | 不像桌面 App，违背产品定位 |

选 A。补充约束：**Mermaid 相关 chunk 体积大，第三栏不可见时应卸载 WebView**；桥协议只走 `postMessage`，不在前端拼 shell 字符串。

### D2 前端落位：从 `docs/` 毕业到 `Web/`

`docs/git-workbench-prototype/` 是原型考古现场，不是生产代码目录。迁到仓库根 `Web/`，一并处理：

- 删除 Sites 资产（`.openai/`、`worker/`、`scripts/prepare-sites-build.mjs`、`tests/sites-worker.test.mjs`、`package.json` 里的 `test:sites` 与 build 链中的 prepare 步骤）。
- `node_modules/`、`dist/` 进 `.gitignore`；保留 `package-lock.json`。
- 原型根目录的截图（20 张 png）迁到 `docs/git-workbench-reference/`，不跟随代码。
- 原型内 `DEVELOPMENT.md` / `design-qa.md` 作为参考文档留在原处（只读），生产文档写进仓库根 `DEVELOPMENT.md` 新章节。

### D3 数据层：先抽适配层，再逐页接线

原型是「组件内联 `useState` + 硬编码 mock」（`App.jsx:9-27`、`FileBrowser.jsx:16+`）。直接改会造成改动洒满 1400 行。
所以 T1 先落 `Web/src/bridge/`：`protocol.js`（方法清单/编码）+ `client.js`（`request()` 统一封装）+ `mock.js`（原 mock 数据原样搬进来）。
组件层只允许通过 `dataSource` 取数，禁止直接 `window.webkit.messageHandlers.*`。

---

## 3. 波次与阶段

| 波次 | 阶段 | 任务 | 并行度 | 出口门禁 |
|---|---|---|---|---|
| W0 | P0 地基 | T0 原型毕业+拆文件 → T1 桥协议 → T2 Swift 能力层 → T3 第三栏容器 | 1 窗口（T1/T2 可小并行） | `swift build` + 回归脚本 + `npm run build` + 应用里看到原型第三栏 |
| W1 | P1 只读链路 | T4 Git 只读、T5 文件树/预览、T6 项目与会话真实化 | 3 路 | 上述门禁 + 三页面真实数据手测 |
| W2 | P2 写操作 | T7 暂存/提交、T8 分支/冲突/Stash、T9 文件编辑保存 | 3 路 | 门禁 + 破坏性操作确认 + 外部修改冲突用例 |
| W3 | P3 会话创建 | T10 当前分支会话 → T11 Worktree 会话 | 1 路（T10→T11 串行） | 门禁 + 两种模式各建一次会话 + 失败恢复演练 |
| W4 | P4 收尾 | T12 空态/错误态/键盘/无障碍 + 打包 + 文档 | 2 路 | 全量回归 + DMG 出包 |

依赖图：

```
T0 ──► T1 ──► T2 ──► T3 ──┬──► T4 ──┬──► T7 ──┐
                          │         └──► T8 ──┤
                          ├──► T5 ──────► T9 ──┼──► T12
                          └──► T6            │
                    T2 + T4 ──► T10 ──► T11 ─┘
```

---

## 4. 任务卡

> 每张卡的「写作用域」是硬边界。越界即视为冲突，必须停下来报 lead。
> 「禁止」栏里的事项是踩过的坑，不是建议。

### T0 原型毕业与文件拆分（P0，单窗口）

- **产出**
  - `Web/`（新目录）：`src/`、`public/`、`index.html`、`vite.config.mjs`、`package.json`、`package-lock.json`、`bridge/` 骨架。
  - `src/App.jsx` 里的 9 个页面拆到 `src/pages/`：`WorkspacePage`、`HistoryPage`、`BranchesPage`、`ConflictPage`、`StashPage`、`TagsPage`、`WorktreePage`、`RemotePage`、`OperationsPage`。
  - `src/FileBrowser.jsx` 拆到 `src/files/`：`FileTree`、`ChangedList`、`DiffView`（`CodeDiff`/`BinaryDiff`/`ChangeDiff`）、`PreviewRenderer`（`MarkdownPreview`/`DiagramPreview`/`HtmlPreview`/`CsvPreview`/`ImagePreview`/`PdfPreview`）、`LiveEditor`。
  - `src/App.jsx` 收敛为布局 + 状态容器（≤150 行）。
- **写作用域**：`Web/**`（新增）；`docs/git-workbench-prototype/**` 只读，不修改。
- **禁止**：不引入 TypeScript、不引入状态库、不改视觉样式、不改交互行为、不删 mock 数据（搬到 `bridge/mock.js`）。
- **验收**：`cd Web && npm ci && npm run build` 产出 `dist/client/index.html`；`npm run dev` 打开后 9 个 Git 页 + 文件预览与拆分前逐项一致（对照 `design-qa.md` 的交互检查清单）。

### T1 桥协议定稿（P0）

- **产出**：`Web/src/bridge/protocol.js`（方法名、请求/响应信封、错误码枚举、超时与取消）、`client.js`（`request(method, params)`，未注入原生桥时回落 mock）、`mock.js`。
- **协议要求**：信封 `{id, method, params}` / `{id, ok, result}` / `{id, ok:false, error:{code,message,detail,recoverable}}`；方法清单严格对齐原型 `DEVELOPMENT.md` §11–§13 的 `GitAPI` / `FileAPI` / `SessionAPI`；新增 `app.projects` / `app.sessions`（对应 Swift 侧 `SessionScanner`、`Project`）。
- **写作用域**：`Web/src/bridge/**`。
- **禁止**：不在 UI 组件里出现 `window.webkit`；不设计流式/事件推送（先一律请求-响应，`file.watch` 用轮询 1s 起步）。
- **验收**：方法清单与 SPEC 逐条对照表附在 `Web/src/bridge/README.md`；`npm run build` 通过。

### T2 Swift 能力层（P0）

- **产出**（全部新增文件，不改既有文件）
  - `Sources/ClaudeDeck/Git/ProcessRunner.swift`：参数数组起进程、超时、stdout/stderr 捕获、结构化退出码。
  - `Sources/ClaudeDeck/Git/GitService.swift`：`status/diff/stage/unstage/commit/branches/switchBranch/log/tags/remotes/worktrees/stash`。
  - `Sources/ClaudeDeck/Git/FileService.swift`：`list/read/write/stat`，`realpath` 前缀校验、`.git` 过滤、256 KB 预览阈值、原子保存（临时文件 + `replaceItemAt`）。
  - `Sources/ClaudeDeck/Git/GitError.swift`：SPEC §11.1 的错误码。
  - `Tests/GitServiceRegression/main.swift`：在临时目录造仓库，跑通 status/stage/commit/worktree add，断言错误码。
- **写作用域**：`Sources/ClaudeDeck/Git/**`、`Tests/GitServiceRegression/**`、`Package.swift`（仅在必须加 target 时）。
- **禁止**：不拼 shell 字符串（`/bin/sh -c` 一律不允许）；不碰 `main.swift`、`TerminalPane.swift`、`models.swift`；不新增第三方依赖。
- **验收**：`swift build` 通过；回归程序手动执行全绿；`git` 子进程用 `/bin/zsh -lc` 取 PATH（与 `TerminalPane.swift:76` 一致）。

### T3 第三栏容器（P0，唯一可动 `main.swift` 的窗口）

- **产出**
  - `Sources/ClaudeDeck/ThirdPane/WebPane.swift`：`WKWebView` + `WKScriptMessageHandler` 桥宿主，加载 bundle 内 `Web/dist/client/index.html`。
  - `Sources/ClaudeDeck/ThirdPane/ThirdPaneStore.swift`：栏宽（570 起，最大 55%）、折叠、工具切换、WebView 懒加载与不可见卸载。
  - `main.swift` 三处锚点改动：`PickerView` 的 `HStack` 增加第三栏与分隔条、`Store` 增加第三栏字段、`AppDelegate` 窗口最小宽。
  - `scripts/check-session-regressions.sh` 同步：切片锚点仍是 `let store = Store(buildProjects())` 与 `app.run()`（**不得在新代码里再写 `executable: "/bin/zsh"` 字面量**，改用常量，否则脚本断言炸）。
  - `scripts/build-app.sh`：`npm --prefix Web run build` + 拷 `dist/client` 到 `Contents/Resources/web`。
- **写作用域**：`Sources/ClaudeDeck/ThirdPane/**`、`Sources/ClaudeDeck/main.swift`、`scripts/**`。
- **禁止**：不改终端焦点状态机（`store.pane` 0/1 语义）；不让 WebView 抢 `Tab` / `⌘Esc`；不改 `TerminalPane.swift`。
- **验收**：`swift build` + `scripts/check-session-regressions.sh` 全绿；`.app` 里第三栏渲染原型且无白屏；点击 WebView 后终端按键不再透传，点回终端后恢复；窗口收窄到 1000px 无横向溢出。

### T4 Git 只读接线（P1）

- **产出**：`pages/WorkspacePage`（真实 status + diff）、`HistoryPage`（`log`）、`BranchesPage`（`branches`）、`TagsPage`、`RemotePage`、`WorktreePage` 接真实数据；Swift 侧补齐对应 `GitService` 方法与 DTO 序列化。
- **写作用域**：`Web/src/pages/{WorkspacePage,HistoryPage,BranchesPage,TagsPage,RemotePage,WorktreePage}.jsx`、`Web/src/bridge/dto.js`、`Sources/ClaudeDeck/Git/GitService+Read.swift`、`Sources/ClaudeDeck/ThirdPane/BridgeHandlers+Git.swift`。
- **禁止**：不实现写操作（按钮走「暂不支持」提示而非假成功）；不改 `DiffView` 视觉。
- **验收**：在 `claude-picker` 自身仓库上，工作区文件数 / 分支列表 / 最近 20 条提交与 `git status`、`git branch -a`、`git log --oneline -20` 逐项一致。

### T5 文件树与只读预览（P1）

- **产出**：`files/FileTree`、`files/ChangedList` 接 `file.list` / `git.status`；`PreviewRenderer` 接 `file.read`（Markdown、Mermaid、HTML、代码、JSON、YAML、CSV、图片、PDF）；大文件与二进制走「打开外部」入口。
- **写作用域**：`Web/src/files/{FileTree,ChangedList,PreviewRenderer}.jsx`、`Sources/ClaudeDeck/Git/FileService.swift`（读侧）、`Sources/ClaudeDeck/ThirdPane/BridgeHandlers+File.swift`。
- **禁止**：本阶段不做编辑（编辑按钮隐藏）；不遍历 `.git`、`node_modules`、`dist`（默认忽略表 + 可配置）。
- **验收**：含中文路径、软链接、空目录的项目能正确展示；PDF 与图片无编辑按钮；1 MB 以上文本弹确认。

### T6 项目与会话真实化（P1）

- **产出**：第一栏项目/会话改由 Swift `Store` 数据驱动（`app.projects` / `app.sessions`），项目下拉 = 真实项目列表；点击会话触发既有 `openSession` 路径；新建会话插入真实树。
- **写作用域**：`Web/src/AppContext.jsx` 拆出的 `ProjectSidebar.jsx` / `SessionPane.jsx`、`Sources/ClaudeDeck/ThirdPane/BridgeHandlers+App.swift`。
- **禁止**：不改 `SessionScanner` 的解析逻辑（只读复用）；不改树排序/隐藏的持久化格式（`tree.json`）。
- **验收**：会话标题、相对时间、忙碌转圈状态与 Swift 侧一致；切换项目时 Git 与文件视图同步切换且不保留旧路径。

### T7 暂存与提交（P2）

- **产出**：`stage/unstage/commit/amend` 真实执行；`全部暂存`、单文件 `＋`、回退、`提交到当前分支`、`更多提交方式`（签名 / `--no-verify` / `--allow-empty`）；提交成功刷新 status + log。
- **写作用域**：`Web/src/pages/WorkspacePage.jsx`、`Sources/ClaudeDeck/Git/GitService+Write.swift`、`Sources/ClaudeDeck/ThirdPane/BridgeHandlers+Commit.swift`。
- **禁止**：`--no-verify` 必须在按钮上显式写出；提交失败保留输入内容；不做 `push`（T8 才有）。
- **验收**：真实提交后 `git log -1` 与 UI 一致；hooks 失败原样回显 stderr；`amend` 不产生新提交。

### T8 分支 / 冲突 / Stash（P2）

- **产出**：`switchBranch`、新建分支、合并预览与 `MERGE_CONFLICT` 三选（OURS/THEIRS/BOTH）+ 标记已解决 + 终止合并；Stash 的 save/apply/pop/drop；fetch/pull/push（含 ahead 计数）。
- **写作用域**：`Web/src/pages/{BranchesPage,ConflictPage,StashPage}.jsx`、`Sources/ClaudeDeck/Git/GitService+Branch.swift`、`Sources/ClaudeDeck/ThirdPane/BridgeHandlers+Branch.swift`。
- **禁止**：合并前不隐式 stash（有未提交变更就报 `DIRTY_WORKTREE`）；`reset --hard`、`clean -fd` 只走「全部操作」且强制二次确认；冲突未全解决时禁用「继续合并」。
- **验收**：制造真实冲突能走完解决流程；`push` 被远端拒绝时展示 stderr 且不谎报成功。

### T9 文件编辑与保存（P2）

- **产出**：文本类文件（md/mmd/html/code/json/yaml/csv）进入 `LiveEditor`，保存走 `file.write` 原子写；保存前比对 `stat` 的 mtime+size，外部改动则提示覆盖/放弃/另存；保存后刷新 Diff 当前版本。
- **写作用域**：`Web/src/files/LiveEditor.jsx`、`Sources/ClaudeDeck/Git/FileService+Write.swift`、`Sources/ClaudeDeck/ThirdPane/BridgeHandlers+Edit.swift`。
- **禁止**：图片/PDF 不显示编辑按钮；不实现自动保存；保存失败必须保留用户输入。
- **验收**：编辑 → 保存 → `git diff` 内容一致；并发外部修改会拦下；保存后行号与 Diff 同步。

### T10 当前分支会话（P3）

- **产出**：`CreateSessionModal` 的「基于当前分支」真实生效：以项目根为 cwd 起 `claude`（复用 `TerminalPane` 的启动参数构造），插入会话树，写成功 Toast 与操作日志。
- **写作用域**：`Web/src/CreateSessionModal.jsx`、`Sources/ClaudeDeck/ThirdPane/BridgeHandlers+Session.swift`、`Sources/ClaudeDeck/Session/SessionLauncher.swift`。
- **禁止**：不复制 `TerminalPane` 的进程代码（抽公共 `ProcessRunner`，T2 已提供）；不创建分支、不建 worktree。
- **验收**：标题为空禁用提交；成功后第一栏出现「当前分支 · 刚刚」；取消无副作用。

### T11 Worktree 会话（P3）

- **产出**：`.worktrees/{branchSlug}` 创建、目标分支校验、6 项前置检查（T0 卡里的 SPEC §7.4 清单）、会话以 worktree 为 cwd 启动、失败三恢复动作（保留/重试/清理）。
- **写作用域**：`Web/src/CreateSessionModal.jsx`、`Sources/ClaudeDeck/Git/GitService+Worktree.swift`、`Sources/ClaudeDeck/ThirdPane/BridgeHandlers+Worktree.swift`。
- **禁止**：路径 realpath 后必须仍在项目根内；`.worktrees` 不可写就不建；worktree 建成功而会话失败时**不得**先插入会话行。
- **验收**：两种模式各建一次并与 `git worktree list` 对齐；人为制造「分支已存在」「路径占用」「非仓库」三种失败，UI 均给出可恢复提示。

### T12 收尾与出包（P4）

- **产出**：空态/错误态/加载态补齐（SPEC §15 全表）；`⌘K`、`Esc`、`Tab`、`aria-label`、`role="tab"` 齐备；`Web/dist` 进 bundle；`Info.plist` 版本号联动；`DEVELOPMENT.md` 增加「第三栏 Git 工作台」章节与源码地图；`scripts/check-session-regressions.sh` 扩展第三栏冒烟。
- **写作用域**：`Web/src/**`（收尾修补）、`DEVELOPMENT.md`、`scripts/build-app.sh`、`Tests/**`。
- **验收**：`swift build` + 回归 + `npm run build` 全绿；`./scripts/build-app.sh --dmg` 出包并能在干净机打开；SPEC §16 测试清单逐条打勾。

---

## 5. 写作用域矩阵

| 文件 | T0 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `Sources/ClaudeDeck/main.swift` | | | | **W** | | | | | | | | | |
| `Sources/ClaudeDeck/TerminalPane.swift` | | | | | | | | | | | | | |
| `scripts/check-session-regressions.sh` | | | | **W** | | | | | | | | | W |
| `scripts/build-app.sh` | | | | **W** | | | | | | | | | W |
| `Web/src/App.jsx` | **W** | | | | | | | | | | | | |
| `Web/src/pages/*` | **W(拆)** | | | | W(读页) | | | W | W | | | | W |
| `Web/src/FileBrowser.jsx`→`files/*` | **W(拆)** | | | | | W | | | | W | | | W |
| `Web/src/bridge/*` | | **W** | | | W(dto) | | | | | | | | |
| `Web/src/AppContext.jsx`→`ProjectSidebar/SessionPane` | **W(拆)** | | | | | | W | | | | | | |
| `Sources/ClaudeDeck/Git/*` | | | **W** | | W(+Read) | W(读侧) | | W(+Write) | W(+Branch) | W(+Write) | | W(+Worktree) | |
| `Sources/ClaudeDeck/ThirdPane/*` | | | | **W** | W(Git) | W(File) | W(App) | W(Commit) | W(Branch) | W(Edit) | W(Session) | W(Worktree) | |

读法：同一列内的 W 互不重叠；同一行的多列 W 表示跨波次顺序占用，不同时发生。
`main.swift`、`TerminalPane.swift` 无 T3 之外任何窗口；`ThirdPane/BridgeHandlers+*` 按功能分文件，一人一个文件，避免合并冲突。

---

## 6. 智能体编排

### 6.1 编制（4 执行 + 1 lead，超过 4 个执行会锁竞争）

| 角色 | 承担 | 特点 |
|---|---|---|
| `lead`（本 agent） | 决策、门禁、`main.swift` / 脚本 / 打包、冲突裁决、最终验收 | 唯一可动 `main.swift` 的执行者（与 T3 合并） |
| `agent-frontend` | T0、T1、T9、T12（Web 侧） | 前端拆分与桥接客户端 |
| `agent-swift-core` | T2、T6 | 能力层与 App 数据接线 |
| `agent-swift-git` | T4、T7、T8 | Git 读写与危险操作确认 |
| `agent-session` | T10、T11 | 会话与 worktree 流程 |

### 6.2 派发模板（每次派发必须带全）

```
任务卡：<T编号 + 标题>（文件 docs/git-workbench-plan.md 第 4 节原文为准）
写作用域：<精确路径列表>
禁止：<该卡禁止栏 + 全局禁止：不碰其他卡的写作用域、不新增依赖、不改视觉>
验收命令：swift build -c release | scripts/check-session-regressions.sh | cd Web && npm run build
交付：改动文件清单 + 验收输出摘要 + 已知未完成项
```

### 6.3 交接协议

- 一个 agent 完成后**先报 lead**，由 lead 跑门禁再解锁下游卡；不让 agent 自行宣布解锁。
- 需要跨作用域改动时，不得直接改：在回报里给出「需要的补丁 + 原因」，由 lead 或该域 owner 执行。
- 同一波次内三个 agent 若有共享新文件（如 `dto.js`），由先到者创建并在回报中锁定接口，后到者只读调用。

---

## 7. 门禁与验证

每个任务收口必须全绿：

```bash
swift build -c release
scripts/check-session-regressions.sh
cd Web && npm run build
```

手测清单（W1 起每波回归一次，对照 SPEC §16）：

1. 三栏 1281×983 无横向溢出；终端收起后第三栏扩展。
2. 项目切换后分支/变更数/文件树三者联动。
3. 工作区文件数与 `git status --porcelain | wc -l` 一致。
4. 提交后 `git log -1 --stat` 与 UI 一致。
5. 冲突未全解决时「继续合并」禁用。
6. 破坏性操作均出现确认弹窗。
7. 会话创建两种模式各一次，且 `git worktree list` 对齐。
8. 关闭窗口再打开，无 WebView 泄漏（活动监视器内存回落）。

---

## 8. 风险登记

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| R1 | `check-session-regressions.sh` 字符串切片断言 | 改 `main.swift` 即红 | T3 内同步脚本；新代码禁止出现 `executable: "/bin/zsh"` 字面量 |
| R2 | WebView 与 SwiftTerm 键盘焦点互抢 | 终端输入丢失，核心体验退化 | T3 显式焦点隔离 + `Tab` 不穿透；点击即切换 `store.pane` |
| R3 | Mermaid chunk 大（dist 内数十个图表分块） | 内存 150–250 MB | 第三栏不可见时销毁 WebView；Mermaid 保持 `lazy()` |
| R4 | 无沙盒 + 任意路径读写 | 误删用户文件 | `FileService` 全部 realpath 前缀校验；写操作只允许项目根内；删除/丢弃二次确认 |
| R5 | `git` 在 GUI 里 PATH 缺失 | 全部 Git 功能失效 | 统一 `/bin/zsh -lc` 启动，失败时显式报 `COMMAND_FAILED` + 提示装 Xcode CLT |
| R6 | Worktree 部分成功（目录建了、会话没起） | 留下脏状态 | SPEC §7.4 三恢复动作 + 先校验后写、失败不插会话 |
| R7 | 原型是 JS 无类型，桥参数易错 | 运行时 undefined 崩溃 | T1 协议文件集中定义 + `client.js` 统一参数校验（缺失即抛结构化错误） |
| R8 | 三路并行仍可能撞 `Web/src/App.jsx` | 合并冲突 | T0 强制拆分，T0 之后 `App.jsx` 冻结，只允许 lead 改 |

---

## 9. 里程碑

| 里程碑 | 内容 | 判据 |
|---|---|---|
| M0（W0 结束） | 应用里能看到原型第三栏，桥一次往返成功 | 手测：调 `git.status` 返回真实 JSON 并在 DevTools 打印 |
| M1（W1 结束） | 只读可用：工作区/历史/分支/文件预览全是真数据 | 三项与 CLI 逐条对齐 |
| M2（W2 结束） | 写操作可用：暂存/提交/分支/冲突/Stash/编辑保存 | 真实仓库上完整走一遍提交流 |
| M3（W3 结束） | 会话创建两种模式可用 | worktree 会话能真正 `claude --resume` 起来 |
| M4（W4 结束） | 出包 | DMG 在干净机打开无白屏、无控制台报错 |

节奏：W0 是单窗口冲刺（关键路径，不可压缩）；W1/W2 各 3 路并行；W3 串行；W4 收尾。
若 W0 拖长，**优先砍 T5 的 PDF 预览与 T8 的 pull/push**，这两块对「第三栏可用」不是必要条件。

---

## 10. 立即下一步（W0 派发顺序）

1. lead 建任务板，把 T0–T12 入板并标注写作用域与依赖（本文件第 5 节）。
2. 派 `agent-frontend` 执行 T0 → 报回 → lead 跑 `npm run build` 门禁。
3. 并行：`agent-swift-core` 做 T2（新增目录，不碰既有文件）；`agent-frontend` 接着做 T1。
4. lead 做 T3（`main.swift` + 脚本 + 打包），以 T1 协议与 T2 能力层为输入。
5. M0 演示通过后，一次性解锁 W1 三张卡。

### 10.1 共享任务板映射（已入板）

| 卡 | 任务板 id | 依赖 | 当前状态 |
|---|---|---|---|
| T0 | `task-1` | — | ✅ 完成（原型毕业 + 拆分） |
| T0.5 | `task-14` | — | ✅ 完成（prettier 格式化基线） |
| T1 | `task-2` | T0.5 | ✅ 完成（桥协议 + mock） |
| T2 | `task-3` | — | ✅ 完成（Swift 能力层） |
| T3 | `task-4` | T1, T2 | ✅ 完成（第三栏容器 + 打包） |
| T4 | `task-5` | T3 | ✅ 完成（Git 只读 8 条接线） |
| T5 | `task-6` | T3 | ✅ 完成（文件树 / 预览只读） |
| T6 | `task-7` | T3 | ✅ 完成（项目 / 会话真实化） |
| T7 | `task-8` | T4 | **ready** |
| T8 | `task-9` | T4 | **ready** |
| T9 | `task-10` | T5 | **ready** |
| T10 | `task-11` | T2, T4 | blocked |
| T11 | `task-12` | T10 | blocked |
| T12 | `task-13` | T7, T8, T9, T11 | blocked |

W0 允许同时开工的只有 `task-1`（agent-frontend）与 `task-3`（agent-swift-core / lead），二者写作用域完全不重叠（`Web/` vs `Sources/ClaudeDeck/Git/`）。
其余卡必须等 lead 跑完门禁再解锁——不要让 agent 自己宣布 ready。

---

## 11. T3 实施记录（lead 亲自执行）

### 11.1 交付物

| 文件 | 说明 |
|---|---|
| `Sources/ClaudeDeck/ThirdPane/WebPane.swift` | `NSViewRepresentable` 包 WKWebView；`Coordinator` 同时是 `WKScriptMessageHandler`；`dismantleNSView` 里摘 handler、停加载 |
| `Sources/ClaudeDeck/ThirdPane/Bridge.swift` | 桥常量、三级加载入口、`NOT_IMPLEMENTED` 应答、`WebBundleSchemeHandler` |
| `Sources/ClaudeDeck/main.swift` | 常量 / Store 字段 / 三栏 HStack / 第三栏分隔条 / 窗口最小宽 / 「显示」菜单 / WebView 焦点豁免 |
| `Sources/ClaudeDeck/Models.swift` | `AppSettings` 加 `thirdPaneWidth` / `thirdPaneVisible`，`init(from:)` 走 `decodeIfPresent` |
| `scripts/build-app.sh` | 插入 2/7 前端构建，拷贝 `Web/dist` → `Contents/Resources/web` |
| `scripts/check-session-regressions.sh` | 手工 swiftc 补 `Git/*.swift`、`ThirdPane/*.swift`、`-framework WebKit` |

### 11.2 两个必须记住的坑

**① `file://` 下 Vite 产物白屏。** 第一版用 `loadFileURL(index, allowingReadAccessTo:)`，第三栏整片空白：`file://` 页面 origin 是 `null`，Vite 产出的 `<script type="module">` 被 CORS 直接拦掉。换成自定义 scheme（`claude-picker://app/index.html` + `WKURLSchemeHandler` 映射 `Contents/Resources/web`）后正常，顺带让 fetch 与相对路径都可用，且不必碰 WebKit 的私有偏好键。

**② `swift build` 会因增量缓存报假绿。** T2 出现过 `invalid redeclaration` 但输出 `Build complete! (0.24秒)`。门禁一律先 `touch Sources/ClaudeDeck/main.swift` 强制重编，或看编译耗时是否合理（正常 5–10 秒），不能只 grep "Build complete"。

### 11.3 桥的过渡策略

T3 阶段 Swift 对所有方法回 `NOT_IMPLEMENTED`，`Web/src/bridge/client.js` 在 `request()` 里识别该码后自动用 mock 重发一次。于是第三栏在接线期就是完整可用的原型；T4 起每接一批方法，对应请求自然走真桥，前端零改动。这条回落逻辑在 W1 全接完后再删。

### 11.4 焦点与布局

- `isWebPaneFocused` 沿响应链找 WKWebView，命中时跳过终端那段 ⌘C/⌘V 分支，网页复制不被吞；`store.pane` 0/1 语义未动。
- 第三栏默认 620pt，范围 480–1180（SPEC 写 570，因窗口最小宽 1080 而放宽下限，注释已说明）。挂在 `terminalArea` 右侧，向左拖变宽。
- 窗口最小尺寸 900×520 → 1080×560。
- 收起即销毁 WKWebView（`if store.thirdVisible { WebPane() }`），避免 mermaid/elk 上兆 chunk 常驻；实测反复收起/展开后重建正常。

### 11.5 验收结果

`touch main.swift && swift build` 真编译 5.4s 通过；`scripts/check-session-regressions.sh` 双段全绿；`scripts/build-app.sh` 产出 14M bundle，`Contents/Resources/web` 5.9M；实机截图确认三栏并存、Git 工作台与文件预览两页渲染正常、菜单「显示 → Git 工作台」收起/展开并写盘 `thirdPaneVisible`。

### 11.6 遗留

- `docs/git-workbench-prototype/` 仍占 356M（含 node_modules），已在 `.gitignore` 里挡住产物；源码是否删除留到 T12 收尾再决定，保留回滚能力。
- 拖动分隔条的物理手感未做自动化验证，留给人手确认。

---

## 12. W1 收尾核对（2026-11-13）

### 12.1 布局

- 第三栏改为 solo 模式：原型自带的项目/会话列与「项目工作台」标题栏不渲染（与原生侧栏重复），`?full=1` 可还原完整原型。
- 媒体查询按 WebView 视口（= 第三栏宽）触发，原 760px 手机断点会在第三栏里误触发，已统一下移到 480px（第三栏最小 520，永不触发）。
- Git 导航在 solo 下收成顶部横条（对齐原型 three-column 形态），放不下时横向滚动，滚动条改细暗色。此前「620 以下改图标 / 窗口最小宽 1160」的二选一因此不再需要。
- 栏宽：`thirdPreferredW` 存期望宽、`thirdW` 为夹紧后实际宽，`.layoutPriority(1)` 生效。实测 1360 窗口、期望 947 → 实际 836（终端保留 ≥260），磁盘仍为 947。

### 12.2 去掉真实仓库下的演示数据 / 假成功

- 导航计数改由 `git.status/branches/tags/worktrees` 给出（窗口重获焦点与切页时刷新）；提交历史、Stash、冲突暂无真实计数，留空。工具栏拉取/推送数取 `behind/ahead`。
- 原生桥在线（`transportKind() !== 'mock'`）时：提交、弹窗类写操作（分支/标签/Stash/克隆）、Stash 应用/弹出、获取/拉取/推送、创建会话一律提示「暂不支持」；Stash 页与冲突页显示待接入占位；「复制路径」改为真实复制。mock 模式行为不变。

### 12.3 调试包

`scripts/build-app.sh --dev` 产出 `dist-dev/ClaudePickerDev.app`（bundle id `local.zcl.claude-picker.dev`，窗口标题 `Claude Code Dev`，数据目录 `~/.local/share/claude-picker-dev`，首启从正式目录拷贝）。调试一律用它，只按 `pkill -x ClaudePickerDev` 结束，不碰正在使用的正式版。

### 12.4 仍未完成

- ~~桥同步执行，git 命令期间主线程阻塞~~ → 已在 §13 解决。
- W2（T7 暂存提交 / T8 冲突与 Stash（分支部分已在 §13 完成）/ T9 编辑保存）→ W3（T10/T11 会话创建）→ W4（T12）。
- 会话忙碌转圈/绿点在第三栏的实机触发尚未验证。

---

## 13. 顶栏合并 + 分支右键操作（2026-11-13）

### 13.1 布局

第三栏顶部一行：项目下拉 ｜ 「Git 工作台 · 当前分支 ▾」｜ 文件预览。原「当前项目」块、面包屑工具栏（分支/获取/拉取/推送）、页面大标题全部删除，工作区内容上移约 200pt。
项目下拉仍保留 `aria-label="选择项目"`（`bridge/dto.js` 靠它找当前项目）。

### 13.2 分支下拉与右键菜单（`Web/src/git/BranchSwitcher.jsx`）

- 已在 Git 工作台时点标签（或点箭头）展开下拉：顶部 获取 / 更新(behind) / 推送(ahead) / 新建，下面本地与远程分支，可筛选，单击签出。
- 右键任意分支或右键标签本身（= 当前分支）：签出、更新（当前分支 `pull --ff-only`；其它分支 `fetch <remote> <上游>:<本地>` 原地快进）、推送（无上游时 `--set-upstream`）、合并到当前分支、从此分支新建、复制分支名、删除（`branch -d`，内联二次确认）。远程分支：签出为本地跟踪分支、合并、新建、复制。
- WKWebView 无 `prompt/confirm`，新建名与删除确认都在弹层内联完成；失败把 stderr 显示在弹层里。成功后 `gitEpoch` 自增，导航计数与当前页重新读取。

### 13.3 原生侧

- `GitService` 实现 `createBranch / switchBranch / merge / deleteBranch / fetch / pull / push`（网络操作超时 120s）；所有 git 调用带 `GIT_TERMINAL_PROMPT=0`，无终端时认证失败直接报错而不是挂起。
- 桥新增 `git.deleteBranch`；`git.createBranch` 参数按 protocol 用 `{name, from}`。
- **桥异步化**：`Bridge.reply` 对 `git.*` 用 `Task.detached` 在后台执行、主线程回包（跨线程只传 JSON `Data`）；`app.* / file.* / session.*` 仍在主线程（要读 `@MainActor Store`）。

### 13.4 验证

- `Tests/GitServiceRegression` 新增第 9 节（临时仓库 + bare 远程）：新建/重名 BRANCH_EXISTS、签出、首推建上游、合并、fetch、更新非当前分支不切换、签出远程分支建跟踪、删除、非法名拒绝 —— ALL PASS。顺带修正旧断言把 `origin/HEAD -> origin/main` 别名计入分支数的问题。
- 会话/终端回归双段通过。
- dev 包实机（agent-desktop）：分支下拉列出真实分支；右键菜单内容正确（无上游时「更新」置灰）；单击远程分支签出、弹层新建分支、获取均落到 git 实际状态并刷新界面。右键菜单里的合并/删除/推送项受限于 agent-desktop 无法稳定触发 contextmenu，未在 UI 上逐项点过，其后端由回归测试覆盖。

