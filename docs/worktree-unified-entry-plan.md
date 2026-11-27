# 工作树统一入口接入开发方案

> 日期：2026-11-27 · 状态：已实施（开发分支），桌面界面验收待补
> 来源：《ClaudePicker 接入本机 Worktree 规则》（TAPD 1030864 产出）
> 本机规则正本：`~/.config/ai-worktree/policy.md`，命令：`~/.local/bin/ai-worktree`

## 1. 目标与范围

在「创建工作树」和新建会话的「独立工作树」里接入本机统一命令 `ai-worktree ensure`。配置之后，同一任务在 ClaudePicker、Claude Code、Codex 等工具之间创建或复用同一个目录，不再各建一份 `.worktrees/<slug>`。

**本次范围**

- macOS 原生端和 Electron（Windows）端的 `git.createWorktree` 增加统一模式，`session.create` 的 `mode: "worktree"` 走同一条路径。
- 设置页增加统一命令路径配置。未配置时完全沿用现有项目内 `.worktrees/` 模式。
- 侧栏项目归属改为按 Git common dir 识别，统一目录（`~/project/worktrees/<仓库>/<任务>`）下的会话归到主仓库。
- 删除工作树前检查其它会话引用。

**不在本次范围**

- Work 中心执行隔离（[WorkspaceService.swift:84](../Sources/ClaudeDeck/Work/WorkspaceService.swift)）仍由 App 自己在 `.worktrees/work-*` 管理，属于规则里的「应用原生隔离」。是否迁到 `<统一根>/.managed/claude-picker` 另行处理。
- 从 TAPD 待办列表直接发起创建工作树。本次只预留入参，见 §4.4。
- 修改 `ai-worktree` 本身。需要它配合的点列在 §8。

## 2. 现状代码地图

| 环节 | 位置 | 现状 |
|---|---|---|
| 入参与返回 | [GitModels.swift:235](../Sources/ClaudeDeck/Git/GitModels.swift) `CreateWorktreeInput` / `:249` `WorktreeResult` | 入参是 `projectPath`、`branch`、`path?`、`baseBranch?`，返回 `path`、`branch` |
| Bridge | [BridgeHandlers+Git.swift:179](../Sources/ClaudeDeck/ThirdPane/BridgeHandlers+Git.swift) | 从 `params.input` 取四个字段 |
| 创建实现 | [GitService.swift:550](../Sources/ClaudeDeck/Git/GitService.swift) | 只能建在 `<项目>/.worktrees/<slug>`，写入 `info/exclude` 并校验已被忽略 |
| 列表 | [GitService.swift:158](../Sources/ClaudeDeck/Git/GitService.swift) | `git worktree list --porcelain`，天然包含统一目录里的工作树 |
| 外部命令 | [ProcessRunner.swift:43](../Sources/ClaudeDeck/Git/ProcessRunner.swift) | 可执行文件 + 参数数组，经 login shell 继承用户 PATH，自带超时 |
| 会话创建 | [BridgeHandlers+Session.swift:85](../Sources/ClaudeDeck/ThirdPane/BridgeHandlers+Session.swift) | `mode: current` 带 `worktreePath` 时用 Git 列表核对；`:100` `mode: worktree` 直接调 `createWorktree` |
| 项目归属 | [Models.swift:287](../Sources/ClaudeDeck/Models.swift) `WorktreeLayout.owner`；调用处 [main.swift:560](../Sources/ClaudeDeck/main.swift)、[main.swift:2951](../Sources/ClaudeDeck/main.swift) | 只认路径中的 `/.worktrees/<名字>`，统一目录会被当成独立项目 |
| 设置 | [Models.swift:346](../Sources/ClaudeDeck/Models.swift) `AppSettings`；`app.settings` → `store.applySettings` | 无工作树相关项 |
| Electron 创建 | [Desktop/git.cjs:520](../Desktop/git.cjs) | 独立的 `.worktrees` 路径计算，无忽略校验 |
| Electron 会话 | [Desktop/runtime.cjs:544](../Desktop/runtime.cjs) 核对 `worktreePath`；`:558` `mode: worktree` | 与 macOS 同构 |
| Electron 归属 | [Desktop/runtime.cjs:126](../Desktop/runtime.cjs) | 同样只认 `.worktrees` 片段 |
| 界面 | [Modals.jsx:575](../Web/src/shell/Modals.jsx) `CreateWorktreeModal`；`:685` `SessionModal` | 标题转拼音生成分支，预览 `.worktrees/<slug>` |
| 显示名 | [worktree-name.js](../Web/src/shell/worktree-name.js)、[App.jsx:328](../Web/src/shell/App.jsx) | 首个会话标题生成显示名，存本地 `worktreeLabels`，与磁盘路径无关 |
| 删除 | [GitPages.jsx:299](../Web/src/shell/GitPages.jsx) → `git.removeWorktree` | 非强制删除，保留分支，不检查会话引用 |

