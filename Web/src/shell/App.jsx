// 应用外壳：标题栏 + 项目侧栏 + 终端栏（原生终端嵌在透明的「洞」下面）+ Git 工作台。
// 结构、文案与交互以 docs/app-layout-prototype 为准；数据全部来自原生桥。
import React, { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import {
  ArrowDown,
  ArrowUp,
  ArrowsClockwise,
  CaretDoubleLeft,
  CaretDown,
  Check,
  ClockCounterClockwise,
  Code,
  DotsThree,
  Folder,
  GitBranch,
  GitDiff,
  GitMerge,
  House,
  MagnifyingGlass,
  Minus,
  Terminal,
  TreeStructure,
  Warning,
  X,
} from '@phosphor-icons/react';
import './style.css';
import appIcon from './clawd-mark.png';
import { errorText, isNative, on, request } from './bridge.js';
import { IconButton, tildePath, useStored } from './ui.jsx';
import Sidebar from './Sidebar.jsx';
import Composer from './Composer.jsx';
import WorkspaceTab from './WorkspaceTab.jsx';
import { BranchesTab, HistoryTab, MoreTab, WorktreeTab } from './GitPages.jsx';
import { ContextModal, DirectoryModal, McpModal, SessionModal, SettingsModal } from './Modals.jsx';

const tabs = [
  ['工作区', GitDiff],
  ['提交历史', ClockCounterClockwise],
  ['分支', GitBranch],
  ['工作树', TreeStructure],
  ['更多', DotsThree],
];

const DEFAULT_TERMINAL_WIDTH = 30;
const native = isNative();
if (native) document.documentElement.classList.add('native');

export default function App() {
  const [state, setState] = useState(null);
  const [settings, setSettings] = useState(null);
  const [workbenchPath, setWorkbenchPath] = useStored('workbenchProject', '');
  const [tab, setTab] = useStored('tab', '工作区');
  const [morePage, setMorePage] = useState(null);

  const [status, setStatus] = useState(null);
  const [statusError, setStatusError] = useState(null);
  const [stamp, setStamp] = useState(0);
  const [branches, setBranches] = useState(null);
  const [branchesError, setBranchesError] = useState(null);
  const [epoch, setEpoch] = useState(0);
  const [gitBusy, setGitBusy] = useState(false);
  const gitBusyRef = useRef(false);

  const [menu, setMenu] = useState(null);
  const [branchFilter, setBranchFilter] = useState('');
  const [pickedBranch, setPickedBranch] = useState('');
  const [branchContext, setBranchContext] = useState(null);
  const [treeContext, setTreeContext] = useState(null);
  const [treeCursor, setTreeCursor] = useState(null);
  const [runtimeMenu, setRuntimeMenu] = useState(null);
  const [modal, setModal] = useState(null);
  const [toast, setToast] = useState(null);
  const [log, setLog] = useState([]);
  const [followBanner, setFollowBanner] = useState(null);

  const [prompt, setPrompt] = useState('');
  const [sending, setSending] = useState(false);
  const [context, setContext] = useState(null);

  const [floatingMinimized, setFloatingMinimized] = useStored('floatingMinimized', false);
  const [floatingPosition, setFloatingPosition] = useStored('floatingPosition', {
    x: Math.max(12, window.innerWidth - 384),
    y: Math.max(56, window.innerHeight - 218),
  });
  const floatingRef = useRef(null);
  const floatingDragMoved = useRef(false);
  const toastTimer = useRef(0);
  const lastLayout = useRef('');

  // ---------- 原生快照 ----------
  useEffect(() => {
    let alive = true;
    request('app.state')
      .then((snapshot) => {
        if (!alive) return;
        setState(snapshot);
        setSettings(snapshot.settings);
      })
      .catch(() => {});
    const off = on('state', (snapshot) => setState(snapshot));
    return () => {
      alive = false;
      off();
    };
  }, []);

  const notify = useCallback((text, failed = false) => {
    setToast({ text, failed });
    const now = new Date();
    const time = [now.getHours(), now.getMinutes(), now.getSeconds()]
      .map((n) => String(n).padStart(2, '0'))
      .join(':');
    setLog((current) => [{ time, text, failed }, ...current].slice(0, 200));
    window.clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), failed ? 5200 : 2800);
  }, []);

  const updateSettings = useCallback((patch, persist = true) => {
    setSettings((current) => ({ ...current, ...patch }));
    if (persist) request('app.settings', patch).catch(() => {});
  }, []);

  const projects = state?.projects ?? [];
  const active = state?.active ?? null;
  const project = projects.find((item) => item.path === workbenchPath) ?? null;
  const pathRef = useRef(workbenchPath);
  pathRef.current = workbenchPath;

  // 工作台项目：记住上次的；不在列表里了就跟当前会话走，再不行取第一个普通项目。
  useEffect(() => {
    if (!projects.length || project) return;
    const fallback =
      projects.find((item) => item.path === active?.projectPath) ??
      projects.find((item) => !item.isHome) ??
      projects[0];
    setWorkbenchPath(fallback.path);
  }, [projects.length, project?.path, active?.projectPath]);

  // ---------- Git 状态 ----------
  const statusLoading = useRef(false);
  const loadStatus = useCallback(() => {
    const path = pathRef.current;
    if (!path || statusLoading.current) return;
    statusLoading.current = true;
    request('git.status', { projectPath: path }, { timeoutMs: 60000 })
      .then((snapshot) => {
        if (pathRef.current !== path) return;
        setStatus(snapshot);
        setStatusError(null);
        setStamp((value) => value + 1);
      })
      .catch((error) => {
        if (pathRef.current !== path) return;
        setStatus(null);
        setStatusError({ code: error.code, text: errorText(error) });
      })
      .finally(() => {
        statusLoading.current = false;
        // 加载期间切了项目：给新项目补一次
        if (pathRef.current !== path) loadStatus();
      });
  }, []);

  const loadBranches = useCallback(() => {
    const path = pathRef.current;
    if (!path) return;
    request('git.branches', { projectPath: path }, { timeoutMs: 60000 })
      .then((list) => {
        if (pathRef.current !== path) return;
        setBranches(list);
        setBranchesError(null);
      })
      .catch((error) => {
        if (pathRef.current !== path) return;
        setBranches(null);
        setBranchesError(errorText(error));
      });
  }, []);

  useEffect(() => {
    setStatus(null);
    setStatusError(null);
    setBranches(null);
    setBranchesError(null);
    setFollowBanner((banner) => (banner && banner.projectPath !== workbenchPath ? null : banner));
  }, [workbenchPath]);

  useEffect(() => {
    if (!workbenchPath) return;
    loadStatus();
    loadBranches();
  }, [workbenchPath, epoch]);

  const workbenchVisible = Boolean(settings?.workbench);
  useEffect(() => {
    if (!workbenchVisible) return undefined;
    // 终端里的会话随时在改文件：工作台可见时定时刷新，回到窗口时立刻刷新。
    const timer = window.setInterval(() => {
      if (!document.hidden) loadStatus();
    }, 5000);
    const onFocus = () => {
      loadStatus();
      loadBranches();
    };
    window.addEventListener('focus', onFocus);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener('focus', onFocus);
    };
  }, [workbenchVisible]);

  // 会话跑完一轮：多半改了文件或提交了代码，整体刷新一次
  const wasBusy = useRef(false);
  useEffect(() => {
    if (wasBusy.current && !active?.busy) setEpoch((value) => value + 1);
    wasBusy.current = Boolean(active?.busy);
  }, [active?.busy]);

  // ---------- 上下文占用 ----------
  useEffect(() => {
    let alive = true;
    const load = () =>
      request('app.context')
        .then((result) => alive && setContext(result))
        .catch(() => {});
    load();
    const timer = window.setInterval(load, 30000);
    return () => {
      alive = false;
      window.clearInterval(timer);
    };
  }, [active?.sessionId, active?.busy]);

  const runGit = useCallback(
    async (method, params, done) => {
      if (gitBusyRef.current) {
        notify('上一个 Git 操作还在进行，请稍候再试', true);
        return false;
      }
      gitBusyRef.current = true;
      setGitBusy(true);
      try {
        await request(method, { projectPath: pathRef.current, ...params }, { timeoutMs: 150000 });
        if (done) notify(done);
        return true;
      } catch (error) {
        notify(errorText(error), true);
        if (error.code === 'MERGE_CONFLICT') {
          setTab('更多');
          setMorePage('合并与冲突');
        }
        return false;
      } finally {
        gitBusyRef.current = false;
        setGitBusy(false);
        setEpoch((value) => value + 1);
      }
    },
    [notify],
  );

  const currentBranch = status?.branch ?? null;
  const isRepository = Boolean(status);
  const notRepository = statusError?.code === 'NOT_A_REPOSITORY';

  function selectProject(path) {
    if (path !== workbenchPath) setWorkbenchPath(path);
    setMenu(null);
    setBranchContext(null);
    setBranchFilter('');
    setPickedBranch('');
    setMorePage(null);
  }

  async function checkoutBranch(name) {
    if (!name || name === currentBranch) return;
    setMenu(null);
    setBranchContext(null);
    const ok = await runGit('git.switchBranch', { branch: name }, `已切换到 ${name}`);
    if (ok && settings?.followSessionBranch) revealBranch(name);
  }

  // 分支 → 会话：选中分支后在左侧定位到该分支的会话（设置里开了绑定才生效）
  function revealBranch(name) {
    const local = branches?.find((item) => item.name === name)?.isRemote
      ? name.replace(/^[^/]+\//, '')
      : name;
    request('app.revealBranchSessions', { projectPath: workbenchPath, branch: local }).catch(
      () => {},
    );
  }

  function openBranchContext(event, name) {
    event.preventDefault();
    if (!name) return;
    setTreeContext(null);
    setBranchContext({
      name,
      x: Math.min(event.clientX, window.innerWidth - 218),
      y: Math.min(event.clientY, window.innerHeight - 238),
    });
  }

  function branchAction(action) {
    const name = branchContext.name;
    const info = branches?.find((item) => item.name === name);
    const remote = info?.isRemote ? name.split('/')[0] : null;
    setBranchContext(null);
    setMenu(null);
    if (action === '切换分支') checkoutBranch(name);
    if (action === '获取')
      runGit(
        'git.fetch',
        remote ? { remote } : {},
        remote ? `已获取 ${remote}` : '已获取所有远程的最新引用',
      );
    if (action === '拉取') {
      if (remote) runGit('git.fetch', { remote }, `已获取 ${remote}`);
      else runGit('git.pull', name === currentBranch ? {} : { branch: name }, `已更新 ${name}`);
    }
    if (action === '推送') runGit('git.push', { branch: name }, `已推送 ${name}`);
    if (action === '合并到当前分支')
      runGit('git.merge', { branch: name }, `已将 ${name} 合并到 ${currentBranch ?? '当前分支'}`);
  }

  function openTreeContext(event, target, session = null) {
    event.preventDefault();
    setMenu(null);
    setBranchContext(null);
    setTreeContext({
      project: target,
      session,
      x: Math.min(event.clientX, window.innerWidth - 218),
      y: Math.min(event.clientY, window.innerHeight - 210),
    });
  }

  function treeAction(action) {
    const { project: target, session } = treeContext;
    setTreeContext(null);
    if (action === '新建对话') {
      selectProject(target.path);
      if (!target.expanded) request('app.toggleProject', { path: target.path });
      setModal({ kind: 'session', mode: 'current', projectPath: target.path });
    }
    if (action === '置顶')
      request('app.pin', { projectPath: target.path, sessionId: session?.id }).catch(() => {});
    if (action === '展开' || action === '收起') request('app.toggleProject', { path: target.path });
    if (action === '在访达中显示')
      request('app.revealInFinder', { path: target.path }).catch((error) =>
        notify(errorText(error), true),
      );
    if (action === '从列表移除')
      request('app.remove', { projectPath: target.path, sessionId: session?.id }).catch((error) =>
        notify(errorText(error), true),
      );
  }

  function openSession(target, session) {
    if (target.path !== workbenchPath) selectProject(target.path);
    if (!settings.terminal) updateSettings({ terminal: true });
    request('session.open', {
      projectPath: target.path,
      cwd: session.cwd,
      sessionId: session.id,
    }).catch((error) => notify(errorText(error), true));
  }

  async function sendPrompt() {
    const text = prompt.trim();
    if (!text || sending) return;
    setSending(true);
    try {
      await request('app.prompt', { text, projectPath: workbenchPath });
      setPrompt('');
    } catch (error) {
      notify(errorText(error), true);
    } finally {
      setSending(false);
    }
  }

  // ---------- 原生命令 / 事件 ----------
  const toggles = useRef({});
  toggles.current = {
    newSession: () => setModal({ kind: 'session', mode: 'current', projectPath: workbenchPath }),
    toggleTerminal: () => updateSettings({ terminal: !settings.terminal }),
    toggleSidebar: () => updateSettings({ sidebar: !settings.sidebar }),
    toggleWorkbench: () => updateSettings({ workbench: !settings.workbench }),
    openSettings: () => setModal({ kind: 'settings' }),
    focusTree: () =>
      (
        document.querySelector('.session-row.selected') ?? document.querySelector('.project-row')
      )?.focus(),
  };

  useEffect(() => {
    const offCommand = on('command', (detail) => toggles.current[detail.name]?.());
    const offFollow = on('follow-session', (detail) => {
      if (!detail.projectPath) return;
      setWorkbenchPath(detail.projectPath);
      setEpoch((value) => value + 1);
      if (detail.state === 'mismatch') {
        setFollowBanner({
          projectPath: detail.projectPath,
          sessionBranch: detail.sessionBranch,
          currentBranch: detail.currentBranch,
          reason: detail.reason,
        });
      } else {
        setFollowBanner(null);
        if (detail.state === 'switched') notify(`已切换到会话分支 ${detail.sessionBranch}`);
      }
    });
    const offReveal = on('reveal', (detail) => {
      setTreeCursor(`session-${detail.sessionId}`);
      window.setTimeout(
        () =>
          document
            .querySelector(`[data-session="${detail.sessionId}"]`)
            ?.scrollIntoView({ block: 'nearest' }),
        60,
      );
      if (detail.matched > 1) notify(`已定位到该分支最近的会话（共 ${detail.matched} 个）`);
    });
    return () => {
      offCommand();
      offFollow();
      offReveal();
    };
  }, []);

  useEffect(() => {
    const handleKey = (event) => {
      // 原生窗口里这三个快捷键由菜单统一处理（终端有焦点时网页收不到按键）
      if (!native && (event.metaKey || event.ctrlKey)) {
        const command = { n: 'newSession', j: 'toggleTerminal', b: 'toggleSidebar' }[event.key];
        if (command) {
          event.preventDefault();
          toggles.current[command]();
        }
      }
      if (event.key === 'Escape') {
        setModal(null);
        setMenu(null);
        setBranchContext(null);
        setTreeContext(null);
        setRuntimeMenu(null);
      }
    };
    window.addEventListener('keydown', handleKey);
    return () => window.removeEventListener('keydown', handleKey);
  }, []);

  useEffect(() => {
    if (!menu && !branchContext && !treeContext && !runtimeMenu) return undefined;
    const dismiss = (event) => {
      if (!event.target.closest('.project-menu-wrap, .branch-context')) {
        setMenu(null);
        setBranchContext(null);
      }
      if (!event.target.closest('.tree-context') && event.button !== 2) setTreeContext(null);
      if (!event.target.closest('.runtime-options')) setRuntimeMenu(null);
    };
    window.addEventListener('pointerdown', dismiss);
    return () => window.removeEventListener('pointerdown', dismiss);
  }, [menu, branchContext, treeContext, runtimeMenu]);

  // ---------- 布局回报：原生据此摆放终端视图与窗口拖动区 ----------
  // 弹窗 / 菜单打开时带 data-blocking：原生把整窗的鼠标与键盘都交给网页。
  const reportLayout = useCallback(() => {
    const rectOf = (element) => {
      const box = element.getBoundingClientRect();
      return { x: box.left, y: box.top, w: box.width, h: box.height };
    };
    const hole = document.querySelector('[data-terminal-hole]');
    const payload = {
      terminal: hole ? rectOf(hole) : null,
      drag: [...document.querySelectorAll('[data-drag-region]')].map(rectOf),
      overlays: [...document.querySelectorAll('[data-terminal-overlay]')].map(rectOf),
      blocked: Boolean(document.querySelector('[data-blocking]')),
    };
    const json = JSON.stringify(payload);
    if (json === lastLayout.current) return;
    lastLayout.current = json;
    request('app.layout', payload).catch(() => {});
  }, []);
  useLayoutEffect(() => {
    reportLayout();
  });
  useEffect(() => {
    window.addEventListener('resize', reportLayout);
    return () => window.removeEventListener('resize', reportLayout);
  }, [reportLayout]);

  // ---------- 悬浮输入窗 ----------
  const terminalOpen = Boolean(settings?.terminal);
  useEffect(() => {
    if (terminalOpen) return undefined;
    const containFloating = () => {
      const bounds = floatingRef.current?.getBoundingClientRect();
      if (!bounds) return;
      setFloatingPosition((position) => {
        const next = {
          x: Math.max(12, Math.min(window.innerWidth - bounds.width - 12, position.x)),
          y: Math.max(52, Math.min(window.innerHeight - bounds.height - 12, position.y)),
        };
        return next.x === position.x && next.y === position.y ? position : next;
      });
    };
    containFloating();
    window.addEventListener('resize', containFloating);
    return () => window.removeEventListener('resize', containFloating);
  }, [terminalOpen, floatingMinimized]);

  function dragFloating(event) {
    if (event.button !== 0) return;
    const button = event.target.closest('button');
    if (button && button !== event.currentTarget) return;
    const handle = event.currentTarget;
    const panel = floatingRef.current;
    const start = { ...floatingPosition };
    const pointerX = event.clientX;
    const pointerY = event.clientY;
    floatingDragMoved.current = false;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (move) => {
      const deltaX = move.clientX - pointerX;
      const deltaY = move.clientY - pointerY;
      if (Math.hypot(deltaX, deltaY) <= 4 && !floatingDragMoved.current) return;
      floatingDragMoved.current = true;
      setRuntimeMenu(null);
      setFloatingPosition({
        x: Math.max(12, Math.min(window.innerWidth - panel.offsetWidth - 12, start.x + deltaX)),
        y: Math.max(52, Math.min(window.innerHeight - panel.offsetHeight - 12, start.y + deltaY)),
      });
    };
    const finish = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
      window.setTimeout(() => {
        floatingDragMoved.current = false;
      }, 0);
    };
    handle.onpointerup = finish;
    handle.onpointercancel = finish;
  }

  function beginResize(event) {
    if (event.button !== 0) return;
    const handle = event.currentTarget;
    const body = handle.parentElement;
    handle.setPointerCapture(event.pointerId);
    let latest = settings.terminalWidth;
    handle.onpointermove = (move) => {
      const rect = body.getBoundingClientRect();
      const sidebarWidth = settings.sidebar ? 250 : 48;
      latest = Math.max(
        24,
        Math.min(
          57,
          ((move.clientX - rect.left - sidebarWidth) / (rect.width - sidebarWidth)) * 100,
        ),
      );
      updateSettings({ terminalWidth: latest }, false);
    };
    const finish = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
      updateSettings({ terminalWidth: latest });
    };
    handle.onpointerup = finish;
    handle.onpointercancel = finish;
  }

  if (!state || !settings) return <div className="app booting" />;

  const { sidebar, terminal, workbench } = settings;
  // 图形聊天模式：第二栏里是 Swttch 自己的输入区，外壳的输入框不再显示。
  const chatMode = settings.interactionMode === 'chat';
  const terminalWidth = settings.terminalWidth ?? DEFAULT_TERMINAL_WIDTH;
  const runtime = state.runtime;
  const modelLabel =
    runtime.models.find((item) => item.id === runtime.model)?.label ?? runtime.model;
  const sessionProject = projects.find((item) => item.path === active?.projectPath) ?? project;
  const changedCount = status?.files?.length ?? 0;
  const branchLabel = currentBranch ?? (status?.detachedHead ? 'detached HEAD' : '—');
  const modalProject =
    projects.find((item) => item.path === modal?.projectPath) ?? project ?? projects[0];

  const composer = (
    <Composer
      runtime={runtime}
      context={context}
      prompt={prompt}
      onPrompt={setPrompt}
      onSend={sendPrompt}
      sending={sending}
      runtimeMenu={runtimeMenu}
      onRuntimeMenu={setRuntimeMenu}
      onOpenContext={() => setModal({ kind: 'context' })}
    />
  );

  const branchGroups = ['本地分支', '远程分支'].map((group) => ({
    group,
    items: (branches ?? []).filter(
      (item) =>
        item.isRemote === (group === '远程分支') &&
        item.name.toLowerCase().includes(branchFilter.toLowerCase()),
    ),
  }));

  function renderWorkbench() {
    if (!project)
      return (
        <div className="empty">
          <Folder size={30} />
          <h3>还没有项目</h3>
          <p>在左侧添加一个目录开始使用</p>
        </div>
      );
    if (notRepository)
      return (
        <div className="empty">
          <GitBranch size={30} />
          <h3>这个目录不是 Git 仓库</h3>
          <p>{tildePath(project.path, state.home)}</p>
        </div>
      );
    if (tab === '工作区')
      return (
        <WorkspaceTab
          key={project.path}
          projectPath={project.path}
          status={status}
          statusError={statusError?.text ?? null}
          stamp={stamp}
          refresh={() => setEpoch((value) => value + 1)}
          notify={notify}
        />
      );
    if (tab === '提交历史')
      return (
        <HistoryTab
          key={project.path}
          projectPath={project.path}
          branch={currentBranch}
          epoch={epoch}
          notify={notify}
        />
      );
    if (tab === '分支')
      return (
        <BranchesTab
          branches={branches}
          branchesError={branchesError}
          currentBranch={currentBranch}
          onNewSession={(mode) => setModal({ kind: 'session', mode, projectPath: project.path })}
          onCheckout={checkoutBranch}
          onBranchContext={openBranchContext}
        />
      );
    if (tab === '工作树')
      return (
        <WorktreeTab
          key={project.path}
          projectPath={project.path}
          home={state.home}
          epoch={epoch}
          runGit={runGit}
          onNewSession={(mode) => setModal({ kind: 'session', mode, projectPath: project.path })}
        />
      );
    return (
      <MoreTab
        key={project.path}
        page={morePage}
        onPage={setMorePage}
        projectPath={project.path}
        epoch={epoch}
        branches={branches}
        currentBranch={currentBranch}
        changed={changedCount}
        log={log}
        runGit={runGit}
      />
    );
  }

  return (
    <div
      className={`app ${settings.density === 'compact' ? 'compact' : ''}`}
      style={{
        '--app-scale': settings.appFontSize / 12,
        '--terminal-font-size': `${settings.termFontSize}px`,
      }}
    >
      <header className="titlebar">
        <div className={`window-brand ${sidebar ? '' : 'sidebar-hidden'}`} data-drag-region>
          <div className="window-controls">
            {!native && (
              <>
                <i />
                <i />
                <i />
              </>
            )}
          </div>
        </div>
        {terminal && workbench && (
          <div
            className="titlebar-spacer"
            data-drag-region
            style={{ flexBasis: `${terminalWidth}%` }}
          />
        )}
        {workbench ? (
          <div className="workbench-header">
            <div className="project-menu-wrap">
              <button
                className="branch-picker"
                aria-label="选择分支"
                title={project ? `${project.title} · ${tildePath(project.path, state.home)}` : ''}
                onClick={() => {
                  setMenu(menu === 'branch' ? null : 'branch');
                  setPickedBranch(currentBranch ?? '');
                  if (menu !== 'branch') loadBranches();
                }}
                onContextMenu={(event) => openBranchContext(event, currentBranch)}
              >
                <GitBranch size={15} />
                <b>{branchLabel}</b>
                <CaretDown size={12} />
              </button>
              {menu === 'branch' && (
                <div
                  className="dropdown project-branch-dropdown"
                  role="dialog"
                  aria-label="项目与分支"
                  data-blocking
                >
                  <div className="branch-project-list">
                    <div className="menu-title">项目</div>
                    {projects.map((item) => (
                      <button
                        key={item.path}
                        className={workbenchPath === item.path ? 'selected' : ''}
                        title={tildePath(item.path, state.home)}
                        onClick={() => {
                          selectProject(item.path);
                          setMenu('branch');
                        }}
                      >
                        {item.isHome ? (
                          <House
                            size={14}
                            weight={workbenchPath === item.path ? 'fill' : 'regular'}
                          />
                        ) : (
                          <Folder
                            size={14}
                            weight={workbenchPath === item.path ? 'fill' : 'regular'}
                          />
                        )}
                        <span>{item.title}</span>
                      </button>
                    ))}
                  </div>
                  <div className="branch-options">
                    <label className="search">
                      <MagnifyingGlass size={13} />
                      <input
                        aria-label="筛选分支"
                        placeholder="筛选分支…"
                        value={branchFilter}
                        onChange={(event) => setBranchFilter(event.target.value)}
                      />
                    </label>
                    {notRepository && <div className="pane-note">这个目录不是 Git 仓库</div>}
                    {branchesError && !notRepository && (
                      <div className="pane-note error">{branchesError}</div>
                    )}
                    {!branches && !branchesError && !notRepository && (
                      <div className="pane-note">正在读取分支…</div>
                    )}
                    {branches &&
                      branchGroups.map(({ group, items }) => (
                        <div key={group}>
                          <div className="menu-title">{group}</div>
                          {items.map((item) => (
                            <button
                              key={item.name}
                              className={`${pickedBranch === item.name ? 'picked' : ''} ${item.isCurrent ? 'current' : ''}`}
                              disabled={gitBusy}
                              onClick={() => {
                                setPickedBranch(item.name);
                                if (settings.followSessionBranch) revealBranch(item.name);
                              }}
                              onDoubleClick={() => checkoutBranch(item.name)}
                              onKeyDown={(event) => {
                                if (event.key === 'Enter') {
                                  event.preventDefault();
                                  checkoutBranch(item.name);
                                }
                              }}
                              onContextMenu={(event) => {
                                setPickedBranch(item.name);
                                openBranchContext(event, item.name);
                              }}
                            >
                              <GitBranch size={14} />
                              <span>{item.name}</span>
                              {item.isCurrent && <Check size={13} />}
                            </button>
                          ))}
                        </div>
                      ))}
                    <div className="branch-picker-hint">双击签出 · 右键更多操作</div>
                  </div>
                </div>
              )}
            </div>
            <nav className="git-nav">
              {tabs.map(([name, Icon]) => (
                <button
                  className={tab === name ? 'selected' : ''}
                  onClick={() => {
                    setTab(name);
                    setMorePage(null);
                  }}
                  key={name}
                >
                  <Icon size={16} />
                  {name}
                  {name === '工作区' && <span>{changedCount}</span>}
                </button>
              ))}
              <IconButton
                icon={ArrowsClockwise}
                label="刷新 Git 状态"
                className={`icon-button ${gitBusy ? 'spinning' : ''}`}
                onClick={() => {
                  setEpoch((value) => value + 1);
                  notify('已刷新 Git 状态');
                }}
              />
            </nav>
            <IconButton
              icon={Minus}
              label="收起工作台 ⌘\"
              onClick={() => updateSettings({ workbench: false })}
            />
          </div>
        ) : (
          <>
            <div className="titlebar-fill" data-drag-region />
            <IconButton
              icon={Code}
              label="展开工作台 ⌘\"
              className="icon-button titlebar-restore"
              onClick={() => updateSettings({ workbench: true })}
            />
          </>
        )}
      </header>
      <div className="layout">
        <Sidebar
          state={state}
          open={sidebar}
          terminalOpen={terminal}
          workbenchPath={workbenchPath}
          treeCursor={treeCursor}
          onCursor={setTreeCursor}
          onToggleSidebar={() => updateSettings({ sidebar: !sidebar })}
          onExpandTerminal={() => updateSettings({ terminal: true })}
          onSelectProject={selectProject}
          onOpenSession={openSession}
          onTreeContext={openTreeContext}
          onAddDirectory={() => setModal({ kind: 'directory' })}
          onSettings={() => setModal({ kind: 'settings' })}
          onNewSession={() =>
            setModal({ kind: 'session', mode: 'current', projectPath: workbenchPath })
          }
          onFocusTerminal={() => request('app.command', { name: 'focusTerminal' })}
        />

        {terminal ? (
          <section
            className="terminal-pane"
            style={{ flexBasis: workbench ? `${terminalWidth}%` : '100%' }}
          >
            <div className="terminal-actions" data-terminal-overlay>
              {active && (
                <IconButton
                  icon={X}
                  label="关闭当前终端 ⌘Esc"
                  onClick={() => request('app.command', { name: 'closeTerminal' })}
                />
              )}
              <IconButton
                icon={CaretDoubleLeft}
                label="收起终端 ⌘J"
                onClick={() => updateSettings({ terminal: false })}
              />
            </div>
            {active && native ? (
              <div className="terminal-hole" data-terminal-hole />
            ) : (
              <div className="terminal-content">
                <div className="terminal-intro">
                  <img src={appIcon} alt="Claude" />
                  <div>
                    <strong>Claude Code</strong>
                    <span>
                      {modelLabel}
                      {sessionProject ? ` · ${sessionProject.title}` : ''}
                    </span>
                  </div>
                </div>
                {active ? (
                  <p className="terminal-user">
                    {active.label} · 终端由 ClaudePicker 原生窗口承载，浏览器预览不显示终端内容。
                  </p>
                ) : (
                  <div className="terminal-empty">
                    <p>展开左侧项目，选一个会话；或直接在下方输入开始新的对话。</p>
                    <small>回车 = 打开 · 右键 = 新建 / 置顶 · 拖拽 = 排序 · ⌘N = 新建会话</small>
                  </div>
                )}
              </div>
            )}
            {!chatMode && <div className="terminal-dock">{composer}</div>}
          </section>
        ) : null}

        {terminal && workbench && (
          <div
            className="resizer"
            role="separator"
            aria-label="拖动调整终端宽度"
            title="左右拖动调整宽度，双击恢复默认"
            onPointerDown={beginResize}
            onDoubleClick={() => updateSettings({ terminalWidth: DEFAULT_TERMINAL_WIDTH })}
          />
        )}

        {workbench ? (
          <main className="workbench">
            {followBanner && (
              <div className="follow-banner" role="status">
                <GitBranch size={14} />
                <span>
                  会话分支 <b>{followBanner.sessionBranch}</b> ≠ 当前分支{' '}
                  <b>{followBanner.currentBranch}</b>
                  {followBanner.reason && <em>（{followBanner.reason}，未自动切换）</em>}
                </span>
                <button
                  className="primary"
                  onClick={async () => {
                    const ok = await runGit(
                      'git.switchBranch',
                      { branch: followBanner.sessionBranch },
                      `已切换到会话分支 ${followBanner.sessionBranch}`,
                    );
                    if (ok) setFollowBanner(null);
                  }}
                >
                  签出 {followBanner.sessionBranch}
                </button>
                <button onClick={() => setFollowBanner(null)}>忽略</button>
              </div>
            )}
            {renderWorkbench()}
          </main>
        ) : (
          <div className="workbench-rail">
            <IconButton
              icon={Code}
              label="展开工作台 ⌘\"
              onClick={() => updateSettings({ workbench: true })}
            />
            <span>工作台</span>
          </div>
        )}
      </div>
      {!terminal &&
        (chatMode ? (
          <button
            className={`composer-bubble ${active?.busy ? 'busy' : ''}`}
            style={{ left: floatingPosition.x, top: floatingPosition.y }}
            aria-label="恢复第二栏"
            title="恢复第二栏 ⌘J"
            onClick={() => updateSettings({ terminal: true })}
          >
            <img src={appIcon} alt="" />
          </button>
        ) : floatingMinimized ? (
          <button
            ref={floatingRef}
            className={`composer-bubble ${active?.busy ? 'busy' : ''}`}
            style={{ left: floatingPosition.x, top: floatingPosition.y }}
            aria-label="展开悬浮输入框"
            title="展开输入框 · 拖动可移动"
            onPointerDown={dragFloating}
            onClick={() => {
              if (floatingDragMoved.current) {
                floatingDragMoved.current = false;
                return;
              }
              setFloatingMinimized(false);
            }}
          >
            <img src={appIcon} alt="" />
          </button>
        ) : (
          <section
            ref={floatingRef}
            className={`floating-composer ${floatingPosition.y < 220 ? 'near-top' : ''}`}
            style={{ left: floatingPosition.x, top: floatingPosition.y }}
            aria-label="悬浮输入框"
          >
            <div className="floating-composer-header" onPointerDown={dragFloating}>
              <img src={appIcon} alt="" />
              {active && <span>{active.label}</span>}
              <small role="status">
                {active?.busy ? '正在思考…' : active ? '当前会话' : '新对话'}
              </small>
              <IconButton
                icon={Minus}
                label="缩小为圆形浮标"
                onClick={() => {
                  setRuntimeMenu(null);
                  floatingDragMoved.current = false;
                  setFloatingMinimized(true);
                }}
              />
              <IconButton
                icon={Terminal}
                label="恢复第二栏 ⌘J"
                onClick={() => updateSettings({ terminal: true })}
              />
            </div>
            {composer}
          </section>
        ))}
      {treeContext && (
        <div
          className="branch-context tree-context"
          role="menu"
          aria-label="项目与会话操作"
          data-blocking
          style={{ left: treeContext.x, top: treeContext.y }}
        >
          <div className="menu-title">
            {treeContext.session?.title ?? treeContext.project.title}
          </div>
          {[
            ['新建对话', false],
            [
              '置顶',
              treeContext.session
                ? treeContext.project.sessions[0]?.id === treeContext.session.id
                : treeContext.project.isHome,
            ],
            ...(!treeContext.session
              ? [
                  [treeContext.project.expanded ? '收起' : '展开', false],
                  ['在访达中显示', false],
                ]
              : []),
            ['从列表移除', !treeContext.session && treeContext.project.isHome],
          ].map(([action, disabled]) => (
            <button
              role="menuitem"
              key={action}
              disabled={disabled}
              onClick={() => treeAction(action)}
            >
              {action}
            </button>
          ))}
        </div>
      )}
      {branchContext && (
        <div
          className="branch-context"
          role="menu"
          aria-label="分支操作"
          data-blocking
          style={{ left: branchContext.x, top: branchContext.y }}
        >
          <div className="menu-title">
            <GitBranch size={13} />
            {branchContext.name}
          </div>
          {[
            ['切换分支', GitBranch, branchContext.name === currentBranch],
            ['获取', ArrowsClockwise, false],
            ['拉取', ArrowDown, false],
            [
              '推送',
              ArrowUp,
              Boolean(branches?.find((item) => item.name === branchContext.name)?.isRemote),
            ],
            ['合并到当前分支', GitMerge, branchContext.name === currentBranch],
          ].map(([action, Icon, disabled]) => (
            <button
              role="menuitem"
              key={action}
              disabled={disabled || gitBusy}
              onClick={() => branchAction(action)}
            >
              <Icon size={14} />
              {action}
            </button>
          ))}
        </div>
      )}
      {runtimeMenu && <i hidden data-blocking />}
      {toast && (
        <div className={`toast ${toast.failed ? 'failed' : ''}`} role="status">
          {toast.failed ? <Warning size={16} /> : <Check size={16} />}
          {toast.text}
        </div>
      )}
      {modal && <i hidden data-blocking />}
      {modal?.kind === 'context' && (
        <ContextModal context={context} modelLabel={modelLabel} onClose={() => setModal(null)} />
      )}
      {modal?.kind === 'mcp' && (
        <McpModal projectPath={workbenchPath} notify={notify} onClose={() => setModal(null)} />
      )}
      {modal?.kind === 'directory' && (
        <DirectoryModal
          notify={notify}
          onClose={() => setModal(null)}
          onAdded={(path) => selectProject(path)}
        />
      )}
      {modal?.kind === 'session' && modalProject && (
        <SessionModal
          project={modalProject}
          home={state.home}
          branch={modalProject.path === workbenchPath ? currentBranch : null}
          isRepository={modalProject.path === workbenchPath ? isRepository : true}
          initialMode={modal.mode}
          notify={notify}
          onClose={() => setModal(null)}
          onCreated={() => {
            if (!settings.terminal) updateSettings({ terminal: true });
            setEpoch((value) => value + 1);
          }}
        />
      )}
      {modal?.kind === 'settings' && (
        <SettingsModal
          settings={settings}
          onChange={updateSettings}
          onOpenMcp={() => setModal({ kind: 'mcp' })}
          onClose={() => setModal(null)}
        />
      )}
    </div>
  );
}
