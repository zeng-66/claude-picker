/**
 * 桥协议 v1：信封、方法清单、错误码、超时。
 *
 * 三份权威来源，改动前先对齐：
 * - 方法名与参数：`docs/git-workbench-prototype/DEVELOPMENT.md` §11–§13（GitAPI / FileAPI / SessionAPI）
 * - 错误码：SPEC §11.1，字面量与 `Sources/ClaudeDeck/Git/GitError.swift` 的 `GitErrorCode` 一致
 * - DTO 字段名：`Sources/ClaudeDeck/Git/GitModels.swift`（Codable 属性名即 JSON 键名）
 *
 * 信封：
 *   请求 `{ id, method, params }`
 *   成功 `{ id, ok: true, result }`
 *   失败 `{ id, ok: false, error: { code, message, detail, recoverable } }`
 */

export const PROTOCOL_VERSION = 1;

/** 单次请求的默认超时。超时由 client.js 在本地 reject，桥上不感知。 */
export const DEFAULT_TIMEOUT_MS = 30_000;

/** SPEC §11.1 的 8 个错误码。不要改名——Swift 侧 `GitErrorCode` 逐字相同。 */
export const ERROR_CODES = Object.freeze({
  NOT_A_REPOSITORY: 'NOT_A_REPOSITORY',
  DETACHED_HEAD: 'DETACHED_HEAD',
  BRANCH_EXISTS: 'BRANCH_EXISTS',
  WORKTREE_PATH_EXISTS: 'WORKTREE_PATH_EXISTS',
  DIRTY_WORKTREE: 'DIRTY_WORKTREE',
  MERGE_CONFLICT: 'MERGE_CONFLICT',
  PERMISSION_DENIED: 'PERMISSION_DENIED',
  COMMAND_FAILED: 'COMMAND_FAILED',
});

/**
 * 前端本地错误码。只在 client.js 里产生，请求不会发到桥上，
 * 因此不会污染 SPEC 的 8 个码；UI 用 `code` 分支即可，无需区分来源。
 */
export const CLIENT_ERROR_CODES = Object.freeze({
  INVALID_PARAMS: 'INVALID_PARAMS',
  UNKNOWN_METHOD: 'UNKNOWN_METHOD',
  TIMEOUT: 'TIMEOUT',
  ABORTED: 'ABORTED',
  BRIDGE_UNAVAILABLE: 'BRIDGE_UNAVAILABLE',
  NOT_IMPLEMENTED: 'NOT_IMPLEMENTED',
});

/** 桥错误。字段与 SPEC §11.1 的 GitError 一一对应，`toJSON()` 直接塞进信封。 */
export class BridgeError extends Error {
  constructor(code, message, { detail = null, recoverable = false, source = 'bridge' } = {}) {
    super(message);
    this.name = 'BridgeError';
    this.code = code;
    this.detail = detail;
    this.recoverable = recoverable;
    /** 'bridge' = 来自原生侧；'client' = 本地校验/超时等，未过桥。 */
    this.source = source;
  }

  toJSON() {
    return {
      code: this.code,
      message: this.message,
      detail: this.detail,
      recoverable: this.recoverable,
    };
  }
}

const S = (extra = {}) => ({ type: 'string', required: true, ...extra });
const OPT_S = { type: 'string', required: false };
const A = (extra = {}) => ({ type: 'string[]', required: true, ...extra });

/** CreateWorktreeInput（GitModels.swift） */
const CREATE_WORKTREE_FIELDS = {
  projectPath: S(),
  branch: S(),
  path: OPT_S,
  baseBranch: OPT_S,
};

/** RemoveWorktreeInput（GitModels.swift） */
const REMOVE_WORKTREE_FIELDS = {
  projectPath: S(),
  path: S(),
  force: { type: 'boolean', required: false },
};

/** CommitOptions（GitModels.swift），四个开关都可省略，默认 false。 */
const COMMIT_OPTION_FIELDS = {
  amend: { type: 'boolean', required: false },
  signOff: { type: 'boolean', required: false },
  noVerify: { type: 'boolean', required: false },
  allowEmpty: { type: 'boolean', required: false },
};

