# Git 工作台与文件预览开发文档

## 1. 文档范围

本文档描述 ClaudePicker 第三栏的 Git 工作台、文件预览、技术文件编辑、项目切换、终端折叠，以及从 Git 分支创建会话的交互和开发约束。

当前目录中的实现是 H5 交互原型，运行于 Vite + React。Git、文件写入、Worktree 和 Claude 会话启动均使用模拟数据。正式接入时需要由 macOS 客户端提供受控的本地 Git、文件系统和进程能力。

文档中的状态标记：

| 标记 | 含义 |
| --- | --- |
| `已验证` | 交互原型中可操作，并已完成浏览器验证 |
| `模拟` | 有完整前端表现，外部副作用由演示数据代替 |
| `待接入` | 已定义产品或接口约束，需要连接本地能力 |
| `待完善` | 原型有入口，生产级参数、确认或异常处理尚未完整实现 |

## 2. 产品目标

用户无需离开当前 Claude Code 会话，即可完成以下工作：

1. 在左侧查看项目和会话，在中间查看终端。
2. 在第三栏切换 Git 文件和项目文件。
3. 查看项目全部文件或仅查看 Git 变更。
4. 查看 Diff、图片、PDF、Markdown、Mermaid、HTML、代码、JSON、YAML 和 CSV。
5. 编辑文本型技术文件，并实时查看结果。
6. 从当前 Git 分支创建一个归属于当前项目的新会话。
7. 选择直接使用当前分支，或从当前分支创建隔离 Worktree。
8. 收起终端以扩大 Git 和文件工作区。

## 3. 页面结构

应用根布局是 CSS Grid，桌面宽度下分为三栏：

| 区域 | 默认宽度 | 内容 | 折叠行为 |
| --- | ---: | --- | --- |
| 第一栏 | 210px | 项目与会话树 | 当前原型未提供独立折叠 |
| 第二栏 | 自适应 | 当前 Claude 会话终端 | 可收起为 44px 纵向窄条 |
| 第三栏 | 剩余空间，最小 570px | Git 工作台或文件预览 | 随第二栏收起自动扩展 |

顶栏和底部状态栏跨越三栏。桌面端根网格：

```css
grid-template-columns: 210px minmax(220px, 1fr) minmax(570px, 55%);
```

第二栏收起后：

```css
grid-template-columns: 210px 44px minmax(570px, 1fr);
```

第三栏顶部是公共工具切换器，只负责切换 Git 工作台和文件预览，并显示当前项目名称。

Git 工作台内部是固定左侧导航栏和右侧内容区：

```text
┌──────────────┬──────────────────────────────┐
│ 当前项目下拉 │ 工具栏                       │
│              │ 页面标题                     │
│ 工作区       │ 文件列表 + Diff / 页面主体   │
│ 提交历史     │                              │
│ 分支管理     │                              │
│ 合并与冲突   │                              │
│ Stash        │                              │
│ Tags         │                              │
│ 工作树       │                              │
│ 远程仓库     │                              │
│ 全部操作     │                              │
└──────────────┴──────────────────────────────┘
```

## 4. 核心数据模型

### 4.1 项目

```ts
interface Project {
  id: string;
  label: string;
  path: string;
  branch: string;
  ahead: number;
  changes: number;
}
```

约束：

- `id` 在一次应用生命周期内唯一。
- `path` 是项目根目录。
- 项目切换必须同时更新 Git 数据、文件树和后续会话的归属项目。
- 当前原型项目为 `claude-picker`、`lm-global-java`、`lanma-bankend`。

### 4.2 Git 变更文件

```ts
type GitStatus = "modified" | "added" | "deleted" | "untracked";

interface GitChange {
  path: string;
  kind: "markdown" | "diagram" | "html" | "code" | "csv" | "image" | "pdf";
  state: GitStatus;
  label: "M" | "A" | "D" | "?";
  staged: boolean;
  before: string | null;
  after: string | null;
  binary?: boolean;
}
```

状态颜色：

| 状态 | 英文标记 | 颜色 | 含义 |
| --- | --- | --- | --- |
| 未暂存 | `M` / `A` | 琥珀色 | 工作区有修改，尚未加入暂存区 |
| 已暂存 | `M` / `A` | 绿色 | 修改已经加入暂存区 |
| 已删除 | `D` | 红色 | 文件已从工作区或暂存区删除 |
| 未跟踪 | `?` | 蓝色 | 文件尚未被 Git 跟踪 |

