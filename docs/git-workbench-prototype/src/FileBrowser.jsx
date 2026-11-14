import React, { lazy, Suspense, useState } from 'react';
import {
  ArrowsInLineVertical, ArrowsOutLineVertical, CaretDown, CaretRight,
  Code, DownloadSimple, FileCsv, FileImage, FilePdf, FileText, Folder,
  FolderOpen, GitBranch, MagnifyingGlass, Minus, Plus, SidebarSimple,
  PencilSimple, TreeStructure
} from '@phosphor-icons/react';
import { diffLines, pairedLines } from './CommitDetails.jsx';
import './file-browser.css';

const MarkdownRenderer = lazy(() => import('./MarkdownRenderer.jsx'));
const MermaidDiagram = lazy(() => import('./MermaidDiagram.jsx'));

const markdownFiles = {
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
`
};

const diagramFiles = {
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
    FileSystem-->>User: 保存成功`
};

const htmlFiles = {
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
</html>`
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
  '> 原型中的保存操作只更新浏览器内存。'
].join('\n');
markdownFiles['docs/architecture.md'] = architectureMarkdown;

const codeFiles = {
  'Sources/ClaudeDeck/main.swift': `import AppKit
import SwiftUI

@main
struct ClaudePickerApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
`,
  'Sources/ClaudeDeck/Models.swift': `import Foundation

struct Project: Identifiable {
    let id: String
    let name: String
    let path: String
    var sessions: [Session]
}

struct WorkspacePreview {
    var selectedPath: String?
    var mode: PreviewMode = .rendered
}

enum PreviewMode {
    case rendered
    case source
}
`,
  'Sources/ClaudeDeck/GitPanel.swift': `import SwiftUI

struct GitPanel: View {
    @ObservedObject var store: GitStore

    var body: some View {
        HSplitView {
            changesSidebar
                .frame(minWidth: 280)
            DiffView(file: store.selectedFile)
        }
        .background(Color.workspace)
    }
}
`,
  'Sources/ClaudeDeck/GitService.swift': `import Foundation

final class GitService {
    func changedFiles() throws -> [GitFile] {
        let output = try shell.run("git", "status", "--porcelain")
        return GitFileParser.parse(output)
    }
}
`,
  'Sources/ClaudeDeck/LegacySession.swift': `import Foundation

final class LegacySessionStore {
    private var sessions: [String: LegacySession] = [:]

    func append(_ session: LegacySession) {
        sessions[session.id] = session
    }
}
`,
  'package.json': `{
  "name": "claude-picker",
  "version": "0.3.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "test": "node --test"
  }
}
`
};

codeFiles['data/pipeline.yaml'] = `phases:
  - build
  - test
  - package

artifacts:
  - ClaudePicker.app
  - ClaudePicker.dmg

preview:
  live: true
  formats:
    - markdown
    - mermaid
    - html