## 3. `ai-worktree` 契约（按当前脚本核对）

```bash
ai-worktree ensure --repo <绝对路径> --task <ID> [--name <名>] [--subtask <子任务>] \
                   [--base <基线>] [--branch <分支>] --json
ai-worktree repo-root --repo <路径>     # 只读，打印主工作树
```

- **成功**：退出码 0，stdout 一行 JSON：

  ```json
  {"action":"created|reused","repo_root":"…","task":"1030864[/sub]","path":"…","branch":"…|null",
   "head":"…","base_ref":"…|null","base_commit":"…|null"}
  ```

  复用 Git 未留建分支记录的历史工作树时，`base_ref` 和 `base_commit` 为 null。分离 HEAD 时 `branch` 为 null。
- **失败**：退出码 1，stderr 为 `ai-worktree: <原因>`。参数错误由 argparse 返回退出码 2。
- `--task`、`--name`、`--subtask` 各自须匹配 `^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$` 且不以 `.` 结尾，三者用 `-` 拼成的目录名也受同样限制。
- 目录为 `${AI_WORKTREE_ROOT:-~/project/worktrees}/<仓库目录名>/<task>-<name>-<subtask>`，登记在 `<根>/.registry/<仓库>.json`，按仓库加 `flock` 互斥。并发创建由命令保证只登记一次。
- 未传 `--branch` 时，普通仓库默认 `worktree/<目录名>`。`lm-global-java` 按 TAPD 规则生成。方果、蓝马仓库必须显式传 `--branch`，否则报错。
- 主动报错的情形：分支已存在、远端已有同名分支、目标目录被占用、任务已登记在别的分支、复用时改了基线、登记存在但 Git 已无对应工作树。

## 4. 设计

### 4.1 模式与设置

- 新增设置 `worktreeCommand: String`，默认空。空值为**项目模式**（现有行为），非空为**统一模式**。macOS 写入 `AppSettings`（`init(from:)` 同步加缺省解码），Electron 写入 `config.settings`，键名一致。
- 保存时校验：绝对路径、解析符号链接后是普通文件、有执行权限。校验失败不保存并提示原因。
- 设置页「界面与会话」（[SettingsModal.jsx:247](../Web/src/shell/work/SettingsModal.jsx) `Appearance`）加一张「工作树」卡片：路径输入框和「检测」按钮。检测执行只读的 `repo-root --repo <当前项目>`，显示返回的主仓库路径或错误。本机填 `/Users/zcl/.local/bin/ai-worktree`。Windows 上该脚本依赖 `fcntl`，暂不可用，保持留空。
- 统一模式下命令缺失、超时、退出码非 0、JSON 无效都按**错误**处理，**不回退**到项目模式，以免同一任务出现两份目录。

### 4.2 接口契约

`git.createWorktree` 的 `input` 增加可选字段，旧调用方不受影响：

| 字段 | 项目模式 | 统一模式 |
|---|---|---|
| `projectPath` | 必填 | 必填，解析为绝对路径后作为 `--repo` |
| `branch` | 必填 | 可选，非空时传 `--branch` |
| `baseBranch` | 可选 | 可选，非空时传 `--base` |
| `path` | 可选（须在 `.worktrees/` 下） | 忽略，目录由命令返回 |
| `task` | 忽略 | **必填** |
| `name`、`subtask` | 忽略 | 可选 |

`WorktreeResult` 增加可选字段，项目模式填 `action: "created"`、`mode: "project"`：

```swift
struct WorktreeResult: Codable, Sendable, Equatable {
    let path: String
    let branch: String?          // 统一模式复用分离 HEAD 时为 nil
    var action: String = "created"   // created | reused
    var mode: String = "project"     // project | unified
    var task: String? = nil
    var baseRef: String? = nil
    var baseCommit: String? = nil
    var head: String? = nil
}
```

`branch` 改为可选后，需检查 Swift 端所有读取 `WorktreeResult.branch` 的位置（`BridgeHandlers+Session.swift:107` 等）。

`session.create` 的 `mode: "worktree"` 同样接受 `task`、`name`、`subtask`，原样转给 `createWorktree`，返回里附带 `worktreeAction`。

### 4.3 统一模式执行流程（两端一致）

