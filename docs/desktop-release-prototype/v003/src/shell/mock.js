// 浏览器直开（npm run dev / 静态预览）时替代原生桥的内存后端。
// 数据沿用 docs/app-layout-prototype 的演示内容；所有写操作只改内存，刷新即复原。
// 方法名与返回结构和 Swift 侧一一对应，原生桥在线时本文件完全不参与。

const HOME = '/Users/demo';
const P = (name) => `${HOME}/project/${name}`;

const projectSeed = [
  [
    'claude-picker',
    'codex/git-features',
    ['Git 工作台界面整理', '终端交互与会话状态', '项目侧栏优化'],
  ],
  [
    'lm-global-java',
    'feature/order-decode',
    [
      '订单解码流程梳理',
      '物流 webhook 对接',
      '运营端订单导出',
      '设计记录字段调整',
      '商品列表筛选',
      '接口响应检查',
    ],
  ],
  ['lanma-bankend', 'beta', ['商品标题响应优化', '生产日志排查']],
  ['fangguo-erp-java', 'feature/webhook', ['Webhook 事件处理']],
];

const baseFiles = [
  ['Sources/ClaudeDeck/main.swift', 'M', false],
  ['Sources/ClaudeDeck/Models.swift', 'M', false],
  ['Web/src/App.jsx', 'M', false],
  ['Web/src/styles.css', 'M', true],
  ['docs/interface-notes.md', '?', false],
];

const mainSwiftPatch = `@@ -38,15 +38,18 @@
 struct PickerView: View {
     @ObservedObject var store: Store

     var body: some View {
-        HStack(spacing: 12) {
+        HStack(spacing: 0) {
             ProjectSidebar(store: store)

-            TerminalPane(store: store)
+            if !store.settings.terminalCollapsed {
+                TerminalPane(store: store)
+                    .frame(minWidth: 320)
+            }

             if store.thirdVisible {
                 WebPane(store: store)
             }
         }
     }
 }`;

function originalContent(path) {
  if (path.endsWith('.md'))
    return '# 界面交互说明\n\n项目、会话与工作台共用当前项目上下文。\n\n## 文件操作\n\n- 点击变更文件查看差异。\n- 在同一面板切换预览与编辑。\n- 保存后继续查看其他文件。';
  if (path.endsWith('.css'))
    return '.workspace {\n  display: flex;\n  min-height: 0;\n  background: #18191c;\n}\n\n.file-row {\n  display: flex;\n  align-items: center;\n  gap: 8px;\n}';
  if (path.endsWith('.jsx'))
    return 'export default function Workspace() {\n  return (\n    <main className="workspace">\n      <ChangedFiles />\n      <FilePreview />\n    </main>\n  );\n}';
  if (path.endsWith('Models.swift'))
    return 'struct AppSettings: Codable {\n    var sidebarWidth: Double = 248\n    var terminalCollapsed = false\n    var thirdPaneVisible = true\n}\n\nstruct Project {\n    var title: String\n    var path: String\n}';
  return mainSwiftPatch
    .split('\n')
    .slice(1)
    .filter((line) => !line.startsWith('-'))
    .map((line) => line.slice(1))
    .join('\n');
}

let seq = 0;
const db = {
  projects: [
    { path: HOME, title: '~', isHome: true, expanded: false, showAll: false, sessions: [] },
    ...projectSeed.map(([name, , sessions], index) => ({
      path: P(name),
      title: name,
      isHome: false,
      expanded: index === 0,
      showAll: false,
      sessions: sessions.map((title, i) => ({
        id: `demo-${name}-${i}`,
        title,
        cwd: P(name),
        time: i === 0 ? '刚刚' : `${i + 1} 小时前`,
        running: false,
        unread: false,
      })),
    })),
  ],
  active: null,
  runtime: { mode: 'auto', model: 'opus', effort: 'medium', fast: false },
  settings: {
    appFontSize: 12,
    termFontSize: 12.5,
    followSessionBranch: false,
    density: 'comfortable',
    sidebar: true,
    terminal: true,
    workbench: false,
    terminalWidth: 30,
  },
  repos: {},
  mcp: [
    [
      'Filesystem',
      'stdio',
      'npx -y @modelcontextprotocol/server-filesystem ~/project',
      ['read_file', 'write_file', 'list_directory', 'search_files'],
      true,
    ],
    ['Git', 'stdio', 'uvx mcp-server-git', ['git_status', 'git_diff', 'git_log', 'git_show'], true],
    ['Docs', 'http', 'https://docs.example.com/mcp', ['search_documents', 'read_document'], false],
  ].map(([name, transport, endpoint, tools, connected]) => ({
    id: 'user:' + name,
    name,
    scope: 'user',
    transport,
    endpoint,
    description: transport === 'http' ? '远程 HTTP 服务' : '本地 stdio 服务',
    enabled: true,
    removable: true,
    tools,
    connected,
  })),
};
db.active = {
  sessionId: db.projects[1].sessions[0].id,
  cwd: db.projects[1].path,
  projectPath: db.projects[1].path,
  label: db.projects[1].sessions[0].title,
  busy: false,
};

