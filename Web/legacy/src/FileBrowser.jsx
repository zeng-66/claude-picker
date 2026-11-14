import React, { useState } from 'react';
import { Splitter, useStoredSize } from './ui/Splitter.jsx';
import {
  DownloadSimple,
  MagnifyingGlass,
  Minus,
  PencilSimple,
  Plus,
  SidebarSimple,
} from '@phosphor-icons/react';
import { projectData, createTextDocuments } from './mock/data.js';
import {
  EDITABLE_KINDS,
  fileIcon,
  statusTone,
  fileByName,
  languageFor,
  initialContent,
} from './files/file-meta.jsx';
import FileTree from './files/FileTree.jsx';
import ChangedList from './files/ChangedList.jsx';
import DiffView from './files/DiffView.jsx';
import LiveEditor from './files/LiveEditor.jsx';
import PreviewRenderer from './files/PreviewRenderer.jsx';
import './file-browser.css';

// 对外导出的名字必须保持不变：CreateSessionModal 等上层仍按原路径引用。
export { projectOptions } from './mock/projects.js';
export { WorkspaceToolSwitcher } from './files/WorkspaceToolSwitcher.jsx';

// 文件预览容器：持有选择 / 搜索 / 布局 / 编辑态，具体渲染交给 files/ 下的子组件。
export default function FileBrowser({ onNotify, repo, projectPath }) {
  const project = projectData[repo] || projectData['claude-picker'];
  const allFiles = [...project.files, ...project.deletedFiles];
  const stagedFiles = Object.entries(project.changes).filter(([, change]) => change.staged);
  const unstagedFiles = Object.entries(project.changes).filter(([, change]) => !change.staged);
  const [scope, setScope] = useState('all');
  const [selectedPath, setSelectedPath] = useState(project.defaultPath);
  const [query, setQuery] = useState('');
  const [expanded, setExpanded] = useState(new Set(project.expanded));
  const [previewMode, setPreviewMode] = useState('preview');
  const [markdownMode, setMarkdownMode] = useState('preview');
  const [diffLayout, setDiffLayout] = useState('统一');
  const [zoom, setZoom] = useState(1);
  const [editing, setEditing] = useState(false);
  const [documents, setDocuments] = useState(createTextDocuments);
  const [dirtyFiles, setDirtyFiles] = useState(new Set());
  const file = fileByName(selectedPath, allFiles) || allFiles[0];
  const change = project.changes[file.path];
  const content = documents[file.path] ?? initialContent(file);
  const effectiveChange = change
    ? { ...change, after: change.state === 'deleted' ? change.after : content }
    : undefined;
  const editable = EDITABLE_KINDS.has(file.kind) && change?.state !== 'deleted';
  const queryText = query.trim().toLowerCase();

  const toggleFolder = (name) => {
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  };

  const selectFile = (selected) => {
    setSelectedPath(selected.path);
    setEditing(false);
    setMarkdownMode('preview');
    setPreviewMode(project.changes[selected.path] ? 'diff' : 'preview');
  };

  const updateContent = (nextContent) => {
    setDocuments((current) => ({ ...current, [file.path]: nextContent }));
    setDirtyFiles((current) => {
      const next = new Set(current);
      next.add(file.path);
      return next;
    });
  };

  const toggleEditing = () => {
    if (editing) {
      setEditing(false);
      if (dirtyFiles.has(file.path)) {
        onNotify(`演示：已保存 ${file.path}，预览已同步`);
        setDirtyFiles((current) => {
          const next = new Set(current);
          next.delete(file.path);
          return next;
        });
      }
      return;
    }
    setPreviewMode('preview');
    setMarkdownMode('preview');
    setEditing(true);
  };

  const switchScope = (nextScope) => {
    setScope(nextScope);
    setQuery('');
  };

  const treeW = useStoredSize('cp.files.treeW', 216, 150, 560);

  return (
    <section
      className="file-browser"
      aria-label="项目文件与预览"
      style={{ '--tree-w': treeW.size + 'px' }}
    >
      <Splitter
        state={treeW}
        axis="x"
        reserve={280}
        className="file-browser-split"
        style={{ left: treeW.size - 3 }}
      />
      <aside className="file-explorer">
        <div className="file-explorer-heading">
          <div>
            <b>文件预览</b>
            <span>
              {allFiles.length} 个文件 · {Object.keys(project.changes).length} 项变更
            </span>
          </div>
          <span className="file-view-icon" aria-hidden="true">
            <SidebarSimple size={16} />
          </span>
        </div>
        <div className="file-scope-tabs" role="tablist" aria-label="文件视图">
          <button
            role="tab"
            aria-selected={scope === 'all'}
            className={scope === 'all' ? 'selected' : ''}
            onClick={() => switchScope('all')}
          >
            全部文件
          </button>
          <button
            role="tab"
            aria-selected={scope === 'changed'}
            className={scope === 'changed' ? 'selected' : ''}
            onClick={() => switchScope('changed')}
          >
            变更文件 <small>{Object.keys(project.changes).length}</small>
          </button>
        </div>
        <label className="file-search">
          <MagnifyingGlass size={15} />
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={scope === 'all' ? '搜索全部文件…' : '搜索变更文件…'}
          />
        </label>
        {scope === 'all' ? (
          <FileTree
            tree={project.tree}
            projectPath={projectPath}
            allFiles={allFiles}
            changes={project.changes}
            selectedPath={selectedPath}
            queryText={queryText}
            expanded={expanded}
            onToggleFolder={toggleFolder}
            onSelect={selectFile}
            onExpandAll={() =>
              setExpanded(
                new Set(
                  project.tree.filter((node) => node.type === 'folder').map((node) => node.name),
                ),
              )
            }
            onCollapseAll={() => setExpanded(new Set())}
          />
        ) : (
          <ChangedList
            projectPath={projectPath}
            unstaged={unstagedFiles}
            staged={stagedFiles}
            changes={project.changes}
            allFiles={allFiles}
            queryText={queryText}
            onSelect={selectFile}
          />
        )}
        <div className="file-explorer-footer">
          <span className="dot" />
          本地工作区{' '}
          <b>{scope === 'all' ? allFiles.length : Object.keys(project.changes).length}</b>
        </div>
      </aside>
      <section className="file-preview">
        <header className="file-preview-header">
          <div className="file-breadcrumb">
            {fileIcon(file.kind)}
            <span>{file.path}</span>
            {change && (
              <em className={`header-change ${statusTone(change)}`}>
                {change.label} · {change.staged ? '已暂存' : '未暂存'}
              </em>
            )}
          </div>
          <div className="file-preview-actions">
            <button onClick={() => copyText(file.path, onNotify)}>复制路径</button>
            <button aria-label="下载文件" onClick={() => onNotify('暂不支持：下载文件')}>
              <DownloadSimple />
            </button>
          </div>
        </header>
        <div className="file-preview-toolbar">
          {editing ? (
            <span className="editing-status">
              <i />
              编辑中 · 右侧实时预览
            </span>
          ) : (
            <>
              {change && (
                <div className="segmented change-mode">
                  {[
                    ['diff', '变更差异'],
                    ['preview', '文件预览'],
                  ].map(([mode, label]) => (
                    <button
                      key={mode}
                      className={previewMode === mode ? 'chosen' : ''}
                      onClick={() => setPreviewMode(mode)}
                    >
                      {label}
                    </button>
                  ))}
                </div>
              )}
              {previewMode === 'diff' &&
                !change?.binary &&
                file.kind !== 'image' &&
                file.kind !== 'pdf' && (
                  <div className="segmented">
                    {[
                      ['并排', '并排'],
                      ['统一', '统一'],
                    ].map(([mode, label]) => (
                      <button
                        key={mode}
                        className={diffLayout === mode ? 'chosen' : ''}
                        onClick={() => setDiffLayout(mode)}
                      >
                        {label}
                      </button>
                    ))}
                  </div>
                )}
              {previewMode === 'preview' &&
                ['markdown', 'diagram', 'html', 'csv'].includes(file.kind) && (
                  <div className="segmented">
                    {[
                      [
                        'preview',
                        file.kind === 'csv'
                          ? '表格'
                          : file.kind === 'diagram'
                            ? '图表'
                            : file.kind === 'html'
                              ? '网页'
                              : '渲染',
                      ],
                      ['source', '源码'],
                    ].map(([mode, label]) => (
                      <button
                        key={mode}
                        className={markdownMode === mode ? 'chosen' : ''}
                        onClick={() => setMarkdownMode(mode)}
                      >
                        {label}
                      </button>
                    ))}
                  </div>
                )}
              {previewMode === 'preview' && file.kind === 'image' && (
                <div className="zoom-control" aria-label="图片缩放">
                  <button
                    onClick={() => setZoom((value) => Math.max(0.5, value - 0.25))}
                    aria-label="缩小"
                  >
                    <Minus />
                  </button>
                  <span>{Math.round(zoom * 100)}%</span>
                  <button
                    onClick={() => setZoom((value) => Math.min(2, value + 0.25))}
                    aria-label="放大"
                  >
                    <Plus />
                  </button>
                </div>
              )}
            </>
          )}
          <span className="preview-toolbar-note">
            {editing
              ? `${languageFor(file)} · ${content.split('\n').length} 行`
              : change
                ? `${change.staged ? '已暂存' : '未暂存'} · 点击文件名可查看同一预览`
                : '工作区文件与 HEAD 一致'}
          </span>
          {editable && (
            <button
              className={`file-edit-button ${editing ? 'active' : ''}`}
              onClick={toggleEditing}
            >
              <PencilSimple />
              {editing ? '完成编辑' : '编辑'}
            </button>
          )}
        </div>
        <div className={`file-preview-body ${file.kind} ${editing ? 'editing' : previewMode}`}>
          {editing ? (
            <LiveEditor file={file} content={content} onChange={updateContent} />
          ) : previewMode === 'diff' && change ? (
            <DiffView file={file} change={effectiveChange} layout={diffLayout} />
          ) : (
            <PreviewRenderer
              file={file}
              content={content}
              viewMode={markdownMode}
              change={change}
              zoom={zoom}
            />
          )}
        </div>
        <footer className="file-preview-footer">
          <span>
            {languageFor(file)} · UTF-8{editable ? ' · 可编辑' : ' · 只读'}
          </span>
          <span>
            {dirtyFiles.has(file.path)
              ? '编辑未保存'
              : change
                ? `${change.label} · ${change.staged ? '已暂存' : '未暂存'}`
                : '与 HEAD 一致'}
          </span>
        </footer>
      </section>
    </section>
  );
}

// WKWebView 的自定义 scheme 不一定被当作安全上下文，navigator.clipboard 可能不存在，
// 退回 execCommand('copy')。
function copyText(text, onNotify) {
  const done = () => onNotify(`已复制 ${text}`);
  const fallback = () => {
    const el = document.createElement('textarea');
    el.value = text;
    el.style.position = 'fixed';
    el.style.opacity = '0';
    document.body.appendChild(el);
    el.select();
    const ok = document.execCommand('copy');
    el.remove();
    ok ? done() : onNotify('复制失败');
  };
  if (navigator.clipboard?.writeText) navigator.clipboard.writeText(text).then(done, fallback);
  else fallback();
}