`;

const claudeFiles = [
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
  { path: 'assets/workspace-preview.png', kind: 'image', src: '/assets/workspace-preview.png', dimensions: '1180 × 728 px', size: '152 KB' },
  { path: 'assets/app-icon.png', kind: 'image', src: '/assets/app-icon.png', dimensions: '1024 × 1024 px', size: '8 KB' },
  { path: 'package.json', kind: 'code' },
  { path: 'data/releases.csv', kind: 'csv' },
  { path: 'data/pipeline.yaml', kind: 'code' }
];

const claudeChanges = {
  'docs/git-workbench.md': {
    state: 'modified', label: 'M', staged: false,
    before: markdownFiles['docs/git-workbench.md'].replace('## 交互原则\n\n- 破坏性操作必须明确说明影响范围\n- 文件、提交与命令入口保持一致\n- 临时状态在操作完成后给出反馈\n', ''),
    after: markdownFiles['docs/git-workbench.md']
  },
  'docs/draft-notes.md': {
    state: 'untracked', label: '?', staged: false,
    before: '', after: markdownFiles['docs/draft-notes.md']
  },
  'Sources/ClaudeDeck/GitPanel.swift': {
    state: 'modified', label: 'M', staged: false,
    before: codeFiles['Sources/ClaudeDeck/GitPanel.swift'].replace('        .background(Color.workspace)\n', ''),
    after: codeFiles['Sources/ClaudeDeck/GitPanel.swift']
  },
  'Sources/ClaudeDeck/GitService.swift': {
    state: 'added', label: 'A', staged: false,
    before: '', after: codeFiles['Sources/ClaudeDeck/GitService.swift']
  },
  'data/releases.csv': {
    state: 'modified', label: 'M', staged: false,
    before: 'version,date,type\n0.2.1,2026-11-08,fix\n0.2.0,2026-10-30,feature\n',
    after: 'version,date,type\n0.3.0,2026-11-13,feature\n0.2.1,2026-11-08,fix\n0.2.0,2026-10-30,feature\n'
  },
  'Sources/ClaudeDeck/Models.swift': {
    state: 'modified', label: 'M', staged: true,
    before: codeFiles['Sources/ClaudeDeck/Models.swift'].replace('\nstruct WorkspacePreview {\n    var selectedPath: String?\n    var mode: PreviewMode = .rendered\n}\n\nenum PreviewMode {\n    case rendered\n    case source\n}\n', ''),
    after: codeFiles['Sources/ClaudeDeck/Models.swift']
  },
  'assets/workspace-preview.png': {
    state: 'added', label: 'A', staged: true, binary: true,
    before: null, after: '/assets/workspace-preview.png'
  },
  'Sources/ClaudeDeck/LegacySession.swift': {
    state: 'deleted', label: 'D', staged: true,
    before: codeFiles['Sources/ClaudeDeck/LegacySession.swift'], after: ''
  }
};

const claudeTree = [
  { type: 'folder', name: 'docs', files: ['docs/architecture.md', 'docs/workbench-flow.mmd', 'docs/database-er.mmd', 'docs/save-sequence.mmd', 'docs/file-preview.html', 'docs/git-workbench.md', 'docs/release-notes.md', 'docs/draft-notes.md', 'docs/design-spec.pdf'] },
  { type: 'folder', name: 'Sources', files: ['Sources/ClaudeDeck/main.swift', 'Sources/ClaudeDeck/Models.swift', 'Sources/ClaudeDeck/GitPanel.swift', 'Sources/ClaudeDeck/GitService.swift'] },
  { type: 'folder', name: 'assets', files: ['assets/workspace-preview.png', 'assets/app-icon.png'] },
  { type: 'folder', name: 'data', files: ['data/releases.csv', 'data/pipeline.yaml'] },
  { type: 'file', path: 'README.md' },
  { type: 'file', path: 'package.json' }
];

const lmOrderControllerContent = `package com.lanma.order.controller;

import org.springframework.web.bind.annotation.*;
import com.lanma.order.service.OrderService;

@RestController
@RequestMapping("/api/orders")
public class OrderController {
    private final OrderService orderService;

    public OrderController(OrderService orderService) {
        this.orderService = orderService;
    }

    @PostMapping("/{orderId}/retry")
    public RetryResponse retry(@PathVariable Long orderId) {
        return orderService.retry(orderId);
    }
}
`;
const lmOrderServiceContent = `package com.lanma.order.service;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class OrderService {
    @Transactional
    public RetryResponse retry(Long orderId) {
        Order order = repository.findForUpdate(orderId);
        order.requireRetryable();
        retryTask.enqueue(order.getId());
        return RetryResponse.accepted(order.getId());
    }
}
`;
const lmApplicationContent = `server:
  port: 8080

spring:
  datasource:
    url: jdbc:mysql://localhost:3306/lanma
    username: lanma
    password: change-me

order:
  retry:
    max-attempts: 3
`;
const lmFlowContent = `flowchart LR
  A[运营端请求重试] --> B[OrderController]
  B --> C[OrderService]
  C --> D{订单可重试?}
  D -- 是 --> E[写入重试任务]
  E --> F[XXL-JOB 执行]
  D -- 否 --> G[返回业务错误]`;
const lmApiContent = `# 订单重试接口

## POST /api/orders/{orderId}/retry

触发订单异步重试。

### 返回示例

\`\`\`json
{
  "accepted": true,
  "orderId": 1050356
}
\`\`\`
`;
const lmOrdersCsv = `orderId,status,attempts\n1050356,PAID,0\n1050357,PAYING,1\n1050358,WAIT_SHIP,0\n`;
const lmReadmeContent = `# lm-global-java

面向 Lanma 与 Fangguo 业务的 Java 服务。

## 当前项目能力

- 订单操作与批量任务
- 工厂列表与商品同步
- S3 素材与裁片任务
`;
const lmDeletedContent = `# Legacy API

旧版订单查询接口，已从路由中删除。

GET /api/legacy/orders/{id}
`;

