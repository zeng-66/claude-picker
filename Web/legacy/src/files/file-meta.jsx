// 文件元信息：类型图标、状态色、语言标签、可编辑类型与初始正文。
// 纯函数，不含状态；文件树、变更列表、差异与预览共用。
import { Code, FileCsv, FileImage, FilePdf, FileText, TreeStructure } from '@phosphor-icons/react';
import { createTextDocuments, projectData } from '../mock/data.js';
import { projectOptions } from '../mock/projects.js';

// T5 只读阶段：编辑按钮关闭（LiveEditor 仍是 mock 数据）。
// T9 接上 file.write 后，把可编辑类型加回这里即可恢复「编辑」入口。
export const EDITABLE_KINDS = new Set();

// 文件树遍历 / 展示时跳过的名字。Swift 侧 FileService 有同一份过滤表（可用
// CLAUDE_PICKER_IGNORED_NAMES=foo,bar 追加）；这里的导出是前端的兜底与可配置入口。
export const IGNORED_NAMES = new Set([
  '.git',
  'node_modules',
  'dist',
  'build',
  '.build',
  '.next',
  '.venv',
  '.DS_Store',
  ...(typeof window === 'undefined' ? [] : (window.__CLAUDE_PICKER_IGNORED_NAMES ?? [])),
]);

export function fileIcon(kind) {
  if (kind === 'image') return <FileImage size={16} />;
  if (kind === 'markdown') return <FileText size={16} />;
  if (kind === 'diagram') return <TreeStructure size={16} />;
  if (kind === 'pdf') return <FilePdf size={16} />;
  if (kind === 'csv') return <FileCsv size={16} />;
  if (kind === 'html') return <Code size={16} />;
  return <Code size={16} />;
}

export function statusTone(change) {
  if (!change) return 'clean';
  if (change.state === 'deleted') return 'deleted';
  if (change.state === 'untracked') return 'untracked';
  return change.staged ? 'staged' : 'unstaged';
}

/**
 * 从 `project.tree` / `project.files` / `project.changes` / 单个文件对象反查项目路径。
 * mock 的 projectOptions 是当前唯一的项目清单，真实桥调用需要绝对路径或 `~/` 路径。
 */
export function projectPathFor(value) {
  if (!value) return null;
  for (const [id, project] of Object.entries(projectData)) {
    if (
      project === value ||
      project.tree === value ||
      project.files === value ||
      project.changes === value ||
      project.files?.includes(value) ||
      project.deletedFiles?.includes(value)
    ) {
      return projectOptions.find((option) => option.id === id)?.path ?? null;
    }
  }
  return value.projectPath ?? null;
}

// mock 变更表里有若干路径与真实仓库同名（如 Sources/ClaudeDeck/GitService.swift）。
// FileBrowser 是只读的，它用 `project.changes[file.path]` 决定是否进 DiffView，于是真实文件
// 会被 mock 的伪造 diff 顶掉。这里把 project.changes 换成过滤视图：已登记的真实路径从枚举
// 与索引里同时消失（语义等同删除，但不改 mock 源对象，也不影响未登记的项目）。
const hiddenChangePaths = new Map();
const guardedProjects = new WeakSet();

function guardMockChanges(projectPath, path) {
  let hidden = hiddenChangePaths.get(projectPath);
  if (!hidden) hiddenChangePaths.set(projectPath, (hidden = new Set()));
  hidden.add(path);
  const id = projectOptions.find((option) => option.path === projectPath)?.id;
  const project = id ? projectData[id] : null;
  if (!project?.changes || guardedProjects.has(project)) return;
  const target = project.changes;
  project.changes = new Proxy(target, {
    get(object, key, receiver) {
      if (typeof key === 'string' && hidden.has(key)) return undefined;
      return Reflect.get(object, key, receiver);
    },
    has(object, key) {
      if (typeof key === 'string' && hidden.has(key)) return false;
      return Reflect.has(object, key);
    },
    ownKeys(object) {
      return Reflect.ownKeys(object).filter((key) => typeof key !== 'string' || !hidden.has(key));
    },
    getOwnPropertyDescriptor(object, key) {
      if (typeof key === 'string' && hidden.has(key)) return undefined;
      return Reflect.getOwnPropertyDescriptor(object, key);
    },
  });
  guardedProjects.add(project);
}

