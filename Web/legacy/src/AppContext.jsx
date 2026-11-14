import React, { useEffect, useMemo, useSyncExternalStore } from 'react';
import { setSharedActiveProject } from './bridge/active-project.js';
import {
  Folder,
  House,
  CaretDown,
  CaretRight,
  CircleNotch,
  Gear,
  Plus,
  Terminal,
  SidebarSimple,
} from '@phosphor-icons/react';
import { request } from './bridge/client.js';

/* ------------------------------------------------------------------ *
 * 真实数据层
 *
 * 数据源是原生 `Store.projects`（BridgeHandlers+App.swift 的 app.projects /
 * app.sessions），也就是第一栏 SwiftUI 侧栏正在渲染的同一份内存树，所以标题、
 * 相对时间、忙闲标记都由构造保证与第一栏一致，前端不做二次拼装。
 *
 * 浏览器里没有原生桥时，client.js 会自动回落到 mock.js（app.projects /
 * app.sessions 各有 mock 实现），因此 `npm run dev` 依旧可跑，只是演示数据。
 * 两边的字段形状都在 normalize* 里做兼容，组件只认统一形状。
 * ------------------------------------------------------------------ */

const POLL_INTERVAL_MS = 2000;

const EMPTY_SNAPSHOT = {
  projects: [],
  sessions: [],
  loading: true,
  error: null,
  loadedAt: 0,
};

let snapshot = EMPTY_SNAPSHOT;
const dataListeners = new Set();

let pollTimer = null;
let pollUsers = 0;
let inflight = null;

function publish(patch) {
  snapshot = { ...snapshot, ...patch };
  for (const listener of dataListeners) listener();
}

function subscribeData(listener) {
  dataListeners.add(listener);
  return () => {
    dataListeners.delete(listener);
  };
}

function getDataSnapshot() {
  return snapshot;
}

function basename(path) {
  const trimmed = String(path ?? '').replace(/\/+$/, '');
  const index = trimmed.lastIndexOf('/');
  return index >= 0 ? trimmed.slice(index + 1) : trimmed;
}

function shortPath(path) {
  const home = '/Users/';
  const value = String(path ?? '');
  if (!value) return '';
  const match = value.match(new RegExp(`^${home}([^/]+)`));
  if (match) return `~${value.slice(home.length + match[1].length)}`;
  return value;
}

function toEpochSeconds(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  const parsed = Date.parse(String(value ?? ''));
  return Number.isFinite(parsed) ? Math.floor(parsed / 1000) : 0;
}

/**
 * Swift `relativeText(_:)`（main.swift:1029）的等价前端实现。
 * 只在原生没有下发 relativeTime（mock 形状）时用，保证文案口径一致。
 */
function relativeTextFromEpoch(seconds) {
  if (!seconds) return '';
  const delta = Math.max(0, Math.floor(Date.now() / 1000 - seconds));
  if (delta < 60) return '刚刚';
  if (delta < 3600) return `${Math.floor(delta / 60)} 分钟前`;
  if (delta < 86400) return `${Math.floor(delta / 3600)} 小时前`;
  const days = Math.floor(delta / 86400);
  if (days < 30) return `${days} 天前`;
  if (days < 365) return `${Math.floor(days / 30)} 个月前`;
  return `${Math.floor(days / 365)} 年前`;
}

function normalizeProject(raw, index) {
  const path = String(raw?.path ?? '');
  const title = String(raw?.title ?? raw?.label ?? (path ? basename(path) : ''));
  const nested = Array.isArray(raw?.sessions) ? raw.sessions : [];
  return {
    id: raw?.id ?? index,
    path,
    title,
    label: String(raw?.label ?? title),
    subtitle: String(raw?.subtitle ?? path),
    isHome: Boolean(raw?.isHome ?? title === '~'),
    expanded: Boolean(raw?.expanded),
    showAll: Boolean(raw?.showAll),
    sessionCount: Number(raw?.sessionCount ?? nested.length) || 0,
    nestedSessions: nested,
    sessions: [],
  };
}

