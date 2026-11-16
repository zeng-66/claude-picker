# SuperAgent 与 Claude Picker 融合建议

日期：2026-11-16。此处 SuperAgent 指 DeepSeek 的 dsh-superagent-prototype，尚未安装或运行。

## 定位

Swttch 提供图形聊天及 Claude CLI 通信；SuperAgent 提供跨事件的任务管理与执行编排。两者解决不同层的问题，可以分层融合，不应把两个服务的原始协议直接拼接。

官方 README 说明它是面向单个 GitHub 仓库、构建于 DeepSeek Harness 的研究原型，并非正式产品；公开实现与设计文章不完全相同。许可证为 MIT。

来源：https://github.com/deepseek-ai/dsh-superagent-prototype

## 建议架构（本项目设计，不是上游现有能力）

```text
Claude Picker
  ├─ 项目与 Git 管理
  ├─ 图形会话（Swttch WebView）
  └─ 任务面板（待处理、执行、待回答、待审阅、完成）
                  ↓
本地 Node 服务
  ├─ 聊天接口：沿用 Swttch
  ├─ TaskCoordinator：任务、事件、排队、恢复
  ├─ WorkspaceManager：每任务独立 worktree
  └─ AgentExecutor：执行器适配边界
        ├─ Claude：使用 Swttch 现有通信路径
        └─ DeepSeek Harness：后续独立验证适配
```

第一版只接 Claude 执行器。借鉴 SuperAgent 的持久任务模型，让一个任务关联项目、worktree、CLI 会话、输入事件及执行记录；模型会话不能替代任务数据库。UI 展示规范化任务状态，具体 CLI 协议留在适配器内部。

## 复用与迁移

可借鉴其 Engine/Ports 的边界：来源输入、授权判断、任务状态、执行适配、持久化和结果通知分开。源码级复用要核对依赖，不能把 DshExecutor 当作 Claude CLI 执行器使用。

其运行层调用 DeepSeek Harness 的会话、工具、hooks 与 inbox。保留原样运行就需引入 Harness；迁移到 Claude 则需重做执行适配和状态回传。仅把模型地址改为 DeepSeek API，不会自动获得 SuperAgent 的任务编排能力。

来源：https://github.com/deepseek-ai/dsh-superagent-prototype/blob/main/docs/007-architecture.md

上游每个任务有独立执行会话和目录，可通过 prepare 命令建立 worktree。独立目录用于减少工作冲突，不是 OS 安全隔离；执行策略不能直接作为本项目默认权限策略。上游并发、恢复及后台任务规则需要结合桌面应用退出行为重新设计。

来源：https://github.com/deepseek-ai/dsh-superagent-prototype/blob/main/docs/003-execution.md

## 实施顺序

1. 先完成现有 Swttch 方案的应用内单会话闭环，验证 stream-json 和 WKWebView。
2. 新增本地持久任务：手动创建、启动、停止、补充要求、查看结果；一个任务关联一个会话和独立 worktree，先串行执行。
3. 加入有限并发、重启恢复和待人工处理列表；恢复不能盲目重复上一次发送或外部动作。
4. 再接 GitHub/飞书/TAPD 等事件来源，按来源分别实现去重、授权和结果回写。实现连接器不代表获得对外发送、推送或合并的默认授权。
5. 确有多执行器需求时，再评估 DeepSeek Harness 的安装、通信接口及分发能力。界面复用不等于其后端协议兼容。

首轮交付目标：用户在 Picker 中建任务 → 创建 worktree → 启动 Claude 图形会话 → 显示执行/待回答/待审阅状态 → 用户检查 Git diff → 手动结束任务。

## 验收边界

完成与审批需分开：CLI 回合结束不等于测试通过，更不等于代码合并；worker 报告 ready 只进入待审阅。需要验证任务/会话身份一致、事件去重、崩溃恢复不重复执行、权限请求可达、取消后进程退出以及 worktree 保留可检查。

初期不启用自动合并、自动部署和全天候外部消息监听。此范围是控制集成复杂度的建议，不是对上游能力的否定。尚未验证 DeepSeek Harness 的本机可用性或任何跨运行时兼容性。