颜色必须与状态字母同时出现，避免只能依赖颜色识别。

### 4.3 文件预览

```ts
interface PreviewFile {
  path: string;
  kind: FileKind;
  content?: string;
  src?: string;
  dimensions?: string;
  size?: string;
  deleted?: boolean;
}
```

### 4.4 会话创建请求

```ts
type SessionMode = "current" | "worktree";

interface CreateSessionRequest {
  title: string;
  prompt?: string;
  mode: SessionMode;
  projectId: string;
  projectPath: string;
  workingDirectory: string;
  baseBranch: string;
  branch: string;
}
```

会话创建成功后，第一栏项目树中的会话必须归属到 `projectId` 对应的项目，并显示创建方式和相对时间。

## 5. 应用状态

### 5.1 主应用状态

| 状态 | 默认值 | 用途 |
| --- | --- | --- |
| `activeTool` | `git` | 第三栏显示 Git 或文件 |
| `sessionCollapsed` | `false` | 第二栏终端是否收起 |
| `repo` | `claude-picker` | 当前 Git 项目 |
| `branch` | `feature/git-workbench` | 当前分支 |
| `files` | 项目变更文件 | Git 工作区文件 |
| `staged` | 空数组 | 已暂存文件 |
| `page` | `工作区` | Git 左侧当前功能 |
| `history` | 演示提交 | 提交历史 |
| `selected` | 首个变更文件 | 当前 Diff 文件 |
| `createdSessions` | 空数组 | 本次原型中新建的会话 |
| `modal` | `null` | 当前弹窗及参数 |
| `showLog` | `false` | 是否显示操作日志 |

### 5.2 文件预览状态

| 状态 | 默认值 | 用途 |
| --- | --- | --- |
| `scope` | `all` | 全部文件 / 变更文件 |
| `selectedPath` | 项目默认文件 | 当前文件 |
| `query` | 空 | 文件搜索 |
| `expanded` | 项目默认目录 | 已展开目录 |
| `previewMode` | `preview` | Diff 或文件预览 |
| `markdownMode` | `preview` | 渲染、源码、图表或表格 |
| `diffLayout` | `统一` | 并排或统一 Diff |
| `zoom` | `1` | 图片缩放倍数 |
| `editing` | `false` | 是否进入实时编辑 |
| `documents` | 初始文件内容 | 浏览器内存中的编辑结果 |
| `dirtyFiles` | 空集合 | 尚未完成编辑的文件 |

每次顶部 Git / 文件切换不得丢失当前项目。每次项目切换必须重建文件预览状态，避免新项目沿用旧文件路径。

## 6. 项目切换

项目下拉位于 Git 工作台左侧导航栏顶部。

交互规则：

1. 下拉展示当前项目的完整名称。
2. 选项至少包含项目名称，正式版建议同时展示路径和状态摘要。
3. 选择新项目后，先校验目标项目仍存在且可访问。
4. 更新仓库路径、当前分支、领先 / 落后提交数和工作区变更。
5. 重置暂存选择、当前文件和 Diff。
6. 文件预览使用新项目的文件树和 Git 状态。
7. 左侧项目会话树将新项目标记为当前项目。
8. Git 页面保持当前工具状态，但切回“工作区”以避免在新项目里停留在无意义的旧子页面。

原型行为：

| 项目 | 演示分支 | 演示变更数 |
| --- | --- | ---: |
| `claude-picker` | `feature/git-workbench` | 4 |
| `lm-global-java` | `bugfix/zcl/20261113_operationRetryCropFailed` | 5 |
| `lanma-bankend` | `beta` | 4 |

## 7. 会话创建

### 7.1 入口

入口位于 Git 左侧导航的“分支管理”页内容工具栏，按钮名称是“创建会话”。

入口只在分支管理页出现。项目下拉位于左侧固定导航栏，因此在分支管理页仍可直接切换当前项目。

### 7.2 弹窗结构

弹窗从上到下包含：

