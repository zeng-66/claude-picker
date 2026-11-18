# agent-starter 融合设计

日期：2026-11-16。源码核查位置：`/Users/zcl/agent-starter`。本文补充 [开发说明](DEVELOPMENT.md)，不执行安装、同步、动态码绑定或用户级配置变更。

## 1. 定位与分工

agent-starter 提供个人工作智能体的技能、知识、仓库规约、权限守卫、任务记录和复盘。它不是替换图形聊天的 UI 组件，也不是持久 Work 调度器。

| 层 | 选用能力 | 对接边界 |
| --- | --- | --- |
| App | 项目、会话、Work、Git、设置与审批界面 | 本地领域状态与用户交互 |
| Swttch / Claude | 图形聊天及结构化代码执行 | 执行器及当前 Run |
| SuperAgent 思路 | 持久任务、事件、排队、恢复与结果投递 | WorkCoordinator；不直接引入 Harness 运行时 |
| WorkBuddy | 企业微信沟通、目标整理、目录判断与结果回复 | 来源与对话适配器 |
| agent-starter | 技能/知识、岗位行为、守卫规则、工作记录与复盘 | AgentProfile、SkillRegistry、PolicyAdapter、RecordService |
| TAPD | 当前需求、迭代、业务进展与受控回填 | 独立 TapdAdapter |

Work 继续属于 App 项目，不改成 TAPD 任务，也不改成某一份 Markdown。WorkBuddy 仍自动判断工作目录，不增加群聊项目映射。技能要求的项目地图可作为判断依据，但不能成为要求用户为每个群手工配目录的新设置。

## 2. 已核实的源码事实

以下来源均为本地只读核查；不意味着相关接入在本机已经配置或真实执行。

| 事实 | 来源 |
| --- | --- |
| 底座包含知识、技能、权限、日志、回放与知识编译；开发岗位包附加需求/发布/运维技能 | [README](/Users/zcl/agent-starter/README.md) |
| 包的个人说明、配置、技能与知识有各自正本；hooks 记录日志并加载业务仓规约 | [模板说明](/Users/zcl/agent-starter/template/AGENTS.md) |
| 分层守卫为 L0 放行、L1 线上只读审批、L2 确认、L3 禁止；环境分类和岗位规则由不同配置提供 | [权限规则](/Users/zcl/agent-starter/template/permissions/policy.json)、[守卫实现](/Users/zcl/agent-starter/template/hooks/permission.py)；层级语义以对应版本源码为准 |
| 密码/token 用系统钥匙串注入子进程，不能把配置里的钥匙串条目名当作秘密本身 | [模板说明](/Users/zcl/agent-starter/template/AGENTS.md)、[secret.py](/Users/zcl/agent-starter/template/scripts/secret.py) |
| WorkBuddy 同步会复制技能/知识，并操作记忆和用户级 hooks，影响所有 WorkBuddy 会话；同名冲突不能静默覆盖 | [workbuddy-sync](/Users/zcl/agent-starter/template/skills/workbuddy-sync/SKILL.md) |
| 文档明确 WorkBuddy 的部分工具不在守卫识别范围，且会话格式不能直接被现有摘要/复盘脚本读取 | 同上 |
| 文档明确消息事件缺少发送人；群里任意人的“确认”可能被接受；按人分权的群机器人适配层尚未包含 | [entry-setup](/Users/zcl/agent-starter/template/skills/entry-setup/SKILL.md)、workbuddy-sync |
| 现有任务卡在 `logs/tasks/*.md`；任务卡状态 active/paused/done，卡内任务 todo/doing/done/blocked | [任务卡模板](/Users/zcl/agent-starter/template/templates/task-card.md)、[tasks.py](/Users/zcl/agent-starter/template/scripts/tasks.py) |
| 研发技能要求从正确主仓和仓规出发，保存基线、验收及证据；编译测试后交付与记录 | [feature-dev](/Users/zcl/agent-starter/roles/dev/skills/feature-dev/SKILL.md) |
| 工作收尾和知识编译分别有回写确认与提案流程，不是完成后直接修改个人知识 | [task-record](/Users/zcl/agent-starter/template/skills/task-record/SKILL.md)、[knowledge-compile](/Users/zcl/agent-starter/template/skills/knowledge-compile/SKILL.md) |

README 描述多个岗位包，但本次本地 `roles/` 核查到 dev；其他岗位内容不按 README 描述假定已随本地包提供。也不把模板的权限配置视为已经生效的宿主权限。

## 3. 接入方式

### 3.1 AgentProfile 与技能索引

新增逻辑对象 AgentProfile，包含名称、岗位、来源包版本、技能索引、知识入口、权限策略引用与连接能力。首版仅读取 dev 岗位配置，不执行 bootstrap/install。

