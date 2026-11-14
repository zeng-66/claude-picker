# Git 工作台原型检查

- source visual truth path: ../git-prototype/reference.png
- implementation screenshot path: desktop.png；mobile.png
- Source: 1180 × 728 px macOS App 截图；Implementation: 1440 × 900 CSS px 桌面、390 × 844 CSS px 窄屏。截图按各自 CSS 视口检查，未将两种布局强行缩放为像素复刻。
- State: 工作区，4 个模拟文件；对照原 App 已打开的 Git 弹窗。
- Full-view comparison: 同一检查输入中查看原 App 与桌面原型。延续深灰底色、暖橙强调、紧凑列表、底部状态栏；将弹窗扩展为主工作区是本次范围内的布局调整。
- Focused comparison: 同次对照中检查侧栏、选中行、工具栏和提交区域；未新增品牌插画。图标使用 Phosphor 图标库，替代原生 SF Symbols 的网页实现。

## Findings

无剩余 P0/P1/P2 问题。

- Typography: 系统中文字体配合 Inter，正文 11–12px，标题 24px，代码使用 Menlo。相对原生界面增加标题层级属预期调整。
- Layout: 仓库导航、功能导航、文件列表、差异预览、提交表单职责清楚；提交表单固定在文件区底部。1440 与 390 宽度无页面横向溢出；窄屏差异区内部允许水平滚动。
- Colors: 延续深灰表面和暖橙选中态；新增绿/红差异语义色。
- Assets: 标准图标，无位图素材需求；品牌标题保留，Git 图标作为功能标识。
- Copy: 主页面中文；高级命令保留英文 Git 名称；模拟数据和不执行命令的边界在顶部、状态栏展示。

## Comparison history

1. 初次构建发现 App 默认导出与入口命名导出不匹配，已修正；浏览器旧日志保留该次错误，随后页面正常渲染，生产构建通过。
2. 初版文件区与提交区共同滚动，提交按钮可能折叠到下方；已将文件列表独立滚动，桌面截图确认表单和提交按钮可见。
3. 窄屏仅显示图标的导航缺少名称，已增加 aria-label 和 title。

## Interaction checks

- 单文件暂存 → 填写说明 → 提交 → 历史显示新提交；未暂存文件保留。
- 创建分支 → 顶栏当前分支更新。
- 冲突选择 → 标记解决 → 页面文案和导航计数更新。
- 全部操作按 rebase 筛选，展示普通与交互式变基入口。
- 差异并排/统一切换、命令弹窗、参数输入、日志均为前端演示。
- 生产构建通过；不调用 Git、不接入后端。

## Follow-up polish

- 高级操作当前使用统一参数预览弹窗；定稿后逐个设计完整参数、错误、取消与恢复流程。
- 多仓库共用演示数据；正式开发时按仓库隔离。
- 未穷举全部 Git 参数，低频命令由自定义命令入口覆盖。

## 文件预览调整

第三栏新增 Git 工作台 / 文件预览切换。文件预览由文件树和只读预览区组成，支持目录展开、文件搜索、Markdown 渲染与源码切换、图片 PNG 信息与 50%–200% 缩放、代码和 JSON 行号、CSV 表格与源码、PDF 页面预览。第一栏项目会话和第二栏终端保持可见。

已验证 1281 × 983、1000 × 800 和 390 × 844 CSS px，无页面水平溢出。确认 Markdown 渲染、源码、图片与缩放、代码、PDF、CSV、文件搜索及 Git/文件切换正常，浏览器控制台无错误。截图为 file-preview.png、file-image-preview.png、file-preview-narrow.png 和 file-preview-mobile.png。

## 双文件视图

文件预览左栏新增“全部文件 / 变更文件”双视图。全部文件保留项目目录树，支持全部展开和全部折叠，文件名同时使用颜色和 M/A/D/? 状态字母。变更文件只列工作区改动，并按未暂存和已暂存分组。未暂存为琥珀色、已暂存为绿色、删除为红色、未跟踪为蓝色。

两个视图共用右侧预览。点击任一变更文件默认显示相同 Diff 面板，并可切换到文件预览。已验证代码 Diff 的并排/统一、未跟踪 Markdown、新增图片的二进制对比、删除文件的父提交内容、文件预览开关，以及 390px 窄屏无页面横向溢出。截图为 file-all-statuses.png、file-changes-diff.png 和 file-two-views-mobile.png。

## 技术文件实时编辑

新增可编辑技术文件模式。Markdown 可渲染 GFM 表格、任务列表和 Mermaid 代码块；独立 `.mmd` 可显示与编辑流程图、ER 图和时序图。代码、JSON、YAML、CSV 和 HTML 提供编辑区与同步预览，HTML 在 `allow-scripts` 的隔离 iframe 中运行。图片和 PDF 保持只读。

验证了 Markdown 文本和 Mermaid 图源修改后的同步更新、代码预览与 Diff 同步、CSV 表格实时更新、HTML iframe 实时更新，以及 390 × 844 CSS px 编辑布局。1281 × 983 下第三栏实时编辑区宽 488px，页面和工具栏无横向溢出；Mermaid 图和 ER 图渲染成功，浏览器控制台无错误。

Mermaid 依赖采用按需加载，生产构建会生成较大的专用图表分块，这是当前原型的体积限制。截图为 technical-doc-live-edit.png、mermaid-er-preview.png 和 technical-doc-live-edit-mobile.png。

## 项目切换与终端收起

项目选择器固定在 Git 工作区左侧导航栏顶部，与 Git 功能入口处于同一列。桌面宽度下导航栏宽 150px，在分支管理、提交历史等所有 Git 页中持续可用。选择 `claude-picker`、`lm-global-java` 或 `lanma-bankend` 会同步更新 Git 分支、推送数量、变更文件和文件预览树。共享工具条只保留 Git / 文件预览切换和当前项目提示。

第二栏终端标题栏新增收起按钮。收起后保留 44px 垂直窄条，第三栏从约 704px 扩展到 1027px。展开按钮可以恢复原宽度。已验证项目切换、文件预览继承所选项目、终端展开收起的双向操作和 1281 × 983 布局，页面无水平溢出，新标签页控制台无错误。最终截图为 git-project-picker-collapsed-terminal.png。

## 会话创建

分支管理页新增“创建会话”入口。弹窗提供“基于当前分支”和“创建 Worktree”两种模式，提交前展示项目目录、会话或 Worktree 目录、基准 / 目标分支。Worktree 模式生成项目内 `.worktrees/<slug>` 路径，两种模式创建的会话都插入当前项目节点。

已分别验证当前分支模式和 Worktree 模式。空标题时提交按钮禁用，取消无副作用，创建成功后弹窗关闭、项目会话计数增加并显示成功 Toast。最终截图为 create-worktree-session.png。

final result: passed