function repo(projectPath) {
  if (!db.repos[projectPath]) {
    const seed = projectSeed.find(([name]) => P(name) === projectPath);
    if (!seed) return null;
    db.repos[projectPath] = {
      branch: seed[1],
      branches: [...new Set([seed[1], 'main', 'feature/session-layout'])],
      remotes: ['origin/main'],
      files: baseFiles.map(([path, label, staged]) => ({ path, label, staged })),
      contents: {},
      history: [
        ['整理 Git 工作台布局与分支入口', 'a84c2e1', -12],
        ['补充终端会话状态与恢复逻辑', '73f4b96', -60],
        ['统一项目上下文与文件预览', '618de32', -180],
        ['调整侧栏展开与收起交互', '49d13a0', -1440],
      ].map(([message, shortHash, minutes]) => ({
        hash: shortHash.padEnd(40, '0'),
        shortHash,
        message,
        author: '曾长亮',
        authorEmail: 'demo@example.com',
        date: new Date(Date.now() + minutes * 60000).toISOString(),
        parents: [],
      })),
      stashes: [],
      worktrees: [{ path: projectPath, head: 'a84c2e1', branch: seed[1] }],
    };
  }
  return db.repos[projectPath];
}

function fail(code, message, detail = null) {
  const error = new Error(message);
  error.code = code;
  error.detail = detail;
  return error;
}

function requireRepo(projectPath) {
  const found = repo(projectPath);
  if (!found) throw fail('NOT_A_REPOSITORY', '这个目录不是 Git 仓库', projectPath);
  return found;
}

function snapshot() {
  const modes = [
    ['auto', '自动'],
    ['manual', '手动'],
    ['acceptEdits', '接受编辑'],
    ['plan', '规划'],
  ];
  const models = [
    ['opus', 'Opus 5.5'],
    ['sonnet', 'Sonnet 5.5'],
    ['haiku', 'Haiku 5.5'],
    ['fable', 'Fable 5.5'],
  ];
  const efforts = [
    ['medium', '默认'],
    ['low', '低'],
    ['high', '高'],
    ['xhigh', '极高'],
    ['max', '最高'],
  ];
  const pair = ([id, label]) => ({ id, label });
  return JSON.parse(
    JSON.stringify({
      home: HOME,
      projects: db.projects,
      active: db.active,
      runtime: {
        ...db.runtime,
        modes: modes.map(pair),
        models: models.map(pair),
        efforts: efforts.map(pair),
      },
      settings: db.settings,
      usage: {
        session: { percent: 40, reset: '23:50' },
        weekly: { percent: 26, reset: '11-18' },
        note: null,
      },
    }),
  );
}

function push() {
  window.dispatchEvent(new CustomEvent('claude-picker:state', { detail: snapshot() }));
}

function project(path) {
  const found = db.projects.find((item) => item.path === path);
  if (!found) throw fail('COMMAND_FAILED', '找不到项目', path);
  return found;
}