1. 标题和关闭按钮。
2. 当前项目名称、项目路径和“归属当前项目”标记。
3. 两种创建模式。
4. 会话标题输入框。
5. Worktree 模式下的分支名称输入框。
6. 可选初始任务文本框。
7. 项目目录、会话目录、基准 / 目标分支摘要。
8. Worktree 模式的 Git 命令预览。
9. 取消和提交按钮。

### 7.3 基于当前分支

输入：

- 会话标题，必填。
- 初始任务，可选。

生成结果：

```ts
{
  mode: "current",
  projectPath: project.path,
  workingDirectory: project.path,
  baseBranch: currentBranch,
  branch: currentBranch
}
```

正式实现应直接以项目根目录启动 Claude 会话，不创建分支，不创建 Worktree。新会话写入当前项目的会话列表。

### 7.4 创建 Worktree

输入：

- 会话标题，必填。
- 新分支名称，可选。默认建议为 `session/<slug>`。
- 初始任务，可选。

目录规则：

```text
项目目录：{project.path}
Worktree 目录：{project.path}/.worktrees/{branchSlug}
```

分支规则：

```text
当前分支 → 新分支
```

正式命令意图：

```bash
git -C <project.path> worktree add \
  <project.path>/.worktrees/<branchSlug> \
  -b <targetBranch> \
  <currentBranch>
```

执行前必须检查：

- `.worktrees` 是安全且可写的目录。
- 目标分支不存在。
- Worktree 路径为空或不存在。
- 项目根目录是 Git 仓库。
- 当前分支仍存在。
- 路径经过标准化后仍位于项目目录内。

执行后：

1. 记录实际 Worktree 路径和分支。
2. 会话归属仍是当前项目的 `projectId`。
3. 会话工作目录使用 Worktree 路径。
4. 失败时不得先在项目树中插入成功会话。
5. Worktree 创建成功但会话启动失败时，必须提供保留 Worktree、重试会话和清理 Worktree 三种恢复动作。

### 7.5 创建结果

原型成功后：

- 关闭弹窗。
- 在第一栏当前项目下插入会话。
- 会话摘要显示“当前分支 · 刚刚”或“Worktree · 刚刚”。
- 写入底部操作日志。
- 显示成功 Toast。

正式实现需要返回：

```ts
interface CreatedSession {
  sessionId: string;
  projectId: string;
  title: string;
  mode: SessionMode;
  workingDirectory: string;
  branch: string;
  processId?: number;
  createdAt: string;
}
```

## 8. 控件与按钮清单

以下清单覆盖当前原型中的按钮。正式实现不得只保留视觉样式，必须遵守对应前置条件和状态反馈。

### 8.1 顶部栏

| 控件 | 动作 | 状态与结果 | 实现状态 |
| --- | --- | --- | --- |
| `搜索操作` | 打开 Git 命令搜索弹窗 | `⌘K` / `Ctrl+K` 同样触发 | 已验证 |

### 8.2 项目与会话栏

| 控件 | 动作 | 状态与结果 | 实现状态 |
| --- | --- | --- | --- |
| 当前会话终端收起按钮 | 收起第二栏 | 保留 44px 窄条并扩展第三栏 | 已验证 |
| 终端窄条 `展开当前会话终端` | 恢复第二栏 | 恢复原终端宽度 | 已验证 |
| 项目行 | 正式版应展开 / 折叠 | 当前原型仅展示状态 | 待完善 |
| 会话行 | 正式版应恢复会话 | 当前原型仅展示状态 | 待完善 |
| `添加目录` | 正式版应选择项目目录 | 当前原型为静态入口 | 待接入 |

### 8.3 第三栏公共工具

| 控件 | 动作 | 状态与结果 |
| --- | --- | --- |
| `Git 工作台` | 显示 Git 工作区 | 保留当前项目 |
| `文件预览` | 显示文件工作区 | 使用 Git 中选定的项目 |

### 8.4 Git 左侧导航

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| 项目下拉 | 切换项目 | 更新分支、变更、Diff 和文件树 |
| `添加项目` | 打开添加 / 克隆项目弹窗 | 通用参数弹窗 |
| `工作区` | 打开工作区 | 默认页 |
| `提交历史` | 打开提交列表 | 显示提交记录 |
| `分支管理` | 打开分支列表 | 显示“创建会话”和“新建分支” |
| `合并与冲突` | 打开冲突页 | 显示当前冲突状态 |
| `Stash 暂存` | 打开 Stash 列表 | 显示暂存记录 |
| `标签 Tags` | 打开标签页 | 显示标签 |
| `工作树` | 打开 Worktree 列表 | 显示工作树 |
| `远程仓库` | 打开 Remote 页 | 显示远端 |
| `全部操作` | 打开操作目录 | 分组展示 Git 命令 |