const lmFiles = [
  { path: 'README.md', kind: 'markdown', content: lmReadmeContent },
  { path: 'pom.xml', kind: 'code', content: '<?xml version="1.0" encoding="UTF-8"?>\n<project>\n  <modelVersion>4.0.0</modelVersion>\n</project>\n' },
  { path: 'docs/order-api.md', kind: 'markdown', content: lmApiContent },
  { path: 'docs/order-flow.mmd', kind: 'diagram', content: lmFlowContent },
  { path: 'src/main/java/com/lanma/order/controller/OrderController.java', kind: 'code', content: lmOrderControllerContent },
  { path: 'src/main/java/com/lanma/order/service/OrderService.java', kind: 'code', content: lmOrderServiceContent },
  { path: 'src/main/resources/application.yml', kind: 'code', content: lmApplicationContent },
  { path: 'data/orders.csv', kind: 'csv', content: lmOrdersCsv },
  { path: 'assets/order-dashboard.png', kind: 'image', src: '/assets/workspace-preview.png', dimensions: '1180 × 728 px', size: '152 KB' }
];

const lmProject = {
  branch: 'bugfix/zcl/20261113_operationRetryCropFailed',
  ahead: 0,
  defaultPath: 'docs/order-api.md',
  expanded: ['docs', 'src', 'data', 'assets'],
  files: lmFiles,
  deletedFiles: [{ path: 'docs/legacy-api.md', kind: 'markdown', deleted: true, content: lmDeletedContent }],
  tree: [
    { type: 'folder', name: 'docs', files: ['docs/order-api.md', 'docs/order-flow.mmd'] },
    { type: 'folder', name: 'src', files: ['src/main/java/com/lanma/order/controller/OrderController.java', 'src/main/java/com/lanma/order/service/OrderService.java', 'src/main/resources/application.yml'] },
    { type: 'folder', name: 'data', files: ['data/orders.csv'] },
    { type: 'folder', name: 'assets', files: ['assets/order-dashboard.png'] },
    { type: 'file', path: 'README.md' },
    { type: 'file', path: 'pom.xml' }
  ],
  changes: {
    'src/main/java/com/lanma/order/controller/OrderController.java': {
      state: 'modified', label: 'M', staged: false,
      before: lmOrderControllerContent.replace('        return orderService.retry(orderId);\n', '        return RetryResponse.notReady();\n'),
      after: lmOrderControllerContent
    },
    'docs/order-flow.mmd': {
      state: 'modified', label: 'M', staged: false,
      before: lmFlowContent.replace('  E --> F[XXL-JOB 执行]\n', ''),
      after: lmFlowContent
    },
    'src/main/java/com/lanma/order/service/OrderService.java': {
      state: 'modified', label: 'M', staged: true,
      before: lmOrderServiceContent.replace('        retryTask.enqueue(order.getId());\n', ''),
      after: lmOrderServiceContent
    },
    'assets/order-dashboard.png': {
      state: 'added', label: 'A', staged: true, binary: true,
      before: null, after: '/assets/workspace-preview.png'
    },
    'docs/legacy-api.md': {
      state: 'deleted', label: 'D', staged: true,
      before: lmDeletedContent, after: ''
    }
  }
};

const lanmaRoutesContent = `from fastapi import APIRouter, Depends

router = APIRouter(prefix="/api/orders", tags=["orders"])

@router.post("/{order_id}/retry")
async def retry_order(order_id: int, service=Depends(get_order_service)):
    return await service.retry(order_id)
`;
const lanmaServiceContent = `class OrderService:
    async def retry(self, order_id: int):
        order = await self.repository.find_for_update(order_id)
        self.retry_policy.ensure_retryable(order)
        await self.jobs.enqueue("order.retry", order_id=order.id)
        return {"accepted": True, "orderId": order.id}
`;
const lanmaAgentFlowContent = `flowchart TD
  A[用户消息] --> B[意图识别]
  B --> C{需要工单?}
  C -- 是 --> D[创建工单]
  C -- 否 --> E[直接回答]
  D --> F[通知处理人]
  E --> G[返回结果]`;
const lanmaApiDocContent = `# Lanma API

## 对话接口

客户端通过 SSE 接收 Agent 输出。

- POST /api/chat/stream
- GET /api/orders/{id}
- POST /api/orders/{id}/retry
`;
const lanmaTestContent = `import pytest
from app.services.order_service import OrderService

@pytest.mark.asyncio
async def test_retry_order():
    service = OrderService(repository=FakeRepository())
    result = await service.retry(1050356)
    assert result["accepted"] is True
`;
const lanmaReadmeContent = `# lanma-bankend

Lanma 业务后端，包含订单、工单和 Agent 服务。

## 运行

\`\`\`bash
uvicorn app.main:app --reload
\`\`\`
`;
const lanmaDeletedContent = `class LegacySessionAdapter:
    def load(self, session_id):
        return self.repository.get(session_id)
`;

