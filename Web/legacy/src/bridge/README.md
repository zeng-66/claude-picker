# 桥接协议（T1 定稿，v1）

前端与 Swift 原生侧的唯一通道。UI 组件只 `import` 本目录的 `client.js`，**全仓库只有 `client.js` 出现 `window.webkit`**。

```
Web/src/bridge/
├── protocol.js   方法清单、信封、错误码、DTO 字段表、参数校验
├── client.js     request(method, params)、超时/取消、原生 ⇄ mock 选择
├── mock.js       浏览器直开时的假实现（数据来自 src/mock/data.js）
└── README.md     本文件：SPEC 逐条对照表 + 验收清单
```

## 1. 信封

```jsonc
// 请求（JS → 原生）
{ "id": 1, "method": "git.status", "params": { "projectPath": "~/project/claude-picker" } }

// 成功（原生 → JS）
{ "id": 1, "ok": true, "result": { /* DTO */ } }

// 失败（原生 → JS）
{ "id": 1, "ok": false, "error": { "code": "COMMAND_FAILED", "message": "…", "detail": "stderr 原文", "recoverable": true } }
```

- `id`：`client.js` 自增，一次请求一个；原生必须原样回传，**不回传或回错 id 会让 Promise 挂到超时**。
- `detail`：无子进程输出时省略或 `null`；`recoverable` 恒为布尔。
- 无事件推送。唯一的「推送类」需求 `file.watch` 本卡只留接口（见 §5）。

### 原生侧接入（T3）

1. `WKWebView` 注入 `window.webkit.messageHandlers.claudeBridge`，`postMessage` 收到上面的请求对象。
2. 处理完调 `evaluateJavaScript("window.__claudeBridge.receive(\(jsonString))")`；传 JSON 字符串或对象都可以。
3. `window.__claudeBridge` 由 `client.js` 在首次 `request()` 时挂到 `window`，原生不要自己覆盖。
4. 失败时把 `GitError` 直接 `JSONEncoder().encode` 进 `error` 字段——字段名与 `GitError.swift` 完全一致。

## 2. 方法对照表（22 个 = SPEC 20 + 补充 2）

`*` 表示必填参数。参数名与 SPEC 的 TypeScript 签名一一对应；Swift 侧方法名仅供对照，**下发的是 SPEC 的字符串**。

### GitAPI：SPEC §11

| SPEC 方法 | 桥方法名 | 参数 | 返回 | mock |
| --- | --- | --- | --- | --- |
| `status(projectPath)` | `git.status` | `projectPath*` | `GitStatusSnapshot` | ✓ |
| `diff(projectPath, filePath, staged)` | `git.diff` | `projectPath*`、`filePath*`、`staged` | `DiffResult` | ✓ |
| `stage(projectPath, paths)` | `git.stage` | `projectPath*`、`paths*: string[]` | `void` | ✓ |
| `unstage(projectPath, paths)` | `git.unstage` | `projectPath*`、`paths*: string[]` | `void` | ✓ |
| `commit(projectPath, message, options)` | `git.commit` | `projectPath*`、`message*`、`options: CommitOptions` | `CommitResult` | ✓ |
| `branches(projectPath)` | `git.branches` | `projectPath*` | `GitBranchInfo[]` | ✓ |
| `switchBranch(projectPath, branch)` | `git.switchBranch` | `projectPath*`、`branch*` | `void` | ✓ |
| `createWorktree(input)` | `git.createWorktree` | `input*: CreateWorktreeInput` | `WorktreeResult` | ✓ |
| `removeWorktree(input)` | `git.removeWorktree` | `input*: RemoveWorktreeInput` | `void` | ✓ |
| `tags(projectPath)` | `git.tags` | `projectPath*` | `GitTag[]` | ✓ |
| `remotes(projectPath)` | `git.remotes` | `projectPath*` | `GitRemote[]` | ✓ |

### FileAPI：SPEC §12

| SPEC 方法 | 桥方法名 | 参数 | 返回 | mock |
| --- | --- | --- | --- | --- |
| `list(projectPath)` | `file.list` | `projectPath*`、`path`（子目录，省略为根） | `FileNode[]` | ✓ |
| `read(projectPath, filePath)` | `file.read` | `projectPath*`、`filePath*`、`maxBytes` | `FileContent` | ✓ |
| `write(projectPath, filePath, content)` | `file.write` | `projectPath*`、`filePath*`、`content*`、`expectedModifiedAt` | `void` | ✓（只改内存） |
| `stat(projectPath, filePath)` | `file.stat` | `projectPath*`、`filePath*` | `FileStat` | ✓ |
| `watch(projectPath, callback)` | `file.watch` | `projectPath*` | `unsubscribe` | 未实现 |

### SessionAPI：SPEC §13

| SPEC 方法 | 桥方法名 | 参数 | 返回 | mock |
| --- | --- | --- | --- | --- |
| `create(input)` | `session.create` | `input*: CreateSessionRequest` | `CreatedSession` | ✓ |
| `resume(sessionId)` | `session.resume` | `sessionId*` | `void` | ✓ |
| `terminate(sessionId)` | `session.terminate` | `sessionId*` | `void` | ✓ |
| `listForProject(projectId)` | `session.listForProject` | `projectId*` | `SessionSummary[]` | ✓ |

### SPEC 未定义，本卡补充

| 用途 | 桥方法名 | 参数 | 返回 | mock |
| --- | --- | --- | --- | --- |
| 项目列表（对应 `Project`） | `app.projects` | 无 | `Project[]` | ✓ |
| 全部会话（对应 `SessionScanner.scan()`） | `app.sessions` | 无 | `SessionSummary[]` | ✓ |