### 8.5 Git 顶部工具栏

| 控件 | 动作 | 状态与结果 | 实现状态 |
| --- | --- | --- | --- |
| 当前分支按钮 | 打开分支管理 | 分支名来自当前项目 | 已验证 |
| `获取` | Fetch | 显示同步结果 | 模拟 |
| `拉取` | Pull | 显示远端落后数量 | 待接入 |
| `推送` | Push | 成功后本地领先数量归零 | 模拟 |

### 8.6 工作区页

| 控件 | 前置条件 | 动作 | 结果 |
| --- | --- | --- | --- |
| `全部暂存` | 有未暂存变更 | 全部加入暂存区 | 文件移入已暂存分组 |
| 文件名称行 | 文件可读 | 选中文件 | 右侧显示该文件 Diff |
| 未暂存文件 `＋` | 文件未暂存 | 暂存单个文件 | 文件进入已暂存分组 |
| `取消全部暂存` | 至少一个已暂存文件 | 清空暂存选择 | 文件回到未暂存分组 |
| 已暂存文件回退按钮 | 文件已暂存 | 取消该文件暂存 | 文件回到未暂存分组 |
| `更多提交方式` | 无 | 打开提交参数弹窗 | 签名、跳过 hooks、空提交等 |
| `提交到当前分支` | 有已暂存文件且提交信息非空 | 创建提交 | 写入历史、增加本地领先提交 |
| `并排` | 当前为 Diff | 切换双列 Diff | 显示父版本和工作区版本 |
| `统一` | 当前为 Diff | 切换单列 Diff | 显示统一 Diff |
| `文件历史` | 已选文件 | 打开文件历史 | 正式版按路径过滤提交 |
| `放弃文件修改` | 已选文件有变更 | 二次确认后恢复 | 产生破坏性操作确认 |
| `暂存此文件` | 当前 Diff 对应文件未暂存 | 暂存当前文件 | 更新分组和状态 |
| `复制路径` | 已选文件 | 复制绝对或项目相对路径 | 显示 Toast |

### 8.7 提交历史页

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| `差异` | 打开提交详情 | 显示提交摘要、文件列表、Diff 和完整文件 |
| 单条提交更多按钮 | 打开提交操作 | Cherry-pick、Revert、Reset、创建分支 |

提交详情内：

| 控件 | 动作 |
| --- | --- |
| `关闭提交详情` | 返回历史 |
| 提交文件行 | 切换当前文件 |
| `Diff` | 显示相对父提交的差异 |
| `文件内容` | 显示完整文件 |
| `并排` | 双列 Diff |
| `统一` | 单列 Diff |
| `提交前` | 显示父提交完整内容 |
| `提交后` | 显示本次提交完整内容 |
| `返回提交历史` | 关闭详情 |

### 8.8 分支管理页

| 控件 | 前置条件 | 动作 | 结果 |
| --- | --- | --- | --- |
| `创建会话` | 有当前项目和当前分支 | 打开会话创建弹窗 | 提供当前分支和 Worktree 两种模式 |
| `新建分支` | 有当前项目 | 打开新建分支弹窗 | 输入分支名后加入列表 |
| `切换分支` | 非当前分支 | 切换本地分支 | 更新当前分支和状态 |
| `合并` | 目标分支可合并 | 打开合并预览 | 正式版执行合并 |
| 单分支更多按钮 | 非当前分支 | 打开分支操作 | 重命名、删除、变基、设置上游 |
| `检出本地分支` | 远程分支存在 | 创建本地跟踪分支 | 更新当前分支 |

### 8.9 创建会话弹窗