const lanmaFiles = [
  { path: 'README.md', kind: 'markdown', content: lanmaReadmeContent },
  { path: 'requirements.txt', kind: 'code', content: 'fastapi>=0.115\nuvicorn>=0.32\nsqlalchemy>=2.0\n' },
  { path: 'docs/agent-flow.mmd', kind: 'diagram', content: lanmaAgentFlowContent },
  { path: 'docs/api-design.md', kind: 'markdown', content: lanmaApiDocContent },
  { path: 'app/api/routes/orders.py', kind: 'code', content: lanmaRoutesContent },
  { path: 'app/services/order_service.py', kind: 'code', content: lanmaServiceContent },
  { path: 'tests/test_orders.py', kind: 'code', content: lanmaTestContent },
  { path: 'data/conversations.csv', kind: 'csv', content: 'id,role,status\nc-101,agent,resolved\nc-102,human,waiting\n' }
];

const lanmaProject = {
  branch: 'beta',
  ahead: 1,
  defaultPath: 'docs/api-design.md',
  expanded: ['docs', 'app', 'tests', 'data'],
  files: lanmaFiles,
  deletedFiles: [{ path: 'app/legacy/session.py', kind: 'code', deleted: true, content: lanmaDeletedContent }],
  tree: [
    { type: 'folder', name: 'docs', files: ['docs/agent-flow.mmd', 'docs/api-design.md'] },
    { type: 'folder', name: 'app', files: ['app/api/routes/orders.py', 'app/services/order_service.py'] },
    { type: 'folder', name: 'tests', files: ['tests/test_orders.py'] },
    { type: 'folder', name: 'data', files: ['data/conversations.csv'] },
    { type: 'file', path: 'README.md' },
    { type: 'file', path: 'requirements.txt' }
  ],
  changes: {
    'app/api/routes/orders.py': {
      state: 'added', label: 'A', staged: false,
      before: '', after: lanmaRoutesContent
    },
    'docs/api-design.md': {
      state: 'modified', label: 'M', staged: false,
      before: lanmaApiDocContent.replace('- POST /api/orders/{id}/retry\n', ''),
      after: lanmaApiDocContent
    },
    'app/services/order_service.py': {
      state: 'modified', label: 'M', staged: true,
      before: lanmaServiceContent.replace('        await self.jobs.enqueue("order.retry", order_id=order.id)\n', ''),
      after: lanmaServiceContent
    },
    'app/legacy/session.py': {
      state: 'deleted', label: 'D', staged: true,
      before: lanmaDeletedContent, after: ''
    }
  }
};

const projectData = {
  'claude-picker': {
    branch: 'feature/git-workbench',
    ahead: 2,
    defaultPath: 'docs/architecture.md',
    expanded: ['docs', 'assets'],
    files: claudeFiles,
    deletedFiles: [{ path: 'Sources/ClaudeDeck/LegacySession.swift', kind: 'code', deleted: true }],
    tree: claudeTree,
    changes: claudeChanges
  },
  'lm-global-java': lmProject,
  'lanma-bankend': lanmaProject
};

export const projectOptions = [
  { id: 'claude-picker', label: 'claude-picker', path: '~/project/claude-picker', branch: projectData['claude-picker'].branch, ahead: 2, changes: 8 },
  { id: 'lm-global-java', label: 'lm-global-java', path: '~/project/lm-global-java', branch: lmProject.branch, ahead: 0, changes: 5 },
  { id: 'lanma-bankend', label: 'lanma-bankend', path: '~/project/lanma-bankend', branch: lanmaProject.branch, ahead: 1, changes: 4 }
];

export function WorkspaceToolSwitcher({ activeTool, onChange, repo }) {
  return <div className="workspace-tool-switcher">
    <div className="workspace-tool-tabs" role="tablist" aria-label="第三栏工具">
      <button role="tab" aria-selected={activeTool === 'git'} className={activeTool === 'git' ? 'active' : ''} onClick={() => onChange('git')}><GitBranch size={15}/>Git 工作台</button>
      <button role="tab" aria-selected={activeTool === 'files'} className={activeTool === 'files' ? 'active' : ''} onClick={() => onChange('files')}><FolderOpen size={15}/>文件预览</button>
    </div>
    <span><SidebarSimple size={14}/>{repo}</span>
  </div>;
}

const EDITABLE_KINDS = new Set(['markdown', 'diagram', 'html', 'code', 'csv']);