/** CreateSessionRequest（SPEC §4.4） */
const SESSION_CREATE_FIELDS = {
  title: S(),
  prompt: OPT_S,
  mode: S({ enum: ['current', 'worktree'] }),
  projectId: S(),
  projectPath: S(),
  workingDirectory: S(),
  baseBranch: S(),
  branch: S(),
};

/**
 * 方法清单。`spec` 是 SPEC 章节，`impl` 是 Swift 侧实现入口（仅供对照，不下发）。
 * `implemented: false` 表示接口先留、本卡不实现，client 会本地抛 NOT_IMPLEMENTED。
 */
export const METHODS = Object.freeze({
  // ---------- GitAPI：SPEC §11 ----------
  'git.status': {
    spec: '§11',
    impl: 'GitService.status(projectPath:)',
    params: { projectPath: S() },
    result: 'GitStatusSnapshot',
  },
  'git.diff': {
    spec: '§11',
    impl: 'GitService.diff(projectPath:path:staged:)',
    params: { projectPath: S(), filePath: S(), staged: { type: 'boolean', required: false } },
    result: 'DiffResult',
  },
  'git.stage': {
    spec: '§11',
    impl: 'GitService.stage(projectPath:paths:)',
    params: { projectPath: S(), paths: A() },
    result: 'void',
  },
  'git.unstage': {
    spec: '§11',
    impl: 'GitService.unstage(projectPath:paths:)',
    params: { projectPath: S(), paths: A() },
    result: 'void',
  },
  'git.commit': {
    spec: '§11',
    impl: 'GitService.commit(projectPath:message:options:)',
    params: {
      projectPath: S(),
      message: S(),
      options: { type: 'object', required: false, fields: COMMIT_OPTION_FIELDS },
    },
    result: 'CommitResult',
  },
  'git.branches': {
    spec: '§11',
    impl: 'GitService.branches(projectPath:)',
    params: { projectPath: S() },
    result: 'GitBranchInfo[]',
  },
  'git.switchBranch': {
    spec: '§11',
    impl: 'GitService.switchBranch(projectPath:branch:)',
    params: { projectPath: S(), branch: S() },
    result: 'void',
  },
  'git.createWorktree': {
    spec: '§11',
    impl: 'GitService.createWorktree(_:)',
    params: { input: { type: 'object', required: true, fields: CREATE_WORKTREE_FIELDS } },
    result: 'WorktreeResult',
  },
  'git.removeWorktree': {
    spec: '§11',
    impl: 'GitService.removeWorktree(_:)',
    params: { input: { type: 'object', required: true, fields: REMOVE_WORKTREE_FIELDS } },
    result: 'void',
  },
  'git.tags': {
    spec: '§11',
    impl: 'GitService.tags(projectPath:)',
    params: { projectPath: S() },
    result: 'GitTag[]',
  },
  'git.remotes': {
    spec: '§11',
    impl: 'GitService.remotes(projectPath:)',
    params: { projectPath: S() },
    result: 'GitRemote[]',
  },

  // ---------- GitAPI 扩展：T4 起接线（SPEC §11 未逐条列出，命名沿用 SPEC 风格）----------
  'git.log': {
    spec: '§11',
    impl: 'GitService.log(projectPath:limit:skip:branch:)',
    params: {
      projectPath: S(),
      limit: { type: 'number', required: false },
      skip: { type: 'number', required: false },
      branch: OPT_S,
    },
    result: 'GitCommit[]',
  },
  'git.show': {
    spec: '§11',
    impl: 'GitService.show(projectPath:hash:)',
    params: { projectPath: S(), hash: S() },
    result: 'GitCommitDetail',
  },
  'git.worktrees': {
    spec: '§11',
    impl: 'GitService.worktrees(projectPath:)',
    params: { projectPath: S() },
    result: 'GitWorktreeInfo[]',
  },
  'git.createBranch': {
    spec: '§11',
    impl: 'GitService.createBranch(projectPath:name:from:)',
    params: { projectPath: S(), name: S(), from: OPT_S },
    result: 'void',
  },
  'git.deleteBranch': {
    spec: '扩展',
    impl: 'GitService.deleteBranch(projectPath:branch:)',
    params: { projectPath: S(), branch: S() },
    result: 'void',
  },
  'git.merge': {
    spec: '§11',
    impl: 'GitService.merge(projectPath:branch:)',
    params: { projectPath: S(), branch: S() },
    result: 'void',
  },
  'git.mergeAbort': {
    spec: '§11',
    impl: 'GitService.mergeAbort(projectPath:)',
    params: { projectPath: S() },
    result: 'void',
  },
  'git.resolveConflict': {
    spec: '§11',
    impl: 'GitService.resolveConflict(projectPath:path:strategy:)',
    params: { projectPath: S(), filePath: S(), strategy: S({ enum: ['ours', 'theirs', 'both'] }) },
    result: 'void',
  },
  'git.stashes': {
    spec: '§11',
    impl: 'GitService.stashes(projectPath:)',
    params: { projectPath: S() },
    result: 'GitStash[]',
  },
  'git.stashSave': {
    spec: '§11',
    impl: 'GitService.stashSave(projectPath:message:includeUntracked:)',
    params: { projectPath: S(), message: OPT_S, includeUntracked: { type: 'boolean', required: false } },
    result: 'GitStash',
  },
  'git.stashApply': {
    spec: '§11',
    impl: 'GitService.stashApply(projectPath:index:)',
    params: { projectPath: S(), index: { type: 'number', required: true } },
    result: 'void',
  },
  'git.stashPop': {
    spec: '§11',
    impl: 'GitService.stashPop(projectPath:index:)',
    params: { projectPath: S(), index: { type: 'number', required: true } },
    result: 'void',
  },
  'git.stashDrop': {
    spec: '§11',
    impl: 'GitService.stashDrop(projectPath:index:)',
    params: { projectPath: S(), index: { type: 'number', required: true } },
    result: 'void',
  },
  'git.fetch': {
    spec: '§11',
    impl: 'GitService.fetch(projectPath:remote:)',
    params: { projectPath: S(), remote: OPT_S },
    result: 'void',
  },
  'git.pull': {
    spec: '§11',
    impl: 'GitService.pull(projectPath:remote:branch:)',
    params: { projectPath: S(), remote: OPT_S, branch: OPT_S },
    result: 'void',
  },
  'git.push': {
    spec: '§11',
    impl: 'GitService.push(projectPath:remote:branch:setUpstream:)',
    params: {
      projectPath: S(),
      remote: OPT_S,
      branch: OPT_S,
      setUpstream: { type: 'boolean', required: false },
    },
    result: 'void',
  },

  // ---------- FileAPI：SPEC §12 ----------
  'file.list': {
    spec: '§12',
    impl: 'FileService.list(projectPath:path:)',
    params: { projectPath: S(), path: OPT_S },
    result: 'FileNode[]',
  },
  'file.read': {
    spec: '§12',
    impl: 'FileService.read(projectPath:path:maxBytes:)',
    params: { projectPath: S(), filePath: S(), maxBytes: { type: 'number', required: false } },
    result: 'FileContent',
  },
  'file.write': {
    spec: '§12',
    impl: 'FileService.write(projectPath:path:content:expectedModifiedAt:)',
    params: {
      projectPath: S(),
      filePath: S(),
      content: S({ required: true, allowEmpty: true }),
      expectedModifiedAt: OPT_S,
    },
    result: 'void',
  },
  'file.stat': {
    spec: '§12',
    impl: 'FileService.stat(projectPath:path:)',
    params: { projectPath: S(), filePath: S() },
    result: 'FileStat',
  },
  'file.watch': {
    spec: '§12',
    impl: '（无；T4 起用 1s 轮询 file.stat 实现）',
    params: { projectPath: S() },
    result: 'unsubscribe',
    implemented: false,
  },

  // ---------- SessionAPI：SPEC §13 ----------
  'session.create': {
    spec: '§13',
    impl: '（T5 会话启动）',
    params: { input: { type: 'object', required: true, fields: SESSION_CREATE_FIELDS } },
    result: 'CreatedSession',
  },
  'session.resume': {
    spec: '§13',
    impl: '（T5 会话启动）',
    params: { sessionId: S() },
    result: 'void',
  },
  'session.terminate': {
    spec: '§13',
    impl: '（T5 会话启动）',
    params: { sessionId: S() },
    result: 'void',
  },
  'session.listForProject': {
    spec: '§13',
    impl: 'SessionScanner.scan() 过滤 cwd',
    params: { projectId: S() },
    result: 'SessionSummary[]',
  },
  /** 在第一栏点一条会话时，把终端切到该会话（复用既有 openSession 路径）。 */
  'session.open': {
    spec: '§13',
    impl: 'Store.openSession',
    params: { projectPath: S(), sessionId: OPT_S, cwd: S() },
    result: 'void',
  },

  // ---------- SPEC 未定义，本卡补充 ----------
  'app.projects': {
    spec: '未定义',
    impl: 'Project（Models.swift）',
    params: {},
    result: 'Project[]',
  },
  'app.sessions': {
    spec: '未定义',
    impl: 'SessionScanner.scan()',
    params: {},
    result: 'SessionSummary[]',
  },
  // 第三栏的项目 / 工具 / 分支控件放在原生标题栏：网页启动时取一次状态，之后把变化回报给原生。
  'app.revealBranchSessions': {
    spec: '扩展',
    impl: 'Store.revealBranchSessions(projectPath:branch:)',
    params: { projectPath: S(), branch: S() },
    result: '{ enabled: boolean, matched: number }',
  },
  'app.workbenchState': {
    spec: '扩展',
    impl: 'Store.workbenchProject / workbenchTool',
    params: {},
    result: '{ projectPath: string, tool: "git" | "files" }',
  },
  'app.reportWorkbench': {
    spec: '扩展',
    impl: 'Store.workbench*',
    params: {
      projectPath: OPT_S,
      tool: OPT_S,
      branch: OPT_S,
      ahead: { type: 'number', required: false },
      behind: { type: 'number', required: false },
    },
    result: 'void',
  },
});