// 真实文件登记表：FileBrowser 的 allFiles 来自 mock，选中真实路径时靠这里兜底。
// 一次只挂一个项目（FileBrowser 按 repo 重挂），换项目时整体清空。
const workspaceFiles = new Map();
let workspaceProject = null;

export function prepareWorkspace(projectPath) {
  if (workspaceProject !== projectPath) {
    workspaceFiles.clear();
    workspaceProject = projectPath;
  }
}

/** mock 文件表里的同路径条目：用来把图片的 src / dimensions 带进真实节点。 */
function mockFileFor(path) {
  for (const project of Object.values(projectData)) {
    const hit = project.files?.find((file) => file.path === path);
    if (hit) return hit;
  }
  return null;
}

/** 把真实 FileNode / GitFile 登记成 FileBrowser 可用的 file 对象（只读，不含正文）。 */
export function registerWorkspaceFile(projectPath, entry) {
  if (!projectPath || !entry?.path) return entry;
  prepareWorkspace(projectPath);
  const existing = workspaceFiles.get(entry.path);
  if (existing) {
    if (entry.kind) existing.kind = entry.kind;
    if (entry.name) existing.name = entry.name;
    return existing;
  }
  // 图片预览需要 src；真实后端会把图片转成 data URL，这里只补浏览器 mock 演示用的字段。
  const fallback = mockFileFor(entry.path);
  const file = {
    path: entry.path,
    name: entry.name ?? entry.path.split('/').pop(),
    kind: entry.kind,
    isDirectory: Boolean(entry.isDirectory),
    projectPath,
    ...(fallback?.src ? { src: fallback.src } : {}),
    ...(fallback?.dimensions ? { dimensions: fallback.dimensions } : {}),
    ...(fallback?.size ? { size: fallback.size } : {}),
  };
  workspaceFiles.set(entry.path, file);
  guardMockChanges(projectPath, entry.path);
  return file;
}

/** 这个路径是否已经被真实目录列表登记过（用于判断当前选中项是不是 mock 数据）。 */
export function isWorkspaceFile(path) {
  return workspaceFiles.has(path);
}

export function resetWorkspace() {
  workspaceFiles.clear();
  workspaceProject = null;
}

export function fileByName(path, files) {
  return files.find((file) => file.path === path) ?? workspaceFiles.get(path);
}

export function fileNameOf(file) {
  return file.name ?? file.path.split('/').pop();
}

export function languageFor(file) {
  if (file.kind === 'markdown') return 'Markdown';
  if (file.kind === 'diagram') return 'Mermaid';
  if (file.kind === 'html') return 'HTML';
  if (file.kind === 'image') return '图片';
  if (file.kind === 'pdf') return 'PDF';
  if (file.kind === 'csv') return 'CSV';
  if (file.path.endsWith('.json')) return 'JSON';
  if (file.path.endsWith('.yaml') || file.path.endsWith('.yml')) return 'YAML';
  if (file.path.endsWith('.swift')) return 'Swift';
  return 'Text';
}

/** 源码高亮用的语言 id（见 PreviewRenderer 的精简着色表）。 */
export function syntaxFor(path = '') {
  const ext = path.includes('.') ? path.split('.').pop().toLowerCase() : '';
  if (ext === 'json') return 'json';
  if (ext === 'yaml' || ext === 'yml') return 'yaml';
  if (ext === 'html' || ext === 'htm') return 'html';
  if (['js', 'jsx', 'ts', 'tsx', 'mjs', 'cjs'].includes(ext)) return 'js';
  if (ext === 'py') return 'py';
  if (['css', 'scss', 'less'].includes(ext)) return 'css';
  if (['sh', 'bash', 'zsh'].includes(ext)) return 'shell';
  if (['swift'].includes(ext)) return 'swift';
  if (['md', 'mdx', 'markdown'].includes(ext)) return 'markdown';
  return 'text';
}

export function initialContent(file) {
  return file.content ?? createTextDocuments()[file.path] ?? '';
}