**没有第 23 个方法。** 页面上还用到 `log` / `show` / `worktrees` / `stashes` / `fetch` / `pull` / `push` / `merge` / `createBranch` / `stashSave|Apply|Pop|Drop`，SPEC §11 未定义，本卡不实现，留给对应功能卡扩表（见 §7）。

## 3. 错误码

`error.code` 取 SPEC §11.1 的 8 个值，与 `GitErrorCode` 逐字相同：

`NOT_A_REPOSITORY` `DETACHED_HEAD` `BRANCH_EXISTS` `WORKTREE_PATH_EXISTS` `DIRTY_WORKTREE` `MERGE_CONFLICT` `PERMISSION_DENIED` `COMMAND_FAILED`

`client.js` 另外产生 5 个**本地**错误码（请求不出前端，`error.source === 'client'`）：

| 本地码 | 触发条件 |
| --- | --- |
| `INVALID_PARAMS` | 缺必填参数、类型不符、`params` 不是对象 |
| `UNKNOWN_METHOD` | 方法名不在 `METHODS` 里 |
| `TIMEOUT` | 超过 `timeoutMs`（默认 30s）未回包 |
| `ABORTED` | 调用方 `AbortSignal` 取消 |
| `NOT_IMPLEMENTED` | 方法标了 `implemented: false`（当前只有 `file.watch`） |

## 4. DTO 字段（与 Swift 逐字段对齐）

`protocol.js` 的 `DTOS` 与 `Sources/ClaudeDeck/Git/GitModels.swift` 的存储属性**同名同序**，`ENUMS` 与 `GitErrorCode` / `FileKind` / `GitFile.State` 同值；由 `check_dto` 脚本自动比对（19 个 DTO + 3 个枚举，见 §8）。
覆盖：`GitStatusSnapshot`、`GitFile`、`GitCommit`、`GitCommitFile`、`GitCommitDetail`、`DiffResult`、`GitBranchInfo`、`GitTag`、`GitRemote`、`GitWorktreeInfo`、`GitStash`、`CommitOptions`、`CommitResult`、`CreateWorktreeInput`、`RemoveWorktreeInput`、`WorktreeResult`、`FileNode`、`FileContent`、`FileStat`。

SPEC 有、Swift 侧尚未建模的三个 DTO 本卡按 SPEC 定义（字段以 SPEC 原文为准）：

| DTO | 来源 | 字段 |
| --- | --- | --- |
| `Project` | SPEC §4.1 | `id` `label` `path` `branch` `ahead` `changes` |
| `CreateSessionRequest` | SPEC §4.4 | `title` `prompt?` `mode` `projectId` `projectPath` `workingDirectory` `baseBranch` `branch` |
| `CreatedSession` | SPEC §7.5 | `sessionId` `projectId` `title` `mode` `workingDirectory` `branch` `processId?` `createdAt` |
| `SessionSummary` | SPEC §13 引用但未定义 | `id` `projectId` `title` `summary?` `cwd` `date` `mode` |

## 5. 未实现项

- `file.watch`：接口、参数校验、错误码都已就位，`client.watch()` 直接 reject `NOT_IMPLEMENTED`。T4 接真实监听时按 SPEC 用 1s 轮询 `file.stat`，返回 `unsubscribe`。
- 事件推送：不做。所有桥调用都是一问一答。

## 6. 回落与校验

- 有 `window.webkit.messageHandlers.claudeBridge` → 原生；否则 `mock.js`（`bridge.transportKind()` 可查当前来源）。
- 参数校验集中在 `client.js` → `protocol.validateParams()`，**不合格的请求不会发到桥上**，避免原生侧收到糊状 `COMMAND_FAILED`。
- 超时、取消、未知方法、未实现方法都在前端 reject `BridgeError`；`error.source` 区分 `'bridge'` / `'client'`。
- mock 的写操作（stage/commit/switchBranch/createWorktree/session.create/file.write）只改模块内存，刷新即复原；`git.status` 的变更集来自 `src/mock/data.js` 的 `projectData[*].changes`。

## 7. 方法表扩容记录

T3.5 已把 W1–W3 需要的方法一次性补进 `METHODS`（现有 38 条），后续卡片只填实现、不再改本文件：

| 功能卡需要 | 方法名 | 对应 Swift |
| --- | --- | --- |
| 提交历史 | `git.log`、`git.show` | `GitService.log` / `show` |
| 工作树页 | `git.worktrees` | `GitService.worktrees` |
| 分支页 | `git.createBranch` | `GitService.createBranch` |
| 合并与冲突 | `git.merge`、`git.mergeAbort`、`git.resolveConflict` | 同名方法 |
| Stash 页 | `git.stashes`、`git.stashSave` / `stashApply` / `stashPop` / `stashDrop` | 同名方法 |
| 远程页 / 工具栏 | `git.fetch`、`git.pull`、`git.push` | 同名方法 |
| 第一栏点会话 | `session.open` | `Store.openSession` |

命名沿用 SPEC 风格（`git.verb` / `file.verb` / `session.verb`），不要另发明别名。

## 8. 自测

```bash
# 协议自测：mock 回落、参数校验、超时、取消、原生 id 配对、信封形状
node /tmp/t1/test_bridge.mjs

# 跨语言 DTO 对齐：解析 GitModels.swift / GitError.swift 与 protocol.js 比对
node /tmp/t1/check_dto.mjs
```

脚本随卡交付、不进仓库（`src/bridge` 的写作用域只放运行时文件）。