/** 供 README 表格与测试遍历：`[{ name, ...def }]`。 */
export function listMethods() {
  return Object.entries(METHODS).map(([name, def]) => ({ name, ...def }));
}

export function methodNames() {
  return Object.keys(METHODS);
}

// ---------- DTO 字段（与 Swift 侧逐字对齐）----------
// 键名 = Swift `Codable` 属性名 = JSON 键名。顺序仅作文档用途，传输时是对象。
// 计算属性（`var id`、`var clean` 等）不参与编码，这里也不列。

export const DTOS = Object.freeze({
  // GitModels.swift
  GitStatusSnapshot: ['projectPath', 'branch', 'detachedHead', 'upstream', 'ahead', 'behind', 'files'],
  GitFile: [
    'path',
    'oldPath',
    'kind',
    'state',
    'label',
    'staged',
    'unstaged',
    'untracked',
    'indexStatus',
    'workTreeStatus',
    'binary',
  ],
  GitCommit: ['hash', 'shortHash', 'message', 'author', 'authorEmail', 'date', 'parents'],
  GitCommitFile: ['path', 'additions', 'deletions', 'binary'],
  GitCommitDetail: ['commit', 'files', 'additions', 'deletions', 'patch'],
  DiffResult: ['path', 'staged', 'binary', 'additions', 'deletions', 'patch'],
  GitBranchInfo: [
    'name',
    'isCurrent',
    'isRemote',
    'upstream',
    'ahead',
    'behind',
    'upstreamGone',
    'lastCommit',
  ],
  GitTag: ['name', 'hash', 'date', 'subject'],
  GitRemote: ['name', 'fetchURL', 'pushURL'],
  GitWorktreeInfo: ['path', 'head', 'branch', 'isBare', 'isLocked', 'isPrunable'],
  GitStash: ['index', 'ref', 'hash', 'message', 'date'],
  CommitOptions: ['amend', 'signOff', 'noVerify', 'allowEmpty'],
  CommitResult: ['hash', 'shortHash', 'message', 'amended'],
  CreateWorktreeInput: ['projectPath', 'branch', 'path', 'baseBranch'],
  RemoveWorktreeInput: ['projectPath', 'path', 'force'],
  WorktreeResult: ['path', 'branch'],
  FileNode: ['name', 'path', 'isDirectory', 'size', 'modifiedAt', 'kind'],
  FileContent: ['path', 'size', 'modifiedAt', 'isBinary', 'content', 'truncated', 'kind'],
  FileStat: ['path', 'exists', 'isDirectory', 'size', 'modifiedAt', 'kind'],
});