function createTextDocuments() {
  return {
    ...markdownFiles,
    ...codeFiles,
    ...diagramFiles,
    ...htmlFiles
  };
}

function fileIcon(kind) {
  if (kind === 'image') return <FileImage size={16}/>;
  if (kind === 'markdown') return <FileText size={16}/>;
  if (kind === 'diagram') return <TreeStructure size={16}/>;
  if (kind === 'pdf') return <FilePdf size={16}/>;
  if (kind === 'csv') return <FileCsv size={16}/>;
  if (kind === 'html') return <Code size={16}/>;
  return <Code size={16}/>;
}

function statusTone(change) {
  if (!change) return 'clean';
  if (change.state === 'deleted') return 'deleted';
  if (change.state === 'untracked') return 'untracked';
  return change.staged ? 'staged' : 'unstaged';
}

function fileByName(path, files) {
  return files.find(file => file.path === path);
}

function languageFor(file) {
  if (file.kind === 'markdown') return 'Markdown';
  if (file.kind === 'diagram') return 'Mermaid';
  if (file.kind === 'html') return 'HTML';
  if (file.kind === 'image') return 'PNG';
  if (file.kind === 'pdf') return 'PDF';
  if (file.kind === 'csv') return 'CSV';
  if (file.path.endsWith('.json')) return 'JSON';
  if (file.path.endsWith('.yaml')) return 'YAML';
  if (file.path.endsWith('.swift')) return 'Swift';
  return 'Text';
}

function initialContent(file) {
  return file.content ?? createTextDocuments()[file.path] ?? '';
}

function MarkdownPreview({ content }) {
  return <div className="markdown-document">
    <Suspense fallback={<div className="markdown-loading">正在渲染 Markdown…</div>}><MarkdownRenderer content={content}/></Suspense>
    <div className="markdown-footer">{content.split('\n').length} 行 · Markdown · 最近修改于 10 分钟前</div>
  </div>;
}

function SourceLines({ content }) {
  return <div className="source-lines">{content.split('\n').map((line, index) => <div className="source-row" key={index}><span>{index + 1}</span><code>{line || ' '}</code></div>)}</div>;
}

function DiagramPreview({ content }) {
  return <div className="diagram-preview"><Suspense fallback={<div className="mermaid-loading">正在载入图表…</div>}><MermaidDiagram chart={content}/></Suspense></div>;
}

function HtmlPreview({ content }) {
  return <iframe className="html-preview" title="HTML 实时预览" sandbox="allow-scripts" srcDoc={content}/>;
}

function CsvPreview({ content }) {
  const rows = content.split(/\r?\n/).filter(Boolean).map(row => row.split(','));
  const header = rows[0] || [];
  return <div className="csv-view"><table><thead><tr>{header.map((cell, index) => <th key={`${cell}-${index}`}>{cell}</th>)}</tr></thead><tbody>{rows.slice(1).map((row, rowIndex) => <tr key={rowIndex}>{row.map((cell, index) => <td key={`${cell}-${index}`}>{cell}</td>)}</tr>)}</tbody></table><p>{Math.max(rows.length - 1, 0)} 行数据 · {header.length} 列</p></div>;
}

function TextPreview({ file, content, viewMode, change }) {
  const deleted = change?.state === 'deleted';
  let preview;

  if (file.kind === 'markdown') preview = viewMode === 'source' ? <SourceLines content={content}/> : <MarkdownPreview content={content}/>;
  else if (file.kind === 'diagram') preview = viewMode === 'source' ? <SourceLines content={content}/> : <DiagramPreview content={content}/>;
  else if (file.kind === 'html') preview = viewMode === 'source' ? <SourceLines content={content}/> : <HtmlPreview content={content}/>;
  else if (file.kind === 'csv') preview = viewMode === 'source' ? <SourceLines content={content}/> : <CsvPreview content={content}/>;
  else preview = <SourceLines content={content}/>;

  return <>{deleted && <div className="deleted-file-banner">此文件已从工作区删除，以下内容来自父提交。</div>}{preview}</>;
}

function LivePreview({ file, content }) {
  if (file.kind === 'markdown') return <MarkdownPreview content={content}/>;
  if (file.kind === 'diagram') return <DiagramPreview content={content}/>;
  if (file.kind === 'html') return <HtmlPreview content={content}/>;
  if (file.kind === 'csv') return <CsvPreview content={content}/>;
  return <SourceLines content={content}/>;
}