function statusOf(projectPath) {
  const r = requireRepo(projectPath);
  return {
    projectPath,
    branch: r.branch,
    detachedHead: false,
    upstream: 'origin/' + r.branch,
    ahead: 0,
    behind: 0,
    files: r.files.map((file) => ({
      path: file.path,
      label: file.label,
      staged: file.staged,
      unstaged: !file.staged && file.label !== '?',
      untracked: !file.staged && file.label === '?',
      indexStatus: file.staged ? (file.label === '?' ? 'A' : file.label) : ' ',
      workTreeStatus: file.staged ? ' ' : file.label,
      conflicted: false,
    })),
  };
}

function patchFor(r, path) {
  if (r.contents[path] !== undefined) {
    const before = originalContent(path).split('\n');
    const after = r.contents[path].split('\n');
    return [
      `@@ -1,${before.length} +1,${after.length} @@`,
      ...before.map((line) => '-' + line),
      ...after.map((line) => '+' + line),
    ].join('\n');
  }
  if (path.endsWith('main.swift')) return mainSwiftPatch;
  const lines = originalContent(path).split('\n');
  return [
    `@@ -1,${lines.length - 2} +1,${lines.length} @@`,
    ...lines.map((line, index) => (index < lines.length - 2 ? ' ' : '+') + line),
  ].join('\n');
}