| 控件 | 类型 | 动作 | 验证 |
| --- | --- | --- | --- |
| 关闭按钮 | 按钮 | 关闭弹窗并丢弃输入 | 无副作用 |
| `基于当前分支` | 模式按钮 | 会话目录使用项目根目录 | 必须显示项目目录和当前分支 |
| `创建 Worktree` | 模式按钮 | 显示新分支输入和 Worktree 路径 | 必须显示基准分支和目标分支 |
| `会话标题` | 输入框 | 设置会话在项目树中的标题 | 必填，去除首尾空格 |
| `新分支名称` | 输入框 | 设置 Worktree 目标分支 | Worktree 模式可用 |
| `初始任务` | 文本域 | 作为新会话的首条任务 | 可选 |
| `取消` | 按钮 | 关闭弹窗 | 不创建会话 |
| `创建会话` | 提交按钮 | 在当前分支上创建会话 | 标题为空时禁用 |
| `创建 Worktree 会话` | 提交按钮 | 创建 Worktree 和目标分支后创建会话 | 标题为空时禁用 |

### 8.10 合并与冲突页

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| `采用当前更改` | 选择 OURS | 记录解决策略 |
| `采用传入更改` | 选择 THEIRS | 记录解决策略 |
| `保留双方` | 保留两段内容 | 记录解决策略 |
| `标记为已解决` | 暂存解决结果 | 无选择时禁用 |
| `终止合并` | 取消合并 | 正式版需要确认 |

### 8.11 Stash 页

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| `保存变更` | 打开保存 Stash 弹窗 | 需要说明和是否包含未跟踪文件 |
| `应用 Apply` | 应用并保留 Stash | 工作区恢复 |
| `弹出 Pop` | 应用并删除 Stash | 成功后才删除 |
| 删除按钮 | 删除 Stash | 必须确认 |

### 8.12 Tags 页

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| `新建标签` | 打开标签表单 | 创建轻量或附注标签 |
| `推送标签` | 推送指定标签 | 显示远端结果 |
| `检出` | 检出标签 | detached HEAD 警告 |
| 更多按钮 | 打开标签操作 | 删除、复制引用等 |

### 8.13 Worktree 页

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| `新建工作树` | 打开 Worktree 表单 | 选择路径、分支和基准 |
| `打开工作树` | 切换当前工作树上下文 | 更新文件树和 Git 状态 |
| 更多按钮 | 打开 Worktree 操作 | 锁定、移动、移除、清理 |

### 8.14 远程仓库页

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| `添加远程仓库` | 打开添加表单 | 名称、URL、fetch / push 地址 |
| `编辑` | 编辑 origin | 更新 URL 和跟踪规则 |
| 更多按钮 | 打开 Remote 操作 | 添加、移除、修改 URL、Prune |

### 8.15 全部操作页

以下每个命令名称都是可点击按钮，点击后打开统一的参数和命令预览弹窗：

| 分组 | 按钮 |
| --- | --- |
| 仓库与配置 | 初始化仓库 `init`、克隆仓库 `clone`、仓库配置 `config`、忽略规则 `.gitignore`、子模块 `submodule`、`Git LFS` |
| 日常变更 | `status`、`diff`、`add`、`restore --staged`、恢复文件、`commit`、`amend`、`stash` |
| 分支与协作 | `branch`、`switch`、`merge`、`rebase`、`rebase -i`、`cherry-pick`、`fetch`、`pull`、`push`、`remote`、`tag`、`worktree` |
| 历史与恢复 | `log`、`blame`、`bisect`、`revert`、`reset`、`reflog`、`clean`、`format-patch / apply`、`archive`、`show / ls-tree`、`gc / fsck` |
| 命令入口 | `输入 Git 命令` |

### 8.16 通用操作弹窗

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| 关闭按钮 | 关闭弹窗 | 丢弃未提交参数 |
| 输入框 | 输入分支、标签、URL 或命令 | 实时更新命令预览 |
| `取消` | 关闭弹窗 | 无副作用 |
| `确认演示` | 记录操作日志并关闭 | 不执行真实命令 |
| 危险操作确认 | 显示影响范围后确认 | 正式版二次确认 |

### 8.17 底部状态栏

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| `操作日志` | 打开或关闭日志面板 | 展示最近一次演示操作 |
| 日志关闭按钮 | 关闭面板 | 保留日志数据 |