function LiveEditor({ file, content, onChange }) {
  return <div className="live-editor">
    <section className="editor-pane">
      <header><span>编辑器</span><small>{content.split('\n').length} 行 · {languageFor(file)}</small></header>
      <textarea aria-label={`编辑 ${file.path}`} value={content} onChange={event => onChange(event.target.value)} spellCheck="false"/>
    </section>
    <section className="live-preview-pane">
      <header><span className="live-dot"/>实时预览<small>{file.kind === 'diagram' ? 'Mermaid' : languageFor(file)}</small></header>
      <div className={`live-preview-content ${file.kind}`}><LivePreview file={file} content={content}/></div>
    </section>
  </div>;
}

function ImagePreview({ file, zoom }) {
  return <div className="image-viewer">
    <div className="image-stage"><img src={file.src} alt={file.path} style={{ transform: `scale(${zoom})` }}/></div>
    <div className="image-info"><div><b>{file.path.split('/').pop()}</b><span>PNG 图片 · {file.dimensions}</span></div><span>{file.size}</span></div>
  </div>;
}

function PdfPreview() {
  return <div className="pdf-viewer"><div className="pdf-page"><span className="pdf-kicker">PRODUCT DESIGN</span><h1>Git 工作台</h1><h2>第三栏文件预览</h2><div className="pdf-rule"/><p>在不离开当前会话的情况下审阅代码、查看提交并预览项目文件。</p><div className="pdf-layout"><div/><div/></div><small>ClaudePicker · Design Specification · 2026</small></div></div>;
}

function BinaryDiff({ file, change }) {
  return <div className="binary-diff">
    <div className="binary-diff-summary"><span className="tree-status">{change.label}</span><div><b>{file.path.split('/').pop()}</b><p>{change.state === 'deleted' ? '文件已删除' : '二进制文件已加入变更'}</p></div></div>
    <div className="binary-diff-grid">
      <div><span>父提交</span>{change.before ? <img src={change.before} alt="父提交中的文件"/> : <div className="binary-empty">此前没有此文件</div>}</div>
      <div><span>当前工作区</span>{change.after ? <img src={change.after} alt="当前工作区中的文件"/> : <div className="binary-empty">文件已删除</div>}</div>
    </div>
  </div>;
}

function CodeDiff({ change, layout }) {
  const rows = diffLines(change.before || '', change.after || '');
  const additions = rows.filter(row => row.kind === 'added').length;
  const deletions = rows.filter(row => row.kind === 'removed').length;
  return <div className="code-diff">
    <div className="code-diff-summary"><span>{change.label === '?' ? '未跟踪文件' : '工作区变更'}</span><span className="green">+{additions}</span><span className="red">−{deletions}</span></div>
    {layout === '统一' ? <div className="file-unified-diff">{rows.map((row, index) => <div key={index} className={`commit-code-line ${row.kind}`}><span className="commit-line-number">{row.oldNumber}</span><span className="commit-line-number">{row.newNumber}</span><span className="commit-line-sign">{row.kind === 'added' ? '+' : row.kind === 'removed' ? '−' : ''}</span><code>{row.text || ' '}</code></div>)}</div> : <div className="file-split-diff"><div className="commit-split-labels"><span>HEAD</span><span>工作区</span></div>{pairedLines(rows).map((row, index) => <div className="commit-split-row" key={index}><DiffCell change={row.before} side="before"/><DiffCell change={row.after} side="after"/></div>)}</div>}
  </div>;
}

function DiffCell({ change, side }) {
  return <div className={`commit-code-line ${change?.kind || 'gap'}`}><span className="commit-line-number">{change?.[side === 'before' ? 'oldNumber' : 'newNumber']}</span><span className="commit-line-sign">{change?.kind === 'added' ? '+' : change?.kind === 'removed' ? '−' : ''}</span><code>{change?.text || ' '}</code></div>;
}

function ChangeDiff({ file, change, layout }) {
  if (change.binary || file.kind === 'image' || file.kind === 'pdf') return <BinaryDiff file={file} change={change}/>;
  return <CodeDiff change={change} layout={layout}/>;
}

function TreeFile({ file, change, selectedPath, onSelect, root = false }) {
  const tone = statusTone(change);
  return <button className={`tree-file ${root ? 'root-file' : ''} ${tone} ${selectedPath === file.path ? 'selected' : ''}`} onClick={() => onSelect(file)}>
    {fileIcon(file.kind)}<span>{file.path.split('/').pop()}</span>{change && <em className={`status-letter ${tone}`}>{change.label}</em>}
  </button>;
}