const handlers = {
  'app.state': () => snapshot(),
  'app.layout': () => null,
  'app.settings': (params) => {
    Object.assign(db.settings, params);
    return null;
  },
  'app.runtime': ({ key, value }) => {
    db.runtime[key] = value;
    push();
    return null;
  },
  'app.toggleProject': ({ path }) => {
    const p = project(path);
    p.expanded = !p.expanded;
    push();
    return null;
  },
  'app.toggleShowAll': ({ path }) => {
    const p = project(path);
    p.showAll = !p.showAll;
    push();
    return null;
  },
  'app.pin': ({ projectPath, sessionId }) => {
    const p = project(projectPath);
    if (sessionId) {
      const s = p.sessions.find((item) => item.id === sessionId);
      p.sessions = [s, ...p.sessions.filter((item) => item !== s)];
    } else if (!p.isHome) {
      db.projects = [db.projects[0], p, ...db.projects.slice(1).filter((item) => item !== p)];
    }
    push();
    return null;
  },
  'app.remove': ({ projectPath, sessionId }) => {
    const p = project(projectPath);
    if (sessionId) p.sessions = p.sessions.filter((item) => item.id !== sessionId);
    else if (!p.isHome) db.projects = db.projects.filter((item) => item !== p);
    push();
    return null;
  },
  'app.renameSession': ({ sessionId, title }) => {
    for (const p of db.projects) {
      const s = p.sessions.find((item) => item.id === sessionId);
      if (!s) continue;
      if (title.trim()) {
        s.autoTitle ??= s.title;
        s.title = title.trim();
        s.named = true;
      } else {
        s.title = s.autoTitle ?? s.title;
        s.named = false;
      }
      if (db.active?.sessionId === sessionId) db.active.label = s.title;
      push();
      return null;
    }
    throw fail('COMMAND_FAILED', `列表里没有这个会话：${sessionId}`);
  },
  'app.revealInFinder': () => null,
  'app.moveProject': ({ from, to }) => {
    const a = db.projects.findIndex((item) => item.path === from);
    const b = db.projects.findIndex((item) => item.path === to);
    if (a < 1 || b < 1 || a === b) return null;
    const [moved] = db.projects.splice(a, 1);
    db.projects.splice(b, 0, moved);
    push();
    return null;
  },
  'app.moveSession': ({ projectPath, from, to }) => {
    const p = project(projectPath);
    const a = p.sessions.findIndex((item) => item.id === from);
    const b = p.sessions.findIndex((item) => item.id === to);
    if (a < 0 || b < 0 || a === b) return null;
    const [moved] = p.sessions.splice(a, 1);
    p.sessions.splice(b, 0, moved);
    push();
    return null;
  },
  'app.addDirectory': ({ path }) => {
    const clean = String(path).trim().replace(/\/+$/, '').replace(/^~/, HOME);
    const title = clean.split('/').pop();
    if (!title) throw fail('COMMAND_FAILED', '目录不存在', path);
    if (!db.projects.some((item) => item.path === clean))
      db.projects.splice(1, 0, {
        path: clean,
        title,
        isHome: false,
        expanded: true,
        showAll: false,
        sessions: [],
      });
    push();
    return { path: clean };
  },
  'app.pickDirectory': () => ({ path: null }),
  'app.prompt': () => {
    if (!db.active) throw fail('COMMAND_FAILED', '没有正在运行的会话');
    const target = db.projects
      .flatMap((item) => item.sessions)
      .find((item) => item.id === db.active.sessionId);
    db.active.busy = true;
    if (target) target.running = true;
    push();
    setTimeout(() => {
      if (db.active) db.active.busy = false;
      if (target) target.running = false;
      push();
    }, 900);
    return { ok: true };
  },
  'app.command': ({ name }) => {
    if (name === 'closeTerminal') {
      db.active = null;
      push();
    }
    return null;
  },
  'app.context': () => ({
    sessionId: db.active?.sessionId ?? null,
    model: 'Opus 5.5',
    total: 200000,
    used: db.active ? 68400 : 0,
    parts: db.active
      ? [
          { label: '缓存命中', value: 31400 },
          { label: '缓存写入', value: 16200 },
          { label: '新增输入', value: 12600 },
          { label: '模型输出', value: 8200 },
        ]
      : [],
  }),
  'app.revealBranchSessions': () => ({ enabled: false, matched: 0 }),
  'session.open': ({ projectPath, cwd, sessionId }) => {
    const p = db.projects.find((item) => item.sessions.some((s) => s.id === sessionId));
    const s = p?.sessions.find((item) => item.id === sessionId);
    db.active = {
      sessionId,
      cwd,
      projectPath: p?.path ?? projectPath,
      label: s?.title ?? '会话',
      busy: false,
    };
    push();
    return null;
  },
  'session.create': ({ projectPath, title, mode, branch }) => {
    const p = project(projectPath);
    let cwd = projectPath;
    if (mode === 'worktree') {
      const r = requireRepo(projectPath);
      if (r.branches.includes(branch)) throw fail('BRANCH_EXISTS', `分支已存在：${branch}`);
      cwd = `${projectPath}/.worktrees/${branch.replace(/[^\w.-]+/g, '-')}`;
      r.branches.push(branch);
      r.worktrees.push({ path: cwd, head: 'a84c2e1', branch });
    }
    const id = `demo-new-${++seq}`;
    const label = title || '新建会话';
    p.sessions.unshift({ id, title: label, named: Boolean(title), cwd, time: '刚刚', running: false, unread: false });
    p.expanded = true;
    db.active = { sessionId: id, cwd, projectPath, label, busy: false };
    push();
    return { sessionId: id, cwd };
  },
  'git.status': ({ projectPath }) => statusOf(projectPath),
  'git.diff': ({ projectPath, filePath, staged }) => {
    const patch = patchFor(requireRepo(projectPath), filePath);
    const lines = patch.split('\n');
    return {
      path: filePath,
      staged: Boolean(staged),
      binary: false,
      additions: lines.filter((line) => line.startsWith('+')).length,
      deletions: lines.filter((line) => line.startsWith('-')).length,
      patch,
    };
  },
  'git.stage': ({ projectPath, paths }) => {
    for (const file of requireRepo(projectPath).files)
      if (paths.includes(file.path)) file.staged = true;
    return { ok: true };
  },
  'git.unstage': ({ projectPath, paths }) => {
    for (const file of requireRepo(projectPath).files)
      if (paths.includes(file.path)) file.staged = false;
    return { ok: true };
  },
  'git.commit': ({ projectPath, message, options }) => {
    const r = requireRepo(projectPath);
    const shortHash = ('d3m0' + ++seq).padEnd(7, '0');
    const commit = {
      hash: shortHash.padEnd(40, '0'),
      shortHash,
      message,
      author: '曾长亮',
      authorEmail: 'demo@example.com',
      date: new Date().toISOString(),
      parents: [],
    };
    r.history = [commit, ...(options?.amend ? r.history.slice(1) : r.history)];
    r.files = r.files.filter((file) => !file.staged);
    return { hash: commit.hash, shortHash, message, amended: Boolean(options?.amend) };
  },
  'git.log': ({ projectPath, limit = 50, skip = 0 }) =>
    requireRepo(projectPath).history.slice(skip, skip + limit),
  'git.show': ({ projectPath, hash }) => {
    const commit = requireRepo(projectPath).history.find((item) => item.hash === hash);
    if (!commit) throw fail('COMMAND_FAILED', '找不到提交', hash);
    return {
      commit,
      files: [{ path: 'Sources/ClaudeDeck/main.swift', additions: 5, deletions: 2, binary: false }],
      additions: 5,
      deletions: 2,
      patch:
        'diff --git a/Sources/ClaudeDeck/main.swift b/Sources/ClaudeDeck/main.swift\n--- a/Sources/ClaudeDeck/main.swift\n+++ b/Sources/ClaudeDeck/main.swift\n' +
        mainSwiftPatch,
    };
  },
  'git.branches': ({ projectPath }) => {
    const r = requireRepo(projectPath);
    return [
      ...r.branches.map((name) => ({
        name,
        isCurrent: name === r.branch,
        isRemote: false,
        upstream: name === 'main' ? 'origin/main' : null,
        ahead: 0,
        behind: 0,
        upstreamGone: false,
        lastCommit: 'a84c2e1',
      })),
      ...r.remotes.map((name) => ({
        name,
        isCurrent: false,
        isRemote: true,
        upstream: null,
        ahead: 0,
        behind: 0,
        upstreamGone: false,
        lastCommit: '618de32',
      })),
    ];
  },
  'git.switchBranch': ({ projectPath, branch }) => {
    const r = requireRepo(projectPath);
    const local = branch.replace(/^origin\//, '');
    if (!r.branches.includes(local)) r.branches.push(local);
    r.branch = local;
    return { ok: true };
  },
  'git.fetch': () => ({ ok: true }),
  'git.pull': () => ({ ok: true }),
  'git.push': () => ({ ok: true }),
  'git.merge': () => ({ ok: true }),
  'git.worktrees': ({ projectPath }) =>
    requireRepo(projectPath).worktrees.map((item, index) => ({
      ...item,
      branch: index === 0 ? requireRepo(projectPath).branch : item.branch,
      isBare: false,
      isLocked: false,
      isPrunable: false,
    })),
  'git.removeWorktree': ({ input }) => {
    const r = requireRepo(input.projectPath);
    r.worktrees = r.worktrees.filter((item) => item.path !== input.path);
    return { ok: true };
  },
  'git.stashes': ({ projectPath }) =>
    requireRepo(projectPath).stashes.map((item, index) => ({
      ...item,
      index,
      ref: `stash@{${index}}`,
    })),
  'git.stashSave': ({ projectPath, message }) => {
    const r = requireRepo(projectPath);
    if (!r.files.length) throw fail('COMMAND_FAILED', '没有可以保存的本地变更');
    r.stashes.unshift({
      hash: 'st4sh' + ++seq,
      message: message || `WIP on ${r.branch}`,
      date: new Date().toISOString(),
      files: r.files,
    });
    r.files = [];
    return { ok: true };
  },
  'git.stashApply': ({ projectPath, index }) => {
    const r = requireRepo(projectPath);
    r.files = r.stashes[index]?.files ?? r.files;
    return { ok: true };
  },
  'git.stashPop': ({ projectPath, index }) => {
    const r = requireRepo(projectPath);
    r.files = r.stashes[index]?.files ?? r.files;
    r.stashes.splice(index, 1);
    return { ok: true };
  },
  'git.stashDrop': ({ projectPath, index }) => {
    requireRepo(projectPath).stashes.splice(index, 1);
    return { ok: true };
  },
  'git.mergeState': ({ projectPath }) => {
    requireRepo(projectPath);
    return { merging: false, head: null, conflicts: [] };
  },
  'git.resolveConflict': () => ({ ok: true }),
  'git.mergeAbort': () => ({ ok: true }),
  'git.mergeContinue': () => ({ ok: true }),
  'git.reflog': ({ projectPath }) =>
    requireRepo(projectPath).history.map((commit, index) => ({
      hash: commit.shortHash,
      selector: `HEAD@{${index}}`,
      message: 'commit: ' + commit.message,
      date: commit.date,
    })),
  'file.read': ({ projectPath, filePath }) => {
    const r = requireRepo(projectPath);
    const content = r.contents[filePath] ?? originalContent(filePath);
    return {
      path: filePath,
      size: content.length,
      modifiedAt: '2026-11-13T14:20:00Z',
      isBinary: false,
      content,
      truncated: false,
      kind: filePath.endsWith('.md') ? 'markdown' : 'code',
    };
  },
  'file.write': ({ projectPath, filePath, content }) => {
    const r = requireRepo(projectPath);
    r.contents[filePath] = content;
    const file = r.files.find((item) => item.path === filePath);
    if (file) Object.assign(file, { staged: false, label: file.label === '?' ? '?' : 'M' });
    return { modifiedAt: new Date().toISOString() };
  },
  'mcp.list': () => db.mcp.map(({ tools, connected, ...server }) => server),
  'mcp.status': () =>
    Object.fromEntries(
      db.mcp.map((server) => [
        server.id,
        !server.enabled ? 'disabled' : server.connected ? 'connected' : 'failed',
      ]),
    ),
  'mcp.tools': ({ id }) => {
    const server = db.mcp.find((item) => item.id === id);
    return {
      connected: Boolean(server?.connected),
      tools: server?.connected ? server.tools : [],
      error: null,
    };
  },
  'mcp.reconnect': ({ id }) => {
    const server = db.mcp.find((item) => item.id === id);
    if (server) server.connected = true;
    return { status: 'connected', tools: server?.tools ?? [], error: null };
  },
  'mcp.add': ({ name, transport, endpoint }) => {
    if (db.mcp.some((item) => item.name === name))
      throw fail('COMMAND_FAILED', `已存在同名服务：${name}`);
    db.mcp.push({
      id: 'user:' + name,
      name,
      scope: 'user',
      transport,
      endpoint,
      description: '自定义服务',
      enabled: true,
      removable: true,
      tools: [],
      connected: false,
    });
    return { id: 'user:' + name };
  },
  'mcp.remove': ({ id }) => {
    db.mcp = db.mcp.filter((item) => item.id !== id);
    return { ok: true };
  },
  'mcp.setEnabled': ({ id, enabled }) => {
    const server = db.mcp.find((item) => item.id === id);
    if (server) server.enabled = enabled;
    return { ok: true };
  },
};

// Work 相关接口在浏览器演示模式下只返回空数据：真实状态只存在于原生侧的数据库里。
const drafts = new Map();
Object.assign(handlers, {
  'work.snapshot': () => ({
    available: true,
    owner: true,
    works: [],
    projects: [],
    capacity: { slots: 2, running: 0, queued: 0, waitingStart: 0 },
    workSessionIds: [],
  }),
  'draft.get': ({ scope, key }) => ({ value: drafts.get(`${scope}:${key}`) ?? '' }),
  'draft.set': ({ scope, key, value }) => {
    drafts.set(`${scope}:${key}`, value);
    return { ok: true };
  },
  'tapd.settings': () => ({
    settings: { enabled: false, cliPath: '', workspaces: [], syncOnLaunch: true },
    prerequisites: { cli: null, endpointSet: false, tokenSet: false },
  }),
  'source.overview': () => ({
    settings: { name: '开发协作助手', enabled: false, autoStart: false, remoteAnswers: false },
    socket: null,
    listening: false,
    lastSeen: null,
    conversations: [],
  }),
  'source.mcpCommand': () => ({ command: 'ClaudePicker', args: ['--source-mcp'], listening: false }),
  'agent.pack': () => ({ valid: false, configured: false }),
  'work.create': () => {
    throw fail('UNAVAILABLE', '浏览器演示模式不能创建 Work，请在应用里使用');
  },
});

export function mockRequest(method, params) {
  return new Promise((resolve, reject) => {
    setTimeout(() => {
      const handler = handlers[method];
      if (!handler) {
        reject(fail('NOT_IMPLEMENTED', `mock 未实现：${method}`));
        return;
      }
      try {
        resolve(handler(params ?? {}) ?? null);
      } catch (error) {
        reject(error);
      }
    }, 20);
  });
}