1. 读取设置里的 `worktreeCommand`；为空则走项目模式。
2. 本地校验 `task`、`name`、`subtask` 的格式（同 §3 正则），不合规直接返回参数错误，不启动进程。
3. 以参数数组启动：`[cmd, "ensure", "--repo", repo, "--task", task, (--name …), (--subtask …), (--base …), (--branch …), "--json"]`。macOS 用 `ProcessRunner.shared.run`，Electron 用 `execFile`。超时 120 秒，包含远端 fetch 的时间，前端已有 150 秒请求超时。设置 `GIT_TERMINAL_PROMPT=0`。
4. 退出码非 0：取 stderr，去掉 `ai-worktree: ` 前缀，作为可恢复错误返回，界面原样展示。
5. 解析 stdout 最后一个非空行为 JSON，缺少 `action`、`path`、`repo_root` 中任一字段即视为 JSON 无效。
6. **Git 复核**，任一不符都报错，不登记会话：
   - `repo_root` 与 `projectPath` 的主工作树一致（规范化路径后比较）；
   - `git worktree list --porcelain` 中存在该 `path`，且未标记 prunable；
   - 列表中该条目的分支等于返回的 `branch`；
   - `git -C <path> rev-parse --path-format=absolute --git-common-dir` 与项目的 common dir 相同。
7. 返回扩展后的 `WorktreeResult`。统一模式不写 `info/exclude`，因为目录在仓库外。

macOS 把以上逻辑放进 `GitService` 的一个新私有方法 `ensureUnifiedWorktree`，`createWorktree` 开头按模式分派。设置从 `Store` 读取后随 `CreateWorktreeInput` 传入，`GitService` 不直接依赖 `Store`。Electron 在 `git.cjs` 的 `git.createWorktree` 分支里实现同样的步骤，同时给项目模式补上 macOS 已有的 `.worktrees` 范围检查和忽略校验，消除两端差异。

### 4.4 界面

**CreateWorktreeModal（统一模式）**

| 字段 | 说明 |
|---|---|
| 项目、起始分支、代理 | 保持现状 |
| 任务标识（必填） | 预填顺序：调用方传入的 `tapd.id` → 标题里的 `tapd <编号>` → 空。TAPD 一律取**完整 ID**，不截短。实时校验格式 |
| 子任务（可选） | 并行独立子任务时填写 |
| 名称（可选） | 沿用现有标题输入，经 `worktreeTitleSlug` 转 ASCII 后作为 `--name`，最长截到满足 100 字符限制 |
| 分支（可选） | 默认留空，提示「留空按仓库规则生成」。命令报 `Specify --branch` 时保留表单并聚焦此框 |
| 目录预览 | 创建前显示「由 ai-worktree 决定，已登记的任务沿用原路径」，返回后显示实际路径 |

- 结果提示按 `action` 区分：「已创建工作树 …」或「已复用工作树 …」。
- 失败时保留全部输入，错误显示在表单内。已拿到 `createdTree` 但代理启动失败时，沿用现有「重试启动代理」，不再调用 ensure。
- 项目模式界面不变。
- 组件新增可选 prop `tapd: { id, title }`（完整 ID），为将来从 TAPD 待办发起创建预留。

**SessionModal「独立工作树」**：统一模式下同样显示任务标识和子任务，必填校验与上表一致，目录预览改为同样的提示文案。

**TAPD 任务标识取完整 ID**（用户 2026-11-27 确认）：统一工作树的 `--task` 直接使用 TAPD 完整 ID，不做截短，因此不需要统一 `TapdAdapter.swift` 与 `worktree-name.js` 的短 ID 规则；两者仅用于显示名，保持现状。本机规则 `policy.md` 已同步改为完整 ID。改之前用短 ID 登记的任务（如 lm-global-java 的 `1030864`）仍按原短 ID 续做，用完整 ID 会被当作新任务。

### 4.5 项目归属（Git common dir）

新增归属解析器，Swift 放在 `Models.swift` 替换 `WorktreeLayout.owner` 的实现，Node 放在 `runtime.cjs`：

1. 路径含 `/.worktrees/<名字>` 时沿用现有快速判断。
2. `<cwd>/.git` 是**文件**时，读取其中的 `gitdir: <X>`，再读 `<X>/commondir`（相对于 X 解析）得到 common dir。common dir 的末段是 `.git` 时，主仓库为其父目录。
3. `.git` 是目录、不存在、读不到，或 common dir 不以 `.git` 结尾（bare 仓库或分离 git dir）时，返回 cwd 本身，保持现有降级行为。

这一步只读一个小文件、不起进程，扫描会话时开销可忽略，实现中未另加缓存。Windows 上 `gitdir` 用正斜杠，Node 端统一 `path.resolve` 后比较。