function normalizeSession(raw, project, index) {
  const epoch = toEpochSeconds(raw?.dateEpoch ?? raw?.date);
  const cwd = String(raw?.cwd ?? project?.path ?? '');
  const title = String(raw?.title ?? '').trim();
  return {
    id: String(raw?.id ?? `${project?.path ?? ''}#${index}`),
    projectPath: String(raw?.projectPath ?? project?.path ?? ''),
    projectTitle: String(raw?.projectTitle ?? project?.title ?? ''),
    title: title || '未命名会话',
    summary: typeof raw?.summary === 'string' && raw.summary ? raw.summary : null,
    cwd,
    epoch,
    relativeTime: String(raw?.relativeTime || relativeTextFromEpoch(epoch)),
    running: Boolean(raw?.running),
    unread: Boolean(raw?.unread),
    live: Boolean(raw?.live),
    mode: String(raw?.mode ?? 'terminal'),
  };
}

/**
 * 把 app.projects 与 app.sessions 拼成侧栏需要的树。
 * 会话集合优先取 app.sessions（扁平、带忙闲），没有命中再退回项目内嵌会话。
 */
function buildTree(rawProjects, rawSessions) {
  const projects = (Array.isArray(rawProjects) ? rawProjects : []).map(normalizeProject);
  const byPath = new Map(projects.map((project) => [project.path, project]));
  const byLabel = new Map(projects.map((project) => [project.title, project]));

  const flat = Array.isArray(rawSessions) ? rawSessions : [];
  const grouped = new Map();
  const all = [];

  flat.forEach((raw, index) => {
    const project =
      (raw?.projectPath && byPath.get(String(raw.projectPath))) ||
      (raw?.cwd && byPath.get(String(raw.cwd))) ||
      (raw?.projectId != null && byLabel.get(String(raw.projectId))) ||
      null;
    const session = normalizeSession(raw, project, index);
    all.push(session);
    if (!session.projectPath) return;
    const list = grouped.get(session.projectPath);
    if (list) list.push(session);
    else grouped.set(session.projectPath, [session]);
  });

  const withSessions = projects.map((project) => {
    // 顺序沿用原生下发的顺序（SessionScanner 的顺序），前端不重排。
    const fromFlat = grouped.get(project.path) ?? [];
    const sessions = fromFlat.length
      ? fromFlat
      : project.nestedSessions.map((raw, index) => normalizeSession(raw, project, index));
    return { ...project, sessions, sessionCount: sessions.length };
  });

  return { projects: withSessions, sessions: all };
}

async function loadProjects() {
  if (inflight) return inflight;
  inflight = (async () => {
    try {
      // 原生侧 `app.projects` 已经把每个项目的会话内嵌（顺序与第一栏一致），
      // 只有 mock 回落（浏览器直开）没有内嵌字段，才再取一次 `app.sessions`。
      // 这样真桥下 2s 轮询只打一个方法，不会每轮重复传整棵会话树。
      const rawProjects = await request('app.projects');
      const hasNested =
        Array.isArray(rawProjects) &&
        rawProjects.some(
          (project) => Array.isArray(project?.sessions) && project.sessions.length > 0,
        );
      const rawSessions = hasNested ? [] : await request('app.sessions');
      const tree = buildTree(rawProjects, rawSessions);
      publish({
        projects: tree.projects,
        sessions: tree.sessions,
        loading: false,
        error: null,
        loadedAt: Date.now(),
      });
      ensureActiveProject(tree.projects);
    } catch (error) {
      publish({
        loading: false,
        error: error instanceof Error ? error : new Error(String(error)),
      });
    } finally {
      inflight = null;
    }
  })();
  return inflight;
}

/* ---------------- 当前项目（第三栏全局唯一） ---------------- */

