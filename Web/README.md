# claude-picker-web

ClaudePicker 的整窗界面。结构、文案与交互以 `docs/app-layout-prototype/` 为准，数据全部来自原生桥。

原生窗口只负责三件事：状态（`Store`）、终端（SwiftTerm，嵌在网页给第二栏留出的透明区域下面）、窗口与快捷键。
其余界面——标题栏、项目侧栏、输入区、Git 工作台、各种弹窗——都在这个网页里。

## 运行

```bash
cd Web
npm install
npm run dev      # 浏览器里打开，走 src/shell/mock.js 的内存演示数据
npm run build    # 产出 dist/，scripts/build-app.sh 会拷进 Contents/Resources/web
```

接 vite dev server 调试原生窗口：`CLAUDE_PICKER_WEB_URL=http://127.0.0.1:5173/ .build/debug/ClaudeDeck`。

## 目录

```
src/
  main.jsx               入口
  shell/
    App.jsx              外壳：标题栏、分支弹层、三栏布局、悬浮输入窗、右键菜单、布局回报
    Sidebar.jsx          项目与会话树（展开、拖动排序、键盘导航、用量条）
    Composer.jsx         输入区（模式 / 模型 / 推理强度 / 快速模式 / 上下文环 / 发送）
    WorkspaceTab.jsx     工作区：暂存、提交、差异 / 预览 / 编辑保存
    GitPages.jsx         提交历史、分支、工作树、更多（合并与冲突、Stash、操作日志）
    Modals.jsx           模型上下文、MCP 服务、添加目录、新建会话、界面设置
    DiffView.jsx diff.js 差异解析与渲染
    bridge.js            唯一出现 window.webkit 的地方：request() 与原生事件订阅
    mock.js              浏览器直开时的演示后端（方法名、返回结构与 Swift 一致）
    style.css            原型样式原文 + 文件末尾「接入真实应用的补充」
  MarkdownRenderer.jsx MermaidDiagram.jsx   Markdown 预览（懒加载）
legacy/                  重构前的 Git 工作台前端与旧桥接文件，仅供对照，不参与构建
```

## 桥方法

| 前缀 | 处理 | 线程 |
|---|---|---|
| `app.*` | `Sources/ClaudeDeck/ThirdPane/BridgeHandlers+App.swift`（状态快照、布局、设置、项目树、发送提示词、上下文占用） | 主线程 |
| `session.*` | `BridgeHandlers+Session.swift`（打开会话、新建会话：当前分支 / 独立工作树） | 主线程 + 后台建工作树 |
| `git.*` | `BridgeHandlers+Git.swift` → `GitService` | 后台 |
| `file.*` | `BridgeHandlers+File.swift` → `FileService`（读、原子保存、外部修改检测） | 后台 |
| `mcp.*` | `BridgeHandlers+Mcp.swift` → `McpService`（读配置、`claude mcp list/get/add/remove`、握手发现工具） | 后台 |

原生 → 网页事件：`claude-picker:state`（状态快照）、`command`（菜单快捷键）、`follow-session`、`reveal`。

## 测试

- `scripts/check-session-regressions.sh`：会话 / 终端 / 桥分发三套回归（`Tests/BridgeRegression` 按网页实际发送的参数逐个调用桥方法）。
- `scripts/test-git.sh`：GitService / FileService 在临时仓库上的读写回归。
- 两个脚本都通过 `CLAUDE_PICKER_DATA_DIR` 把 tree.json / settings.json 写进临时目录，不会碰正式版数据。