调用处：`main.swift:560 projectIndex(owning:)`、`main.swift:2951` 的会话分组、`runtime.cjs:126`。改完用 `grep -rn "WorktreeLayout.owner\|\\.worktrees" Sources Desktop` 再核一遍，确认没有遗漏的路径片段判断。

已被删除的统一目录工作树，其历史会话无法再读到 `.git` 文件，会退回为独立项目显示，与现状里删掉 `.worktrees` 子目录的表现一致。是否用 `ai-worktree` 登记表补救见 §8。

### 4.6 生命周期与删除

- 关闭会话只结束进程，不动工作树。
- `git.removeWorktree` 前增加检查：
  - 有运行中会话的 cwd 位于该工作树内时拒绝删除，提示先结束会话；
  - 有历史会话引用时，确认框列出数量，用户确认后继续；
  - 仍用非强制 `git worktree remove`，未提交修改由 Git 拒绝，界面展示原因。现有行为不变。
- 统一目录里的工作树被删除后，`ai-worktree` 的登记仍在，下次 `ensure` 同一任务会报「登记存在但 Git 已无对应工作树」。本次在删除确认框里提示这一点，并原样展示后续报错。根治依赖 §8 第 1 项。

### 4.7 错误展示

| 情形 | 展示 | 表单 |
|---|---|---|
| 未填任务标识或格式不合规 | 字段内提示 | 不提交 |
| 命令不存在或不可执行 | 「工作树命令不可用：<路径>，请在设置中检查」 | 保留 |
| 超时 | 「工作树命令超时（120s）」 | 保留，可重试 |
| 退出码非 0 | stderr 原文（去前缀） | 保留 |
| JSON 无效 | 「工作树命令返回格式无效」并附 stdout 前 200 字符 | 保留 |
| Git 复核不通过 | 具体哪一项不符，以及返回的路径 | 保留，不登记会话 |
| 代理启动失败 | 沿用现有提示 | 保留已建工作树，可重试启动 |

## 5. 实施步骤

| 步 | 内容 | 文件 |
|---|---|---|
| 1 | 设置项、保存校验、设置卡片和只读检测 | `Models.swift`、`main.swift`（`applySettings`）、`Desktop/runtime.cjs`、`SettingsModal.jsx` |
| 2 | 入参、返回模型、Bridge 透传 | `GitModels.swift`、`BridgeHandlers+Git.swift`、`BridgeHandlers+Session.swift` |
| 3 | macOS 统一模式执行与 Git 复核 | `GitService.swift` |
| 4 | Electron 统一模式，以及项目模式补齐范围与忽略校验 | `Desktop/git.cjs`、`Desktop/runtime.cjs` |
| 5 | 两个表单的界面、TAPD 完整 ID 预填 | `Modals.jsx`、`worktree-name.js` |
| 6 | 按 common dir 归属 | `Models.swift`、`main.swift`、`Desktop/runtime.cjs` |
| 7 | 删除前的会话引用检查 | `GitService.swift` 或 Bridge 层、`GitPages.jsx`、`Desktop/git.cjs` |
| 8 | 回归测试、桌面验收、文档同步 | `Tests/*`、`DEVELOPMENT.md`、`docs/cli-integration-prototype/DEVELOPMENT.md` §2 |

步 1 到 3 完成后 macOS 即可单独验收，步 4 和步 6 可以并行。

## 6. 测试

所有测试使用临时 Git 仓库（带一个本地 bare 仓库作 `origin`），并设置 `CLAUDE_PICKER_DATA_DIR` 和 `AI_WORKTREE_ROOT` 指向临时目录，不碰真实项目、真实 `tree.json` 和真实 `~/project/worktrees`。

- **GitServiceRegression**
  - 假命令脚本：成功创建、成功复用、退出码 1 带 stderr、JSON 无效、超时、返回路径不在 Git 列表、分支不符、common dir 不符，各一例。
  - 真实 `ai-worktree`（`AI_WORKTREE_ROOT` 指向临时目录）：首次 `created`，第二次 `reused` 且路径和 `base_commit` 相同；两路并发 ensure 只产生一条 `git worktree` 登记；分支已存在时原目录和分支保持完整；两个 `--subtask` 得到不同的路径和分支。
  - 项目模式现有用例全部保持通过。