### 8.18 文件预览工具栏

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| `全部文件` | 显示项目完整树 | 文件名显示 Git 状态颜色 |
| `变更文件` | 仅显示变更 | 按已暂存和未暂存分组 |
| 文件搜索框 | 筛选完整路径 | 自动展开匹配目录 |
| `展开全部文件夹` | 展开树 | 显示所有目录 |
| `折叠全部文件夹` | 折叠树 | 保留根文件 |
| 目录行 | 展开或折叠目录 | 更新箭头和 aria-expanded |
| 文件行 | 选中文件 | 更新共享预览区 |
| `复制路径` | 复制当前路径 | 显示反馈 |
| `下载文件` | 下载当前文件 | 正式版限制二进制和大小 |
| `变更差异` | 显示 Git Diff | 变更文件默认进入此状态 |
| `文件预览` | 显示当前文件 | 与 Diff 共用同一个预览位置 |
| `并排` | 双列 Diff | 仅文本 Diff |
| `统一` | 单列 Diff | 仅文本 Diff |
| `渲染 / 图表 / 网页 / 表格` | 切换可视化预览 | 因文件类型不同显示不同标签 |
| `源码` | 显示源文本 | 所有文本类型可用 |
| `缩小` | 图片缩小 | 下限 50% |
| `放大` | 图片放大 | 上限 200% |
| `编辑` | 进入实时编辑 | 文本型文件可用 |
| `完成编辑` | 结束编辑并保存到内存 | 显示保存反馈 |

### 8.19 文件编辑器

| 控件 | 动作 | 结果 |
| --- | --- | --- |
| 文本编辑区 | 修改源内容 | 右侧实时重新渲染或刷新行号 |
| 实时预览区 | 查看当前结果 | Mermaid、Markdown、HTML、CSV 实时更新 |

## 9. 文件类型支持

| 类型 | 扩展名 | 默认预览 | 可编辑 | 特殊处理 |
| --- | --- | --- | --- | --- |
| Markdown | `.md`, `.mdx` | GFM 渲染 | 是 | 支持表格、任务列表、内嵌 Mermaid |
| Mermaid | `.mmd`, `.mermaid` | 图表 | 是 | 流程图、ER 图、时序图 |
| HTML | `.html` | iframe 页面 | 是 | `sandbox="allow-scripts"`，隔离父页面 |
| 代码 | `.swift`, `.java`, `.py` 等 | 带行号源码 | 是 | 编辑后刷新行号和 Diff |
| JSON | `.json` | 源码 | 是 | 正式版应校验语法 |
| YAML | `.yaml`, `.yml` | 源码 | 是 | 正式版应校验缩进和语法 |
| CSV | `.csv` | 表格 | 是 | 支持表格 / 源码切换 |
| 图片 | PNG / JPG / GIF / WebP | 图片查看器 | 否 | 缩放 50%–200% |
| PDF | `.pdf` | 页面预览 | 否 | 正式版使用 PDF 渲染器 |
| 未知二进制 | 其他 | 类型信息和下载 | 否 | 不尝试文本解码 |

## 10. 文件预览状态规则

1. 全部文件视图包含完整项目文件树。
2. 变更文件视图只包含新增、修改、删除和未跟踪文件。
3. 删除文件不出现在全部文件树中，只在变更视图和历史中可见。
4. 点击有 Git 变更的文件，默认进入 Diff。
5. 点击无 Git 变更的文件，默认进入文件预览。
6. 从 Diff 切换到文件预览时，不丢失当前文件。
7. 编辑后的内容进入 Diff 的当前版本。
8. 切换项目后重建文件树、选中文件和编辑状态。
9. 图片和 PDF 不显示编辑按钮。
10. HTML 脚本在 iframe 中运行，脚本不能访问父页面。

## 11. Git 操作接口

正式版建议通过结构化接口执行命令，禁止前端直接拼接 shell 字符串。

```ts
interface GitAPI {
  status(projectPath: string): Promise<GitStatusSnapshot>;
  diff(projectPath: string, filePath: string, staged: boolean): Promise<DiffResult>;
  stage(projectPath: string, paths: string[]): Promise<void>;
  unstage(projectPath: string, paths: string[]): Promise<void>;
  commit(projectPath: string, message: string, options: CommitOptions): Promise<CommitResult>;
  branches(projectPath: string): Promise<BranchInfo[]>;
  switchBranch(projectPath: string, branch: string): Promise<void>;
  createWorktree(input: CreateWorktreeInput): Promise<WorktreeResult>;
  removeWorktree(input: RemoveWorktreeInput): Promise<void>;
  tags(projectPath: string): Promise<TagInfo[]>;
  remotes(projectPath: string): Promise<RemoteInfo[]>;
}
```

