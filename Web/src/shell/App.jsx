// 应用外壳：标题栏 + 项目侧栏 + 终端栏（原生终端嵌在透明的「洞」下面）+ Git 工作台。
// 结构、文案与交互以 docs/app-layout-prototype 为准；数据全部来自原生桥。
import React, { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import {
  ArrowDown,
  ChatCircleDots,
  ArrowUp,
  ArrowsClockwise,
  CaretDoubleLeft,
  CaretDown,
  Check,
  ClockCounterClockwise,
  Code,
  DotsThree,
  Briefcase,
  ChatsCircle,
  Folder,
  Gear,
  GitBranch,
  GitDiff,
  GitMerge,
  House,
  MagnifyingGlass,
  Minus,
  SquaresFour,
  Terminal,
  Tray,
  TreeStructure,
  Warning,
  X,
} from '@phosphor-icons/react';
import './style.css';
import appIcon from './clawd-mark.png';
import { errorText, isNative, on, request } from './bridge.js';
import { IconButton, tildePath, useStored } from './ui.jsx';
import { resumeCommand } from './session-info.js';
import Sidebar from './Sidebar.jsx';
import {
  GIT_SECTIONS,
  ModuleSidebar,
  SIDEBAR_DEFAULT,
  SidebarResizer,
  WORK_SECTIONS,
  moveNavigation,
  normalizeNavigation,
  tapdSections,
  useNavigationDrag,
} from './ModuleViews.jsx';
import './modules.css';
import Composer, { RuntimeBar } from './Composer.jsx';
import DesktopTerminal from './DesktopTerminal.jsx';
import FloatingConsole, { ConsoleBubble } from './FloatingConsole.jsx';
import DesktopPet from './pet/DesktopPet.jsx';
import { petEvent, usePetSignals } from './pet/usePetSignals.js';
import WorkspaceTab from './WorkspaceTab.jsx';
import { BranchesTab, HistoryTab, MoreTab, WorktreeTab } from './GitPages.jsx';
import { ContextModal, CreateWorktreeModal, DirectoryModal, McpModal, RenameSessionModal, SessionInfoModal, SessionModal } from './Modals.jsx';
import './work/work.css';
import SessionChat from './SessionChat.jsx';
import { DeepSeekBanner } from './work/DeepSeekMaintenance.jsx';
import { needsAttention, useWorks } from './work/useWorks.js';
import WorkChat from './work/WorkChat.jsx';
import ContextPanel from './work/ContextPanel.jsx';
import BoardPage from './work/BoardPage.jsx';
import TapdModule from './work/TapdModule.jsx';
import ReviewTab from './work/ReviewTab.jsx';
import FloatingWork from './work/FloatingWork.jsx';
import SettingsModal from './work/SettingsModal.jsx';
import { ConfirmHost, confirmAction } from './work/confirm.jsx';
import { DeliveryModal, ExportModal, NewWorkModal, SearchModal, SourceModal } from './work/WorkModals.jsx';

const PAGES = [
  ['workspace', '工作空间', ChatsCircle],
  ['tapd', 'TAPD 待办', Tray],
  ['works', 'Work 中心', SquaresFour],
  ['git', '变更', GitDiff],
];

const tabs = [
  ['工作区', GitDiff],
  ['提交历史', ClockCounterClockwise],
  ['分支', GitBranch],
  ['工作树', TreeStructure],
  ['更多', DotsThree],
];

const DEFAULT_TERMINAL_WIDTH = 30;

/// Work 第一栏各分类的数量（docs §6.1）。
export function workSection(work) {
  if (work.archived || work.status === 'completed' || work.status === 'cancelled') return 'ended';
  if (work.status === 'failed' || work.status === 'interrupted') return 'trouble';
  return work.status;
}
function countWorkSections(works) {
  const counts = { all: 0 };
  for (const work of works) {
    const section = workSection(work);
    counts[section] = (counts[section] ?? 0) + 1;
    if (!work.archived) counts.all += 1;
  }
  delete counts.ended;
  return counts;
}
const native = isNative();
if (native) document.documentElement.classList.add('native');

const OPEN_MODE_ACTIONS = { '改用终端打开': 'terminal', '改用结构化聊天': 'structured', '改用 Swttch 图形聊天': 'chat' };
const OPEN_MODE_LABEL = { terminal: '原生终端', structured: '结构化聊天', chat: 'Swttch 图形聊天' };

export default function App() {
  const [state, setState] = useState(null);
  const [settings, setSettings] = useState(null);
  const [workbenchPath, setWorkbenchPath] = useStored('workbenchProject', '');
  const [tab, setTab] = useStored('tab', '工作区');
  const [morePage, setMorePage] = useState(null);

  const [statusResult, setStatus] = useState(null);
  const [statusErrorResult, setStatusError] = useState(null);
  const [stamp, setStamp] = useState(0);
  const [branchesResult, setBranches] = useState(null);
  const [branchesErrorResult, setBranchesError] = useState(null);
  const [epoch, setEpoch] = useState(0);
  const [gitBusy, setGitBusy] = useState(false);
  const gitBusyRef = useRef(false);

  const [menu, setMenu] = useState(null);
  const [branchFilter, setBranchFilter] = useState('');
  const [branchContext, setBranchContext] = useState(null);
  const [treeContext, setTreeContext] = useState(null);
  const [diffWorkspace, setDiffWorkspace] = useState(null);
  const [treeCursor, setTreeCursor] = useState(null);
  const [runtimeMenu, setRuntimeMenu] = useState(null);
  const [modal, setModal] = useState(null);
  useEffect(() => {
    const open = () => setModal({ kind: 'settings', page: 'cli' });
    window.addEventListener('claude-picker:open-cli-settings', open);
    return () => window.removeEventListener('claude-picker:open-cli-settings', open);
  }, []);
  const [toast, setToast] = useState(null);
  const [log, setLog] = useState([]);
  const [followBanner, setFollowBanner] = useState(null);
  const [deepseekReport, setDeepseekReport] = useState(null);

  // ---------- Work ----------
  const { snapshot: workSnap } = useWorks();
  const petSignals = usePetSignals(state, workSnap, settings);
  const [page, setPage] = useStored('page', 'workspace');
  // 模块第一栏的当前分类：TAPD 为 workspace id 或 'all'，Work 为 WORK_SECTIONS 的 id。
  const [sections, setSections] = useStored('moduleSections', { tapd: 'all', works: 'all' });
  // 第一栏宽度按模块分别记忆（180–360，默认 248）。
  const [sidebarWidths, setSidebarWidths] = useStored('sidebarWidths', {});
  const [tapdConfig, setTapdConfig] = useState(null);
  const [selectedWorkId, setSelectedWorkId] = useStored('selectedWork', null);
  const [contextTab, setContextTab] = useState('context');
  const [reviewFile, setReviewFile] = useState(null);
  const [workModal, setWorkModal] = useState(null);
  const [tapdFocus, setTapdFocus] = useState(null);
  const [workFocus, setWorkFocus] = useState(null);
  // TAPD / Work 第一栏的搜索框内容（不持久化）。
  const [moduleQuery, setModuleQuery] = useState({ tapd: '', works: '' });
  const tapdSubmit = useRef(null);
  const layoutApplied = useRef(false);
  const selectedWork = workSnap.works.find((item) => item.id === selectedWorkId) ?? null;

  const [prompt, setPrompt] = useState('');
  const [sending, setSending] = useState(false);
  const [context, setContext] = useState(null);

  // 悬浮终端是否展开（收起后只能从桌宠或圆形浮标重新打开）。
  const [consoleOpen, setConsoleOpen] = useStored('consoleOpen', false);
  const toastTimer = useRef(0);
  const terminalVisibleRef = useRef(false);
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

  // ---------- 顶部页签 ----------
  const navigation = normalizeNavigation(settings?.navigation);
  const visiblePages = navigation
    .filter((item) => item.visible)
    .map((item) => PAGES.find(([id]) => id === item.id))
    .filter(Boolean);
  const visibleKey = visiblePages.map(([id]) => id).join(',');
  const setNavigation = useCallback(
    (next) => updateSettings({ navigation: normalizeNavigation(next) }),
    [updateSettings],
  );
  const navigationDrag = useNavigationDrag((from, to) => setNavigation(moveNavigation(navigation, from, to)));
  /// 让某个页签可见（只有在还有其它页签可见时才改；全部隐藏时保持全部隐藏）。
  function revealPage(id) {
    if (!navigation.some((item) => item.visible)) return;
    if (navigation.find((item) => item.id === id)?.visible) return;
    setNavigation(navigation.map((item) => (item.id === id ? { ...item, visible: true } : item)));
  }

  // 当前页签被隐藏：切到剩余顺序里的第一个。全部隐藏时回到工作空间。
  useEffect(() => {
    if (!settings) return;
    if (!visiblePages.some(([id]) => id === page)) setPage(visiblePages[0]?.[0] ?? 'workspace');
  }, [visibleKey, page, Boolean(settings)]);

  // 刚进入「全部隐藏」：回到工作空间默认两栏（只执行一次）。
  const allHiddenApplied = useRef(false);
  useEffect(() => {
    if (!settings) return;
    if (visiblePages.length) {
      allHiddenApplied.current = false;
      return;
    }
    if (allHiddenApplied.current) return;
    allHiddenApplied.current = true;
    setPage('workspace');
    setSelectedWorkId(null);
    updateSettings({ sidebar: true, terminal: true, workbench: false });
  }, [visibleKey, Boolean(settings)]);

  // TAPD 第一栏：设置里启用的项目。
  const loadTapdConfig = useCallback(() => {
    request('tapd.settings')
      .then(setTapdConfig)
      .catch(() => setTapdConfig(null));
  }, []);
  useEffect(() => {
    loadTapdConfig();
  }, []);

  // 默认布局 B（任务看板）：启动时先进入 Work 中心。只在启动时应用一次，不改变之后的手动切换。
  useEffect(() => {
    if (!settings || layoutApplied.current) return;
    layoutApplied.current = true;
    if (settings.layout === 'B') setPage('works');
  }, [settings]);

  const projects = state?.projects ?? [];
  const active = state?.active ?? null;
  const project = projects.find((item) => item.path === workbenchPath) ?? null;
  const gitPath = diffWorkspace?.projectPath === workbenchPath ? diffWorkspace.worktree : workbenchPath;
  const [worktreesByProject, setWorktreesByProject] = useState({});
  const projectPaths = JSON.stringify(projects.filter((item) =>
    !item.isHome && (item.expanded || item.path === workbenchPath)).map((item) => item.path));
  useEffect(() => {
    let cancelled = false;
    Promise.all(JSON.parse(projectPaths).map(async (projectPath) => {
      try {
        const list = await request('git.worktrees', { projectPath });
        return [projectPath, list.filter((item, index) => index !== 0 && item.path !== projectPath && !item.isPrunable && !item.isBare)];
      } catch {
        return [projectPath, null];
      }
    })).then((entries) => {
      if (!cancelled) setWorktreesByProject(Object.fromEntries(entries));
    });
    return () => { cancelled = true; };
  }, [projectPaths, epoch]);
  const pathRef = useRef(gitPath);
  pathRef.current = gitPath;

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
  const status = statusResult?.path === gitPath ? statusResult.value : null;
  const statusError = statusErrorResult?.path === gitPath ? statusErrorResult.value : null;
  const branches = branchesResult?.path === gitPath ? branchesResult.value : null;
  const branchesError = branchesErrorResult?.path === gitPath ? branchesErrorResult.value : null;
  const navigationRef = useRef(0);
  useEffect(() => { navigationRef.current += 1; }, [gitPath]);

  const statusLoading = useRef(false);
  const loadStatus = useCallback(() => {
    const path = pathRef.current;
    if (!path || statusLoading.current) return;
    statusLoading.current = true;
    const navigation = navigationRef.current;
    request('git.status', { projectPath: path }, { timeoutMs: 60000 })
      .then((snapshot) => {
        if (pathRef.current !== path || navigationRef.current !== navigation) return;
        setStatus({ path, value: snapshot });
        setStatusError(null);
        setStamp((value) => value + 1);
      })
      .catch((error) => {
        if (pathRef.current !== path || navigationRef.current !== navigation) return;
        setStatus(null);
        setStatusError({ path, value: { code: error.code, text: errorText(error) } });
      })
      .finally(() => {
        statusLoading.current = false;
        // 加载期间切了项目：给新项目补一次
        if (pathRef.current !== path || navigationRef.current !== navigation) loadStatus();
      });
  }, []);

  const loadBranches = useCallback(() => {
    const path = pathRef.current;
    if (!path) return;
    const navigation = navigationRef.current;
    request('git.branches', { projectPath: path }, { timeoutMs: 60000 })
      .then((list) => {
        if (pathRef.current !== path || navigationRef.current !== navigation) return;
        setBranches({ path, value: list });
        setBranchesError(null);
      })
      .catch((error) => {
        if (pathRef.current !== path || navigationRef.current !== navigation) return;
        setBranches(null);
        setBranchesError({ path, value: errorText(error) });
      });
  }, []);

  useEffect(() => {
    setStatus(null);
    setStatusError(null);
    setBranches(null);
    setBranchesError(null);
    setFollowBanner((banner) => (banner && banner.projectPath !== workbenchPath ? null : banner));
  }, [gitPath]);

  useEffect(() => {
    if (!gitPath) return;
    loadStatus();
    loadBranches();
  }, [gitPath, epoch]);

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
        // 桌宠的 Git 事件反应（docs §9.5）。
        if (method === 'git.stashSave') petEvent('stash');
        else if (/cherry/i.test(method)) petEvent('cherry');
        else if (method === 'git.push' && params?.force) petEvent('forcepush');
        return true;
      } catch (error) {
        notify(errorText(error), true);
        if (error.code === 'MERGE_CONFLICT') {
          petEvent('conflict');
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
  const wasDetached = useRef(false);
  useEffect(() => {
    const detached = Boolean(status?.detachedHead);
    if (detached && !wasDetached.current) petEvent('detached_long');
    wasDetached.current = detached;
  }, [status?.detachedHead]);
  const isRepository = Boolean(status);
  const notRepository = statusError?.code === 'NOT_A_REPOSITORY';

  function selectProject(path) {
    navigationRef.current += 1;
    setDiffWorkspace(null);
    if (path !== workbenchPath) setWorkbenchPath(path);
    setMenu(null);
    setBranchContext(null);
    setBranchFilter('');
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

  function openTreeContext(event, target, session = null, group = null) {
    event.preventDefault();
    setMenu(null);
    setBranchContext(null);
    setTreeContext({
      project: target,
      session,
      group,
      x: Math.min(event.clientX, window.innerWidth - 218),
      y: Math.max(8, Math.min(event.clientY, window.innerHeight - (session ? 330 : 200))),
    });
  }

  async function handoffSession(sessionId, sourceProvider, targetProvider, projectPath, cwd) {
    if (!sessionId) return;
    try {
      setSelectedWorkId(null);
      revealPage('workspace');
      setPage('workspace');
      if (projectPath && projectPath !== workbenchPath) selectProject(projectPath);
      if (!settings?.terminal) updateSettings({ terminal: true });
      await request(
        'session.handoff',
        { sessionId, sourceProvider, targetProvider, projectPath, cwd },
        { timeoutMs: 90000 },
      );
      const targetName = targetProvider === 'antigravity' ? 'Antigravity' : 'Claude Code';
      notify(`已生成前情摘要并转到 ${targetName} 继续`);
    } catch (error) {
      notify(errorText(error), true);
    }
  }

  async function openBranchDiff(target, group) {
    if (!group?.branch && !group?.worktree) return;
    const navigation = ++navigationRef.current;
    try {
      const cwd = group.worktree ?? target.path;
      const status = await request('git.status', { projectPath: cwd });
      if (navigationRef.current !== navigation) return;
      if (!group.worktree && status.branch !== group.branch) {
        await request('git.switchWorkspaceBranch', { projectPath: cwd, branch: group.branch });
      }
      if (navigationRef.current !== navigation) return;
      selectProject(target.path);
      setDiffWorkspace(group.worktree ? { projectPath: target.path, worktree: cwd } : null);
      setSelectedWorkId(null);
      revealPage('workspace');
      setPage('workspace');
      setTab('工作区');
      setConsoleOpen(false);
      updateSettings({ terminal: false, workbench: true });
      setEpoch((value) => value + 1);
    } catch (error) {
      notify(errorText(error), true);
    }
  }

  async function copyTreeValue(value, label, sessionInfo = null) {
    if (!value) return;
    try {
      await request('app.copyText', { text: value });
      notify(`已复制${label}`);
    } catch {
      if (sessionInfo) setModal({ kind: 'session-info', ...sessionInfo });
      notify('无法写入剪贴板，请手动复制', true);
    }
  }

  function openModeMenu(session) {
    const provider = session.provider ?? 'claude';
    const supported = settings.cliPreferences?.[provider]?.modes ?? ['terminal'];
    const current = session.openMode ?? 'terminal';
    return Object.entries(OPEN_MODE_ACTIONS)
      .filter(([, mode]) => mode !== current && supported.includes(mode))
      .map(([label]) => [label, !session.originalSessionId]);
  }

  async function switchOpenMode(session, mode) {
    if (session.running) {
      const ok = await confirmAction({
        title: '切换打开方式',
        text: '这条会话的当前回合还在进行。切换前会先中断这一轮并等待执行器释放会话，未完成的输出不会继续。',
        confirmLabel: '中断并切换',
        cancelLabel: '取消',
      });
      if (!ok) return;
    }
    notify(`正在切换为「${OPEN_MODE_LABEL[mode]}」…`);
    try {
      await request('session.setOpenMode', { sessionId: session.id, mode }, { timeoutMs: 45000 });
      notify(`已用「${OPEN_MODE_LABEL[mode]}」打开`);
    } catch (cause) {
      notify(`切换失败，已保留原界面：${errorText(cause)}`, true);
    }
  }

  function treeAction(action) {
    const { project: target, session, group } = treeContext;
    setTreeContext(null);
    if (action === '复制分支名') { copyTreeValue(group?.branch, '分支名'); return; }
    if (action === '复制工作目录') { copyTreeValue(group?.worktree ?? target.path, '工作目录'); return; }
    if (session && ['查看会话信息', '复制会话 ID', '复制恢复命令'].includes(action)) {
      const info = { session, projectPath: target.path };
      if (action === '查看会话信息') setModal({ kind: 'session-info', ...info });
      if (action === '复制会话 ID') copyTreeValue(session.originalSessionId, '会话 ID', info);
      if (action === '复制恢复命令') copyTreeValue(resumeCommand(session.provider ?? 'claude', session.originalSessionId), '恢复命令', info);
      return;
    }
    if (action === '在工作区查看 Diff') {
      openBranchDiff(target, group);
      return;
    }
    if (action === '创建工作树') {
      setModal({ kind: 'create-worktree', projectPath: target.path });
      return;
    }
    if (action === '新建对话') {
      if (!group) selectProject(target.path);
      if (!target.expanded) request('app.toggleProject', { path: target.path });
      setModal({ kind: 'session', mode: 'current', projectPath: target.path,
        workspace: group ? { branch: group.branch, worktreePath: group.worktree } : null });
      return;
    }
    if (session && OPEN_MODE_ACTIONS[action]) {
      switchOpenMode(session, OPEN_MODE_ACTIONS[action]);
      return;
    }
    if (action === '重命名' && session) setModal({ kind: 'rename', session });
    if (action === '转到 Antigravity 继续' && session) {
      handoffSession(session.id, session.provider ?? 'claude', 'antigravity', target.path, session.cwd);
    }
    if (action === '转到 Claude Code 继续' && session) {
      handoffSession(session.id, session.provider ?? 'antigravity', 'claude', target.path, session.cwd);
    }
    if (action === '作为 Work 继续' && session) {
      setWorkModal({
        kind: 'new',
        adopt: {
          sessionId: session.id,
          cwd: session.cwd,
          label: session.title,
          projectPath: target.path,
          provider: session.provider ?? 'claude',
        },
      });
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

  function openWork(id) {
    setSelectedWorkId(id);
    revealPage('workspace');
    setPage('workspace');
    setReviewFile(null);
    if (settings && !settings.terminal) updateSettings({ terminal: true });
  }

  function openWorkByDisplayId(displayId) {
    const found = workSnap.works.find((item) => item.displayId.toLowerCase() === String(displayId).toLowerCase());
    if (found) openWork(found.id);
    else notify(`没有找到 ${displayId}`, true);
  }

  function openSession(target, session) {
    const provider = session.provider ?? 'claude';
    if (settings.cliPreferences?.[provider]?.enabled === false) {
      const engine = state.providers?.find((item) => item.id === provider)?.label ?? provider;
      notify(`${engine} 已停用，请在 CLI 引擎设置中启用。`, true);
      return;
    }
    setSelectedWorkId(null);
    revealPage('workspace');
    setPage('workspace');
    selectProject(target.path);
    const tree = worktreesByProject[target.path]?.find((item) =>
      session.cwd === item.path || session.cwd?.startsWith(item.path + '/'));
    if (tree) setDiffWorkspace({ projectPath: target.path, worktree: tree.path });
    if (!settings.terminal) updateSettings({ terminal: true });
    request('session.open', {
      projectPath: target.path,
      cwd: session.cwd,
      sessionId: session.id,
      provider,
    }).catch((error) => notify(errorText(error), true));
  }

  /// 回到工作空间并展开第二栏终端（模块侧栏 / 悬浮终端 / 桌宠 / ⌘J 共用）。
  function restoreTerminal() {
    setSelectedWorkId(null);
    revealPage('workspace');
    setPage('workspace');
    if (!settings.terminal) updateSettings({ terminal: true });
  }

  function selectPageAt(index) {
    const target = visiblePages[index];
    if (target) setPage(target[0]);
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
    toggleTerminal: () => (terminalVisibleRef.current ? updateSettings({ terminal: false }) : restoreTerminal()),
    // 桌面桌宠悬浮窗的操作（原生先把主窗口带到前台）。
    petClick: () => {
      if (terminalVisibleRef.current) request('app.command', { name: 'focusTerminal' }).catch(() => {});
      else setConsoleOpen(true);
    },
    openConsole: () => {
      if (terminalVisibleRef.current) updateSettings({ terminal: false });
      setConsoleOpen(true);
    },
    restoreTerminal: () => restoreTerminal(),
    openPetSettings: () => setModal({ kind: 'settings', page: 'pet' }),
    page1: () => selectPageAt(0),
    page2: () => selectPageAt(1),
    page3: () => selectPageAt(2),
    page4: () => selectPageAt(3),
    toggleSidebar: () => updateSettings({ sidebar: !settings.sidebar }),
    toggleWorkbench: () => updateSettings({ workbench: !settings.workbench }),
    openSettings: () => setModal({ kind: 'settings' }),
    search: () => setWorkModal({ kind: 'search' }),
    focusTree: () =>
      (
        document.querySelector('.session-row.selected') ?? document.querySelector('.project-row')
      )?.focus(),
  };

  const workCommands = useRef({});
  workCommands.current = {
    openByDisplayId: openWorkByDisplayId,
    heldByWork: (sessionId) => {
      const owner = workSnap.works.find((item) => item.sessionId === sessionId);
      notify('这个会话正由 Work 执行器使用，已切换到对应的 Work', false);
      if (owner) openWork(owner.id);
    },
  };

  useEffect(() => {
    const offCommand = on('command', (detail) => {
      if (detail.name === 'openWork') return workCommands.current.openByDisplayId(detail.displayId);
      if (detail.name === 'sessionHeldByWork') return workCommands.current.heldByWork(detail.sessionId);
      if (detail.name === 'deepseekMaintenance' && detail.report) {
        setDeepseekReport(detail.report);
        return;
      }
      if (detail.name === 'structuredFallback') {
        notify(`${detail.provider ?? 'CLI'} 结构化聊天未能启动，已改用终端：${detail.message ?? ''}`, true);
        return;
      }
      if (detail.name === 'toast' && detail.text) {
        notify(detail.text, true);
        return;
      }
      if (detail.name === 'chatFallbackForProvider') {
        notify(`${detail.provider ?? 'Antigravity'} 会话暂不支持图形聊天，已自动用原生终端打开`);
        return;
      }
      if (detail.name === 'runtimeSavedNextLaunch') {
        if (detail.text) notify(detail.text);
        return;
      }
      toggles.current[detail.name]?.();
    });
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
      if ((!native || window.claudeDesktop) && (event.metaKey || event.ctrlKey)) {
        const command = {
          n: 'newSession',
          j: 'toggleTerminal',
          b: 'toggleSidebar',
          1: 'page1',
          2: 'page2',
          3: 'page3',
          4: 'page4',
        }[event.key];
        if (command) {
          event.preventDefault();
          toggles.current[command]();
        }
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        toggles.current.search?.();
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
    // 自己管位置的浮层（悬浮终端、桌宠）移动后发这个事件，原生据此重新摆放终端与可点区域。
    window.addEventListener('claude-picker:layout', reportLayout);
    return () => {
      window.removeEventListener('resize', reportLayout);
      window.removeEventListener('claude-picker:layout', reportLayout);
    };
  }, [reportLayout]);

  function beginResize(event) {
    if (event.button !== 0) return;
    const handle = event.currentTarget;
    const body = handle.parentElement;
    handle.setPointerCapture(event.pointerId);
    let latest = settings.terminalWidth;
    handle.onpointermove = (move) => {
      const rect = body.getBoundingClientRect();
      const firstColumn = settings.sidebar ? sidebarWidths[page] || SIDEBAR_DEFAULT : 48;
      latest = Math.max(
        24,
        Math.min(
          57,
          ((move.clientX - rect.left - firstColumn) / (rect.width - firstColumn)) * 100,
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
  const sidebarWidth = sidebarWidths[page] || SIDEBAR_DEFAULT;
  const terminalVisible = page === 'workspace' && terminal && !selectedWork;
  terminalVisibleRef.current = terminalVisible;
  // 悬浮终端：第二栏终端不可见时可用；选中 Work 且收起对话时沿用 FloatingWork。
  // 原生终端（非图形聊天）：终端下方挂运行参数条。
  const runtimeBar = (
    <RuntimeBar
      runtime={state.runtime}
      providers={state.providers ?? []}
      active={active}
      runtimeMenu={runtimeMenu}
      onRuntimeMenu={setRuntimeMenu}
      onHandoff={(targetProv) =>
        active &&
        handoffSession(
          active.sessionId,
          active.provider ?? 'claude',
          targetProv,
          active.projectPath,
          active.cwd,
        )
      }
    />
  );
  const consoleAllowed = !terminalVisible && !(page === 'workspace' && selectedWork && !terminal);
  const petOn = settings.pet?.enabled !== false;
  // macOS 原生由桌面悬浮窗显示桌宠（state.desktopPet），主窗口里不再画一份。
  const petEnabled = petOn && !state.desktopPet;
  const structuredActive = active?.surface === 'structured';
  // 右上角的打开方式切换：终端 ↔ 结构化聊天（引擎不支持结构化聊天或尚无原始 ID 时不显示）。
  const activeModes = settings.cliPreferences?.[active?.provider ?? 'claude']?.modes ?? ['terminal'];
  const surfaceToggle = !active || !active.sessionId || active.sessionId.startsWith('pending-')
    ? null
    : structuredActive
      ? { mode: 'terminal', icon: Terminal, label: '切换为终端' }
      : activeModes.includes('structured')
        ? { mode: 'structured', icon: ChatCircleDots, label: '切换为结构化聊天' }
        : null;
  async function switchSurfaceOfActive(mode) {
    if (!active) return;
    if (active.busy) {
      const ok = await confirmAction({
        title: '切换打开方式',
        text: '当前回合还在进行。切换前会先中断这一轮并等待执行器释放会话。',
        confirmLabel: '中断并切换',
        cancelLabel: '取消',
      });
      if (!ok) return;
    }
    try {
      await request('session.setOpenMode', { sessionId: active.sessionId, mode }, { timeoutMs: 45000 });
    } catch (cause) {
      notify(`切换失败，已保留原界面：${errorText(cause)}`, true);
    }
  }
  const consoleTerminal =
    structuredActive ? (
      <SessionChat sessionId={active.sessionId} provider={active.provider} label={active.label}
        supportedModes={settings.cliPreferences?.[active.provider]?.modes ?? ['terminal']} />
    ) : active && window.claudeDesktop ? (
      <DesktopTerminal sessionId={active.sessionId} fontSize={settings.termFontSize} provider={active.provider} />
    ) : active && native ? (
      consoleOpen && consoleAllowed ? <div className="terminal-hole" data-terminal-hole /> : null
    ) : (
      <div className="console-placeholder">
        {active ? `${active.label} · 终端由 ClaudePicker 原生窗口承载，浏览器预览不显示终端内容。` : '还没有打开会话。'}
      </div>
    );
  function openConsoleFromPet() {
    // 第二栏终端可见时只聚焦它（Q11）；否则打开悬浮终端。
    if (terminalVisible) {
      request('app.command', { name: 'focusTerminal' }).catch(() => {});
      return;
    }
    setConsoleOpen(true);
  }
  const showTopnav = visiblePages.length > 0 && !(visiblePages.length === 1 && visiblePages[0][0] === 'workspace');
  const tapdWorkspaces = (tapdConfig?.settings?.enabled ? tapdConfig.settings.workspaces ?? [] : []).filter(
    (item) => item.enabled !== false,
  );
  // 图形聊天模式：第二栏里是 Swttch 自己的输入区（仅 Claude 会话走图形聊天，Antigravity 自动回退原生终端）。
  // 打开方式按会话决定：结构化聊天与 Swttch 都自带输入区，不再显示外壳输入区和终端运行参数。
  const chatMode = active
    ? active.surface === 'chat' || active.surface === 'structured'
    : settings.interactionMode === 'chat' && (state.runtime?.provider ?? 'claude') === 'claude';
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
      providers={state.providers ?? []}
      active={active}
      context={context}
      prompt={prompt}
      onPrompt={setPrompt}
      onSend={sendPrompt}
      sending={sending}
      runtimeMenu={runtimeMenu}
      onRuntimeMenu={setRuntimeMenu}
      onOpenContext={() => setModal({ kind: 'context' })}
      onHandoff={(targetProv) =>
        active &&
        handoffSession(
          active.sessionId,
          active.provider ?? 'claude',
          targetProv,
          active.projectPath,
          active.cwd,
        )
      }
    />
  );

  const branchGroups = ['本地分支', '远程分支'].map((group) => ({
    group,
    items: (branches ?? []).filter(
      (item) =>
        item.isRemote === (group === '远程分支') &&
        item.name.toLowerCase().includes(branchFilter.trim().toLowerCase()),
    ),
  }));

  function chooseBranch(item) {
    if (!item) return;
    if (item.isCurrent) { setMenu(null); return; }
    checkoutBranch(item.name);
  }

  function branchPickerKeys(event) {
    if (event.key === 'Escape') {
      event.stopPropagation();
      setMenu(null);
      event.currentTarget.parentElement.querySelector('.branch-picker')?.focus();
      return;
    }
    const buttons = [...event.currentTarget.querySelectorAll('[data-branch-option]:not(:disabled)')];
    if (event.key === 'Enter' && event.target.tagName === 'INPUT') {
      event.preventDefault();
      buttons[0]?.click();
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const index = buttons.indexOf(event.target);
      if (event.key === 'ArrowUp' && index === 0) {
        event.currentTarget.querySelector('input')?.focus();
        return;
      }
      const next = index + (event.key === 'ArrowDown' ? 1 : -1);
      buttons[Math.max(0, Math.min(buttons.length - 1, next))]?.focus();
    }
  }

  const branchPicker = (
    <div className="project-menu-wrap cli-branch-picker">
      <label className="cli-project-picker">
        <Folder size={14} />
        <select aria-label="选择项目" value={workbenchPath}
          onChange={(event) => selectProject(event.target.value)}>
          {projects.map((item) => <option key={item.path} value={item.path}>{item.title}</option>)}
        </select>
      </label>
      <button
        className="branch-picker"
        aria-label="选择分支"
        aria-expanded={menu === 'branch'}
        title={gitPath}
        onClick={() => {
          if (menu === 'branch') { setMenu(null); return; }
          setBranchFilter('');
          setMenu('branch');
          loadBranches();
        }}
        onContextMenu={(event) => openBranchContext(event, currentBranch)}
      >
        <GitBranch size={15} /><b>{branchLabel}</b><CaretDown size={12} />
      </button>
      {menu === 'branch' && (
        <div className="dropdown project-branch-dropdown cli-branch-menu" role="dialog"
          aria-label="切换分支" data-blocking onKeyDown={branchPickerKeys}>
          <div className="branch-options">
            <label className="search">
              <MagnifyingGlass size={13} />
              <input autoFocus aria-label="搜索分支" placeholder="搜索本地或远程分支…"
                value={branchFilter} onChange={(event) => setBranchFilter(event.target.value)} />
            </label>
            {notRepository && <div className="pane-note">这个目录不是 Git 仓库</div>}
            {branchesError && !notRepository && <div className="pane-note error">{branchesError}</div>}
            {!branches && !branchesError && !notRepository && <div className="pane-note">正在读取分支…</div>}
            {branches && !branchesError && !notRepository && branchGroups.every(({ items }) => !items.length) && (
              <div className="pane-note">没有匹配的分支</div>
            )}
            {branches && branchGroups.filter(({ items }) => items.length).map(({ group, items }) => (
              <div key={group}>
                <div className="menu-title">{group}</div>
                {items.map((item) => (
                  <button key={item.name} data-branch-option disabled={gitBusy}
                    className={item.isCurrent ? 'current' : ''} title={item.name}
                    onClick={() => chooseBranch(item)}
                    onContextMenu={(event) => openBranchContext(event, item.name)}>
                    <GitBranch size={14} /><span>{item.name}</span>{item.isCurrent && <Check size={13} />}
                  </button>
                ))}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );

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
          key={gitPath}
          projectPath={gitPath}
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
          onCreateWorktree={() => setModal({ kind: 'create-worktree', projectPath: project.path })}
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

  const attentionCount = workSnap.works.filter(needsAttention).length;
  const workSectionCounts = countWorkSections(workSnap.works);
  const showGitHeader = (page === 'workspace' && !selectedWork && workbench) || (page === 'git' && !selectedWork);
  const contextOpen = settings.contextOpen !== false;
  const contextWidth = settings.contextWidth ?? 330;

  function openSource(work) {
    const ref = work.tapdRefs?.[0];
    if (ref) {
      setTapdFocus({ ...ref });
      setPage('tapd');
    } else if (work.origin === 'wecom') {
      setWorkModal({ kind: 'source', workId: work.id });
    }
  }

  function resizeContext(event) {
    if (event.button !== 0) return;
    const handle = event.currentTarget;
    const container = handle.parentElement.getBoundingClientRect();
    handle.setPointerCapture(event.pointerId);
    let latest = contextWidth;
    handle.onpointermove = (move) => {
      // 详情栏 290–520，同时给对话至少留 360。
      latest = Math.round(Math.max(290, Math.min(520, container.right - move.clientX, container.width - 360)));
      updateSettings({ contextWidth: latest }, false);
    };
    handle.onpointerup = handle.onpointercancel = () => {
      handle.onpointermove = null;
      updateSettings({ contextWidth: latest });
    };
  }

  function renderWorkspaceWork(work) {
    return (
      <main className="main-page work-split">
        {terminal && (
          <WorkChat
            work={work}
            capacity={workSnap.capacity}
            notify={notify}
            focus={settings.layout === 'C'}
            contextOpen={contextOpen}
            onToggleContext={() => updateSettings({ contextOpen: !contextOpen })}
            onCollapse={() => updateSettings({ terminal: false })}
            onOpenReview={() => setPage('git')}
            onOpenSource={() => openSource(work)}
          />
        )}
        {terminal && contextOpen && (
          <div
            className="work-resizer"
            role="separator"
            aria-orientation="vertical"
            aria-label="调整详情栏宽度（方向键调整，双击恢复默认）"
            aria-valuemin={290}
            aria-valuemax={520}
            aria-valuenow={contextWidth}
            tabIndex={0}
            onPointerDown={resizeContext}
            onDoubleClick={() => updateSettings({ contextWidth: 330 })}
            onKeyDown={(event) => {
              if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
              event.preventDefault();
              const next = contextWidth + (event.key === 'ArrowLeft' ? 10 : -10);
              updateSettings({ contextWidth: Math.max(290, Math.min(520, next)) });
            }}
          />
        )}
        {contextOpen && (
          <aside
            className="context-panel"
            style={terminal ? { width: contextWidth } : { flex: 1 }}
            aria-label={`${work.displayId} 详情`}
          >
            <ContextPanel
              work={work}
              active={active}
              project={project}
              gitStatus={status}
              home={state.home}
              tab={contextTab}
              onTab={setContextTab}
              onClose={() => updateSettings({ contextOpen: false })}
              notify={notify}
              onOpenFile={(path) => {
                setReviewFile(path);
                setPage('git');
              }}
              onOpenReview={() => setPage('git')}
              onOpenGit={() => setPage('git')}
              onOpenSource={() => openSource(work)}
              onExport={() => setWorkModal({ kind: 'export', workId: work.id })}
              onOpenTerminal={() => {
                setSelectedWorkId(null);
                request('session.open', {
                  projectPath: work.project?.path,
                  cwd: work.workspacePath,
                  sessionId: work.sessionId,
                  provider: work.executor ?? 'claude',
                }).catch((error) => notify(errorText(error), true));
              }}
              onContinueAsWork={() => {}}
            />
          </aside>
        )}
        {!terminal && !contextOpen && (
          <div className="empty">
            <Briefcase size={30} />
            <h3>对话与详情都已收起</h3>
            <p>可以继续在悬浮输入框里补充说明。</p>
            <div className="settings-inline">
              <button onClick={() => updateSettings({ terminal: true })}>恢复对话</button>
              <button onClick={() => updateSettings({ contextOpen: true })}>显示详情</button>
            </div>
          </div>
        )}
      </main>
    );
  }

  function renderMain(legacy) {
    if (page === 'tapd')
      return (
        <TapdModule
          workspace={sections.tapd ?? 'all'}
          workspaces={tapdWorkspaces}
          config={tapdConfig}
          projects={projects}
          runtime={state.runtime}
          notify={notify}
          focusRef={tapdFocus}
          query={moduleQuery.tapd}
          submitRef={tapdSubmit}
          onOpenSettings={() => setModal({ kind: 'settings', page: 'tapd' })}
          onOpenWork={openWork}
          onWorkCreated={(work) => {
            // 创建任务后进入 Work 中心「全部 Work」，并定位到新卡片（docs §5.4）。
            setSections((current) => ({ ...current, works: 'all' }));
            revealPage('works');
            setPage('works');
            setWorkFocus(work.id);
          }}
        />
      );
    if (page === 'works')
      return (
        <main className="main-page">
          <BoardPage
            snapshot={workSnap}
            notify={notify}
            onOpenWork={(work) => openWork(work.id)}
            onNewWork={() => setWorkModal({ kind: 'new' })}
            onOpenTapd={() => {
              revealPage('tapd');
              setPage('tapd');
            }}
            onExport={(work) => setWorkModal({ kind: 'export', workId: work.id })}
            category={sections.works ?? 'all'}
            focusId={workFocus}
            query={moduleQuery.works}
          />
        </main>
      );
    if (page === 'git') {
      if (selectedWork)
        return (
          <main className="main-page">
            <ReviewTab
              key={selectedWork.id}
              work={selectedWork}
              notify={notify}
              initialFile={reviewFile}
              onDelivery={(target) => setWorkModal({ kind: 'delivery', target, workId: selectedWork.id })}
              onBack={() => setPage('workspace')}
            />
          </main>
        );
      return <main className="workbench">{renderWorkbench()}</main>;
    }
    if (selectedWork) return renderWorkspaceWork(selectedWork);
    return legacy;
  }

  return (
    <div
      data-module={page}
      className={`app module-shell ${sidebar ? '' : 'module-sidebar-collapsed'} ${settings.density === 'compact' ? 'compact' : ''}`}
      style={{
        '--first-sidebar-width': `${sidebarWidth}px`,
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
        {showTopnav && (
          <nav className="topnav" aria-label="工作台导航">
            {visiblePages.map(([id, label, Icon], index) => (
              <button
                key={id}
                data-navigation-id={id}
                data-navigation-group="top"
                aria-label={label}
                className={page === id ? 'active' : ''}
                title={
                  id === 'git' && selectedWork
                    ? `${selectedWork.displayId} 的变更审阅`
                    : `${label}${index < 4 ? ` ⌘${index + 1}` : ''} · 拖动排序`
                }
                onPointerDown={navigationDrag.beginDrag}
                onClick={() => {
                  if (!navigationDrag.wasDragged()) setPage(id);
                }}
              >
                <Icon size={15} />
                <span className="nav-label">{label}</span>
                {id === 'works' && attentionCount > 0 && <span className="nav-count">{attentionCount}</span>}
              </button>
            ))}
          </nav>
        )}
        {showGitHeader ? (
          <div className="workbench-header">
            {page !== 'git' && branchPicker}
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
            {page === 'workspace' && (
              <IconButton
                icon={Minus}
                label="收起工作台 ⌘\"
                onClick={() => updateSettings({ workbench: false })}
              />
            )}
          </div>
        ) : (
          <div className="titlebar-fill" data-drag-region />
        )}
        <div className="titlebar-end">
          {page === 'workspace' && !selectedWork && !workbench && (
            <IconButton icon={Code} label="展开工作台 ⌘\\" onClick={() => updateSettings({ workbench: true })} />
          )}
          <IconButton icon={Gear} label="设置 ⌘," onClick={() => setModal({ kind: 'settings' })} />
        </div>
      </header>
      <div className="layout">
        {page === 'workspace' ? (
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
            worktreesByProject={worktreesByProject}
            onBranchTreeContext={(event, target, group) => openTreeContext(event, target, null, group)}
            onAddDirectory={() => setModal({ kind: 'directory' })}
            onSettings={() => setModal({ kind: 'settings' })}
            onNewSession={() =>
              setModal({ kind: 'session', mode: 'current', projectPath: workbenchPath })
            }
            onFocusTerminal={() => request('app.command', { name: 'focusTerminal' })}
            works={workSnap.works}
            workSessionIds={workSnap.workSessionIds}
            selectedWorkId={page === 'workspace' || page === 'git' ? selectedWorkId : null}
            onOpenWork={openWork}
            onSearch={() => setWorkModal({ kind: 'search' })}
            providerFilter={settings.providerFilter ?? 'all'}
            onProviderFilter={(value) => updateSettings({ providerFilter: value })}
          />
        ) : (
          <ModuleSidebar
            page={page}
            items={
              page === 'tapd' ? tapdSections(tapdWorkspaces) : page === 'works' ? WORK_SECTIONS : GIT_SECTIONS
            }
            section={page === 'git' ? tab : sections[page] ?? 'all'}
            counts={page === 'works' ? workSectionCounts : {}}
            collapsed={!sidebar}
            onToggle={() => updateSettings({ sidebar: !sidebar })}
            onSection={(section) => {
              if (page === 'git') {
                setTab(section);
                setMorePage(null);
              } else setSections((current) => ({ ...current, [page]: section }));
            }}
            onSettings={() => setModal({ kind: 'settings' })}
            terminalVisible={terminalVisible}
            onTerminal={restoreTerminal}
            branchControls={page === 'git' ? branchPicker : null}
            search={
              page === 'tapd'
                ? {
                    label: '搜索 TAPD 任务',
                    placeholder: '搜索任务名称或 ID，编号回车查询',
                    value: moduleQuery.tapd,
                    onChange: (value) => setModuleQuery((current) => ({ ...current, tapd: value })),
                    onSubmit: (value) => tapdSubmit.current?.(value),
                  }
                : page === 'works'
                  ? {
                      label: '搜索 Work',
                      placeholder: '搜索名称、编号或 TAPD ID',
                      value: moduleQuery.works,
                      onChange: (value) => setModuleQuery((current) => ({ ...current, works: value })),
                    }
                  : null
            }
          />
        )}
        {sidebar && (
          <SidebarResizer
            width={sidebarWidth}
            onChange={(value) => setSidebarWidths((current) => ({ ...current, [page]: value }))}
          />
        )}

        {renderMain(
          <>
        {terminal ? (
          <section
            className={`terminal-pane${(active ? active.provider : state.runtime?.provider) === 'antigravity' ? ' is-antigravity' : ''}`}
            style={{ flexBasis: workbench ? `${terminalWidth}%` : '100%' }}
          >
            <div className="terminal-actions" data-terminal-overlay>
              {active && surfaceToggle && (
                <IconButton
                  icon={surfaceToggle.icon}
                  label={surfaceToggle.label}
                  onClick={() => switchSurfaceOfActive(surfaceToggle.mode)}
                />
              )}
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
            {structuredActive ? (
              <SessionChat sessionId={active.sessionId} provider={active.provider} label={active.label}
        supportedModes={settings.cliPreferences?.[active.provider]?.modes ?? ['terminal']} />
            ) : active && window.claudeDesktop ? (
              <DesktopTerminal sessionId={active.sessionId} fontSize={settings.termFontSize} provider={active.provider} />
            ) : active && native ? (
              <div className="terminal-hole" data-terminal-hole />
            ) : (
              <div className="terminal-content">
                <div className="terminal-intro">
                  <img src={appIcon} alt="CLI" />
                  <div>
                    <strong>{state.providers?.find((engine) => engine.id === runtime?.provider)?.label ?? 'CLI'}</strong>
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
            {!chatMode && !native && !window.claudeDesktop && <div className="terminal-dock">{composer}</div>}
            {!chatMode && (native || window.claudeDesktop) && runtimeBar}
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
        ) : null}
          </>,
        )}
      </div>
      {page === 'workspace' && selectedWork && !terminal && (
        <FloatingWork work={selectedWork} onRestore={() => updateSettings({ terminal: true })} />
      )}
      {consoleAllowed && (
        <FloatingConsole
          open={consoleOpen}
          onClose={() => setConsoleOpen(false)}
          title={active?.label ?? '新对话'}
          status={active?.busy ? '正在思考…' : active ? '当前会话' : null}
          composer={composer}
          terminal={consoleTerminal}
          footer={!chatMode && (native || window.claudeDesktop) ? runtimeBar : null}
          onRestore={() => {
            setConsoleOpen(false);
            restoreTerminal();
          }}
        />
      )}
      {consoleAllowed && !consoleOpen && !petOn && (
        <ConsoleBubble busy={active?.busy} onOpen={() => setConsoleOpen(true)} />
      )}
      {petEnabled && (
        <DesktopPet
          settings={settings.pet}
          onChange={(patch) => updateSettings({ pet: { ...settings.pet, ...patch } })}
          signals={petSignals}
          onClick={openConsoleFromPet}
          onOpenConsole={() => {
            if (terminalVisible) updateSettings({ terminal: false });
            setConsoleOpen(true);
          }}
          onOpenSession={restoreTerminal}
          onSettings={() => setModal({ kind: 'settings', page: 'pet' })}
          onOpenTarget={(target) => (target?.displayId ? openWorkByDisplayId(target.displayId) : restoreTerminal())}
        />
      )}
      {treeContext && (
        <div
          className="branch-context tree-context"
          role="menu"
          aria-label="项目与会话操作"

          data-blocking
          style={{ left: treeContext.x, top: treeContext.y }}
        >
          <div className="menu-title">
            {treeContext.group?.branch ?? treeContext.session?.title ?? treeContext.project.title}
          </div>
          {(treeContext.group ? [
            ['新建对话', !treeContext.group.branch && !treeContext.group.worktree],
            ['在工作区查看 Diff', !treeContext.group.branch && !treeContext.group.worktree],
            ['复制分支名', !treeContext.group.branch],
            ['复制工作目录', false],
          ] : [
            ['新建对话', false],
            ...(!treeContext.session && !treeContext.project.isHome ? [['创建工作树', false]] : []),
            ...(treeContext.session
              ? [
                  ['重命名', false],
                  ['查看会话信息', false],
                  ['复制会话 ID', !treeContext.session.originalSessionId],
                  ['复制恢复命令', !resumeCommand(treeContext.session.provider ?? 'claude', treeContext.session.originalSessionId)],
                  ...openModeMenu(treeContext.session),
                  ...(['codex', 'dsh'].includes(treeContext.session.provider) ? [] : [[
                    (treeContext.session.provider ?? 'claude') === 'antigravity'
                      ? '转到 Claude Code 继续'
                      : '转到 Antigravity 继续',
                    (state.providers ?? []).length > 0 &&
                      !(state.providers ?? []).some(
                        (p) =>
                          p.id ===
                            ((treeContext.session.provider ?? 'claude') === 'antigravity'
                              ? 'claude'
                              : 'antigravity') && p.available,
                      ),
                    ], ['作为 Work 继续', false]]),
                ]
              : []),
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
          ]).map(([action, disabled]) => (
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
      {modal?.kind === 'create-worktree' && modalProject && (
        <CreateWorktreeModal projectPath={modalProject.path}
          projects={projects.filter((item) => !item.isHome)}
          settings={settings} providers={state.providers ?? []}
          onClose={() => setModal(null)}
          onCreated={(result, path) => {
            if (path !== workbenchPath) selectProject(path);
            if (result.sessionId && !settings.terminal) updateSettings({ terminal: true });
            setEpoch((value) => value + 1);
            notify(result.sessionId ? '已创建工作树并打开会话' : '已创建工作树');
          }} />
      )}
      {modal?.kind === 'session' && modalProject && (
        <SessionModal
          project={modalProject}
          home={state.home}
          branch={modalProject.path === workbenchPath ? currentBranch : null}
          workspace={modal.workspace}
          isRepository={modalProject.path === workbenchPath ? isRepository : true}
          initialMode={modal.mode}
          providers={state.providers ?? []}
          cliPreferences={settings.cliPreferences}
          interactionMode={settings.interactionMode}
          defaultProvider={settings.defaultProvider ?? 'claude'}
          notify={notify}
          onClose={() => setModal(null)}
          onCreated={(result) => {
            if (modal.workspace || result.mode === 'worktree') {
              selectProject(modalProject.path);
              setSelectedWorkId(null);
              revealPage('workspace');
              setPage('workspace');
              if (result.cwd !== modalProject.path) setDiffWorkspace({ projectPath: modalProject.path, worktree: result.cwd });
            }
            if (!settings.terminal) updateSettings({ terminal: true });
            setEpoch((value) => value + 1);
          }}
        />
      )}
      {modal?.kind === 'session-info' && (
        <SessionInfoModal session={modal.session} projectPath={modal.projectPath}
          providerLabel={(state.providers ?? []).find((p) => p.id === (modal.session.provider ?? 'claude'))?.label}
          onCopy={copyTreeValue} onClose={() => setModal(null)} />
      )}
      {modal?.kind === 'rename' && (
        <RenameSessionModal session={modal.session} notify={notify} onClose={() => setModal(null)} />
      )}
      {modal?.kind === 'settings' && (
        <SettingsModal
          initialPage={modal.page}
          settings={settings}
          providers={state.providers ?? []}
          capacity={workSnap.capacity}
          projects={projects}
          notify={notify}
          onChange={updateSettings}
          navigation={navigation}
          onNavigationChange={setNavigation}
          onOpenMcp={() => setModal({ kind: 'mcp' })}
          onOpenConversations={() => {
            setModal(null);
            setWorkModal({ kind: 'source' });
          }}
          onClose={() => {
            setModal(null);
            loadTapdConfig();
          }}
        />
      )}
      {workModal?.kind === 'new' && (
        <NewWorkModal
          projects={projects}
          defaultProject={workModal.adopt ? undefined : workbenchPath}
          defaultProvider={settings.defaultProvider ?? 'claude'}
          adopt={workModal.adopt}
          runtime={state.runtime}
          home={state.home}
          notify={notify}
          onClose={() => setWorkModal(null)}
          onCreated={(work) => openWork(work.id)}
        />
      )}
      {workModal?.kind === 'search' && (
        <SearchModal
          state={state}
          works={workSnap.works}
          onClose={() => setWorkModal(null)}
          onOpenWork={(id) => {
            setWorkModal(null);
            openWork(id);
          }}
          onOpenSession={(target, session) => {
            setWorkModal(null);
            openSession(target, session);
          }}
          onOpenProject={(target) => {
            setWorkModal(null);
            setSelectedWorkId(null);
            setPage('workspace');
            selectProject(target.path);
            if (!target.expanded) request('app.toggleProject', { path: target.path });
          }}
        />
      )}
      {workModal?.kind === 'source' && (
        <SourceModal
          work={workSnap.works.find((item) => item.id === workModal.workId) ?? null}
          onClose={() => setWorkModal(null)}
          onOpenWork={(id) => {
            setWorkModal(null);
            openWork(id);
          }}
        />
      )}
      {workModal?.kind === 'delivery' && workSnap.works.some((item) => item.id === workModal.workId) && (
        <DeliveryModal
          work={workSnap.works.find((item) => item.id === workModal.workId)}
          target={workModal.target}
          notify={notify}
          onClose={() => setWorkModal(null)}
        />
      )}
      {workModal?.kind === 'export' && workSnap.works.some((item) => item.id === workModal.workId) && (
        <ExportModal
          work={workSnap.works.find((item) => item.id === workModal.workId)}
          notify={notify}
          onClose={() => setWorkModal(null)}
        />
      )}
      {workModal && <i hidden data-blocking />}
      <ConfirmHost />
      {deepseekReport && <DeepSeekBanner report={deepseekReport} notify={notify} onClose={() => setDeepseekReport(null)} />}

    </div>
  );
}
