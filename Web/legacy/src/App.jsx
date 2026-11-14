import CreateSessionModal from './CreateSessionModal.jsx';
import FileBrowser, { WorkspaceToolSwitcher, projectOptions } from './FileBrowser.jsx';
import {
  ProjectSidebar,
  SessionPane,
  setActiveProjectPath,
  useActiveProject,
  useProjectTree,
} from './AppContext.jsx';
import CommitDetails, { demoCommit, snapshotFile } from './CommitDetails.jsx';
import React, { useState, useEffect } from 'react';
import {
  GitBranch,
  Folder,
  Plus,
  MagnifyingGlass,
  Terminal,
  CaretDown,
  CaretRight,
  X,
  Check,
  Gear,
} from '@phosphor-icons/react';
import { request, transportKind, hasNativeBridge } from './bridge/client.js';
import BranchSwitcher from './git/BranchSwitcher.jsx';

// 真实仓库下尚未接入的写操作统一给这句提示，不做假成功。
const WRITE_PENDING = '暂不支持：写操作待接入（当前只接了只读链路）';
import WorkspacePage from './pages/WorkspacePage.jsx';
import HistoryPage from './pages/HistoryPage.jsx';
import BranchesPage from './pages/BranchesPage.jsx';
import ConflictPage from './pages/ConflictPage.jsx';
import StashPage from './pages/StashPage.jsx';
import TagsPage from './pages/TagsPage.jsx';
import WorktreePage from './pages/WorktreePage.jsx';
import RemotePage from './pages/RemotePage.jsx';
import AllActionsPage from './pages/AllActionsPage.jsx';
import {
  navigation,
  operations,
  demoInitialFiles as initial,
  gitFilesByProject,
  commits,
  demoBranch,
  demoBranches,
  demoStash,
  demoTags,
  demoLog,
  demoWorktrees,
} from './mock/data.js';
// 应用外壳：项目选择 + 左侧 Git 导航 + 工具切换 + 页面路由。
// 各页面的主体在 src/pages/ 下，状态仍集中在这里。
export function App() {
  const [activeTool, setActiveTool] = useState('git'),
    [sessionCollapsed, setSessionCollapsed] = useState(false),
    [createdSessions, setCreatedSessions] = useState([]),
    [page, setPage] = useState('工作区'),
    [repo, setRepo] = useState(''),
    [files, setFiles] = useState(initial),
    [staged, S] = useState([]),
    [selected, select] = useState(initial[0]),
    [message, M] = useState(''),
    [branch, B] = useState(demoBranch),
    [modal, D] = useState(null),
    [value, V] = useState(''),
    [query, Q] = useState(''),
    [toast, T] = useState(''),
    [tab, Tab] = useState('统一'),
    [history, H] = useState(() => commits.map(demoCommit)),
    [ahead, A] = useState(2),
    [log, L] = useState(demoLog),
    [conflictChoice, CC] = useState(''),
    [resolved, RS] = useState(false),
    [amend, AM] = useState(false),
    [showLog, SL] = useState(false),
    [branches, SB] = useState(demoBranches),
    [stash, SS] = useState(demoStash),
    [tags, ST] = useState(demoTags),
    [liveStatus, LS] = useState(null),
    // 分支操作（签出/合并/更新…）完成后自增：刷新计数并让当前页重新读取。
    [gitEpoch, setGitEpoch] = useState(0),
    // 会话 ⇄ 分支绑定：会话分支与仓库当前分支不一致且没能自动签出时的提示
    [followBanner, setFollowBanner] = useState(null);
  const notify = (t) => {
    T(t);
    L((l) => [t, ...l]);
    setTimeout(() => T(''), 3500);
  };
  // 当前项目是第三栏的共享状态（AppContext.jsx 导出），第一栏左侧列表、项目下拉框、
  // Git 页与文件页都读它。repo 只是它的展示名，用于 mock 数据 key 与文案。
  const activeProject = useActiveProject();
  const { projects: realProjects } = useProjectTree();
  const currentProject = activeProject;
  const selectProject = (path) => {
    const selectedProject = realProjects.find((project) => project.path === path);
    if (!selectedProject) return;
    setActiveProjectPath(selectedProject.path);
    notify('已切换到 ' + selectedProject.title);
  };
  // 当前项目一变（下拉框或左侧列表都可能触发），把 Git/文件视图里跟项目绑定的状态
  // 全部换成新项目的，避免残留上一个项目的路径、文件列表与选中项。
  useEffect(() => {
    if (!activeProject || activeProject.title === repo) return;
    const nextFiles =
      gitFilesByProject[activeProject.title] ?? gitFilesByProject[activeProject.label] ?? [];
    const meta = projectOptions.find(
      (option) => option.id === activeProject.title || option.label === activeProject.title,
    );
    setRepo(activeProject.title);
    setFiles(nextFiles);
    select(nextFiles[0] ?? null);
    S([]);
    B(meta?.branch ?? demoBranch);
    A(meta?.ahead ?? 0);
    setPage('工作区');
    D(null);
  }, [activeProject]);
  // 底部状态栏显示真实分支与变更数：Git 页与状态栏必须同源，否则会和页面内数字打架。
  useEffect(() => {
    const path = activeProject?.path;
    if (!path) {
      LS(null);
      return undefined;
    }
    let alive = true;
    const load = () => {
      const params = { projectPath: path };
      Promise.allSettled([
        request('git.status', params),
        request('git.branches', params),
        request('git.tags', params),
        request('git.worktrees', params),
      ]).then(([status, branchList, tagList, worktreeList]) => {
        if (!alive) return;
        if (status.status !== 'fulfilled') {
          LS(null);
          return;
        }
        const snapshot = status.value;
        const count = (r) =>
          r.status === 'fulfilled' && Array.isArray(r.value) ? r.value.length : null;
        LS({
          branch: snapshot?.branch ?? null,
          changed: snapshot?.files?.length ?? 0,
          ahead: snapshot?.ahead ?? 0,
          behind: snapshot?.behind ?? 0,
          branches: count(branchList),
          tags: count(tagList),
          worktrees: count(worktreeList),
        });
      });
    };
    load();
    // 终端里跑 git 命令后回到第三栏要能看到新计数：窗口重新获得焦点时刷新一次。
    window.addEventListener('focus', load);
    return () => {
      alive = false;
      window.removeEventListener('focus', load);
    };
  }, [activeProject?.path, activeTool, page, gitEpoch]);

  // 原生侧打开会话后推来的事件（设置里开启「会话与分支」绑定时才会有）。
  useEffect(() => {
    const onFollow = (event) => {
      const detail = event.detail ?? {};
      if (!detail.projectPath) return;
      setActiveProjectPath(detail.projectPath);
      setActiveTool('git');
      setGitEpoch((value) => value + 1);
      if (detail.state === 'mismatch') {
        setFollowBanner({
          projectPath: detail.projectPath,
          sessionBranch: detail.sessionBranch,
          currentBranch: detail.currentBranch,
          reason: detail.reason,
        });
      } else {
        setFollowBanner(null);
        if (detail.state === 'switched') notify('已切换到会话分支 ' + detail.sessionBranch);
      }
    };
    window.addEventListener('claude-picker:follow-session', onFollow);
    return () => window.removeEventListener('claude-picker:follow-session', onFollow);
  }, []);
  // 提示条只对它所属的项目有效：切到别的项目就收掉。
  useEffect(() => {
    if (followBanner && activeProject?.path !== followBanner.projectPath) setFollowBanner(null);
  }, [activeProject?.path]);
  const checkoutSessionBranch = async () => {
    if (!followBanner) return;
    try {
      await request('git.switchBranch', {
        projectPath: followBanner.projectPath,
        branch: followBanner.sessionBranch,
      });
      notify('已切换到会话分支 ' + followBanner.sessionBranch);
      setFollowBanner(null);
      setGitEpoch((value) => value + 1);
    } catch (error) {
      setFollowBanner((banner) => banner && { ...banner, reason: error?.detail || error?.message });
    }
  };

  // 嵌在 ClaudePicker 里时，项目 / 分支 / 工具切换放在原生标题栏，网页不再画顶部那一行。
  const nativeChrome =
    hasNativeBridge() && !new URLSearchParams(window.location.search).has('full');
  useEffect(() => {
    if (!nativeChrome) return undefined;
    request('app.workbenchState')
      .then((state) => {
        if (state?.projectPath) setActiveProjectPath(state.projectPath);
        if (state?.tool === 'git' || state?.tool === 'files') setActiveTool(state.tool);
      })
      .catch(() => {});
    const onWorkbench = (event) => {
      const detail = event.detail ?? {};
      if (detail.projectPath) setActiveProjectPath(detail.projectPath);
      if (detail.tool === 'git' || detail.tool === 'files') {
        setActiveTool(detail.tool);
        D(null);
      }
      if (detail.refresh) setGitEpoch((value) => value + 1);
    };
    window.addEventListener('claude-picker:workbench', onWorkbench);
    return () => window.removeEventListener('claude-picker:workbench', onWorkbench);
  }, []);
  // 把项目 / 工具 / 分支回报给原生，标题栏上的控件据此显示。
  useEffect(() => {
    if (!nativeChrome) return;
    request('app.reportWorkbench', {
      projectPath: activeProject?.path ?? '',
      tool: activeTool,
      branch: liveStatus?.branch ?? '',
      ahead: liveStatus?.ahead ?? 0,
      behind: liveStatus?.behind ?? 0,
    }).catch(() => {});
  }, [activeProject?.path, activeTool, liveStatus]);

  const open = (title, kind = 'action') => {
    D({ title, kind });
    V('');
  };
  const move = (f) =>
    S((s) => (s.includes(f.name) ? s.filter((x) => x !== f.name) : [...s, f.name]));
  // 原生桥在线时页面展示的是真实仓库，演示用的内存写操作一律拦下。
  const live = transportKind() !== 'mock';
  const commit = () => {
    if (live) return notify(WRITE_PENDING);
    if (!staged.length || !message.trim()) return;
    const submittedFiles = files.filter((file) => staged.includes(file.name)).map(snapshotFile);
    H((previous) => {
      const newCommit = {
        message: message.trim(),
        hash: crypto.randomUUID().replaceAll('-', '').slice(0, 7),
        author: '曾长亮',
        time: '刚刚',
        files: submittedFiles,
      };
      if (amend && previous.length) {
        const combinedFiles = new Map(
          previous[0].files.map((file) => [file.path + '/' + file.name, file]),
        );
        for (const file of submittedFiles) combinedFiles.set(file.path + '/' + file.name, file);
        newCommit.files = [...combinedFiles.values()];
        return [newCommit, ...previous.slice(1)];
      }
      return [newCommit, ...previous];
    });
    setFiles((f) => f.filter((x) => !staged.includes(x.name)));
    S([]);
    M('');
    A((a) => a + 1);
    notify('演示提交已创建，可在提交历史中查看');
  };
  const confirm = () => {
    let title = modal.title;
    if (live) {
      notify('暂不支持：' + title + '（写操作待接入）');
      D(null);
      return;
    }
    if (modal.kind === 'branch') {
      if (!value.trim()) return;
      SB((x) => [value, ...x]);
      B(value);
    }
    if (modal.kind === 'tag') {
      if (!value.trim()) return;
      ST((x) => [value, ...x]);
    }
    if (modal.kind === 'stash') {
      SS((x) => [value || 'WIP: 当前工作区变更', ...x]);
      setFiles([]);
      S([]);
    }
    if (modal.kind === 'clone' && value) setRepo(value.split('/').pop().replace('.git', ''));
    notify('演示完成：' + title);
    D(null);
  };
  useEffect(() => {
    const onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        D({ title: '搜索 Git 操作', kind: 'search' });
        V('');
      }
      if (e.key === 'Escape') D(null);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  const applyStash = () => {
    if (live) return notify(WRITE_PENDING);
    setFiles(initial);
    notify('演示：已应用 Stash，原记录保留');
  };
  const popStash = (index) => {
    if (live) return notify(WRITE_PENDING);
    SS((s) => s.filter((_, j) => index !== j));
    setFiles(initial);
    notify('演示：已恢复并移除 Stash');
  };
  // 嵌在 ClaudePicker 第三栏时只渲染 Git 工作台本体：项目与会话列表已经由原生侧栏承担，
  // 网页里再放一套就是重复的一栏，而且窄宽度下会把内容区挤爆。
  // 需要看完整原型布局时在 URL 上加 ?full=1。
  const solo =
    typeof window === 'undefined' || !new URLSearchParams(window.location.search).has('full');
  return (
    <div
      className={`app${solo ? ' solo' : ''}${nativeChrome ? ' no-status' : ''}${sessionCollapsed ? ' session-collapsed' : ''}`}
    >
      {!solo && (
        <>
          <header className="titlebar">
            <div className="brand">
              <GitBranch size={23} weight="bold" />
              <b>Claude Code</b>
              <span className="divider" />
              <span>项目工作台</span>
            </div>
            <div className="prototype">
              交互原型 <span>·</span> {activeTool === 'git' ? '模拟数据' : '文件为演示内容'}
            </div>
            <button className="command" onClick={() => open('搜索 Git 操作', 'search')}>
              <MagnifyingGlass /> 搜索操作 <kbd>⌘ K</kbd>
            </button>
          </header>
          <ProjectSidebar activeProject={repo} createdSessions={createdSessions} />
          <SessionPane
            collapsed={sessionCollapsed}
            onToggle={() => setSessionCollapsed((value) => !value)}
          />
        </>
      )}
      <div className="shell">
        {nativeChrome ? (
          <div className="workspace-tool-switcher headless-host">
            <BranchSwitcher
              headless
              projects={realProjects}
              onSelectProject={(path) => setActiveProjectPath(path)}
              active={activeTool === 'git'}
              projectPath={activeProject?.path}
              branch={liveStatus?.branch ?? ''}
              ahead={liveStatus?.ahead ?? 0}
              behind={liveStatus?.behind ?? 0}
              onChanged={() => setGitEpoch((value) => value + 1)}
              onNotify={notify}
            />
          </div>
        ) : (
          <WorkspaceToolSwitcher
            activeTool={activeTool}
            onChange={(tool) => {
              setActiveTool(tool);
              D(null);
            }}
            projects={realProjects}
            activeProject={activeProject}
            onSelectProject={selectProject}
            branchProps={{
              projectPath: activeProject?.path,
              branch: liveStatus?.branch ?? (live ? '' : branch),
              ahead: liveStatus ? liveStatus.ahead : ahead,
              behind: liveStatus ? liveStatus.behind : 0,
              onChanged: () => setGitEpoch((value) => value + 1),
              onNotify: notify,
            }}
          />
        )}
        {activeTool === 'git' ? (
          <>
            <div className="git-workspace-layout">
              <aside className="sidebar">
                <nav>
                  {navigation.map(([n, I, c]) => (
                    <button
                      key={n}
                      aria-label={n}
                      title={n}
                      className={page === n ? 'active' : ''}
                      onClick={() => {
                        setPage(n);
                        Q('');
                      }}
                    >
                      <I size={18} />
                      <span>{n}</span>
                      <small>
                        {liveStatus
                          ? // 真实仓库：只显示桥能给出的计数，拿不到的留空，不拿演示数据充数。
                            ({
                              工作区: liveStatus.changed,
                              分支管理: liveStatus.branches,
                              '标签 Tags': liveStatus.tags,
                              工作树: liveStatus.worktrees,
                            }[n] ?? '')
                          : n === '工作区'
                            ? files.length
                            : n === '提交历史'
                              ? history.length
                              : n === '分支管理'
                                ? branches.length
                                : n === 'Stash 暂存'
                                  ? stash.length
                                  : n === '标签 Tags'
                                    ? tags.length
                                    : n === '合并与冲突'
                                      ? resolved
                                        ? 0
                                        : 1
                                      : c}
                      </small>
                    </button>
                  ))}
                </nav>
                {nativeChrome && (
                  <button
                    className={'nav-log' + (showLog ? ' active' : '')}
                    title="操作日志"
                    aria-label="操作日志"
                    onClick={() => SL(!showLog)}
                  >
                    <Terminal size={15} />
                  </button>
                )}
                <div className="side-bottom">
                  <div className="remote-status">
                    <span className="dot" /> origin 已连接 <small>刚刚同步</small>
                  </div>
                  <button onClick={() => open('偏好设置')}>
                    <Gear size={18} />
                    偏好设置
                  </button>
                </div>
              </aside>
              <main key={gitEpoch}>
                {followBanner && (
                  <div className="follow-banner" role="status">
                    <GitBranch size={14} />
                    <span>
                      会话分支 <b>{followBanner.sessionBranch}</b> ≠ 当前分支{' '}
                      <b>{followBanner.currentBranch}</b>
                      {followBanner.reason && <em>（{followBanner.reason}，未自动切换）</em>}
                    </span>
                    <button className="primary" onClick={checkoutSessionBranch}>
                      签出 {followBanner.sessionBranch}
                    </button>
                    <button onClick={() => setFollowBanner(null)}>忽略</button>
                  </div>
                )}
                {page === '工作区' ? (
                  <WorkspacePage
                    files={files}
                    staged={staged}
                    selected={selected}
                    query={query}
                    message={message}
                    amend={amend}
                    tab={tab}
                    onStagedChange={S}
                    onNotify={notify}
                    onQueryChange={Q}
                    onMessageChange={M}
                    onAmendChange={AM}
                    onToggleStage={move}
                    onSelect={select}
                    onCommit={commit}
                    onOpen={open}
                    onTabChange={Tab}
                  />
                ) : (
                  <div className="content-panel">
                    <div className="content-tools">
                      <div className="search-input">
                        <MagnifyingGlass />
                        <input
                          value={query}
                          onChange={(e) => Q(e.target.value)}
                          placeholder={'搜索' + page + '…'}
                        />
                      </div>
                      <div className="content-actions">
                        {page === '分支管理' && (
                          <button
                            className="create-session-entry"
                            onClick={() => open('创建新会话', 'session')}
                          >
                            <Terminal />
                            创建会话
                          </button>
                        )}
                        <button
                          className="primary"
                          onClick={() =>
                            open(
                              page === '分支管理'
                                ? '新建分支'
                                : page === '标签 Tags'
                                  ? '新建标签'
                                  : page === 'Stash 暂存'
                                    ? '保存当前变更'
                                    : page === '工作树'
                                      ? '新建工作树'
                                      : '新建操作',
                              page === '分支管理'
                                ? 'branch'
                                : page === '标签 Tags'
                                  ? 'tag'
                                  : page === 'Stash 暂存'
                                    ? 'stash'
                                    : 'action',
                            )
                          }
                        >
                          <Plus />
                          {page === '分支管理'
                            ? '新建分支'
                            : page === '标签 Tags'
                              ? '新建标签'
                              : page === 'Stash 暂存'
                                ? '保存变更'
                                : page === '工作树'
                                  ? '新建工作树'
                                  : '更多操作'}
                        </button>
                      </div>
                    </div>
                    {page === '全部操作' ? (
                      <AllActionsPage operations={operations} query={query} onOpen={open} />
                    ) : page === '提交历史' ? (
                      <HistoryPage
                        history={history}
                        query={query}
                        onOpenCommit={(item) => D({ kind: 'commit', commit: item })}
                        onOpen={open}
                      />
                    ) : page === '分支管理' ? (
                      <BranchesPage
                        branches={branches}
                        query={query}
                        branch={branch}
                        onSwitchBranch={B}
                        onNotify={notify}
                        onOpen={open}
                      />
                    ) : page === '合并与冲突' ? (
                      <ConflictPage
                        live={live}
                        branch={liveStatus?.branch ?? branch}
                        resolved={resolved}
                        conflictChoice={conflictChoice}
                        onChoose={CC}
                        onResolve={RS}
                        onNotify={notify}
                        onOpen={open}
                      />
                    ) : page === 'Stash 暂存' ? (
                      <StashPage
                        live={live}
                        stash={stash}
                        query={query}
                        branch={branch}
                        onApply={applyStash}
                        onPop={popStash}
                        onOpen={open}
                      />
                    ) : page === '标签 Tags' ? (
                      <TagsPage tags={tags} query={query} onOpen={open} />
                    ) : page === '工作树' ? (
                      <WorktreePage
                        repo={repo}
                        branch={branch}
                        query={query}
                        worktrees={demoWorktrees}
                        onNotify={notify}
                        onOpen={open}
                      />
                    ) : (
                      <RemotePage repo={repo} onOpen={open} />
                    )}
                  </div>
                )}
              </main>
            </div>
          </>
        ) : (
          <FileBrowser key={repo} repo={repo} projectPath={activeProject?.path} onNotify={notify} />
        )}
      </div>
      {/* 嵌在 ClaudePicker 里时分支 / 变更数已在标题栏与导航条上，状态栏去掉；操作日志挪到导航条右端 */}
      {!nativeChrome && (
        <footer className="statusbar">
          <span className="status-branch">
            {activeTool === 'git' ? (
              <>
                <GitBranch />
                {liveStatus?.branch ?? branch}
              </>
            ) : (
              <>
                <Folder />
                {repo} / 文件预览
              </>
            )}
          </span>
          <span>
            <span className="dot" />
            {activeTool === 'git'
              ? '工作区' +
                ((liveStatus?.changed ?? files.length)
                  ? '有 ' + (liveStatus?.changed ?? files.length) + ' 项变更'
                  : '干净')
              : '可编辑预览 · 本地内存'}
          </span>
          <span className="status-right">
            <button onClick={() => SL(!showLog)}>
              <Terminal />
              操作日志{showLog && <CaretDown />}
            </button>
            {activeTool === 'git' ? '分支操作已接入 · 提交待接入' : '本地文件 · 只读预览'}
          </span>
        </footer>
      )}
      {showLog && (
        <div className="log-panel">
          <b>操作日志</b>
          <button onClick={() => SL(false)}>
            <X />
          </button>
          {log.map((x, i) => (
            <p key={i}>
              <code>demo</code> {x}
            </p>
          ))}
        </div>
      )}
      {toast && (
        <div className="toast">
          <Check size={18} />
          {toast}
        </div>
      )}
      {modal?.kind === 'commit' && (
        <CommitDetails key={modal.commit.hash} commit={modal.commit} onClose={() => D(null)} />
      )}
      {modal?.kind === 'session' && (
        <CreateSessionModal
          project={currentProject}
          currentBranch={liveStatus?.branch ?? branch}
          onClose={() => D(null)}
          onCreate={(session) => {
            if (live) {
              notify('暂不支持：创建会话（会话创建待接入）');
              D(null);
              return;
            }
            setCreatedSessions((current) => [session, ...current]);
            notify(
              session.mode === 'worktree'
                ? `已为 ${currentProject.label} 创建 Worktree 会话`
                : `已为 ${currentProject.label} 创建当前分支会话`,
            );
            D(null);
          }}
        />
      )}
      {modal && !['commit', 'session'].includes(modal.kind) && (
        <div className="overlay" onClick={() => D(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-title">
              <h2>{modal.title}</h2>
              <button onClick={() => D(null)}>
                <X size={20} />
              </button>
            </div>
            {modal.kind === 'search' ? (
              <>
                <input
                  autoFocus
                  value={value}
                  onChange={(e) => V(e.target.value)}
                  placeholder="搜索命令，如 rebase、推送、工作树…"
                />
                <div className="command-results">
                  {Object.values(operations)
                    .flat()
                    .filter((x) => x.toLowerCase().includes(value.toLowerCase()))
                    .map((x) => (
                      <button key={x} onClick={() => open(x)}>
                        <Terminal />
                        {x}
                        <CaretRight />
                      </button>
                    ))}
                </div>
              </>
            ) : (
              <>
                <p>
                  {modal.kind === 'danger'
                    ? '此操作可能丢弃修改。正式功能会展示影响范围并要求确认；当前仅预览流程。'
                    : '设置操作参数并预览执行流程。此处使用模拟数据。'}
                </p>
                {['branch', 'tag', 'stash', 'clone', 'command'].includes(modal.kind) && (
                  <label className="modal-field">
                    {modal.kind === 'clone'
                      ? '仓库 URL'
                      : modal.kind === 'command'
                        ? '命令与参数'
                        : '名称 / 说明'}
                    <input
                      autoFocus
                      value={value}
                      onChange={(e) => V(e.target.value)}
                      placeholder={
                        modal.kind === 'branch'
                          ? 'feature/new-feature'
                          : modal.kind === 'command'
                            ? 'git log --oneline --all'
                            : '请输入…'
                      }
                    />
                  </label>
                )}
                <div className="command-preview">
                  <Terminal />
                  <code>
                    {modal.kind === 'branch'
                      ? 'git switch -c ' + (value || '<branch>')
                      : modal.kind === 'tag'
                        ? 'git tag -a ' + (value || '<tag>')
                        : modal.kind === 'command'
                          ? value || 'git <command>'
                          : modal.kind === 'clone'
                            ? 'git clone ' + (value || '<url>')
                            : '操作预览 · ' + modal.title}
                  </code>
                </div>
                <div className="modal-actions">
                  <button onClick={() => D(null)}>取消</button>
                  <button
                    className={modal.kind === 'danger' ? 'danger-btn' : 'primary'}
                    onClick={confirm}
                  >
                    确认演示
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
