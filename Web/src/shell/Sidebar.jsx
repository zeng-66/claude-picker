// 第一栏：项目与会话树。数据来自原生 Store 的快照，所有操作回写原生。
import PromptCacheTimer from './PromptCacheTimer.jsx';
import UsagePopover from './UsagePopover.jsx';
import React, { useEffect, useRef, useState } from 'react';
import {
  CaretDown,
  CaretUp,
  CaretRight,
  ChatCircleDots,
  CircleNotch,
  Folder,
  MagnifyingGlass,
  Gear,
  GitBranch,
  House,
  Plus,
  SidebarSimple,
  Terminal,
  TreeStructure,
} from '@phosphor-icons/react';
import { IconButton } from './ui.jsx';
import { request } from './bridge.js';
import { statusOf } from './work/useWorks.js';

import { engineIcons } from './EngineIcon.jsx';

const VISIBLE_SESSIONS = 5;
const VISIBLE_GROUPS = 5;

function sessionGroups(sessions, worktrees = []) {
  const groups = new Map(worktrees.map((item) => {
    const key = `worktree:${item.path}`;
    return [key, { key, branch: item.branch, worktree: item.path, sessions: [] }];
  }));
  for (const session of sessions) {
    const worktree = worktrees.find((item) => session.cwd === item.path
      || session.cwd?.startsWith(item.path + '/'))?.path;
    const branch = session.branch;
    const key = worktree ? `worktree:${worktree}` : branch ? `branch:${branch}` : 'unbound';
    if (!groups.has(key)) groups.set(key, { key, branch, worktree, sessions: [] });
    groups.get(key).sessions.push(session);
  }
  return [...groups.values()].sort((a, b) => {
    const rank = (item) => item.worktree ? 1 : item.branch ? 0 : 2;
    return rank(a) - rank(b);
  });
}

