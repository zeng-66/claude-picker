// 变更文件视图：未暂存 / 已暂存两组列表，带状态图例与搜索空态。
// 真实数据来自 `git.status`（Swift 侧由 T4 接通）；未接通 / 失败时回落到 mock 的
// `changes`，保证第三栏始终有内容可看。
import React, { useEffect, useState } from 'react';
import { request } from '../bridge/client.js';
import {
  fileIcon,
  fileNameOf,
  projectPathFor,
  registerWorkspaceFile,
  statusTone,
} from './file-meta.jsx';

export function ChangedFile({ file, change, onSelect }) {
  if (!file) return null;
  const tone = statusTone(change);
  return (
    <button className={`changed-file-row ${tone}`} onClick={() => onSelect(file)}>
      {fileIcon(file.kind)}
      <span>
        <b>{fileNameOf(file)}</b>
        <small>{file.path.split('/').slice(0, -1).join('/') || '.'}</small>
      </span>
      <em className={`status-letter ${tone}`}>{change.label}</em>
    </button>
  );
}

function labelOf(file) {
  if (file.label) return file.label;
  if (file.untracked) return '?';
  return (file.indexStatus ?? '').trim() || (file.workTreeStatus ?? '').trim() || 'M';
}

function toEntries(files, stageKey, projectPath, allFiles) {
  return (
    files
      // 未跟踪文件没有暂存区状态位，归到「未暂存」这一组才有地方显示。
      .filter(
        (file) => Boolean(file[stageKey]) || (stageKey === 'unstaged' && Boolean(file.untracked)),
      )
      .map((file) => [
        file.path,
        {
          ...file,
          label: labelOf(file),
          state: file.state ?? (file.untracked ? 'untracked' : 'modified'),
          staged: stageKey === 'staged',
        },
      ])
      .map(([path, change]) => [
        path,
        change,
        registerWorkspaceFile(projectPath, { path, kind: change.kind }) ??
          allFiles.find((file) => file.path === path),
      ])
  );
}

export default function ChangedList({
  unstaged,
  staged,
  changes,
  allFiles,
  queryText,
  projectPath: explicitProjectPath,
  onSelect,
}) {
  const projectPath = explicitProjectPath ?? projectPathFor(changes);
  const [snapshot, setSnapshot] = useState(null);
  const [error, setError] = useState(null);
  const [reloadToken, setReloadToken] = useState(0);

  useEffect(() => {
    if (!projectPath) return undefined;
    let cancelled = false;
    setError(null);
    request('git.status', { projectPath })
      .then((result) => {
        if (!cancelled) setSnapshot(result ?? null);
      })
      .catch((failure) => {
        if (!cancelled) setError(failure);
      });
    return () => {
      cancelled = true;
    };
  }, [projectPath, reloadToken]);

  // 真实状态优先；没有快照时沿用 mock 的两组列表。
  const realUnstaged = snapshot
    ? toEntries(snapshot.files ?? [], 'unstaged', projectPath, allFiles)
    : null;
  const realStaged = snapshot
    ? toEntries(snapshot.files ?? [], 'staged', projectPath, allFiles)
    : null;
  const rowsUnstaged = realUnstaged ?? unstaged.map(([path, change]) => [path, change, null]);
  const rowsStaged = realStaged ?? staged.map(([path, change]) => [path, change, null]);
  const visible = (rows) => rows.filter(([path]) => path.toLowerCase().includes(queryText));
  const matches = visible(rowsUnstaged).length + visible(rowsStaged).length;
  const empty = snapshot && (snapshot.files ?? []).length === 0;

  return (
    <>
      <div className="status-legend">
        <span className="unstaged">
          <i />
          未暂存
        </span>
        <span className="staged">
          <i />
          已暂存
        </span>
        <span className="deleted">
          <i />
          已删除
        </span>
        <span className="untracked">
          <i />
          未跟踪
        </span>
      </div>
      <div className="changed-files-list">
        {error && (
          <div className="empty-tree">
            变更读取失败：{error.message ?? '未知错误'}，以下是上次的列表。
            <button
              className="tree-file"
              style={{ paddingLeft: 0 }}
              onClick={() => setReloadToken((v) => v + 1)}
            >
              重试
            </button>
          </div>
        )}
        {!snapshot && !error && <div className="empty-tree">正在读取变更…</div>}
        {empty && <div className="empty-tree">工作区干净</div>}
        {!empty && !queryText && (
          <div className="change-group-label">
            未暂存 <span>{rowsUnstaged.length}</span>
          </div>
        )}
        {visible(rowsUnstaged).map(([path, item, file]) => (
          <ChangedFile
            key={path}
            file={file ?? registerWorkspaceFile(projectPath, { path, kind: item.kind })}
            change={item}
            onSelect={onSelect}
          />
        ))}
        {!empty && !queryText && (
          <div className="change-group-label">
            已暂存 <span>{rowsStaged.length}</span>
          </div>
        )}
        {visible(rowsStaged).map(([path, item, file]) => (
          <ChangedFile
            key={path}
            file={file ?? registerWorkspaceFile(projectPath, { path, kind: item.kind })}
            change={item}
            onSelect={onSelect}
          />
        ))}
        {queryText && matches === 0 && <div className="empty-tree">没有匹配的变更文件</div>}
      </div>
    </>
  );
}