### 11.1 错误结构

```ts
interface GitError {
  code:
    | "NOT_A_REPOSITORY"
    | "DETACHED_HEAD"
    | "BRANCH_EXISTS"
    | "WORKTREE_PATH_EXISTS"
    | "DIRTY_WORKTREE"
    | "MERGE_CONFLICT"
    | "PERMISSION_DENIED"
    | "COMMAND_FAILED";
  message: string;
  detail?: string;
  recoverable: boolean;
}
```

### 11.2 命令安全

- 路径参数必须以数组形式传给进程调用。
- 所有路径使用 `realpath` 和相对路径校验。
- Worktree 路径必须位于当前项目根目录内。
- 删除 Worktree、Reset、Clean、放弃修改必须二次确认。
- 冲突页必须先阻止继续合并，直到所有冲突文件已解决。
- 拉取或合并前检查未提交变更，避免隐式 stash。
- Git hooks 结果必须原样展示到日志。

## 12. 文件系统接口

```ts
interface FileAPI {
  list(projectPath: string): Promise<FileNode[]>;
  read(projectPath: string, filePath: string): Promise<FileContent>;
  write(projectPath: string, filePath: string, content: string): Promise<void>;
  stat(projectPath: string, filePath: string): Promise<FileStat>;
  watch(projectPath: string, callback: () => void): Promise<() => void>;
}
```

要求：

- 文件树只遍历允许展示的目录。
- `.git` 默认不显示。
- 单文件预览设置大小上限。
- 大文件显示确认提示和分段加载。
- 保存前检查外部修改冲突。
- 编辑器使用原子保存，先写临时文件再替换。
- 图片、PDF 和二进制通过安全 URL 或本地资源处理器读取。

## 13. 会话启动接口

```ts
interface SessionAPI {
  create(input: CreateSessionRequest): Promise<CreatedSession>;
  resume(sessionId: string): Promise<void>;
  terminate(sessionId: string): Promise<void>;
  listForProject(projectId: string): Promise<SessionSummary[]>;
}
```

基于当前分支：

```text
projectPath -> workingDirectory
existing branch -> branch
```

Worktree：

```text
projectPath + "/.worktrees/" + branchSlug -> workingDirectory
new branch -> branch
```

会话写入项目会话索引时，`projectId` 始终由打开下拉时的当前项目决定。Worktree 不创建独立的项目分组。

## 14. 交互和视觉规范

### 14.1 颜色

| 用途 | 色值 |
| --- | --- |
| 主背景 | `#111214` |
| 次级表面 | `#1b1c20` |
| 边框 | `#34353a` |
| 主文字 | `#dadbdd` |
| 次文字 | `#858890` |
| 强调色 | `#de9771` |
| 新增 / 已暂存 | `#91bd9c` |
| 删除 | `#d78e8c` |
| 未暂存 | `#d4b56f` |
| 未跟踪 | `#7fadd4` |

### 14.2 尺寸

| 项目 | 尺寸 |
| --- | ---: |
| 顶栏 | 59px |
| 底部状态栏 | 29px |
| 第三栏工具切换 | 42px |
| Git 左侧导航 | 150px（较窄宽度 132px） |
| Git 变更列 | 215–240px |
| 终端收起窄条 | 44px |
| 常规按钮高度 | 28–35px |
| 主圆角 | 6–9px |
| 弹窗圆角 | 12px |

### 14.3 键盘

| 快捷键 | 动作 |
| --- | --- |
| `⌘K` / `Ctrl+K` | 打开 Git 操作搜索 |
| `Esc` | 关闭当前弹窗 |
| `Tab` | 在可交互控件间移动 |
| `Enter` | 激活当前按钮或提交表单 |
| `Space` | 切换勾选框和标签按钮 |

所有图标按钮必须有 `aria-label` 和 `title`。模式按钮必须通过 `role="tab"` 和 `aria-selected` 表达状态。

