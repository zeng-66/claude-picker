# SuperAgent 源码核查

核查日期为 2026-11-16，仓库快照为 `8c32a9dc5d72c033816c6a8110b37f40cf94fba4`。本次仅浅克隆、阅读文档和源码，未安装、运行、部署或执行 SETUP。以下属于静态核查，运行表现尚未验证。

## 定位与实现边界

README 将该仓库定位为研究原型，并声明它与内部版本及研究文章的实现存在差异，文章中的部分设计属于未来方向。当前包面向一个 GitHub 仓库，提供 GitHub 与可选飞书事件接入、授权评估、任务执行和人工管理面板。实际领域文档路径是 `docs/001-domain.md`。[README](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/README.md)

## 已落地机制

- **Router 与 worker**。主会话使用 `dsh-superagent-router`，接收候选事件、调用评估和路由工具。每个 Ticket 创建持久会话 `worker-<ticketId>`，使用 `dsh-superagent-worker`。Trigger → Eval → Ticket/Mandate → Assignment → Executor 是业务模型，Thread 订阅把后续上下文送到对应 Ticket。Ticket 与执行会话具有各自生命周期，并支持恢复和重新分配。[领域模型](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/docs/001-domain.md) · [会话源码](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/src/app/sessions.ts)
- **持久化**。`Store` 通过 Node `node:sqlite` 打开 `<stateDir>/orchestrator.sqlite`，保存领域对象、KV、配置与提示词版本、待执行 effects、发送 outbox 和回执。接受任务的业务变更可在事务内提交，副作用先存储后执行。Runtime 使用状态目录锁防止第二个进程同时写入。会话历史另依赖 Harness 的 session persistence。代码包含重启恢复、重复输入处理及重试机制。[Store](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/src/app/store.ts) · [架构](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/docs/007-architecture.md)
- **工作目录**。每个 Ticket 分配独立目录，默认位于 `<stateDir>/work`，名字包含短任务名与稳定 ID 后缀。配置的 `executor.prepare` 命令负责准备工作区，随后验证目录。未配置准备命令时会创建空目录，Git worktree 需由准备命令实现。文档明确 worker 以操作者的 OS 用户免审批执行命令，因此这里能确认的是目录级分离，安全边界须结合宿主 Harness 的部署和权限核查。[Executor 源码](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/src/executor/dsh.ts) · [执行文档](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/docs/003-execution.md)
- **调度**。worker slots 限制并发，启动按队列等待空位，准备命令占用自身槽位。人工消息或状态请求可使用额外一个槽位并优先于新任务，CI 等自动输入等待普通槽位。活跃 turn 及其后台工作持有槽位，普通前台 shell 超过 5 秒转后台。effects 持久化后执行，失败投递采用从 2 秒增长至一分钟的重试间隔。此处已有事件、队列和并发控制实现。[执行文档](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/docs/003-execution.md) · [Executor](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/src/executor/dsh.ts)
- **授权与人工介入**。Policy、来源身份允许列表、Eval 和不可变 Mandate 定义任务授权范围。worker 的结构化问题及 blocked/failed 报告可让自动输入等待人工，人工可暂停、停止、重试。shell 免审批执行。默认自动合并约束包含本任务 PR、对应 head 的审批及变更小于 200 行，但文档将这些描述为代理指令，GitHub 强制审批需依赖分支保护。集成时应分别实现任务授权、人工提问、命令权限与 GitHub 合并规则。[授权](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/docs/002-authorization.md) · [执行](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/docs/003-execution.md)

## Harness 耦合及复用范围

入口是 Cordis 插件，注入 agents、sessionController、sessionPersistence、workspaceRegistry、permissionPresets、tools、systemPrompt、skills、webServer、llm、subprocess。包通过 `cordis.patch.yml` 注册 Harness 插件和 preset，面板依赖 Harness 客户端模块，声明 Harness 版本 `^0.2.1-alpha.2`。移植到 Claude Picker 需要替换执行会话、事件投递、模型调用、工具权限、面板宿主和持久化接缝。领域类型、Policy/Mandate 思路、effects/outbox 和调度机制有可复用参考价值，其实际兼容程度需结合目标端接口验证。[入口](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/src/index.ts) · [package.json](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/package.json) · [bundle](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/cordis.patch.yml)

## 许可证

本仓库采用 MIT，允许复制、修改、分发、再许可和商业使用，需在副本或实质部分中保留版权及许可声明。版权人为 2026 DeepSeek Harness Team。Harness 与第三方依赖的许可证需各自核查。[LICENSE](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/8c32a9dc5d72c033816c6a8110b37f40cf94fba4/LICENSE)
