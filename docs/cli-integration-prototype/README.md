# CLI 接入与工作区原型

## 当前 H5 评审

使用当前开发分支的 Web 界面，点击右下角「批注」可保存或导出意见。设置、变更及 TAPD 连接的控件规则见 [交互规范](DEVELOPMENT.md#10-设置与变更交互规范)。[打开当前 H5 原型](http://127.0.0.1:5173/?demo&review)

## 2026-11-19 test 版快照

该版本的开发背景与验收记录见 [开发方案](DEVELOPMENT.md)。

基线为 test 分支的 `63a3bbc`（2026-11-19 测试包），复用该提交的 Web 界面与已有浏览器模拟后端。评审改动集中在 `test-preview.patch`，通过 `./preview-test.sh` 构建并启动预览。访问 [本机预览](http://localhost:5189/)。

- 选定项目后按 ⌘N，或使用项目树右键的「新建会话」。原有的当前分支／独立工作树流程中可选择 Codex CLI 或 DeepSeek Harness。
- 从项目下的分支或工作树打开 Codex 或 DeepSeek 的模拟历史。DeepSeek 默认缺少 `dsh`，可在「设置 → CLI 引擎」中模拟补齐依赖，再继续当前操作。
- 「设置 → CLI 引擎」集中管理全局聊天／终端、权限默认值、已安装／可安装引擎。引擎行支持启停、默认引擎与按引擎覆盖。配置与运行状态均为演示。
- 用右下角的「标注区域」选取界面。对话框内也可直接选择位置，保存或导出批注 JSON。

原型中的 CLI 与工作树操作都是浏览器模拟。独立布局初稿可从 `index.html` 打开，初稿与 test 版各自保留批注。

## 原生聊天与分支会话

- 项目树按会话记录中的分支或工作树分组。工作树使用路径区分，分支未知的历史会话放在「未绑定分支」。拖拽相同分组内的会话会重排；跨分组拖动不会改写会话的归属。
- Claude Code、Codex 和 Antigravity 可各自选择聊天或终端。聊天原型在独立消息滚动区中展示 Markdown 与可展开的工具记录，输入框固定在底部；支持模拟流式回复、审批与中断。当前会话可切回原终端。DeepSeek Harness 使用现有终端。
- Claude 完成一轮后，侧栏显示提示缓存预计剩余时间。默认 5 分钟，可关闭或选择时长。模拟后端使用完成时间，实际接入应由对应引擎的缓存与回合状态决定起点。
- 会话标识取自 [Claude](https://claude.ai/favicon.ico)、[OpenAI](https://github.com/openai.png?size=64)、[Google Antigravity](https://antigravity.google/favicon.ico) 与 [DeepSeek](https://github.com/deepseek-ai.png?size=64) 的官方标识。Codex 目前显示 OpenAI 品牌图标。

Orca 原仓库返回 404，参考的是公开 MIT fork 的固定提交 `4c0d0a8`。原型复用了 ClaudePicker 自己的 Markdown 渲染器，并按 Orca 的 [消息滚动区](https://github.com/quzard/orca-fork/blob/4c0d0a80148782cbbc35cd744861fd1ae776aad5/src/renderer/src/components/native-chat/NativeChatTranscriptViewport.tsx)、[输入区](https://github.com/quzard/orca-fork/blob/4c0d0a80148782cbbc35cd744861fd1ae776aad5/src/renderer/src/components/native-chat/composer/NativeChatComposerPane.tsx) 和 [缓存计时逻辑](https://github.com/quzard/orca-fork/blob/4c0d0a80148782cbbc35cd744861fd1ae776aad5/src/renderer/src/components/sidebar/workspace-card/activity/prompt-cache-timer-selection.ts) 实现交互。

正式接入可沿用同一 UI。Claude 接现有结构化执行器，Codex 接 [App Server 客户端](https://github.com/quzard/orca-fork/blob/4c0d0a80148782cbbc35cd744861fd1ae776aad5/src/main/codex/app-server/codex-app-server-client.ts) 同类的线程和回合接口，Antigravity 验证 ACP。会话首次绑定时需记录项目、分支和执行工作目录，历史没有绑定证据时保留未绑定状态。

[Orca 官方 Native Chat 文档](https://orca.dev/docs/agents/native-chat) 说明了默认打开方式只作用于新会话，旧会话保留当前界面。原型沿用这一规则，并在模拟回合未结束时禁止切换，已处理的审批在消息流中留有记录。正式实现还需验证按原始会话 ID 恢复、同一会话的单写入者约束和重启后的界面恢复。

「工作树」页和项目右键菜单都可以进入「创建工作树」。表单可以切换项目、指定本机运行和起始分支，填写工作区名称，并可选一个代理。选择「仅创建工作树」会在项目树显示一个空分组，选择代理则会在新工作树内打开模拟会话。当前原型只演示本地 Mac。

## 工作区 Diff、TAPD MCP 与额度

- 右键项目树的分支或工作树，选择「在工作区查看 Diff」。普通分支切到对应分支，独立工作树直接读取自己的目录。成功后收起第二栏，第三栏显示目标工作区的 Diff。
- 「设置 → TAPD 连接」默认使用 TAPD MCP。按页内步骤获取服务地址、确定授权方式并填入一个或多个项目 ID，再点「一键配置」。当前演示会验证输入，将服务登记到模拟 MCP 列表并启用新项目。后续可追加，同一个 ID 自动去重，已配置项目和仓库映射保留。正式接入需要为桌面端配置 MCP 服务地址，以只读工具验证权限后才保存成功状态。
- 额度位于第一栏「添加目录」下方，支持已用／剩余、详细／精简、按引擎展开、刷新及账户入口。设置齿轮位于侧栏标题区。额度和账户数据均为演示。

Diff 参考 [IntelliJ IDEA 的 Diff Viewer](https://www.jetbrains.com/help/idea/comparing-file-versions.html)。默认并排显示，变更行按块对齐并通过中央色带关联，成对变更行突出不同的文本区段。可切换统一视图，用导航按钮或聚焦 Diff 后用 F7 / Shift+F7 逐块查看。工作区对比列按暂存状态标记为「暂存区／工作区」或「HEAD／暂存区」。

分支／工作树右键可直接新建绑定会话。会话右键可查看或复制原始 ID 和恢复命令。「变更」页拆分项目选择和分支选择。

「设置 → 企业微信机器人」可新增机器人，可多选人员、群聊／私聊和项目并演示路由，验证不同机器人的 CLI 和原会话独立，以及任务确认和拍板卡。详见 [企业微信开发方案](WECOM-DEVELOPMENT.md)。

WorkBuddy 条目位于「设置 → CLI 引擎」的引擎目录，独立 CLI 启动入口待验证。
