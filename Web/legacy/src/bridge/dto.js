// 桥 → UI 的归一化层。
//
// Swift 的 Codable DTO 字段名与 `protocol.js` 的 `DTOS` 一致；这里只补 UI 需要、
// 但协议里没有的派生字段（文件名 / 目录、时间文本、diff 行），并把缺省值补齐
// （分支的 ahead/behind、remote 的 URL、worktree 的当前标记）。
// 纯数据函数，不碰 window、不发请求、不依赖 React，方便用 node 直接跑。
import { projectOptions } from '../mock/projects.js';
import { getSharedActiveProject } from './active-project.js';

/// 当前项目 id。App.jsx 没有把 repo 传给 WorkspacePage / HistoryPage / TagsPage，
/// 只能读侧栏那个受控 `<select>`（App.jsx:203-213）；其它页面优先用 props.repo。
export function currentProjectId() {
  const shared = getSharedActiveProject();
  if (shared) return shared;
  if (typeof document !== 'undefined') {
    const select = document.querySelector('select[aria-label="选择项目"]');
    if (select && select.value) return select.value;
  }
  return projectOptions[0]?.id ?? 'claude-picker';
}

/// 真实项目路径：App.jsx 的「选择项目」下拉框由 `app.projects` 渲染，
/// `option.value` 是本机真实绝对路径、选项文本是项目标题（第一栏同一个标题）。
/// 用它把标题解析回路径，避免回落到 mock 的 projectOptions（会指向另一个仓库）。
function liveProjectPath(id) {
  if (typeof document === 'undefined' || !id) return null;
  const select = document.querySelector('select[aria-label="选择项目"]');
  if (!select) return null;
  for (const option of select.options) {
    if (option.value === id || option.textContent?.trim() === id) return option.value || null;
  }
  return null;
}

/// 项目路径：真实绝对路径原样返回（`~` 简写交给 Swift 端 `expandingTildeInPath`），
/// 项目标题/旧 mock id 依次查真实下拉框与 mock 表，都没有才退回 `~/<id>`。
export function projectPathFor(id) {
  if (typeof id === 'string' && id) {
    if (id.startsWith('/') || id.startsWith('~')) return id;
    const live = liveProjectPath(id);
    if (live) return live;
  }
  const project = projectOptions.find((item) => item.id === id) ?? projectOptions[0];
  return project?.path ?? '~/' + id;
}

export function baseName(path = '') {
  const clean = String(path).replace(/\/+$/, '');
  const index = clean.lastIndexOf('/');
  return index === -1 ? clean : clean.slice(index + 1);
}

export function dirName(path = '') {
  const clean = String(path).replace(/\/+$/, '');
  const index = clean.lastIndexOf('/');
  return index === -1 ? '' : clean.slice(0, index);
}

/// `2026-11-13T14:10:40+08:00` → `2026-11-13 14:10`（本地时区，解析失败原样返回）。
export function formatTime(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return String(iso);
  const pad = (n) => String(n).padStart(2, '0');
  return (
    date.getFullYear() +
    '-' +
    pad(date.getMonth() + 1) +
    '-' +
    pad(date.getDate()) +
    ' ' +
    pad(date.getHours()) +
    ':' +
    pad(date.getMinutes())
  );
}

export function toStatusFile(file) {
  return {
    ...file,
    name: baseName(file.path),
    dir: dirName(file.path),
    type: file.label ?? '?',
    add: file.add ?? 0,
    del: file.del ?? 0,
  };
}

export function toStatus(snapshot) {
  return {
    ...snapshot,
    ahead: snapshot?.ahead ?? 0,
    behind: snapshot?.behind ?? 0,
    detachedHead: Boolean(snapshot?.detachedHead),
    files: (snapshot?.files ?? []).map(toStatusFile),
  };
}

export function toCommit(commit) {
  return {
    ...commit,
    shortHash: commit.shortHash || String(commit.hash ?? '').slice(0, 7),
    time: formatTime(commit.date),
    parents: commit.parents ?? [],
  };
}

export function toCommits(list) {
  return (list ?? []).map(toCommit);
}

