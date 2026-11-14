# Git 工作台 H5 交互原型

基于当前 ClaudePicker / Claude Code App 的深色样式，独立设计原型。没有修改 Swift 功能，没有执行仓库写操作。

启动：`npm install` 后 `npm run dev -- --host 127.0.0.1 --port 5187`。
构建：`npm run build`。

功能分区：Git 工作台包含工作区、提交历史、分支、合并与冲突、Stash、Tags、Worktree、Remote、全部操作；文件预览包含 Markdown、Mermaid 流程图/ER 图/时序图、HTML、代码、JSON、YAML、CSV、图片和 PDF。
核心模拟交互：Git/文件工具切换、Git 左侧固定项目选择、终端收起与展开、从当前分支或项目内 Worktree 创建会话、“全部文件/变更文件”双视图、全部目录展开/折叠、Git 状态着色、文件搜索、变更文件 Diff、Markdown/Mermaid/HTML/代码/CSV 实时编辑与预览、图片缩放、Git 文件筛选/暂存、提交、差异布局切换、创建/切换分支、冲突选择与解决、暂存恢复、标签创建、命令筛选与预览、操作日志。

完整的页面结构、状态模型、按钮行为、会话创建规则、接口契约和测试清单见 [DEVELOPMENT.md](./DEVELOPMENT.md)。

高级 Git 功能当前为入口与统一弹窗，不代表已经实现真实 Git 命令或全部参数表单。文件编辑内容只保存在浏览器内存，刷新恢复默认演示数据。

- `desktop.png`：桌面预览
- `mobile.png`：窄屏预览
- `design-qa.md`：布局与交互检查记录

- `file-preview.png`：第三栏 Markdown 文件预览
- `file-image-preview.png`：第三栏图片预览
- `file-all-statuses.png`：全部文件视图与 Git 状态颜色
- `file-changes-diff.png`：变更文件视图与 Diff
- `technical-doc-live-edit.png`：Markdown 内嵌 Mermaid 与实时编辑
- `mermaid-er-preview.png`：ER 图文件预览
- `technical-doc-live-edit-mobile.png`：窄屏实时编辑
- `git-project-picker-collapsed-terminal.png`：Git 左侧项目下拉与收起终端
- `create-worktree-session.png`：从当前分支创建 Worktree 会话
