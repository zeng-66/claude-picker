/**
 * mock 传输层：浏览器里直接 `npm run dev` 时替代原生桥。
 *
 * 数据全部来自 `src/mock/data.js`，与 T0 原型一致；写操作只改本模块的内存副本，
 * 刷新页面即复原。真实数据接进来以后，这个文件整体退化成测试夹具。
 */
import { errorEnvelope, okEnvelope, BridgeError, ERROR_CODES, CLIENT_ERROR_CODES } from './protocol.js';
import {
  projectOptions,
  projectData,
  demoBranches,
  demoTags,
  demoStash,
  demoProjects,
  createTextDocuments,
} from '../mock/data.js';

const MODIFIED_AT = '2026-11-13T14:20:00+08:00';

const state = {
  documents: createTextDocuments(),
  /** `${projectId}\u0000${path}` → 是否已暂存 */
  staged: new Map(),
  /** projectId → 当前分支 */
  branch: new Map(),
  sessions: [],
  worktrees: [],
  commitSeq: 0,
};

// ---------- 工具 ----------

const CODE_EXT = new Set([
  'swift', 'm', 'mm', 'h', 'c', 'cc', 'cpp', 'hpp', 'js', 'jsx', 'ts', 'tsx', 'mjs', 'cjs',
  'py', 'rb', 'go', 'rs', 'java', 'kt', 'kts', 'scala', 'php', 'cs', 'fs', 'sh', 'bash', 'zsh',
  'json', 'jsonc', 'yaml', 'yml', 'toml', 'ini', 'conf', 'xml', 'plist', 'sql', 'css', 'scss',
  'less', 'vue', 'svelte', 'lua', 'pl', 'r', 'dart', 'ex', 'exs', 'erl', 'hs', 'clj', 'gradle',
]);

/** 与 GitModels.swift 的 `FileKind(extension:)` 同规则。 */
export function kindOf(path) {
  const ext = String(path).split('.').pop().toLowerCase();
  if (['md', 'markdown', 'mdx'].includes(ext)) return 'markdown';
  if (['mmd', 'mermaid', 'dot', 'puml', 'drawio'].includes(ext)) return 'diagram';
  if (['html', 'htm'].includes(ext)) return 'html';
  if (['csv', 'tsv'].includes(ext)) return 'csv';
  if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'ico', 'bmp', 'tiff', 'heic'].includes(ext)) {
    return 'image';
  }
  if (ext === 'pdf') return 'pdf';
  return CODE_EXT.has(ext) ? 'code' : 'other';
}

function projectById(projectId) {
  return projectOptions.find((p) => p.id === projectId || p.label === projectId) ?? null;
}

function projectByPath(projectPath) {
  if (!projectPath) return null;
  return (
    projectOptions.find((p) => p.path === projectPath) ??
    projectOptions.find((p) => projectPath.endsWith(`/${p.label}`) || projectPath.endsWith(p.label)) ??
    null
  );
}

function requireProject(projectId) {
  const project = projectById(projectId);
  if (!project) {
    throw new BridgeError(ERROR_CODES.NOT_A_REPOSITORY, `不是已知项目：${projectId}`, {
      recoverable: false,
    });
  }
  return project;
}

function requireProjectByPath(projectPath) {
  const project = projectByPath(projectPath);
  if (!project) {
    throw new BridgeError(ERROR_CODES.NOT_A_REPOSITORY, `不是 Git 仓库：${projectPath}`, {
      recoverable: false,
    });
  }
  return project;
}

function stageKey(projectId, path) {
  return `${projectId}\u0000${path}`;
}

function isStaged(projectId, path, fallback) {
  const key = stageKey(projectId, path);
  return state.staged.has(key) ? state.staged.get(key) : Boolean(fallback);
}

function currentBranch(projectId) {
  const project = requireProject(projectId);
  return state.branch.get(project.id) ?? project.branch;
}

function contentOf(path) {
  if (Object.prototype.hasOwnProperty.call(state.documents, path)) return state.documents[path];
  const data = projectData['claude-picker'];
  const entry = [...(data.files ?? [])].find((f) => f.path === path);
  return entry?.src ? '' : '';
}