let activeProjectPath = '';
const activeListeners = new Set();

export function getActiveProjectPath() {
  return activeProjectPath;
}

/// 当前项目变化后广播给桥接层：Git 页 / 文件页用 `dto.onProjectChange` 订阅它重新取数。
/// 程序化切换（首次选项目、第三栏点项目）不会触发 `<select>` 的 change 事件，
/// 所以这里主动广播一次；rAF 是为了等 React 把新的 value 提交到 DOM，
/// 页面在回调里读 `currentProjectId()` 才拿得到新路径。
function broadcastProjectChange() {
  if (typeof document === 'undefined' || typeof requestAnimationFrame !== 'function') return;
  requestAnimationFrame(() => {
    document.dispatchEvent(new CustomEvent('claude-picker:project-change'));
  });
}

export function setActiveProjectPath(path) {
  const next = String(path ?? '');
  if (next === activeProjectPath) return;
  activeProjectPath = next;
  setSharedActiveProject(next);
  for (const listener of activeListeners) listener();
  broadcastProjectChange();
}

function subscribeActive(listener) {
  activeListeners.add(listener);
  return () => {
    activeListeners.delete(listener);
  };
}

function ensureActiveProject(projects) {
  if (!projects.length) return;
  if (activeProjectPath && projects.some((project) => project.path === activeProjectPath)) return;
  const preferred = projects.find((project) => !project.isHome) ?? projects[0];
  setActiveProjectPath(preferred.path);
}

export function useActiveProjectPath() {
  return useSyncExternalStore(subscribeActive, getActiveProjectPath, getActiveProjectPath);
}

/* ---------------- hooks ---------------- */

/**
 * 订阅真实项目树。整棵树的轮询在多组件间共享（引用计数 + 单飞请求），
 * 每 2s 刷新一次；页面隐藏时跳过，回到前台再拉。
 */
export function useProjectTree() {
  const state = useSyncExternalStore(subscribeData, getDataSnapshot, getDataSnapshot);

  useEffect(() => {
    pollUsers += 1;
    loadProjects();
    if (pollUsers === 1) {
      pollTimer = window.setInterval(() => {
        if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return;
        loadProjects();
      }, POLL_INTERVAL_MS);
    }
    return () => {
      pollUsers -= 1;
      if (pollUsers <= 0) {
        pollUsers = 0;
        if (pollTimer) window.clearInterval(pollTimer);
        pollTimer = null;
      }
    };
  }, []);

  return state;
}

export function useActiveProject() {
  const { projects } = useProjectTree();
  const activePath = useActiveProjectPath();
  return useMemo(
    () => projects.find((project) => project.path === activePath) ?? projects[0] ?? null,
    [projects, activePath],
  );
}

/* ---------------- 侧栏 ---------------- */

