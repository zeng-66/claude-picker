// 文件树：全部文件视图。真实数据走桥（file.list），目录点开才拉取；
// 桥不可用时 client.js 已经自动回落 mock，所以这里不再重复 mock 数据。
import React, { useEffect, useRef, useState } from 'react';
import {
  ArrowsInLineVertical,
  ArrowsOutLineVertical,
  CaretDown,
  CaretRight,
  Folder,
} from '@phosphor-icons/react';
import { request } from '../bridge/client.js';
import {
  IGNORED_NAMES,
  fileIcon,
  fileByName,
  isWorkspaceFile,
  projectPathFor,
  registerWorkspaceFile,
  statusTone,
} from './file-meta.jsx';

export function TreeFile({ file, change, selectedPath, onSelect, root = false, depth = 0 }) {
  if (!file) return null;
  const tone = statusTone(change);
  const isLink = typeof file.name === 'string' && file.name.includes(' → ');
  return (
    <button
      className={`tree-file ${root ? 'root-file' : ''} ${tone} ${selectedPath === file.path ? 'selected' : ''}`}
      style={depth ? { paddingLeft: 7 + depth * 12 } : undefined}
      title={file.path}
      onClick={() => onSelect(file)}
    >
      {fileIcon(file.kind)}
      <span>{file.name ?? file.path.split('/').pop()}</span>
      {isLink && (
        <em style={{ marginLeft: 4, color: '#8a8f98', fontStyle: 'normal', fontSize: 8 }}>链接</em>
      )}
      {change && <em className={`status-letter ${tone}`}>{change.label}</em>}
    </button>
  );
}

function labelOf(file) {
  if (file.label) return file.label;
  if (file.untracked) return '?';
  return (file.indexStatus ?? '').trim() || (file.workTreeStatus ?? '').trim() || 'M';
}

function statusMapOf(snapshot) {
  const map = {};
  (snapshot?.files ?? []).forEach((file) => {
    map[file.path] = { ...file, label: labelOf(file) };
  });
  return map;
}

/** 旧 mock 树渲染：只有拿不到项目路径时才会走到（浏览器内预览等）。 */
function MockTree({ tree, allFiles, changes, queryText, expanded, onToggleFolder, onSelect }) {
  return tree.map((node) => {
    if (node.type === 'file') {
      if (queryText && !node.path.toLowerCase().includes(queryText)) return null;
      return (
        <TreeFile
          key={node.path}
          root
          file={fileByName(node.path, allFiles)}
          change={changes[node.path]}
          onSelect={onSelect}
        />
      );
    }
    const matchingPaths = node.files.filter((path) => path.toLowerCase().includes(queryText));
    if (queryText && matchingPaths.length === 0) return null;
    const isOpen = Boolean(queryText) || expanded.has(node.name);
    return (
      <div key={node.name}>
        <button
          className="tree-folder"
          onClick={() => onToggleFolder(node.name)}
          aria-expanded={isOpen}
        >
          {isOpen ? <CaretDown size={12} /> : <CaretRight size={12} />}
          <Folder size={16} />
          <span>{node.name}</span>
          <small>{matchingPaths.length}</small>
        </button>
        {isOpen &&
          matchingPaths.map((path) => (
            <TreeFile
              key={path}
              file={fileByName(path, allFiles)}
              change={changes[path]}
              onSelect={onSelect}
            />
          ))}
      </div>
    );
  });
}

