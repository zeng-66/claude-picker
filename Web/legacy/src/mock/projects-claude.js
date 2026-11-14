import { markdownFiles } from './documents.js';
import { codeFiles } from './code-content.js';

// claude-picker 项目的演示文件树与变更集。
export const claudeFiles = [
  { path: 'README.md', kind: 'markdown' },
  { path: 'docs/git-workbench.md', kind: 'markdown' },
  { path: 'docs/release-notes.md', kind: 'markdown' },
  { path: 'docs/draft-notes.md', kind: 'markdown' },
  { path: 'docs/architecture.md', kind: 'markdown' },
  { path: 'docs/workbench-flow.mmd', kind: 'diagram' },
  { path: 'docs/database-er.mmd', kind: 'diagram' },
  { path: 'docs/save-sequence.mmd', kind: 'diagram' },
  { path: 'docs/file-preview.html', kind: 'html' },
  { path: 'docs/design-spec.pdf', kind: 'pdf' },
  { path: 'Sources/ClaudeDeck/main.swift', kind: 'code' },
  { path: 'Sources/ClaudeDeck/Models.swift', kind: 'code' },
  { path: 'Sources/ClaudeDeck/GitPanel.swift', kind: 'code' },
  { path: 'Sources/ClaudeDeck/GitService.swift', kind: 'code' },
  {
    path: 'assets/workspace-preview.png',
    kind: 'image',
    src: '/assets/workspace-preview.png',
    dimensions: '1180 × 728 px',
    size: '152 KB',
  },
  {
    path: 'assets/app-icon.png',
    kind: 'image',
    src: '/assets/app-icon.png',
    dimensions: '1024 × 1024 px',
    size: '8 KB',
  },
  { path: 'package.json', kind: 'code' },
  { path: 'data/releases.csv', kind: 'csv' },
  { path: 'data/pipeline.yaml', kind: 'code' },
];

export const claudeChanges = {
  'docs/git-workbench.md': {
    state: 'modified',
    label: 'M',
    staged: false,
    before: markdownFiles['docs/git-workbench.md'].replace(
      '## 交互原则\n\n- 破坏性操作必须明确说明影响范围\n- 文件、提交与命令入口保持一致\n- 临时状态在操作完成后给出反馈\n',
      '',
    ),
    after: markdownFiles['docs/git-workbench.md'],
  },
  'docs/draft-notes.md': {
    state: 'untracked',
    label: '?',
    staged: false,
    before: '',
    after: markdownFiles['docs/draft-notes.md'],
  },
  'Sources/ClaudeDeck/GitPanel.swift': {
    state: 'modified',
    label: 'M',
    staged: false,
    before: codeFiles['Sources/ClaudeDeck/GitPanel.swift'].replace(
      '        .background(Color.workspace)\n',
      '',
    ),
    after: codeFiles['Sources/ClaudeDeck/GitPanel.swift'],
  },
  'Sources/ClaudeDeck/GitService.swift': {
    state: 'added',
    label: 'A',
    staged: false,
    before: '',
    after: codeFiles['Sources/ClaudeDeck/GitService.swift'],
  },
  'data/releases.csv': {
    state: 'modified',
    label: 'M',
    staged: false,
    before: 'version,date,type\n0.2.1,2026-11-08,fix\n0.2.0,2026-10-30,feature\n',
    after:
      'version,date,type\n0.3.0,2026-11-13,feature\n0.2.1,2026-11-08,fix\n0.2.0,2026-10-30,feature\n',
  },
  'Sources/ClaudeDeck/Models.swift': {
    state: 'modified',
    label: 'M',
    staged: true,
    before: codeFiles['Sources/ClaudeDeck/Models.swift'].replace(
      '\nstruct WorkspacePreview {\n    var selectedPath: String?\n    var mode: PreviewMode = .rendered\n}\n\nenum PreviewMode {\n    case rendered\n    case source\n}\n',
      '',
    ),
    after: codeFiles['Sources/ClaudeDeck/Models.swift'],
  },
  'assets/workspace-preview.png': {
    state: 'added',
    label: 'A',
    staged: true,
    binary: true,
    before: null,
    after: '/assets/workspace-preview.png',
  },
  'Sources/ClaudeDeck/LegacySession.swift': {
    state: 'deleted',
    label: 'D',
    staged: true,
    before: codeFiles['Sources/ClaudeDeck/LegacySession.swift'],
    after: '',
  },
};

export const claudeTree = [
  {
    type: 'folder',
    name: 'docs',
    files: [
      'docs/architecture.md',
      'docs/workbench-flow.mmd',
      'docs/database-er.mmd',
      'docs/save-sequence.mmd',
      'docs/file-preview.html',
      'docs/git-workbench.md',
      'docs/release-notes.md',
      'docs/draft-notes.md',
      'docs/design-spec.pdf',
    ],
  },
  {
    type: 'folder',
    name: 'Sources',
    files: [
      'Sources/ClaudeDeck/main.swift',
      'Sources/ClaudeDeck/Models.swift',
      'Sources/ClaudeDeck/GitPanel.swift',
      'Sources/ClaudeDeck/GitService.swift',
    ],
  },
  {
    type: 'folder',
    name: 'assets',
    files: ['assets/workspace-preview.png', 'assets/app-icon.png'],
  },
  { type: 'folder', name: 'data', files: ['data/releases.csv', 'data/pipeline.yaml'] },
  { type: 'file', path: 'README.md' },
  { type: 'file', path: 'package.json' },
];

export const claudeProject = {
  branch: 'feature/git-workbench',
  ahead: 2,
  defaultPath: 'docs/architecture.md',
  expanded: ['docs', 'assets'],
  files: claudeFiles,
  deletedFiles: [{ path: 'Sources/ClaudeDeck/LegacySession.swift', kind: 'code', deleted: true }],
  tree: claudeTree,
  changes: claudeChanges,
};