应用本地保存包位置作为来源，不把配置与账号全文复制到模型上下文。索引展示技能名称、描述、适用仓库、所需工具与实际可用性；在需求进入 Work 时按需选取。不得把所有技能、历史和知识一次塞入每个会话。

技能正本可继续由 agent-starter 管理。App 保存来源路径及内容版本，不维护可相互覆盖的两套技能正本。读取符号链接时验证来源目录；对不存在或不可读的文件标记失效。

### 3.2 仓库上下文加载

目录判定成功后，宿主读取目标仓库适用的 AGENTS/CLAUDE 与项目知识入口，构造该 Run 的上下文清单，标注来源与版本。用户当前指令和宿主约束优先，来源文件不能扩大访问或外部操作授权。

同一企业微信对话切换项目时重新加载相应仓规。跨仓需求拆为关联 Work，不复用上一个仓库的 Java 版本、分支或发布流程。

### 3.3 Work 与任务卡

SQLite 中 Work/Run/Attention/Evidence/Delivery 为执行状态正本。任务卡与执行记录是可导出、可审阅的上下文和证据载体。

| App 状态 | 导出的任务卡状态 | 注意 |
| --- | --- | --- |
| queued/running | active | 卡内任务分别 todo/doing；不能丢掉实际排队信息 |
| waiting_user/waiting_review | active | 卡内有关任务 blocked，并写明等待对象；不是用户主动暂停 |
| failed/interrupted | active | 记录失败原因、当前 Run 与下一步，不自动写 done |
| completed | done | 必须注明业务验收、发布与来源投递各自事实 |
| cancelled 或用户明确暂停 | paused | 卡内写实际原因；卡格式没有 cancelled，不把信息压掉 |

卡的 frontmatter 增加 App 关联 ID 时须先验证上游 lint 兼容性；未验证前只在正文元数据区写 Work/Run/来源。外部编辑任务卡不能直接改变数据库或重启任务：检测差异、提出导入建议，按 Work 命令校验后应用。

输出执行记录包含：目标/验收、基线、变更范围、已定决策、实际验证、问题、交付状态与下一步；不写凭据和未发生的完成事实。先保存结构化证据，再生成脱敏 Markdown。

### 3.4 权限守卫

先为上游判定实现适配测试，确认可用工具、环境与策略，再决定复用判定库或以受控子进程调用。禁止只靠技能文本或工具按钮来假装强制执行。

- 宿主自身文件/Git/连接操作在宿主权限边界校验。
- Claude 工具调用通过实际支持的 hooks/控制请求接入判定，记录原始工具身份、判定及执行结果。
- WorkBuddy 未被守卫识别的工具不能自动视为 L0；展示未覆盖能力，并限制其进入需要强制守卫的执行范围。
- 缺少可靠发送人身份的企业微信消息可用于对话、意图草稿和待验证 Work 记录，**不能满足要求绑定具体审批人的操作条件**。转到已认证 App 会话处理，或等真实接入支持身份绑定后开放。
- L3 不提供“强制执行”按钮。动态码只在真实守卫支持且作用域一致时使用，不在本次集成中代用户生成、读取或绑定密钥。
- 策略是版本化输入。当前 Run 的请求、身份、目标与策略版本必须关联；换项目、换环境或过期后不能复用旧批准。

这不是要求所有日常操作都额外确认；已授权且可判定的操作按相应策略继续。这里补足的是上游源码已明确存在的身份和覆盖缺口。

### 3.5 WorkBuddy 同步

设置的“检测同步”先做只读差异预览：技能新增/更新、知识、记忆托管区、hooks、同名冲突及受影响范围。同步不是等同于机器人连接，也不证明 Work 事件接入成功。

实际同步会修改用户级配置，必须展示具体计划与影响后按当次授权执行；禁止在应用启动、创建 Work、保存机器人名称时顺带运行 install 或 `--force`。保留原配置的非托管内容，冲突先 diff；失败要能确定哪些文件已更新与如何恢复。

首版不自动安装 Git post-commit hook，不扫描历史会话，不导入个人知识，不修改 `.claude`、`.agents`、`.workbuddy` 或守卫目录。

### 3.6 记录、复盘与知识

Work 完成后生成执行记录草稿，附可追溯来源。编译/复盘输出“候选改进”，用户确认后才写回知识或技能正本；不自动修订权限规则。已有脚本不能读 WorkBuddy 会话记录时，使用 App 结构化事件及脱敏执行记录，不假装脚本支持该格式。

评测分为仓库实现验收、权限规则回放、技能/知识质量检查三类；这些结果不能相互替代。没有实际跑过的检查显示未运行。

## 4. UI 补充规格（待实现）

本次更新开发方案，不宣称以下新页面已经在 H5 实现。

设置新增“智能体能力”页，机器人页仍只管连接与接收；目录自动识别不变。

