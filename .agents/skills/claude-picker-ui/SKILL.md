---
name: claude-picker-ui
description: 调整和验收 ClaudePicker 的桌面 App 与 H5 原型。用于界面美化、排版、统一控件、处理截图批注，以及终端第三栏、工作区、CLI 设置和 TAPD 连接的交互修改。
---

# ClaudePicker UI 调整与验收

## 确认基线

- 先读用户最新批注，确认目标是 H5 原型、桌面 App，还是两者。用目标版本的实际页面作基线。用户指定 `test` 版时，核对分支、提交与运行版本，再基于该版本改原型。
- 按仓库 [分支与交付契约](../../../DEVELOPMENT.md#0-分支与交付契约) 选择开发、构建和交付入口。涉及 CLI、工作区、额度、终端预览或连接时，查阅 [开发方案](../../../docs/cli-integration-prototype/DEVELOPMENT.md) 对应段落，并用当前代码核对实现状态。用户最新批注优先于旧原型说明。
- 按批注复现涉及的页面和状态。局部改动检查同类控件是否受影响。全 App 走查按影响排序，优先处理布局、信息层级和控件反馈，再处理装饰与动效。

## 使用开源设计指南

- **设计和修改用 Better Design。** 排版或控件调整前，读[布局与对齐](references/better-design/layout-geometry.md)中与目标控件有关的段落。新增或修改交互时，读[组件行为与恢复](references/better-design/behavior-and-content.md)的组件约定及相关状态。重做页面视觉方向时参考[视觉方向](references/better-design/art-direction.md)的 Inherited direction，再基于现有主色探索方案。涉及原生窗口或桌面操作时，读[桌面平台指南](references/better-design/platform-adapters.md)的 Desktop 段落。
- **走查和打磨用 Impeccable。** UI 走查时，将[设计评审准则](references/impeccable/critique-rubric.md)应用到实际截图和操作路径，并按用户影响排序。需要检查可访问性、暗色主题或不同窗口尺寸时，读取[审计指南](references/impeccable/audit.md)对应段落。改稿后用[打磨流程](references/impeccable/polish.md)复查受影响的界面和状态。
- 上游文档在仓库内固定版本。沿用其中与任务相关的设计、检查和取证方法，使用下面的 ClaudePicker 规则、现有浏览器和桌面工具完成验证。上游文档中的安装、脚本、探测端口和自动生成配置属于完整工具链的用法，本技能通过本地文档直接使用其设计指南。[Better Design 源码与 MIT 许可证](https://github.com/Moddingflow/better-design/tree/c373ad7fa122b8c0d63b1be756443cc93a56e71d/skills/better-design) · [本地许可证](references/better-design/LICENSE) · [Impeccable 源码与 Apache-2.0 许可证](https://github.com/pbakaus/impeccable/tree/2fc5e1459efbbf06d92c7306517c286bf12490cf) · [本地许可证](references/impeccable/LICENSE)

## 统一界面

- 从 `Web/src/shell/` 查找实际渲染入口，优先复用 `controls.css` 的语义色和已有组件。共用样式从共用入口调整，并检查设置页、浮窗和终端是否一起生效。
- 保留已定主色：`#222222` 主背景、`#262424` 抬高层、`#383838` 描边、`#3A2F2B` 悬停、`#4A3D36` 选中。为正文、辅助文字和焦点选用能在暗色背景上辨认的颜色。
- 统一按钮、下拉、分段控件、弹窗和表单的字号、间距、圆角、图标对齐与状态反馈。检查悬停、选中、键盘焦点、禁用以及该控件实际会出现的加载和失败状态。对下拉和浮窗检查方向键、Enter、Escape、点外部关闭、关闭后的焦点和窄窗口布局。
- CLI 引擎设置从 `EngineIcon.jsx` 与 `engine-icons/` 复用对应平台 Logo。应用功能图标参考 Pi 的图标风格，优先沿用仓库已有资产。纯图标按钮提供可访问名称。
- 排版方向仍需比较时，交付可点击、可批注的方案。用同一份内容与关键状态比较布局，让选择集中在信息层级、空间密度和操作路径。

## 按涉及区域核对交互

| 区域 | 核对点 |
| --- | --- |
| 项目与分支 | 同一个浮窗内左侧选项目、右侧选分支。验证切换项目后，分支选项和当前值与项目匹配。涉及 Worktree 时依项目现行规则核对无标题时的首会话命名、TAPD 分支名和工作树目录的 Git 排除行为。 |
| CLI 引擎与额度 | 设置页展示对应平台 Logo，核对新会话默认打开方式与旧会话的行为。额度列表按可比较的用量排序，检查未登录或用量缺失的展示。按已确认的会话、分支和 Worktree 场景核对相关控件显隐。 |
| 终端与第三栏 | 文件目标进入第三栏，网页链接打开浏览器，CLI 输出按命令边界展开或收起。可编辑文本修改后自动保存，验证编辑后快速切换文件及保存失败时的草稿状态。可由 macOS 应用打开的文件提供「打开方式」，桌面端核对可用应用、打开结果与失败提示。保留已确认的终端按钮位置。 |
| TAPD 设置 | 默认使用 MCP。核对配置、连接中、成功、失败和重试的界面反馈。实际接入按开发方案验证 App 自身的授权、MCP 握手、工具发现与项目试读，并检查失败时已有可用配置的状态。 |

## 验收与记录

- 用实际页面执行改动涉及的路径。对照批注检查视觉结果，覆盖适用的成功、失败与恢复路径。H5 记录浏览器中验证过的行为，并标注使用演示数据的地方。
- 桌面改动按 [桌面调试与验收](../../../DEVELOPMENT.md#27-桌面调试与验收agent-desktop) 优先使用 `agent-desktop`，核对运行包和渠道，再验证原生窗口、Bridge、文件打开或连接结果。
- 有已确认的交互变化时，按仓库约定同步对应开发文档。交付说明写明验证入口、实际版本、关键结果以及待验证项。