function ChangedFile({ file, change, onSelect }) {
  const tone = statusTone(change);
  return <button className={`changed-file-row ${tone}`} onClick={() => onSelect(file)}>
    {fileIcon(file.kind)}
    <span><b>{file.path.split('/').pop()}</b><small>{file.path.split('/').slice(0, -1).join('/') || '.'}</small></span>
    <em className={`status-letter ${tone}`}>{change.label}</em>
  </button>;
}

export default function FileBrowser({ onNotify, repo }) {
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
  const effectiveChange = change ? { ...change, after: change.state === 'deleted' ? change.after : content } : undefined;
  const editable = EDITABLE_KINDS.has(file.kind) && change?.state !== 'deleted';
  const queryText = query.trim().toLowerCase();
  const visibleWithin = paths => paths.filter(path => path.toLowerCase().includes(queryText));

  const toggleFolder = name => {
    setExpanded(current => {
      const next = new Set(current);
      if (next.has(name)) next.delete(name); else next.add(name);
      return next;
    });
  };

  const selectFile = selected => {
    setSelectedPath(selected.path);
    setEditing(false);
    setMarkdownMode('preview');
    setPreviewMode(project.changes[selected.path] ? 'diff' : 'preview');
  };

  const updateContent = nextContent => {
    setDocuments(current => ({ ...current, [file.path]: nextContent }));
    setDirtyFiles(current => {
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
        setDirtyFiles(current => {
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

  const switchScope = nextScope => {
    setScope(nextScope);
    setQuery('');
  };

  return <section className="file-browser" aria-label="项目文件与预览">
    <aside className="file-explorer">
      <div className="file-explorer-heading"><div><b>文件预览</b><span>{allFiles.length} 个文件 · {Object.keys(project.changes).length} 项变更</span></div><span className="file-view-icon" aria-hidden="true"><SidebarSimple size={16}/></span></div>
      <div className="file-scope-tabs" role="tablist" aria-label="文件视图">
        <button role="tab" aria-selected={scope === 'all'} className={scope === 'all' ? 'selected' : ''} onClick={() => switchScope('all')}>全部文件</button>
        <button role="tab" aria-selected={scope === 'changed'} className={scope === 'changed' ? 'selected' : ''} onClick={() => switchScope('changed')}>变更文件 <small>{Object.keys(project.changes).length}</small></button>
      </div>
      <label className="file-search"><MagnifyingGlass size={15}/><input value={query} onChange={event => setQuery(event.target.value)} placeholder={scope === 'all' ? '搜索全部文件…' : '搜索变更文件…'}/></label>
      {scope === 'all' ? <>
        <div className="tree-controls"><span>当前项目</span><div><button title="展开全部文件夹" aria-label="展开全部文件夹" onClick={() => setExpanded(new Set(project.tree.filter(node => node.type === 'folder').map(node => node.name)))}><ArrowsOutLineVertical/></button><button title="折叠全部文件夹" aria-label="折叠全部文件夹" onClick={() => setExpanded(new Set())}><ArrowsInLineVertical/></button></div></div>
        <div className="file-tree">
          {project.tree.map(node => {
            if (node.type === 'file') {
              if (queryText && !node.path.toLowerCase().includes(queryText)) return null;
              return <TreeFile key={node.path} root file={fileByName(node.path, allFiles)} change={project.changes[node.path]} selectedPath={selectedPath} onSelect={selectFile}/>;
            }
            const matchingPaths = visibleWithin(node.files);
            if (queryText && matchingPaths.length === 0) return null;
            const isOpen = Boolean(queryText) || expanded.has(node.name);
            return <div key={node.name}><button className="tree-folder" onClick={() => toggleFolder(node.name)} aria-expanded={isOpen}>{isOpen ? <CaretDown size={12}/> : <CaretRight size={12}/>}<Folder size={16}/><span>{node.name}</span><small>{matchingPaths.length}</small></button>{isOpen && matchingPaths.map(path => { const item = fileByName(path, allFiles); return <TreeFile key={path} file={item} change={project.changes[path]} selectedPath={selectedPath} onSelect={selectFile}/>; })}</div>;
          })}
        </div>
      </> : <>
        <div className="status-legend"><span className="unstaged"><i/>未暂存</span><span className="staged"><i/>已暂存</span><span className="deleted"><i/>已删除</span><span className="untracked"><i/>未跟踪</span></div>
        <div className="changed-files-list">
          {!queryText && <div className="change-group-label">未暂存 <span>{unstagedFiles.length}</span></div>}
          {unstagedFiles.filter(([path]) => path.toLowerCase().includes(queryText)).map(([path, item]) => <ChangedFile key={path} file={fileByName(path, allFiles)} change={item} onSelect={selectFile}/>)}
          {!queryText && <div className="change-group-label">已暂存 <span>{stagedFiles.length}</span></div>}
          {stagedFiles.filter(([path]) => path.toLowerCase().includes(queryText)).map(([path, item]) => <ChangedFile key={path} file={fileByName(path, allFiles)} change={item} onSelect={selectFile}/>)}
          {queryText && changedFilesMatching(queryText, project.changes).length === 0 && <div className="empty-tree">没有匹配的变更文件</div>}
        </div>
      </>}
      <div className="file-explorer-footer"><span className="dot"/>本地工作区 <b>{scope === 'all' ? allFiles.length : Object.keys(project.changes).length}</b></div>
    </aside>
    <section className="file-preview">
      <header className="file-preview-header">
        <div className="file-breadcrumb">{fileIcon(file.kind)}<span>{file.path}</span>{change && <em className={`header-change ${statusTone(change)}`}>{change.label} · {change.staged ? '已暂存' : '未暂存'}</em>}</div>
        <div className="file-preview-actions"><button onClick={() => onNotify(`演示：已复制 ${file.path}`)}>复制路径</button><button aria-label="下载文件" onClick={() => onNotify(`演示：已下载 ${file.path}`)}><DownloadSimple/></button></div>
      </header>
      <div className="file-preview-toolbar">
        {editing ? <span className="editing-status"><i/>编辑中 · 右侧实时预览</span> : <>
          {change && <div className="segmented change-mode">{[['diff','变更差异'],['preview','文件预览']].map(([mode, label]) => <button key={mode} className={previewMode === mode ? 'chosen' : ''} onClick={() => setPreviewMode(mode)}>{label}</button>)}</div>}
          {previewMode === 'diff' && !change?.binary && file.kind !== 'image' && file.kind !== 'pdf' && <div className="segmented">{[['并排','并排'],['统一','统一']].map(([mode, label]) => <button key={mode} className={diffLayout === mode ? 'chosen' : ''} onClick={() => setDiffLayout(mode)}>{label}</button>)}</div>}
          {previewMode === 'preview' && ['markdown','diagram','html','csv'].includes(file.kind) && <div className="segmented">{[['preview', file.kind === 'csv' ? '表格' : file.kind === 'diagram' ? '图表' : file.kind === 'html' ? '网页' : '渲染'],['source','源码']].map(([mode, label]) => <button key={mode} className={markdownMode === mode ? 'chosen' : ''} onClick={() => setMarkdownMode(mode)}>{label}</button>)}</div>}
          {previewMode === 'preview' && file.kind === 'image' && <div className="zoom-control" aria-label="图片缩放"><button onClick={() => setZoom(value => Math.max(.5, value - .25))} aria-label="缩小"><Minus/></button><span>{Math.round(zoom * 100)}%</span><button onClick={() => setZoom(value => Math.min(2, value + .25))} aria-label="放大"><Plus/></button></div>}
        </>}
        <span className="preview-toolbar-note">{editing ? `${languageFor(file)} · ${content.split('\n').length} 行` : change ? `${change.staged ? '已暂存' : '未暂存'} · 点击文件名可查看同一预览` : '工作区文件与 HEAD 一致'}</span>
        {editable && <button className={`file-edit-button ${editing ? 'active' : ''}`} onClick={toggleEditing}><PencilSimple/>{editing ? '完成编辑' : '编辑'}</button>}
      </div>
      <div className={`file-preview-body ${file.kind} ${editing ? 'editing' : previewMode}`}>
        {editing ? <LiveEditor file={file} content={content} onChange={updateContent}/> : previewMode === 'diff' && change ? <ChangeDiff file={file} change={effectiveChange} layout={diffLayout}/> : file.kind === 'image' ? <ImagePreview file={file} zoom={zoom}/> : file.kind === 'pdf' ? <PdfPreview/> : <TextPreview file={file} content={content} viewMode={markdownMode} change={change}/>}
      </div>
      <footer className="file-preview-footer"><span>{languageFor(file)} · UTF-8{editable ? ' · 可编辑' : ' · 只读'}</span><span>{dirtyFiles.has(file.path) ? '编辑未保存' : change ? `${change.label} · ${change.staged ? '已暂存' : '未暂存'}` : '与 HEAD 一致'}</span></footer>
    </section>
  </section>;
}

function changedFilesMatching(query, changes) {
  return Object.keys(changes).filter(path => path.toLowerCase().includes(query));
}