function sizeOf(path) {
  const content = contentOf(path);
  return content ? new TextEncoder().encode(content).length : 0;
}

/** mock 的 diff：只裁掉公共首尾行，中间整段算增删，够 UI 演示用。 */
function buildPatch(path, before, after) {
  const a = before.split('\n');
  const b = after.split('\n');
  let head = 0;
  while (head < a.length && head < b.length && a[head] === b[head]) head += 1;
  let tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] === b[b.length - 1 - tail]) {
    tail += 1;
  }
  const removed = a.slice(head, a.length - tail);
  const added = b.slice(head, b.length - tail);
  const lines = [`--- a/${path}`, `+++ b/${path}`, `@@ -${head + 1},${removed.length} +${head + 1},${added.length} @@`];
  removed.forEach((line) => lines.push(`-${line}`));
  added.forEach((line) => lines.push(`+${line}`));
  return { patch: lines.join('\n'), additions: added.length, deletions: removed.length };
}

function statusFiles(projectId) {
  const project = requireProject(projectId);
  const changes = projectData[project.id]?.changes ?? {};
  return Object.entries(changes).map(([path, change]) => {
    const staged = isStaged(project.id, path, change.staged);
    const untracked = change.state === 'untracked';
    return {
      path,
      oldPath: null,
      kind: kindOf(path),
      state: change.state,
      label: change.label,
      staged: untracked ? false : staged,
      unstaged: untracked ? true : !staged,
      untracked,
      indexStatus: untracked ? '?' : staged ? change.label : ' ',
      workTreeStatus: untracked ? '?' : staged ? ' ' : change.label,
      binary: kindOf(path) === 'image' || kindOf(path) === 'pdf' ? true : null,
    };
  });
}

function listNodes(projectId, dir) {
  const project = requireProject(projectId);
  const files = projectData[project.id]?.files ?? [];
  const prefix = dir ? `${dir.replace(/\/$/, '')}/` : '';
  const seen = new Map();
  files.forEach((file) => {
    if (!file.path.startsWith(prefix)) return;
    const rest = file.path.slice(prefix.length);
    const slash = rest.indexOf('/');
    const name = slash === -1 ? rest : rest.slice(0, slash);
    const path = `${prefix}${name}`;
    if (seen.has(path)) return;
    seen.set(path, {
      name,
      path,
      isDirectory: slash !== -1,
      size: slash === -1 ? sizeOf(path) : null,
      modifiedAt: slash === -1 ? MODIFIED_AT : null,
      kind: slash === -1 ? kindOf(path) : 'other',
    });
  });
  return [...seen.values()].sort((lhs, rhs) => {
    if (lhs.isDirectory !== rhs.isDirectory) return lhs.isDirectory ? -1 : 1;
    return lhs.name.localeCompare(rhs.name);
  });
}

function allSessions() {
  const demo = demoProjects.flatMap((project) =>
    project.sessions.map((session, index) => ({
      id: `demo:${project.name}:${index}`,
      projectId: project.name,
      title: session.title,
      summary: session.meta === '当前会话' ? null : session.meta,
      cwd: projectOptions.find((p) => p.id === project.name)?.path ?? '',
      date: '2026-11-13T10:00:00+08:00',
      mode: 'current',
    })),
  );
  return [...state.sessions, ...demo];
}

function ok(id, result) {
  return okEnvelope(id, result);
}

// ---------- 方法实现 ----------