export function toBranch(branch) {
  return {
    ...branch,
    ahead: branch.ahead ?? 0,
    behind: branch.behind ?? 0,
    upstream: branch.upstream ?? null,
    upstreamGone: Boolean(branch.upstreamGone),
    shortName: String(branch.name ?? '').replace(/^remotes\//, ''),
  };
}

export function toBranches(list) {
  return (list ?? []).map(toBranch);
}

export function toTag(tag) {
  return {
    ...tag,
    shortHash: String(tag.hash ?? '').slice(0, 7),
    time: formatTime(tag.date),
  };
}

export function toTags(list) {
  return (list ?? []).map(toTag);
}

export function toRemote(remote) {
  return {
    ...remote,
    fetchURL: remote.fetchURL ?? '',
    pushURL: remote.pushURL ?? remote.fetchURL ?? '',
    protocol: /^https?:/i.test(remote.fetchURL ?? '') ? 'HTTPS' : 'SSH',
  };
}

export function toRemotes(list) {
  return (list ?? []).map(toRemote);
}

export function toWorktree(worktree, currentPath) {
  return {
    ...worktree,
    name: baseName(worktree.path),
    shortHead: String(worktree.head ?? '').slice(0, 7),
    branch: worktree.branch ?? null,
    isCurrent: Boolean(currentPath) && worktree.path === currentPath,
  };
}

export function toWorktrees(list, currentPath) {
  return (list ?? []).map((item) => toWorktree(item, currentPath));
}

/// 把 `git diff` 的 patch 拆成可渲染的行。行号按 hunk 头里的起点递推，
/// 与 GitHub 的并排视图同一套语义；`meta` 行（diff --git / index / --- / +++）不渲染内容。
export function parsePatch(patch) {
  if (!patch) return [];
  const lines = String(patch).split('\n');
  if (lines[lines.length - 1] === '') lines.pop();

  const result = [];
  let oldLine = 0;
  let newLine = 0;
  lines.forEach((text) => {
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(text);
    if (hunk) {
      oldLine = Number(hunk[1]);
      newLine = Number(hunk[2]);
      result.push({ kind: 'hunk', text });
      return;
    }
    if (
      /^(diff --git |index |--- |\+\+\+ |new file mode|deleted file mode|old mode|new mode|similarity index|rename (from|to) |Binary files )/.test(
        text,
      )
    ) {
      result.push({ kind: 'meta', text });
      return;
    }
    if (text.startsWith('+')) {
      result.push({ kind: 'added', text: text.slice(1), mark: '+', newLine: newLine++ });
      return;
    }
    if (text.startsWith('-')) {
      result.push({ kind: 'removed', text: text.slice(1), mark: '−', oldLine: oldLine++ });
      return;
    }
    if (text.startsWith('\\')) {
      result.push({ kind: 'meta', text });
      return;
    }
    result.push({
      kind: 'context',
      text: text.startsWith(' ') ? text.slice(1) : text,
      mark: '',
      oldLine: oldLine++,
      newLine: newLine++,
    });
  });
  return result;
}

export function toDiff(diff) {
  return {
    ...diff,
    additions: diff?.additions ?? 0,
    deletions: diff?.deletions ?? 0,
    binary: Boolean(diff?.binary),
    lines: parsePatch(diff?.patch),
  };
}

const ERROR_TITLES = {
  NOT_A_REPOSITORY: '这个目录不是 Git 仓库',
  PERMISSION_DENIED: '没有权限读取这个仓库',
  DETACHED_HEAD: '当前处于分离 HEAD 状态',
  MERGE_CONFLICT: '存在未解决的合并冲突',
  DIRTY_WORKTREE: '工作区还有未提交的变更',
  COMMAND_FAILED: 'Git 命令执行失败',
  NOT_IMPLEMENTED: '这个操作还没有接入真桥',
  UNKNOWN_METHOD: '桥不认识这个方法',
  BRIDGE_UNAVAILABLE: '原生桥不可用',
  TIMEOUT: 'Git 命令超时',
  ABORTED: '请求已取消',
  INVALID_PARAMS: '桥参数不合法',
};

/// 结构化错误 → 给人看的中文。`detail` 是 git stderr，原样保留、必须展示（SPEC §15）。
export function describeError(error) {
  const code = error?.code ?? 'COMMAND_FAILED';
  return {
    code,
    title: ERROR_TITLES[code] ?? '读取 Git 数据失败',
    message: error?.message ?? '未知错误',
    detail: error?.detail ?? null,
    recoverable: error?.recoverable !== false,
  };
}

/// 六个页面共用的内联样式（仓库里没有通用 .error / .loading 类，避免为 T4 改 styles.css）。
export const uiStyles = {
  notice: { color: '#d78e8c', lineHeight: 1.6, whiteSpace: 'normal' },
  detail: {
    margin: '6px 0 0',
    padding: '6px 8px',
    maxHeight: 140,
    overflow: 'auto',
    background: '#1b1c20',
    border: '1px solid #34353a',
    borderRadius: 6,
    color: '#858890',
    fontSize: 11,
    whiteSpace: 'pre-wrap',
  },
  retry: {
    marginTop: 6,
    padding: '3px 10px',
    fontSize: 12,
    background: 'transparent',
    border: '1px solid #34353a',
    borderRadius: 6,
    color: '#dadbdd',
    cursor: 'pointer',
  },
  detailPanel: {
    margin: '0 0 10px 34px',
    padding: '10px 12px',
    background: '#1b1c20',
    border: '1px solid #34353a',
    borderRadius: 8,
    color: '#dadbdd',
    fontSize: 12,
  },
  patch: {
    margin: '8px 0 0',
    padding: '8px 10px',
    maxHeight: 260,
    overflow: 'auto',
    background: '#111214',
    border: '1px solid #34353a',
    borderRadius: 6,
    color: '#dadbdd',
    fontSize: 11,
    whiteSpace: 'pre',
  },
  muted: { color: '#858890' },
};

/// App.jsx 的项目切换只改 `<select>` 的 value，不会重新挂载第三栏；
/// 依赖「当前项目」的页面用它订阅切换事件，切换后重新取数。
/// 事件由 AppContext.jsx 的 setActiveProjectPath 广播（用户下拉、
/// 首次解析出当前项目、第三栏点项目都会走到那里）。
export function onProjectChange(listener) {
  if (typeof document === 'undefined') return () => {};
  const handler = () => listener();
  document.addEventListener('claude-picker:project-change', handler);
  return () => document.removeEventListener('claude-picker:project-change', handler);
}
