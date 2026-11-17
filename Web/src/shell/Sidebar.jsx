// 第一栏：项目与会话树。数据来自原生 Store 的快照，所有操作回写原生。
import React, { useState } from 'react';
import {
  CaretDown,
  CaretRight,
  CaretUp,
  ChatCircleDots,
  CircleNotch,
  Cpu,
  Folder,
  MagnifyingGlass,
  SquaresFour,
  Tray,
  Gear,
  House,
  Plus,
  SidebarSimple,
  Terminal,
} from '@phosphor-icons/react';
import appIcon from './clawd-mark.png';
import { IconButton } from './ui.jsx';
import { request } from './bridge.js';
import { needsAttention, statusOf } from './work/useWorks.js';

const VISIBLE_SESSIONS = 5;

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
  onTreeContext,
  onAddDirectory,
  onSettings,
  onNewSession,
  onFocusTerminal,
  works = [],
  workSessionIds = [],
  capacity,
  selectedWorkId,
  page,
  onPage,
  onOpenWork,
  onSearch,
}) {
  const [dragging, setDragging] = useState(null);
  const projects = state.projects;
  const active = state.active;
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
  const attentionCount = works.filter(needsAttention).length;

  const rowCount = projects.reduce((count, project) => {
    if (!project.expanded) return count + 1;
    const total = project.sessions.length;
    const shown = project.showAll ? total : Math.min(VISIBLE_SESSIONS, total);
    return count + 1 + shown + (total > VISIBLE_SESSIONS ? 1 : 0);
  }, 0);

  function navigateTree(event) {
    const rows = [
      ...event.currentTarget.querySelectorAll('.project-row, .session-row, .more-sessions'),
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
    if (event.key === 'ArrowRight' && event.target === projectRow) {
      event.preventDefault();
      if (projectRow.getAttribute('aria-expanded') === 'false') projectRow.click();
      else group.querySelector('.session-row, .more-sessions')?.focus();
    }
    if (event.key === 'ArrowLeft') {
      event.preventDefault();
      if (event.target === projectRow && projectRow.getAttribute('aria-expanded') === 'true')
        projectRow.click();
      else projectRow?.focus();
    }
    // Tab：把键盘交回终端（与原先「树 ⇄ 终端」的切换一致）
    if (event.key === 'Tab' && !event.shiftKey && active) {
      event.preventDefault();
      onFocusTerminal();
    }
  }

  function drop(event, project, session = null) {
    event.preventDefault();
    const from = dragging;
    setDragging(null);
    if (!from) return;
    if (!from.sessionId && !session && from.path !== project.path)
      request('app.moveProject', { from: from.path, to: project.path });
    if (from.sessionId && session && from.path === project.path && from.sessionId !== session.id)
      request('app.moveSession', {
        projectPath: project.path,
        from: from.sessionId,
        to: session.id,
      });
  }

  const usage = state.usage ?? {};
  const usageRow = (window, weekly) => {
    const percent = Math.round(window?.percent ?? 0);
    const reset = window?.reset ?? (weekly ? '--/--' : '--:--');
    const title = window
      ? `${weekly ? '本周' : '本 5 小时窗口'} ${percent}%，${reset} 重置`
      : (usage.note ?? '用量读取中');
    return (
      <div className={`usage-row ${weekly ? 'weekly' : ''}`} title={usage.note ?? title}>
        <div className="usage-track">
          <i style={{ width: `${Math.max(0, Math.min(100, percent))}%` }} />
        </div>
        <span>
          {reset}&nbsp; {percent}%
        </span>
      </div>
    );
  };

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
        <img src={appIcon} alt="" />
        <div className="sidebar-brand">
          <strong>Claude Code</strong>
          <small>
            {projects.length} 个目录 · {rowCount} 行
          </small>
        </div>
        <div className="sidebar-header-actions">
          <IconButton icon={SidebarSimple} label="收起侧边栏 ⌘B" onClick={onToggleSidebar} />
          {!terminalOpen && (
            <IconButton icon={Terminal} label="展开终端 ⌘J" onClick={onExpandTerminal} />
          )}
        </div>
      </div>
      <div className="sidebar-links">
        <button className={page === 'tapd' ? 'selected' : ''} onClick={() => onPage('tapd')}>
          <Tray size={15} />
          <span>我的待办</span>
        </button>
        <button className={page === 'works' ? 'selected' : ''} onClick={() => onPage('works')}>
          <SquaresFour size={15} />
          <span>Work 中心</span>
          {attentionCount > 0 && <span className="nav-count">{attentionCount}</span>}
        </button>
        <button onClick={onSearch}>
          <MagnifyingGlass size={15} />
          <span>搜索</span>
          <small>⌘K</small>
        </button>
      </div>
      <div className="project-list" onKeyDown={navigateTree}>
        {projects.map((project) => {
          const sessions = project.sessions.filter((session) => !hiddenSessions.has(session.id));
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
                    return (
                      <button
                        className={`work-row ${selectedWorkId === work.id ? 'selected' : ''}`}
                        key={work.id}
                        title={`${work.displayId} · ${work.title} · ${status.label}`}
                        onClick={() => onOpenWork(work.id)}
                      >
                        <span className={`session-indicator ${status.tone}`}>
                          {work.status === 'running' ? <CircleNotch size={12} className="spin" /> : <i />}
                        </span>
                        <span>
                          <b>{work.title}</b>
                          <small>
                            {work.displayId} · {status.label}
                          </small>
                        </span>
                        {(work.status === 'waiting_user' || work.unread) && <ChatCircleDots size={13} />}
                      </button>
                    );
                  })}
                  {sessions
                    .slice(0, project.showAll ? undefined : VISIBLE_SESSIONS)
                    .map((session) => (
                      <button
                        className={`session-row ${!selectedWorkId && active?.sessionId === session.id ? 'selected' : ''} ${dragging?.sessionId === session.id ? 'dragging' : ''}`}
                        key={session.id}
                        data-session={session.id}
                        title={session.title}
                        draggable
                        onDragStart={() =>
                          setDragging({ path: project.path, sessionId: session.id })
                        }
                        onDragEnd={() => setDragging(null)}
                        onDragOver={(event) => event.preventDefault()}
                        onDrop={(event) => drop(event, project, session)}
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
                          <b>{session.title}</b>
                          <small>{session.time}</small>
                        </span>
                      </button>
                    ))}
                  {sessions.length > VISIBLE_SESSIONS && (
                    <button
                      className={`more-sessions ${treeCursor === `more-${project.path}` ? 'cursor' : ''}`}
                      onClick={() => {
                        onCursor(`more-${project.path}`);
                        request('app.toggleShowAll', { path: project.path });
                      }}
                    >
                      {project.showAll
                        ? '收起'
                        : `展开其余 ${sessions.length - VISIBLE_SESSIONS} 条`}
                      {project.showAll ? <CaretUp size={9} /> : <CaretDown size={9} />}
                    </button>
                  )}
                </div>
              )}
            </section>
          );
        })}
      </div>
      {capacity && (
        <button className="agent-capacity" onClick={() => onPage('works')} title="打开 Work 中心">
          <div>
            <Cpu size={13} />
            <span>执行队列</span>
            <b>
              {capacity.running} / {capacity.slots}
            </b>
          </div>
          <div className="capacity-track">
            <span style={{ width: `${Math.min(100, (capacity.running / Math.max(capacity.slots, 1)) * 100)}%` }} />
          </div>
          <small>
            {capacity.queued} 个排队{capacity.waitingStart ? ` · ${capacity.waitingStart} 个待启动` : ''}
          </small>
        </button>
      )}
      <button className="add-directory" onClick={onAddDirectory}>
        <Plus size={12} />
        添加目录
      </button>
      <div className="sidebar-bottom">
        <IconButton icon={Gear} label="界面设置" onClick={onSettings} />
        <div className="usage-bars">
          {usageRow(usage.session, false)}
          {usageRow(usage.weekly, true)}
        </div>
      </div>
    </aside>
  );
}