| 控件 | 行为 |
| --- | --- |
| 选择能力包 | 通过宿主目录选择器选 agent-starter 来源，解析后展示能力，不执行安装脚本 |
| 岗位 | 列出包内实际存在的岗位；不可用岗位不伪造启用 |
| 技能/知识列表 | 查看正本、版本、依赖与可用状态，启停只改变后续 Run 的能力选择，不删除正本 |
| 仓规加载 | 展示当前 Work 的目标仓库和来源文件，不增加群聊目录映射 |
| 权限覆盖 | 按执行器和工具显示覆盖/未覆盖/未知；显示当前策略来源与实际环境 |
| 检测 WorkBuddy 同步 | 只读生成差异计划，不等于已经同步 |
| 应用同步计划 | 有确定计划、当次授权、无未解决冲突才开放；有备份和结果回读 |
| 导出任务卡/执行记录 | 按 Work 生成草稿，可预览、脱敏、保存；不改变 Work 状态 |
| 知识改进建议 | 展示有证据的提案，逐项接受/拒绝，不直接覆盖技能或权限 |

Work 详情增加“本次使用能力”：岗位、技能、知识及仓规来源、守卫覆盖、记录与评测；审批区显示动作/对象/来源身份及有效期。身份缺失时清楚显示需要在 App 处理，而不是从群中收到“确认”后消失。

## 5. 接入顺序

1. 只读解析能力包与来源索引，记录版本，不安装。
2. 将选定技能、知识、目标仓规注入对应 Run，保留来源清单。
3. 打通本地 Work 的任务卡/执行记录导出，维持数据库单一状态正本。
4. 对宿主与 Claude 实际工具链验证权限适配、脱敏及回放；未知覆盖明确禁用相关自动执行。
5. 验证 WorkBuddy 的真实同步与来源身份能力，再开放对应接入；未可靠绑定身份的远程审批不接收为有效批准。
6. 接入复盘和知识提案，不自动导入历史或改写个人记忆。

## 6. 验收补充

| ID | 场景 | 预期 |
| --- | --- | --- |
| AS-01 | 读取能力包 | 不安装依赖、不执行脚本、不修改用户级工具配置 |
| AS-02 | 岗位包缺失 | 如实标缺失，不把 README 目录当实际内容 |
| AS-03 | Work 切换项目 | 重新关联正确仓规与技能，旧项目上下文不泄漏 |
| AS-04 | 任务卡导出再外部编辑 | 保留所有状态事实，外部编辑不直接改变 DB 或重启 |
| AS-05 | 正本版本变化 | 展示新版本，下个 Run 按选择加载，已有证据保留旧版本 |
| AS-06 | WorkBuddy 同名技能与非托管 hooks | 先预览冲突，不执行强制覆盖或删除其他配置 |
| AS-07 | 消息缺发送人身份 | 不把群成员“确认”当指定审批人批准 |
| AS-08 | 守卫不认识的工具 | 显示未覆盖，不伪装为低风险自动放行 |
| AS-09 | 记录和诊断输出 | 脱敏且保留 Work/Run/执行器身份，钥匙串秘密不导出 |
| AS-10 | 知识编译提案 | 确认前正本无变化，拒绝项仍可追溯 |
| AS-11 | 普通机器人消息创建 Work | 无群聊目录映射要求，不受能力包设置页影响 |
| AS-12 | 原生/图形/WorkBuddy 三条路径 | 分别验证守卫和日志覆盖，不能用一条通过推断全部通过 |

## 7. 本次操作范围

只读核查本地包并更新开发文档；未安装/同步 agent-starter，未执行守卫、动态码、历史扫描或外部工具，未改变现有应用和用户级配置。上游源码变化后应按记录的文件版本重新核对，不能把本次静态核查当运行验收。

### 来源快照校验

以下为本次读取文件的 SHA-256 前 16 位，用于核对后续源码漂移；不是安装状态证明。

| 文件 | SHA-256 前缀 |
| --- | --- |
| `README.md` | `1233649db34bb81d` |
| `template/AGENTS.md` | `20a831e846809f53` |
| `template/config.json` | `fa832253f33ed232` |
| `roles/dev/config.json` | `db452f1cab65b5b9` |
| `template/skills/entry-setup/SKILL.md` | `e8de3162e7273aea` |
| `template/skills/workbuddy-sync/SKILL.md` | `d8124425216424e5` |
| `template/templates/task-card.md` | `5a4391ee3d429824` |
| `template/scripts/tasks.py` | `359fd825cde1c85b` |
| `roles/dev/skills/feature-dev/SKILL.md` | `b11944e851446c11` |
| `template/skills/task-record/SKILL.md` | `f9ad842cc6a69759` |
| `template/skills/knowledge-compile/SKILL.md` | `a2488602ed6124a3` |