/** 枚举取值：GitErrorCode 与 GitError.swift 一致，FileKind / state 与 GitModels.swift 一致。 */
export const ENUMS = Object.freeze({
  GitErrorCode: Object.values(ERROR_CODES),
  FileKind: ['markdown', 'diagram', 'html', 'code', 'csv', 'image', 'pdf', 'other'],
  GitFileState: ['modified', 'added', 'deleted', 'untracked'],
});

// ---------- 信封 ----------

export function okEnvelope(id, result) {
  return { id, ok: true, result: result === undefined ? null : result };
}

export function errorEnvelope(id, error) {
  const body =
    error instanceof BridgeError
      ? error.toJSON()
      : {
          code: error?.code ?? ERROR_CODES.COMMAND_FAILED,
          message: error?.message ?? '未知错误',
          detail: error?.detail ?? null,
          recoverable: Boolean(error?.recoverable),
        };
  return { id, ok: false, error: body };
}

/** 原生侧回包的结构校验（T3 实现时两边共用）。 */
export function isEnvelope(value) {
  return (
    value !== null &&
    typeof value === 'object' &&
    !Number.isNaN(Number(value.id)) &&
    typeof value.ok === 'boolean'
  );
}

// ---------- 参数校验 ----------

function typeName(value) {
  if (Array.isArray(value)) return 'array';
  if (value === null) return 'null';
  return typeof value;
}