const handlers = {
  'app.projects': () =>
    projectOptions.map((p) => ({
      id: p.id,
      label: p.label,
      path: p.path,
      branch: currentBranch(p.id),
      ahead: p.ahead,
      changes: Object.keys(projectData[p.id]?.changes ?? {}).length,
    })),

  'app.sessions': () => allSessions(),
  'app.workbenchState': () => ({ projectPath: '', tool: 'git' }),
  'app.revealBranchSessions': () => ({ enabled: false, matched: 0 }),
  'app.reportWorkbench': () => null,

  'git.status': ({ projectPath, projectId }) => {
    const project = projectPath ? requireProjectByPath(projectPath) : requireProject(projectId);
    return {
      projectPath: project.path,
      branch: currentBranch(project.id),
      detachedHead: false,
      upstream: `origin/${currentBranch(project.id)}`,
      ahead: project.ahead,
      behind: 0,
      files: statusFiles(project.id),
    };
  },

  'git.diff': ({ projectPath, projectId, filePath, staged = false }) => {
    const project = projectPath ? requireProjectByPath(projectPath) : requireProject(projectId);
    const change = projectData[project.id]?.changes?.[filePath];
    if (!change) {
      throw new BridgeError(ERROR_CODES.COMMAND_FAILED, `文件没有变更：${filePath}`, {
        recoverable: true,
      });
    }
    const binary = kindOf(filePath) === 'image' || kindOf(filePath) === 'pdf';
    const built = binary
      ? { patch: '', additions: 0, deletions: 0 }
      : buildPatch(filePath, change.before ?? '', change.after ?? '');
    return { path: filePath, staged: Boolean(staged), binary, ...built };
  },

  'git.stage': ({ projectPath, projectId, paths }) => {
    const project = projectPath ? requireProjectByPath(projectPath) : requireProject(projectId);
    paths.forEach((path) => state.staged.set(stageKey(project.id, path), true));
    return null;
  },

  'git.unstage': ({ projectPath, projectId, paths }) => {
    const project = projectPath ? requireProjectByPath(projectPath) : requireProject(projectId);
    paths.forEach((path) => state.staged.set(stageKey(project.id, path), false));
    return null;
  },

  'git.commit': ({ projectPath, projectId, message, options = {} }) => {
    const project = projectPath ? requireProjectByPath(projectPath) : requireProject(projectId);
    state.commitSeq += 1;
    const hash = `${project.id}-${String(state.commitSeq).padStart(7, '0')}`;
    return {
      hash,
      shortHash: hash.slice(0, 7),
      message,
      amended: Boolean(options.amend),
    };
  },

  'git.branches': ({ projectPath, projectId }) => {
    const project = projectPath ? requireProjectByPath(projectPath) : requireProject(projectId);
    const current = currentBranch(project.id);
    return demoBranches.map((name) => ({
      name,
      isCurrent: name === current,
      isRemote: false,
      upstream: name === 'master' ? null : `origin/${name}`,
      ahead: name === current ? project.ahead : 0,
      behind: 0,
      upstreamGone: false,
      lastCommit: `demo ${name}`,
    }));
  },

  'git.switchBranch': ({ projectPath, projectId, branch }) => {
    const project = projectPath ? requireProjectByPath(projectPath) : requireProject(projectId);
    if (!demoBranches.includes(branch)) {
      throw new BridgeError(ERROR_CODES.COMMAND_FAILED, `分支不存在：${branch}`, {
        recoverable: true,
      });
    }
    state.branch.set(project.id, branch);
    return null;
  },

  'git.createWorktree': ({ input }) => {
    const project = requireProjectByPath(input.projectPath);
    const path = input.path ?? `${project.path}/.worktrees/${input.branch.replace(/\//g, '-')}`;
    if (state.worktrees.some((wt) => wt.path === path)) {
      throw new BridgeError(ERROR_CODES.WORKTREE_PATH_EXISTS, `Worktree 路径已存在：${path}`, {
        recoverable: false,
      });
    }
    state.worktrees.push({ path, branch: input.branch });
    return { path, branch: input.branch };
  },

  'git.removeWorktree': ({ input }) => {
    const index = state.worktrees.findIndex((wt) => wt.path === input.path);
    if (index === -1) {
      throw new BridgeError(ERROR_CODES.COMMAND_FAILED, `Worktree 不存在：${input.path}`, {
        recoverable: true,
      });
    }
    state.worktrees.splice(index, 1);
    return null;
  },

  'git.tags': ({ projectPath, projectId }) => {
    const project = projectPath ? requireProjectByPath(projectPath) : requireProject(projectId);
    return demoTags.map((name, index) => ({
      name,
      hash: `${project.id}-tag-${index}`,
      date: '2026-11-13T10:00:00+08:00',
      subject: demoStash[index] ?? '演示标签',
    }));
  },

  'git.remotes': () => [
    {
      name: 'origin',
      fetchURL: 'git@github.com:zcl/claude-picker.git',
      pushURL: 'git@github.com:zcl/claude-picker.git',
    },
  ],

  'file.list': ({ projectPath, projectId, path = '' }) =>
    listNodes((projectPath ? requireProjectByPath(projectPath) : requireProject(projectId)).id, path),

  'file.read': ({ projectPath, projectId, filePath, maxBytes = 262144 }) => {
    const project = projectPath ? requireProjectByPath(projectPath) : requireProject(projectId);
    const kind = kindOf(filePath);
    const binary = kind === 'image' || kind === 'pdf';
    const content = binary ? null : contentOf(filePath);
    return {
      path: filePath,
      size: sizeOf(filePath),
      modifiedAt: MODIFIED_AT,
      isBinary: binary,
      content: content && content.length > maxBytes ? content.slice(0, maxBytes) : content,
      truncated: binary || Boolean(content && content.length > maxBytes),
      kind,
      projectPath: project.path,
    };
  },

  'file.write': ({ filePath, content }) => {
    state.documents[filePath] = content;
    return null;
  },

  'file.stat': ({ projectPath, projectId, filePath }) => {
    projectPath ? requireProjectByPath(projectPath) : requireProject(projectId);
    const exists = Object.prototype.hasOwnProperty.call(state.documents, filePath);
    return {
      path: filePath,
      exists,
      isDirectory: false,
      size: exists ? sizeOf(filePath) : 0,
      modifiedAt: exists ? MODIFIED_AT : null,
      kind: kindOf(filePath),
    };
  },

  'session.create': ({ input }) => {
    const id = `mock-session-${state.sessions.length + 1}`;
    const session = {
      id,
      sessionId: id,
      projectId: input.projectId,
      title: input.title,
      mode: input.mode,
      workingDirectory: input.workingDirectory,
      branch: input.branch,
      summary: input.mode === 'worktree' ? 'Worktree · 刚刚' : '当前分支 · 刚刚',
      cwd: input.workingDirectory,
      date: '2026-11-13T15:00:00+08:00',
      createdAt: '2026-11-13T15:00:00+08:00',
      processId: 4242,
    };
    state.sessions.push(session);
    return session;
  },

  'session.resume': ({ sessionId }) => {
    if (!allSessions().some((s) => s.id === sessionId)) {
      throw new BridgeError(ERROR_CODES.COMMAND_FAILED, `会话不存在：${sessionId}`, {
        recoverable: true,
      });
    }
    return null;
  },

  'session.terminate': ({ sessionId }) => {
    if (!allSessions().some((s) => s.id === sessionId)) {
      throw new BridgeError(ERROR_CODES.COMMAND_FAILED, `会话不存在：${sessionId}`, {
        recoverable: true,
      });
    }
    return null;
  },

  'session.listForProject': ({ projectId }) =>
    allSessions().filter((session) => session.projectId === projectId),

  'file.watch': () => {
    throw new BridgeError(
      CLIENT_ERROR_CODES.NOT_IMPLEMENTED,
      'file.watch 尚未实现（T4 起用 1s 轮询 file.stat）',
      { source: 'client', recoverable: false },
    );
  },
};

/**
 * 执行一条请求并返回信封。永远 async，UI 不会拿到同步结果。
 * 抛出的 `BridgeError` 会被包成 `{id, ok:false, error}`，不会冒泡到调用方。
 */
export async function mockDispatch(message) {
  const { id, method, params = {} } = message ?? {};
  await Promise.resolve();
  const handler = handlers[method];
  if (!handler) {
    return errorEnvelope(
      id,
      new BridgeError(CLIENT_ERROR_CODES.UNKNOWN_METHOD, `mock 未实现方法：${method}`, {
        source: 'client',
      }),
    );
  }
  try {
    return ok(id, handler(params));
  } catch (error) {
    return errorEnvelope(id, error);
  }
}

/** client.js 用的传输对象，形状与原生传输一致。 */
export function createMockTransport() {
  return {
    kind: 'mock',
    send: (message) => mockDispatch(message),
  };
}
