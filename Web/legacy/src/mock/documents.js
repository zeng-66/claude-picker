// 演示文档内容：Markdown / Mermaid / HTML。T1 桥接层接管前，预览与编辑都以此为准。
export const markdownFiles = {
  'README.md': `# ClaudePicker

macOS 上的 Claude Code 会话浏览器。在一个窗口里查看所有项目的历史会话，点击即可恢复。

## Git 工作台

- 审阅工作区变更
- 暂存文件并创建提交
- 查看提交详情与完整 Diff
- 管理分支、Stash、标签和工作树

## 文件预览

在第三栏直接查看项目文件，减少窗口切换。

| 文件类型 | 预览方式 |
| --- | --- |
| Markdown | 渲染预览 / 源码 |
| 图片 | 缩放与文件信息 |
| 代码 | 行号与语法色彩 |
| CSV | 表格 / 源码 |

> 当前页面为交互原型，文件内容使用演示数据。
`,
  'docs/git-workbench.md': `# Git 工作台设计说明

## 目标

把高频 Git 操作放进 Claude Code 的第三栏，让用户在不离开当前会话的情况下完成代码审阅和提交。

## 信息层级

1. 仓库和当前分支
2. 工作区、历史、分支与冲突
3. 文件列表和 Diff

## 交互原则

- 破坏性操作必须明确说明影响范围
- 文件、提交与命令入口保持一致
- 临时状态在操作完成后给出反馈
`,
  'docs/release-notes.md': `# Release Notes

## v0.3.0

- 新增三栏工作区
- 新增 Git 操作台
- 新增图片和 Markdown 文件预览

## v0.2.1

- 优化终端焦点与快捷键响应
- 修复侧边栏折叠后的布局问题
`,
  'docs/draft-notes.md': `# 文件预览草稿

## 待确认

- 全部文件视图保留目录层级
- 变更文件视图只显示工作区改动
- Git 状态使用文件名颜色和状态字母共同表达

## 后续

补充文件大小、编码和二进制内容提示。
`,
};

export const diagramFiles = {
  'docs/workbench-flow.mmd': `flowchart LR
    A[项目会话] --> B[终端会话]
    B --> C[第三栏工具]
    C --> D[Git 工作台]
    C --> E[文件预览]
    E --> F[编辑与实时预览]
    E --> G[图片 / PDF / CSV]`,
  'docs/database-er.mmd': `erDiagram
    PROJECT ||--o{ SESSION : contains
    SESSION ||--o{ FILE_CHANGE : tracks
    FILE_CHANGE }o--|| PREVIEW : opens
    PROJECT {
      string id PK
      string name
      string root_path
    }
    FILE_CHANGE {
      string path PK
      string status
      boolean staged
    }`,
  'docs/save-sequence.mmd': `sequenceDiagram
    actor User
    participant Editor
    participant Preview
    participant FileSystem
    User->>Editor: 输入 Markdown / Mermaid
    Editor->>Preview: 发送最新内容
    Preview-->>User: 实时渲染
    User->>Editor: 完成编辑
    Editor->>FileSystem: 保存文件
    FileSystem-->>User: 保存成功`,
};

export const htmlFiles = {
  'docs/file-preview.html': `<!doctype html>
<html>
<head>
  <style>
    body { margin: 0; padding: 32px; background: #17181b; color: #ddd; font: 14px system-ui; }
    main { max-width: 520px; border: 1px solid #383a40; border-radius: 10px; padding: 24px; }
    h1 { color: #e5b093; font-size: 24px; }
    .row { display: flex; gap: 10px; margin-top: 20px; }
    .card { flex: 1; padding: 14px; background: #24262c; border-radius: 7px; }
    small { color: #8a9099; }
  </style>
</head>
<body>
  <main>
    <small>LIVE HTML PREVIEW</small>
    <h1>第三栏文件工作台</h1>
    <p>编辑 HTML 时，右侧页面会实时更新。</p>
    <div class="row"><div class="card">Markdown</div><div class="card">Mermaid</div><div class="card">Code</div></div>
  </main>
</body>
</html>`,
};

const architectureMarkdown = [
  '# 第三栏技术设计',
  '',
  '当前工作台把项目会话、终端和文件工具放在同一个窗口里。',
  '',
  '## 文件预览流程',
  '',
  '```mermaid',
  diagramFiles['docs/workbench-flow.mmd'],
  '```',
  '',
  '## 数据关系',
  '',
  '```mermaid',
  diagramFiles['docs/database-er.mmd'],
  '```',
  '',
  '## 编辑与预览',
  '',
  'Markdown、Mermaid、HTML、代码和 CSV 使用同一个编辑工具栏。输入内容后，右侧预览立即更新。',
  '',
  '> 原型中的保存操作只更新浏览器内存。',
].join('\n');
markdownFiles['docs/architecture.md'] = architectureMarkdown;