export default function FileTree({
  tree,
  allFiles,
  changes,
  projectPath: explicitProjectPath,
  selectedPath,
  queryText,
  expanded,
  onToggleFolder,
  onExpandAll,
  onCollapseAll,
  onSelect,
}) {
  // 真实路径由 FileBrowser 从当前项目传入；只有在没有真实项目时（浏览器演示）
  // 才回退到按 mock 对象反查。
  const projectPath = explicitProjectPath ?? projectPathFor(tree);
  const [dirs, setDirs] = useState({});
  const [open, setOpen] = useState(() => new Set(expanded));
  const [statusMap, setStatusMap] = useState({});
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  // 目录按需拉取；同目录重复点开用缓存，只有出错才允许重试。
  const loadDir = async (path) => {
    if (!projectPath) return null;
    setDirs((current) => ({ ...current, [path]: { ...(current[path] ?? {}), status: 'loading' } }));
    try {
      const nodes = (await request('file.list', { projectPath, path })) ?? [];
      const entries = nodes
        .filter((node) => !IGNORED_NAMES.has(node.name))
        .map((node) => ({ ...node, file: registerWorkspaceFile(projectPath, node) }));
      if (!mounted.current) return entries;
      setDirs((current) => ({ ...current, [path]: { status: 'ready', nodes: entries } }));
      return entries;
    } catch (error) {
      if (mounted.current) {
        setDirs((current) => ({ ...current, [path]: { status: 'error', nodes: [], error } }));
      }
      return null;
    }
  };

  useEffect(() => {
    if (!projectPath) return undefined;
    let cancelled = false;
    (async () => {
      const nodes = await loadDir('');
      if (cancelled || !nodes) return;
      // FileBrowser 的默认选中项来自 mock（例如 docs/architecture.md），它不一定
      // 在真实仓库里。首屏把它换成一个真实文件，避免第三栏一直显示假内容。
      if (!isWorkspaceFile(selectedPath)) {
        const firstFile =
          nodes.find((node) => !node.isDirectory && /^readme\.md$/i.test(node.name)) ??
          nodes.find((node) => !node.isDirectory);
        if (firstFile) onSelect(firstFile.file);
      }
      // mock 的 expanded 存的是目录名；真实树按路径预取一层，保持首屏观感。
      const prefetch = [...expanded].filter((name) =>
        nodes.some((node) => node.path === name && node.isDirectory),
      );
      if (prefetch.length) {
        setOpen((current) => new Set([...current, ...prefetch]));
        await Promise.all(prefetch.map((name) => loadDir(name)));
      }
    })();
    return () => {
      cancelled = true;
    };
    // 只在挂载时跑一次：FileBrowser 按 repo 重新挂载本组件。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectPath]);

  useEffect(() => {
    if (!projectPath) return undefined;
    let cancelled = false;
    request('git.status', { projectPath })
      .then((snapshot) => {
        if (!cancelled) setStatusMap(statusMapOf(snapshot));
      })
      .catch(() => {
        // 变更集还没接通时保持 mock 的 changes，不影响文件树本身。
      });
    return () => {
      cancelled = true;
    };
  }, [projectPath]);

  const toggle = (path) => {
    const next = new Set(open);
    if (next.has(path)) {
      next.delete(path);
    } else {
      next.add(path);
      if (dirs[path]?.status !== 'ready' && dirs[path]?.status !== 'loading') loadDir(path);
    }
    setOpen(next);
  };

  const expandAll = () => {
    const next = new Set(open);
    Object.keys(dirs).forEach((path) => {
      if (path && dirs[path]?.status === 'ready') next.add(path);
    });
    setOpen(next);
  };

  const collapseAll = () => setOpen(new Set());

  const changeFor = (path) => statusMap[path] ?? changes[path];

  if (!projectPath) {
    return (
      <>
        <div className="tree-controls">
          <span>当前项目</span>
          <div>
            <button title="展开全部文件夹" aria-label="展开全部文件夹" onClick={onExpandAll}>
              <ArrowsOutLineVertical />
            </button>
            <button title="折叠全部文件夹" aria-label="折叠全部文件夹" onClick={onCollapseAll}>
              <ArrowsInLineVertical />
            </button>
          </div>
        </div>
        <div className="file-tree">
          <MockTree
            tree={tree}
            allFiles={allFiles}
            changes={changes}
            queryText={queryText}
            expanded={expanded}
            onToggleFolder={onToggleFolder}
            onSelect={onSelect}
          />
        </div>
      </>
    );
  }

  const matches = (node) => !queryText || node.path.toLowerCase().includes(queryText);

  const renderDir = (path, depth) => {
    const state = dirs[path];
    if (!state) return null;
    if (state.status === 'loading') {
      return (
        <div className="empty-tree" style={{ padding: '8px 0', textAlign: 'left' }}>
          正在读取目录…
        </div>
      );
    }
    if (state.status === 'error') {
      return (
        <div className="empty-tree" style={{ padding: '8px 0' }}>
          目录读取失败：{state.error?.message ?? '未知错误'}
          <button className="tree-file" style={{ paddingLeft: 0 }} onClick={() => loadDir(path)}>
            重试
          </button>
        </div>
      );
    }
    if (!state.nodes.length) {
      return (
        <div className="empty-tree" style={{ padding: '8px 0' }}>
          空目录
        </div>
      );
    }
    return state.nodes.map((node) => {
      const visible = matches(node) || Boolean(queryText && node.isDirectory);
      if (!visible) return null;
      if (!node.isDirectory) {
        return (
          <TreeFile
            key={node.path}
            depth={depth}
            root={depth === 0}
            file={node.file}
            change={changeFor(node.path)}
            selectedPath={selectedPath}
            onSelect={onSelect}
          />
        );
      }
      const isOpen = open.has(node.path) || Boolean(queryText);
      return (
        <div key={node.path}>
          <button
            className="tree-folder"
            style={{ paddingLeft: 7 + depth * 12 }}
            onClick={() => toggle(node.path)}
            aria-expanded={isOpen}
          >
            {isOpen ? <CaretDown size={12} /> : <CaretRight size={12} />}
            <Folder size={16} />
            <span title={node.path}>{node.name}</span>
            {dirs[node.path]?.status === 'ready' && <small>{dirs[node.path].nodes.length}</small>}
          </button>
          {isOpen && dirs[node.path]?.status !== 'ready' && (
            <div className="empty-tree" style={{ padding: '6px 0' }}>
              正在读取目录…
            </div>
          )}
          {isOpen && renderDir(node.path, depth + 1)}
        </div>
      );
    });
  };

  const root = dirs[''];
  return (
    <>
      <div className="tree-controls">
        <span>当前项目</span>
        <div>
          <button title="展开全部文件夹" aria-label="展开全部文件夹" onClick={expandAll}>
            <ArrowsOutLineVertical />
          </button>
          <button title="折叠全部文件夹" aria-label="折叠全部文件夹" onClick={collapseAll}>
            <ArrowsInLineVertical />
          </button>
        </div>
      </div>
      <div className="file-tree">
        {!root && <div className="empty-tree">正在读取项目目录…</div>}
        {root?.status === 'error' && (
          <div className="empty-tree">
            无法读取项目目录：{root.error?.message ?? '未知错误'}
            <button className="tree-file" style={{ paddingLeft: 0 }} onClick={() => loadDir('')}>
              重试
            </button>
          </div>
        )}
        {root?.status === 'ready' && !root.nodes.length && <div className="empty-tree">空目录</div>}
        {root?.status === 'ready' && renderDir('', 0)}
      </div>
    </>
  );
}