export default function Sidebar({
  state,
  open,
  terminalOpen,
  workbenchPath,
  treeCursor,
  onCursor,
  onToggleSidebar,
  onExpandTerminal,
  onSelectProject,
  onOpenSession,
  onBrowseGroup,
  onTreeContext,
  onBranchTreeContext,
  onAddDirectory,
  onSettings,
  onNewSession,
  onFocusTerminal,
  works = [],
  workSessionIds = [],
  selectedWorkId,
  onOpenWork,
  onSearch,
  worktreesByProject,
  worktreeLabels = {},
}) {
  const [dragging, setDragging] = useState(null);
  // 分支 / 工作树分组默认收起，只记展开过的分组。
  const [openGroups, setOpenGroups] = useState({});
  // 展开的分组里默认只列最近 VISIBLE_SESSIONS 条，其余用「展开其余 N 条」收起。
  const [showAllGroups, setShowAllGroups] = useState({});
  // 项目下的分支 / 工作树分组同样默认只列前 VISIBLE_GROUPS 个（按项目路径记录是否展开其余）。
  const [showAllBranches, setShowAllBranches] = useState({});
  const projects = state.projects;
  const active = state.active;
  const providers = state.providers ?? [];
  // 属于 Work 的会话以 Work 的形式出现，不再作为普通会话重复列出。
  const hiddenSessions = new Set(workSessionIds);
  const worksByProject = new Map();
  for (const work of works) {
    if (work.archived || work.status === 'cancelled') continue;
    const path = work.project?.path;
    if (!path) continue;
    if (!worksByProject.has(path)) worksByProject.set(path, []);
    worksByProject.get(path).push(work);
  }

  const visibleSessions = (project) => project.sessions.filter((session) => !hiddenSessions.has(session.id));

  // 打开的会话变化时，展开它所在的分组一次，避免当前会话藏在收起的分组里；之后可再手动收起。
  const activeSessionId = active?.threadId || active?.sessionId;
  const revealedSession = useRef(null);
  useEffect(() => {
    if (!activeSessionId || revealedSession.current === activeSessionId) return;
    for (const project of projects) {
      const projectGroups = sessionGroups(visibleSessions(project), worktreesByProject?.[project.path] ?? []);
      const groupIndex = projectGroups.findIndex((item) => item.sessions.some((session) => session.id === activeSessionId));
      const group = projectGroups[groupIndex];
      if (group) {
        if (groupIndex >= VISIBLE_GROUPS) setShowAllBranches((current) => ({ ...current, [project.path]: true }));
        const groupKey = `${project.path}:${group.key}`;
        revealedSession.current = activeSessionId;
        setOpenGroups((current) => (current[groupKey] ? current : { ...current, [groupKey]: true }));
        // 当前会话排在前 VISIBLE_SESSIONS 条之后时一并展开其余，否则它仍被收起看不到。
        if (group.sessions.findIndex((session) => session.id === activeSessionId) >= VISIBLE_SESSIONS) {
          setShowAllGroups((current) => ({ ...current, [groupKey]: true }));
        }
        return;
      }
    }
  }, [activeSessionId, projects, worktreesByProject]);
  const rowCount = projects.reduce((count, project) => count + 1 + (project.expanded ? visibleSessions(project).length : 0), 0);

  function navigateTree(event) {
    const rows = [
      ...event.currentTarget.querySelectorAll('.project-row, .session-branch-row, .session-row, .more-sessions'),
    ];
    const current = rows.indexOf(event.target.closest('button'));
    if (current < 0) return;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      rows[
        Math.max(0, Math.min(rows.length - 1, current + (event.key === 'ArrowDown' ? 1 : -1)))
      ].focus();
    }
    const group = event.target.closest('.project-group');
    const projectRow = group?.querySelector('.project-row');
    const item = event.target.closest('.session-branch-group');
    const branchRow = item?.querySelector('.session-branch-row');
    const expansion = event.target === projectRow ? projectRow : event.target === branchRow ? branchRow : null;
    if (event.key === 'ArrowRight' && expansion) {
      event.preventDefault();
      if (expansion.getAttribute('aria-expanded') === 'false') expansion.click();
      else (item ?? group)?.querySelector(expansion === branchRow ? '.session-row' : '.session-branch-row')?.focus();
    }
    if (event.key === 'ArrowLeft') {
      event.preventDefault();
      if (expansion?.getAttribute('aria-expanded') === 'true') expansion.click();
      else (item && expansion !== branchRow ? branchRow : projectRow)?.focus();
    }
    // Tab：把键盘交回终端（与原先「树 ⇄ 终端」的切换一致）
    if (event.key === 'Tab' && !event.shiftKey && active) {
      event.preventDefault();
      onFocusTerminal();
    }
  }

  function drop(event, project, session = null, groupKey = null) {
    event.preventDefault();
    const from = dragging;
    setDragging(null);
    if (!from) return;
    if (!from.sessionId && !session && from.path !== project.path)
      request('app.moveProject', { from: from.path, to: project.path });
    if (from.sessionId && session && from.path === project.path && from.groupKey === groupKey && from.sessionId !== session.id)
      request('app.moveSession', {
        projectPath: project.path,
        from: from.sessionId,
        to: session.id,
      });
  }

  if (!open) {
    return (
      <aside className="sidebar collapsed">
        <IconButton icon={SidebarSimple} label="展开项目侧栏 ⌘B" onClick={onToggleSidebar} />
        {!terminalOpen && (
          <IconButton icon={Terminal} label="展开终端 ⌘J" onClick={onExpandTerminal} />
        )}
        <div className="collapsed-projects">
          {projects.map((project) => (
            <IconButton
              icon={project.isHome ? House : Folder}
              key={project.path}
              label={project.title}
              active={project.path === workbenchPath}
              onClick={() => onSelectProject(project.path)}
            />
          ))}
        </div>
        <IconButton icon={Plus} label="新建会话 ⌘N" onClick={() => onNewSession()} />
      </aside>
    );
  }

  return (
    <aside className="sidebar">
      <div className="sidebar-heading">
        <div className="sidebar-brand">
          <strong>Claude<span>Picker</span></strong>
          <small>
            {projects.length} 个目录 · {rowCount} 行
          </small>
        </div>
        <div className="sidebar-header-actions">
          <IconButton icon={Gear} label="界面设置" onClick={onSettings} />
          <IconButton icon={SidebarSimple} label="收起侧边栏 ⌘B" onClick={onToggleSidebar} />
          {!terminalOpen && (
            <IconButton icon={Terminal} label="展开终端 ⌘J" onClick={onExpandTerminal} />
          )}
        </div>
      </div>
      <div className="sidebar-links">
        <button onClick={onSearch}>
          <MagnifyingGlass size={15} />
          <span>搜索</span>
          <small>⌘K</small>
        </button>
      </div>
      <div className="project-list" onKeyDown={navigateTree}>
        {projects.map((project) => {
          const sessions = visibleSessions(project);
          const groups = sessionGroups(sessions, worktreesByProject[project.path] ?? []);
          const projectWorks = (worksByProject.get(project.path) ?? []).filter(
            (work) => work.status !== 'completed' || work.id === selectedWorkId || work.unread,
          );
          return (
            <section className="project-group" key={project.path}>
              <button
                className={`project-row ${project.path === workbenchPath ? 'current' : ''} ${treeCursor === `project-${project.path}` ? 'cursor' : ''} ${dragging && !dragging.sessionId && dragging.path === project.path ? 'dragging' : ''}`}
                aria-expanded={project.expanded}
                title={project.path}
                draggable={!project.isHome}
                onDragStart={() => setDragging({ path: project.path })}
                onDragEnd={() => setDragging(null)}
                onDragOver={(event) => event.preventDefault()}
                onDrop={(event) => drop(event, project)}
                onContextMenu={(event) => onTreeContext(event, project)}
                onClick={() => {
                  onCursor(`project-${project.path}`);
                  // 每次点文件夹，该项目下的分支 / 工作树分组和「展开其余」都回到收起。
                  const prefix = `${project.path}:`;
                  const collapse = (current) => Object.fromEntries(
                    Object.entries(current).filter(([key]) => !key.startsWith(prefix)),
                  );
                  setOpenGroups(collapse);
                  setShowAllGroups(collapse);
                  setShowAllBranches((current) => {
                    const { [project.path]: _removed, ...rest } = current;
                    return rest;
                  });
                  request('app.toggleProject', { path: project.path });
                }}
              >
                {project.expanded ? <CaretDown size={10} /> : <CaretRight size={10} />}
                {project.isHome ? (
                  <House size={15} weight="fill" />
                ) : (
                  <Folder size={15} weight="fill" />
                )}
                <strong>{project.title}</strong>
                <span>{sessions.length + projectWorks.length || ''}</span>
              </button>
              {project.expanded && (
                <div className="sessions">
                  {projectWorks.map((work) => {
                    const status = statusOf(work);
                    const execTag = work.executor === 'antigravity' ? 'Antigravity' : 'Claude';
                    return (
                      <button
                        className={`work-row ${selectedWorkId === work.id ? 'selected' : ''}`}
                        key={work.id}
                        title={`${work.displayId} · ${execTag} · ${work.title} · ${status.label}`}
                        onClick={() => onOpenWork(work.id)}
                      >
                        <span className={`session-indicator ${status.tone}`}>
                          {work.status === 'running' ? <CircleNotch size={12} className="spin" /> : <i />}
                        </span>
                        <span>
                          <b>{work.title}</b>
                          <small>
                            {work.displayId} · {execTag} · {status.label}
                          </small>
                        </span>
                        {(work.status === 'waiting_user' || work.unread) && <ChatCircleDots size={13} />}
                      </button>
                    );
                  })}
                  {(showAllBranches[project.path] ? groups : groups.slice(0, VISIBLE_GROUPS)).map((group) => {
                    const groupKey = `${project.path}:${group.key}`;
                    const expanded = !!openGroups[groupKey];
                    const label = worktreeLabels[group.worktree]?.name || group.branch ||
                      (group.worktree ? group.worktree.split('/').at(-1) : '未绑定分支');
                    return (
                      <div className="session-branch-group" key={group.key}>
                        <button className="session-branch-row" type="button" aria-expanded={expanded}
                          title={group.worktree ?? label}
                          onContextMenu={(event) => onBranchTreeContext(event, project, group)}
                          onClick={() => {
                            onBrowseGroup();
                            setOpenGroups((current) => ({ ...current, [groupKey]: !expanded }));
                          }}>
                          {expanded ? <CaretDown size={10} /> : <CaretRight size={10} />}
                          {group.worktree ? <TreeStructure size={13} /> : <GitBranch size={13} />}
                          <strong>{label}</strong>
                          {group.worktree && <small>工作树</small>}
                          <span>{group.sessions.length}</span>
                        </button>
                        {expanded && group.sessions.length === 0 && <p className="cli-worktree-empty">还没有会话</p>}
                        {expanded && (showAllGroups[groupKey] ? group.sessions : group.sessions.slice(0, VISIBLE_SESSIONS)).map((session) => {
                            const prov = session.provider ?? 'claude';
                            const provLabel = providers.find((item) => item.id === prov)?.label ?? 'Claude Code';
                            const chain = Array.isArray(session.handoffChain) && session.handoffChain.length > 1
                              ? session.handoffChain
                              : null;
                            const isSelected = !selectedWorkId && (active?.threadId === session.id || active?.sessionId === session.id);
                            const tip = chain
                              ? `${provLabel} · ${session.title}（接力轨迹：${chain.map((seg) => seg.shortLabel ?? seg.provider).join(' → ')}）`
                              : session.handoffFrom
                                ? `${provLabel} · ${session.title}（接力自 ${session.handoffFrom}）`
                                : `${provLabel} · ${session.title}`;
                            const visibleChain = chain && chain.length > 4 ? chain.slice(-4) : chain;
                            const clippedCount = chain ? chain.length - visibleChain.length : 0;
                            return (
                              <button
                                className={`session-row ${isSelected ? 'selected' : ''} ${dragging?.sessionId === session.id ? 'dragging' : ''}`}
                                key={`${prov}-${session.id}`}
                                data-session={session.id}
                                title={tip}
                                draggable
                                onDragStart={() =>
                                  setDragging({ path: project.path, sessionId: session.id, groupKey })
                                }
                                onDragEnd={() => setDragging(null)}
                                onDragOver={(event) => event.preventDefault()}
                                onDrop={(event) => drop(event, project, session, groupKey)}
                                onContextMenu={(event) => onTreeContext(event, project, session)}
                                onClick={() => {
                                  onCursor(`session-${session.id}`);
                                  onOpenSession(project, session);
                                }}
                              >
                                <span
                                  className={`session-marker ${session.running ? 'running' : session.unread ? 'unread' : ''}`}
                                >
                                  {session.running ? (
                                    <CircleNotch size={12} />
                                  ) : session.unread ? (
                                    <i />
                                  ) : null}
                                </span>
                                <span>
                                  <b>
                                    <img className="session-engine-icon" src={engineIcons[prov] ?? engineIcons.claude}
                                      alt={provLabel} title={provLabel} />
                                    {session.title}
                                  </b>
                                  <small>
                                    {visibleChain ? (
                                      <>
                                        <span className="handoff-mini-trail" aria-label={`接力 ${chain.length} 段`}>
                                          {clippedCount > 0 && <span className="handoff-mini-more">+{clippedCount}</span>}
                                          {visibleChain.map((seg, idx) => (
                                            <React.Fragment key={`${seg.id}-${idx}`}>
                                              {(idx > 0 || clippedCount > 0) && <span className="handoff-mini-sep" aria-hidden="true">›</span>}
                                              <img
                                                className={`handoff-mini-icon${idx === visibleChain.length - 1 ? ' current' : ''}`}
                                                src={engineIcons[seg.provider] ?? engineIcons.claude}
                                                alt={seg.shortLabel ?? seg.provider}
                                              />
                                            </React.Fragment>
                                          ))}
                                        </span>
                                        {' · '}
                                        {session.time}
                                      </>
                                    ) : session.handoffFrom ? `接力 · ${session.time}` : session.time}
                                    {prov === 'claude' && !session.running && state.settings.promptCacheEnabled !== false && session.lastCompletedTurn &&
                                      <PromptCacheTimer expiresAt={session.lastCompletedTurn * 1000 + (state.settings.promptCacheMinutes ?? 5) * 60000} />}
                                  </small>
                                </span>
                              </button>
                            );
                          })}
                        {expanded && group.sessions.length > VISIBLE_SESSIONS && (
                          <button
                            className={`more-sessions ${treeCursor === `more-${groupKey}` ? 'cursor' : ''}`}
                            type="button"
                            onClick={() => {
                              onCursor(`more-${groupKey}`);
                              setShowAllGroups((current) => ({ ...current, [groupKey]: !current[groupKey] }));
                            }}
                          >
                            {showAllGroups[groupKey] ? '收起' : `展开其余 ${group.sessions.length - VISIBLE_SESSIONS} 条`}
                            {showAllGroups[groupKey] ? <CaretUp size={9} /> : <CaretDown size={9} />}
                          </button>
                        )}
                      </div>
                    );
                  })}
                  {groups.length > VISIBLE_GROUPS && (
                    <button
                      className={`more-sessions more-branches ${treeCursor === `more-branches-${project.path}` ? 'cursor' : ''}`}
                      type="button"
                      onClick={() => {
                        onCursor(`more-branches-${project.path}`);
                        setShowAllBranches((current) => ({ ...current, [project.path]: !current[project.path] }));
                      }}
                    >
                      {showAllBranches[project.path] ? '收起分支' : `展开其余 ${groups.length - VISIBLE_GROUPS} 个分支`}
                      {showAllBranches[project.path] ? <CaretUp size={9} /> : <CaretDown size={9} />}
                    </button>
                  )}
                </div>
              )}
            </section>
          );
        })}
      </div>
      <button className="add-directory" onClick={onAddDirectory}>
        <Plus size={12} />
        添加目录
      </button>
      <UsagePopover usage={state.usage} engineIcons={engineIcons} />
    </aside>
  );
}
