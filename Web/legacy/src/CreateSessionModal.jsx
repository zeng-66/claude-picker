import React, { useState } from 'react';
import { Folder, GitBranch, Terminal, TreeStructure, X } from '@phosphor-icons/react';
import './create-session.css';

function branchSlug(value) {
  return (
    value
      .trim()
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, '') || 'new-session'
  );
}

export default function CreateSessionModal({ project, currentBranch, onClose, onCreate }) {
  const [mode, setMode] = useState('current');
  const [title, setTitle] = useState('');
  const [prompt, setPrompt] = useState('');
  const [branchName, setBranchName] = useState('');
  const isWorktree = mode === 'worktree';
  const slug = branchSlug(branchName || title);
  const targetBranch = branchName.trim() || `session/${slug}`;
  const worktreePath = `${project.path}/.worktrees/${branchSlug(targetBranch)}`;
  const workingDirectory = isWorktree ? worktreePath : project.path;

  const submit = (event) => {
    event.preventDefault();
    if (!title.trim()) return;
    onCreate({
      id: `${project.id}-${Date.now()}`,
      title: title.trim(),
      prompt: prompt.trim(),
      mode,
      projectId: project.id,
      projectPath: project.path,
      workingDirectory,
      baseBranch: currentBranch,
      branch: isWorktree ? targetBranch : currentBranch,
    });
  };

  return (
    <div className="overlay" onClick={onClose}>
      <form
        className="create-session-modal"
        onSubmit={submit}
        onClick={(event) => event.stopPropagation()}
        aria-labelledby="create-session-title"
      >
        <header>
          <div>
            <Terminal size={19} />
            <span>创建新会话</span>
          </div>
          <button type="button" onClick={onClose} aria-label="关闭创建会话">
            <X size={20} />
          </button>
        </header>
        <div className="session-project-context">
          <Folder size={18} weight="fill" />
          <div>
            <b>{project.label}</b>
            <small>{project.path}</small>
          </div>
          <span>归属当前项目</span>
        </div>
        <div className="session-mode-tabs" role="tablist" aria-label="会话创建方式">
          <button
            type="button"
            role="tab"
            aria-selected={mode === 'current'}
            className={mode === 'current' ? 'selected' : ''}
            onClick={() => setMode('current')}
          >
            <GitBranch size={19} />
            <span>
              <b>基于当前分支</b>
              <small>直接在项目目录中创建会话</small>
            </span>
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={mode === 'worktree'}
            className={mode === 'worktree' ? 'selected' : ''}
            onClick={() => setMode('worktree')}
          >
            <TreeStructure size={19} />
            <span>
              <b>创建 Worktree</b>
              <small>从当前分支创建隔离工作区</small>
            </span>
          </button>
        </div>
        <div className="session-form">
          <label>
            <span>会话标题</span>
            <input
              autoFocus
              value={title}
              onChange={(event) => setTitle(event.target.value)}
              placeholder="例如：修复订单重试任务"
            />
          </label>
          {isWorktree && (
            <label>
              <span>新分支名称</span>
              <input
                value={branchName}
                onChange={(event) => setBranchName(event.target.value)}
                placeholder={`session/${branchSlug(title)}`}
              />
            </label>
          )}
          <label>
            <span>
              初始任务 <small>可选</small>
            </span>
            <textarea
              value={prompt}
              onChange={(event) => setPrompt(event.target.value)}
              placeholder="描述要在这个会话里完成的工作…"
            />
          </label>
        </div>
        <div className="session-location-preview">
          <div>
            <span>项目目录</span>
            <code>{project.path}</code>
          </div>
          <div>
            <span>{isWorktree ? 'Worktree 目录' : '会话目录'}</span>
            <code>{workingDirectory}</code>
          </div>
          <div>
            <span>基准 / 目标分支</span>
            <code>{isWorktree ? `${currentBranch} → ${targetBranch}` : currentBranch}</code>
          </div>
          {isWorktree && (
            <p>
              原型展示的执行意图：
              <code>
                git worktree add .worktrees/{branchSlug(targetBranch)} -b {targetBranch}{' '}
                {currentBranch}
              </code>
            </p>
          )}
        </div>
        <footer>
          <button type="button" onClick={onClose}>
            取消
          </button>
          <button className="primary" type="submit" disabled={!title.trim()}>
            {isWorktree ? '创建 Worktree 会话' : '创建会话'}
          </button>
        </footer>
      </form>
    </div>
  );
}