export function ProjectSidebar({ activeProject, createdSessions = [], onSelectProject }) {
  const { projects, sessions, loading, error } = useProjectTree();
  const activePath = useActiveProjectPath();
  const resolvedActivePath = activePath || String(activeProject ?? '');
  const [collapsed, setCollapsed] = React.useState(() => new Set());
  const [showAll, setShowAll] = React.useState(() => new Set());
  const [pendingKey, setPendingKey] = React.useState('');
  const [actionError, setActionError] = React.useState('');

  // 选中项目时自动展开它（与第一栏一致），之后仍可手动折叠。
  useEffect(() => {
    if (!resolvedActivePath) return;
    setCollapsed((current) => {
      if (!current.has(resolvedActivePath)) return current;
      const next = new Set(current);
      next.delete(resolvedActivePath);
      return next;
    });
  }, [resolvedActivePath]);

  const toggle = (path) => {
    setCollapsed((current) => {
      const next = new Set(current);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  };

  const toggleShowAll = (path) => {
    setShowAll((current) => {
      const next = new Set(current);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  };

  const selectProject = (project) => {
    setActiveProjectPath(project.path);
    onSelectProject?.(project);
  };

  const openSession = async (project, session) => {
    const key = `${project.path}|${session.id}`;
    setPendingKey(key);
    setActionError('');
    try {
      await request('session.open', {
        projectPath: project.path,
        sessionId: session.id,
        cwd: session.cwd || project.path,
      });
      setActiveProjectPath(project.path);
      await loadProjects();
    } catch (failure) {
      setActionError(`打开会话失败：${failure?.message ?? failure}`);
    } finally {
      setPendingKey('');
    }
  };

  const extraByProject = useMemo(() => {
    const map = new Map();
    for (const session of createdSessions) {
      const key = session.projectPath ?? session.projectId;
      if (key == null) continue;
      const list = map.get(String(key));
      if (list) list.push(session);
      else map.set(String(key), [session]);
    }
    return map;
  }, [createdSessions]);

  const extraFor = (project) =>
    extraByProject.get(project.path) ??
    extraByProject.get(String(project.id)) ??
    extraByProject.get(project.title) ??
    [];

  const totalSessions = sessions.length || projects.reduce((sum, p) => sum + p.sessionCount, 0);

  return (
    <aside className="project-context" aria-label="项目与会话">
      <div className="project-context-heading">
        <b>项目与会话</b>
        <span>
          <SidebarSimple size={16} />
          <Gear size={16} />
        </span>
      </div>

      {loading && !projects.length && <div className="context-empty">正在读取项目…</div>}
      {!loading && error && (
        <div className="context-error" role="alert">
          读取项目失败：{error.message}
        </div>
      )}
      {!loading && !error && !projects.length && (
        <div className="context-empty">还没有任何项目</div>
      )}

      {projects.map((project) => {
        const extra = extraFor(project);
        // 当前项目默认展开（collapsed 是用户显式折叠的覆盖集合）
        const expanded =
          !collapsed.has(project.path) &&
          (project.expanded || project.path === resolvedActivePath || extra.length > 0);
        // 与第一栏一致：默认只列 5 条，其余折叠（第一栏「展开其余 N 条」）
        const all = showAll.has(project.path) || project.showAll;
        const rows = all ? project.sessions : project.sessions.slice(0, 5);
        const hidden = project.sessions.length - rows.length;
        const count = project.sessionCount + extra.length;
        const isActive = project.path === resolvedActivePath;

        return (
          <React.Fragment key={project.path || project.title}>
            <div
              className={`project-context-group ${isActive ? 'active-project' : ''}`}
              role="button"
              tabIndex={0}
              title={project.subtitle}
              onClick={() => selectProject(project)}
              onKeyDown={(event) => {
                if (event.key === 'Enter' || event.key === ' ') {
                  event.preventDefault();
                  selectProject(project);
                }
              }}
            >
              <span
                className="group-caret"
                role="presentation"
                onClick={(event) => {
                  event.stopPropagation();
                  toggle(project.path);
                }}
              >
                {expanded ? <CaretDown size={12} /> : <CaretRight size={12} />}
              </span>
              {project.isHome ? (
                <House size={16} />
              ) : (
                <Folder size={16} weight={isActive ? 'fill' : 'regular'} />
              )}
              <b>{project.title}</b>
              <small>{count || ''}</small>
            </div>

            {expanded &&
              rows.map((session) => {
                const key = `${project.path}|${session.id}`;
                const selected = isActive && session.live;
                return (
                  <button
                    type="button"
                    key={key}
                    className={`context-session ${selected ? 'selected' : ''}`}
                    title={session.summary || session.title}
                    onClick={() => openSession(project, session)}
                    disabled={pendingKey === key}
                  >
                    <span
                      className={`session-mark ${session.running ? 'running' : session.unread ? 'unread' : ''}`}
                    >
                      {session.running ? <CircleNotch size={11} weight="bold" /> : null}
                    </span>
                    <span className="session-body">
                      <b>{session.title}</b>
                      <small>
                        {session.relativeTime}
                        {session.cwd && session.cwd !== project.path
                          ? ` · ${shortPath(session.cwd)}`
                          : ''}
                        {pendingKey === key ? ' · 切换中…' : ''}
                      </small>
                    </span>
                  </button>
                );
              })}

            {expanded && !project.sessions.length && !extra.length && (
              <div className="context-empty inline">暂无会话</div>
            )}

            {expanded && (hidden > 0 || all) && project.sessionCount > 5 && (
              <button
                type="button"
                className="context-more"
                onClick={() => toggleShowAll(project.path)}
              >
                {hidden > 0 ? `展开其余 ${hidden} 条` : '收起'}
              </button>
            )}

            {expanded &&
              extra.map((session) => (
                <div key={session.id} className="context-session created-session">
                  <span className="session-mark" />
                  <span className="session-body">
                    <b>{session.title}</b>
                    <small>{session.mode === 'worktree' ? 'Worktree' : '当前分支'} · 刚刚</small>
                  </span>
                </div>
              ))}
          </React.Fragment>
        );
      })}

      {actionError && (
        <div className="context-error" role="alert">
          {actionError}
        </div>
      )}

      <div className="context-add" title={`共 ${totalSessions} 条会话 · 在原生侧栏中添加目录`}>
        <Plus size={14} />
        添加目录
      </div>
    </aside>
  );
}

/* ---------------- 终端预览 ---------------- */

export function SessionPane({ collapsed, onToggle }) {
  const { sessions } = useProjectTree();
  const project = useActiveProject();
  const activeSession = useMemo(() => {
    if (!sessions.length) return null;
    const inProject = sessions.filter((session) => session.projectPath === project?.path);
    return (
      inProject.find((session) => session.live) ??
      inProject.find((session) => session.running) ??
      null
    );
  }, [sessions, project]);

  if (collapsed) {
    return (
      <section className="session-context collapsed" aria-label="已收起的会话终端">
        <button
          className="collapsed-terminal-rail"
          onClick={onToggle}
          aria-label="展开当前会话终端"
          title="展开终端"
        >
          <SidebarSimple size={16} />
          <Terminal size={16} />
          <span>终端</span>
        </button>
      </section>
    );
  }

  return (
    <section className="session-context" aria-label="当前会话终端">
      <header>
        <Terminal size={16} />
        <b title={activeSession?.title}>
          {activeSession?.title ?? (project ? `${project.title} · 未选择会话` : '未选择会话')}
        </b>
        <span>{project?.title ?? ''}</span>
        <button
          className="session-collapse"
          onClick={onToggle}
          aria-label="收起当前会话终端"
          title="收起终端"
        >
          <SidebarSimple size={16} />
        </button>
      </header>
      <div className="session-terminal">
        <div className="terminal-welcome">
          <b>Claude Code</b>
          <span>
            {activeSession?.cwd ? shortPath(activeSession.cwd) : (project?.subtitle ?? '')}
          </span>
        </div>
        <div className="terminal-user">
          {activeSession
            ? `在 ${project?.title ?? ''} 里打开会话「${activeSession.title}」。`
            : '从左侧选一条会话，原生终端会切到那一路 PTY。'}
        </div>
        <div className="terminal-answer">
          <p>第三栏只做预览，真正的终端在第一栏右侧的原生终端里。</p>
          <p>点会话行会调用 session.open，由原生侧复用或新建对应终端。</p>
        </div>
        <div className="terminal-command">
          <span>›</span>
          <span className="terminal-caret" />
        </div>
      </div>
      <footer>
        <span>{activeSession?.running ? '运行中' : '空闲'}</span>
        <span>{activeSession ? activeSession.mode : '会话预览'}</span>
        <span>{activeSession?.relativeTime ?? '未选择'}</span>
      </footer>
    </section>
  );
}