## 15. 加载、空状态和错误

| 场景 | UI |
| --- | --- |
| 项目无变更 | 显示“工作区干净” |
| 搜索无结果 | 显示“没有匹配的变更文件” |
| Mermaid 正在渲染 | 显示“正在绘制图表…” |
| Mermaid 编辑中语法错误 | 显示“图表语法尚未完成，请继续编辑。” |
| 删除文件预览 | 显示父提交内容提示 |
| 图片父版本为空 | 显示“此前没有此文件” |
| 图片当前版本为空 | 显示“文件已删除” |
| 二进制文件过大 | 阻止直接加载并提供打开外部文件入口 |
| Git 命令失败 | 保留当前 UI，显示结构化错误和重试入口 |
| Worktree 创建失败 | 不插入会话，显示具体命令错误 |
| 会话启动失败 | 保留已创建 Worktree，提供重试和清理 |

## 16. 测试清单

### 16.1 布局

- 1281 × 983 三栏无页面横向溢出。
- 第二栏收起时第三栏扩展到可用宽度。
- Git 左侧导航在所有 Git 页面保持固定。
- 1000px 以下进入双栏布局。
- 390px 宽度下第三栏可独立使用。

### 16.2 项目

- 三个演示项目均可切换。
- 切换后分支、提交领先数和变更数一致。
- 文件预览显示当前项目文件树。
- 创建会话后出现在对应项目节点下。

### 16.3 会话创建

- 当前分支模式的项目目录和分支正确。
- Worktree 模式生成项目内 `.worktrees` 路径。
- 空标题时提交按钮禁用。
- 取消不产生会话。
- 成功创建后关闭弹窗并显示成功反馈。

### 16.4 文件

- 全部文件和变更文件视图切换正确。
- 状态颜色与 M/A/D/? 字母一致。
- 展开和折叠全部目录正确。
- Markdown 实时编辑并更新预览。
- Mermaid 流程图、ER 图和时序图可实时重绘。
- HTML 修改后在 iframe 内实时更新。
- 代码编辑后文件预览和 Diff 同步。
- CSV 编辑后表格同步。
- 图片缩放上下限正确。
- PDF 和图片没有编辑按钮。

### 16.5 Git

- 暂存、取消暂存、提交和历史更新正确。
- 提交详情可切换文件、Diff 和完整文件。
- 冲突策略选择完成后才能标记解决。
- Stash 的 Apply、Pop、删除反馈明确。
- 分支切换后工具栏和状态栏同步。
- 破坏性操作均出现确认。

## 17. 实施顺序

1. 封装 Ruby / Swift / Node 侧的 Git 执行层，统一返回结构化状态和错误。
2. 接入真实项目发现、项目切换和文件监听。
3. 接入工作区状态、暂存、取消暂存和提交。
4. 接入文件树、文本编辑、原子保存和二进制安全预览。
5. 接入 Markdown、Mermaid、HTML 和代码预览。
6. 接入分支列表和分支切换。
7. 接入当前分支创建会话。
8. 接入项目内 Worktree 创建、会话启动和失败恢复。
9. 接入提交历史、Diff、冲突和 Stash。
10. 接入 Tags、Remote、Worktree 管理和高级命令。
11. 补齐键盘操作、无障碍标签和自动化测试。

## 18. 当前原型的边界

- Git 命令、文件保存和会话进程均未执行。
- 文件编辑内容只在浏览器内存中，刷新页面后恢复演示内容。
- 项目会话树中的新会话只存在于当前页面状态。
- Worktree 路径和命令仅用于确认交互与布局。
- Mermaid 依赖按需加载，构建时会生成较大的图表模块。
- 高级 Git 操作目前共用参数预览弹窗，生产版需要按命令设计独立表单、危险确认和错误恢复。

## 19. 完成标准

- 每个按钮都能在本文档中找到行为、条件和结果。
- 项目选择在所有 Git 页面保持可用。
- 会话创建的两种模式都明确归属于当前项目。
- Worktree 创建失败与会话启动失败不会留下不可解释的中间状态。
- 文件编辑保存失败时保留用户输入。
- 所有 Git 破坏性操作都经过明确确认。
- 三栏在本机窗口缩放、终端收起和不同项目间保持稳定。