function matchesType(value, type) {
  if (type === 'string[]') return Array.isArray(value) && value.every((v) => typeof v === 'string');
  return typeName(value) === type;
}

function checkField(method, key, rule, value) {
  if (value === undefined || value === null) {
    if (rule.required) {
      throw new BridgeError(
        CLIENT_ERROR_CODES.INVALID_PARAMS,
        `${method} 缺少必填参数 ${key}`,
        { source: 'client', recoverable: false },
      );
    }
    return;
  }
  if (!matchesType(value, rule.type)) {
    throw new BridgeError(
      CLIENT_ERROR_CODES.INVALID_PARAMS,
      `${method} 参数 ${key} 应为 ${rule.type}，实际 ${typeName(value)}`,
      { source: 'client', recoverable: false },
    );
  }
  if (rule.enum && !rule.enum.includes(value)) {
    throw new BridgeError(
      CLIENT_ERROR_CODES.INVALID_PARAMS,
      `${method} 参数 ${key} 只能是 ${rule.enum.join(' / ')}，实际 ${value}`,
      { source: 'client', recoverable: false },
    );
  }
  if (rule.type === 'object' && rule.fields) {
    checkFields(method, rule.fields, value, key);
  }
}

function checkFields(method, fields, params, prefix = '') {
  for (const [key, rule] of Object.entries(fields)) {
    const path = prefix ? `${prefix}.${key}` : key;
    checkField(method, path, rule, params[key]);
  }
}

/**
 * 就地校验参数：未知方法、未实现方法、缺参、类型不符都在这里抛 `BridgeError`。
 * 校验通过返回规范化后的 params（对象参数原样透传，不补默认值）。
 */
export function validateParams(method, params) {
  const def = METHODS[method];
  if (!def) {
    throw new BridgeError(CLIENT_ERROR_CODES.UNKNOWN_METHOD, `未定义的桥方法：${method}`, {
      source: 'client',
      recoverable: false,
    });
  }
  if (def.implemented === false) {
    throw new BridgeError(
      CLIENT_ERROR_CODES.NOT_IMPLEMENTED,
      `${method} 尚未实现（接口已预留；file.watch 按 SPEC 用 1s 轮询 file.stat 起步）`,
      { source: 'client', recoverable: false },
    );
  }
  if (params === undefined || params === null) return {};
  if (typeof params !== 'object' || Array.isArray(params)) {
    throw new BridgeError(CLIENT_ERROR_CODES.INVALID_PARAMS, `${method} 的 params 必须是对象`, {
      source: 'client',
      recoverable: false,
    });
  }
  checkFields(method, def.params, params);
  return params;
}
