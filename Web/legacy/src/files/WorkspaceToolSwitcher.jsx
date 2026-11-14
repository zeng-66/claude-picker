// 第三栏顶部一行：项目下拉 ｜ Git 工作台（含分支下拉）｜ 文件预览。
// 项目与分支都放在这一行，下面的工作区不再单独占行显示它们。
import React from 'react';
import { CaretDown, Folder, FolderOpen } from '@phosphor-icons/react';
import BranchSwitcher from '../git/BranchSwitcher.jsx';

export function WorkspaceToolSwitcher({
  activeTool,
  onChange,
  projects = [],
  activeProject,
  onSelectProject,
  branchProps,
}) {
  return (
    <div className="workspace-tool-switcher">
      <label className="tool-project-picker" title={activeProject?.path}>
        <Folder size={14} weight="fill" />
        {/* aria-label 不能改：bridge/dto.js 按它在 DOM 里找当前项目 */}
        <select
          aria-label="选择项目"
          value={activeProject?.path ?? ''}
          onChange={(event) => onSelectProject?.(event.target.value)}
        >
          {!activeProject && <option value="">读取中…</option>}
          {projects.map((project) => (
            <option key={project.path} value={project.path}>
              {project.title}
            </option>
          ))}
        </select>
        <CaretDown size={11} />
      </label>
      <div className="workspace-tool-tabs" role="tablist" aria-label="第三栏工具">
        <BranchSwitcher
          {...branchProps}
          active={activeTool === 'git'}
          onActivate={() => onChange('git')}
        />
        <button
          role="tab"
          aria-selected={activeTool === 'files'}
          className={activeTool === 'files' ? 'active' : ''}
          onClick={() => onChange('files')}
        >
          <FolderOpen size={15} />
          文件预览
        </button>
      </div>
    </div>
  );
}
