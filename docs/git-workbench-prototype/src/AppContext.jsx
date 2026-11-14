import React from 'react';
import { Folder, CaretDown, CaretRight, Gear, Plus, Terminal, SidebarSimple } from '@phosphor-icons/react';

const baseProjects = [
  {
    name: 'claude-picker',
    sessions: [
      { title: 'Git 操作台界面设计', meta: '当前会话', active: true },
      { title: '优化终端焦点与快捷键', meta: '1 小时前' },
      { title: '支持多项目会话切换', meta: '2 小时前' },
      { title: '调整侧边栏布局', meta: '昨天' }
    ]
  },
  { name: 'lm-global-java', sessions: [] },
  { name: 'lanma-bankend', sessions: [] },
  { name: 'fangguo-erp-java', sessions: [] }
];

export function ProjectSidebar({ activeProject = 'claude-picker', createdSessions = [] }) {
  return <aside className="project-context" aria-label="项目与会话">
    <div className="project-context-heading"><b>项目与会话</b><span><SidebarSimple size={16}/><Gear size={16}/></span></div>
    <div className="project-context-group"><CaretRight size={12}/><Folder size={16}/><b>~</b><small>13</small></div>
    {baseProjects.map(project => {
      const extraSessions = createdSessions.filter(session => session.projectId === project.name);
      const expanded = project.name === 'claude-picker' || project.name === activeProject || extraSessions.length > 0;
      const count = project.sessions.length + extraSessions.length;
      return <React.Fragment key={project.name}>
        <div className={`project-context-group ${project.name === activeProject ? 'active-project' : ''}`}>
          {expanded ? <CaretDown size={12}/> : <CaretRight size={12}/>}<Folder size={16} weight={project.name === activeProject ? 'fill' : 'regular'}/><b>{project.name}</b><small>{count || ''}</small>
        </div>
        {expanded && project.sessions.map(session => <div key={session.title} className={`context-session ${session.active ? 'selected' : ''}`}><b>{session.title}</b><small>{session.meta}</small></div>)}
        {expanded && extraSessions.map(session => <div key={session.id} className="context-session created-session"><b>{session.title}</b><small>{session.mode === 'worktree' ? 'Worktree' : '当前分支'} · 刚刚</small></div>)}
      </React.Fragment>;
    })}
    <div className="context-add"><Plus size={14}/>添加目录</div>
  </aside>;
}

export function SessionPane({ collapsed, onToggle }) {
  if (collapsed) {
    return <section className="session-context collapsed" aria-label="已收起的会话终端">
      <button className="collapsed-terminal-rail" onClick={onToggle} aria-label="展开当前会话终端" title="展开终端">
        <SidebarSimple size={16}/>
        <Terminal size={16}/>
        <span>终端</span>
      </button>
    </section>;
  }
  return <section className="session-context" aria-label="当前会话终端">
    <header><Terminal size={16}/><b>Git 操作台界面设计</b><span>claude-picker</span><button className="session-collapse" onClick={onToggle} aria-label="收起当前会话终端" title="收起终端"><SidebarSimple size={16}/></button></header>
    <div className="session-terminal">
      <div className="terminal-welcome"><b>Claude Code</b><span>~/project/claude-picker</span></div>
      <div className="terminal-user">将 Git 操作台放到软件的第三栏，看看整体效果。</div>
      <div className="terminal-answer"><p>Git 操作台已展开在右侧。</p><p>当前会话与仓库工具可以同时查看。右侧支持审阅文件、创建提交、查看历史和管理分支。</p></div>
      <div className="terminal-command"><span>›</span><span className="terminal-caret"/></div>
    </div>
    <footer><span>自动模式</span><span>Opus 5.5</span><span>会话预览</span></footer>
  </section>;
}