- **归属解析**：`.worktrees` 子目录、统一目录工作树、主仓库、非仓库、已删除路径、bare 仓库，各一例。Swift 和 Node 共用一份用例表。
- **BridgeRegression**：`task`、`name`、`subtask` 透传；`session.create` 的 `mode: worktree` 在统一模式下缺少 `task` 时报参数错误。
- **DesktopRegression**：Electron 端与 macOS 同一组假命令用例。
- **Web**：`npm run build`；在 H5 预览中核对两种模式的表单、`created`/`reused` 提示和错误保留。

## 7. 验收

按 [DEVELOPMENT.md §2.7](../DEVELOPMENT.md#27-桌面调试与验收agent-desktop) 用 `agent-desktop` 在独立命名的开发包（`./scripts/build-app.sh --dev`）上执行。只操作临时演示仓库，启动时注入临时 `AI_WORKTREE_ROOT`。

1. macOS 与 Electron 用相同输入各发起一次创建，得到同一路径和基线，第二次提示「已复用」。
2. 在统一目录以外先用 `git worktree add` 建一个分支名含任务 ID 的历史工作树。CLI 与应用都复用原路径，历史会话在侧栏仍归到主仓库。
3. 快速连点两次创建同一任务，只出现一条 Git 工作树登记。制造分支冲突和目录占用，现有目录与分支保持完整，界面显示命令原因并保留表单。
4. 用两个子任务验证分支与路径隔离。主工作区和共享工作区都有未提交修改时，均能正常新建会话续做。
5. 清空设置后回到项目模式，`.worktrees/` 创建、`info/exclude` 校验和现有会话核对行为不变。
6. 删除工作树：有运行中会话时被拒绝；有脏文件时 Git 拒绝；删除统一目录工作树时确认框出现登记提示。

## 8. 待拍板与风险

1. **删除后的登记残留**：`ai-worktree` 没有释放登记的子命令，App 删除统一目录工作树后，同一任务无法再 ensure。建议给命令增加 `release --repo --task [--subtask]`，或让 ensure 在登记路径已不在 Git 列表时自动清理后重建。App 端在命令支持后再接入。
2. **已删除工作树的历史会话归属**：是否读取 `<根>/.registry/*.json` 补救归属。这样会依赖命令的内部文件格式，建议不做，等命令提供只读查询子命令后再接。
3. **Work 中心隔离**：是否迁到 `<统一根>/.managed/claude-picker`。本次不动。
4. **Windows**：当前脚本依赖 `fcntl`，Windows 只能保持项目模式，等有等效命令后再配置。
5. **GUI 环境变量**：从 Finder 启动的 App 不继承终端里的 `AI_WORKTREE_ROOT`，统一根总是默认值。若需要自定义根目录，后续在设置里加一项并作为环境变量传给命令。

## 9. 验收记录（2026-11-27）

开发包 `dist-dev/ClaudePickerDev.app`（`--dev`，来源分支 `codex/agent-workspace-development-spec`，未提交）。桌面验收用 `agent-desktop` 在独立实例上执行：临时数据目录、临时演示仓库 `wt-demo`（无远端、主工作区有未提交修改），统一命令为包装脚本，`AI_WORKTREE_ROOT` 指向临时目录。

| 场景 | 结果 |
|---|---|
| 设置填相对路径保存 | 通过：提示「工作树命令必须是绝对路径」，未写入 |
| 检测 / 保存有效路径 | 通过：显示主仓库路径；保存后写入 settings，按钮回到禁用 |
| 标题含 `TAPD 1131010001030864` | 通过：任务标识自动填完整 ID |
| 首次创建 / 再次创建同任务 | 通过：`shared/wt-demo/1131010001030864-…` 创建；第二次提示「已复用工作树」，未新增登记 |
| 分支已存在 | 通过：表单内显示命令原因、保留输入、焦点移到分支框，未新增工作树 |
| 新建会话·独立工作树（无远端仓库） | 通过：从当前分支创建 `T5-a`，CLI 在新目录启动，会话归到 wt-demo 的工作树节点 |
| 删除有运行中会话的工作树 | 通过：拒绝并提示「还有 1 个会话在运行」，确认框显示登记保留提示 |

验收中发现并已修复：保存命令后前端设置未同步（表单不切换统一模式）；新建会话未传基线导致无远端仓库报错（前后端均改为默认当前分支）；`--branch` 报错后焦点未落到分支框；`/private/tmp` 与 `/tmp` 写法不一致导致会话与工作树节点分组重复。

同期修复：接力启动 Claude / Codex 报 `zsh:1: unmatched '`。原因是 zsh 以 CLI 名作 argv[0]，`c` 开头触发 csh 仿真（`CSH_JUNKIE_QUOTES`），多行接力信封无法解析；改为 argv[0] 固定 `zsh`，并加入终端回归。
