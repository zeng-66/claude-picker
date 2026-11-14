import React, { useState } from 'react';
import { X, FileCode, GitCommit, CaretLeft } from '@phosphor-icons/react';
import './commit-details.css';

const fileVersions = {
  'GitPanel.swift': {
    before: 'import SwiftUI\n\nstruct GitPanel: View {\n    var body: some View {\n        VStack(spacing: 12) {\n            statusHeader\n            changedFiles\n            commitForm\n        }\n    }\n}',
    after: 'import SwiftUI\n\nstruct GitPanel: View {\n    @ObservedObject var store: GitStore\n\n    var body: some View {\n        HSplitView {\n            changesSidebar\n                .frame(minWidth: 280)\n            DiffView(file: store.selectedFile)\n        }\n        .background(Color.workspace)\n    }\n}'
  },
  'Models.swift': {
    before: 'import Foundation\n\nstruct WorkspaceState {\n    var branch: String\n}',
    after: 'import Foundation\n\nstruct WorkspaceState {\n    var branch: String\n    var changedFiles: [GitFile] = []\n    var selectedFile: GitFile?\n    var isLoading = false\n}'
  },
  'GitService.swift': {
    before: '',
    after: 'import Foundation\n\nstruct GitFile: Identifiable {\n    let path: String\n    let status: String\n    var id: String { path }\n}\n\nfinal class GitService {\n    func changedFiles() -> [GitFile] {\n        return []\n    }\n}'
  },
  'git-workbench.md': {
    before: '',
    after: '# Git 工作台\n\n## 工作区\n\n- 审阅文件变更\n- 暂存文件\n- 创建提交\n\n## 提交历史\n\n选择提交，查看文件内容及差异。'
  },
  'TerminalPane.swift': {
    before: 'import SwiftUI\n\nfunc focusTerminal() {\n    terminal.becomeFirstResponder()\n}\n',
    after: 'import SwiftUI\n\nfunc focusTerminal() {\n    guard window.isKeyWindow else { return }\n    terminal.becomeFirstResponder()\n}\n'
  },
  'SessionList.swift': {
    before: 'import SwiftUI\n\nfunc selectSession(_ session: Session) {\n    store.activeSession = session\n}',
    after: 'import SwiftUI\n\nfunc selectSession(_ session: Session) {\n    store.activeProject = session.project\n    store.activeSession = session\n    store.restoreTerminal(for: session)\n}'
  },
  'WorkspaceStore.swift': {
    before: 'import Combine\n\nfinal class WorkspaceStore: ObservableObject {\n    var selectedProject: String = ""\n}',
    after: 'import Combine\n\nfinal class WorkspaceStore: ObservableObject {\n    @Published var selectedProject: String = ""\n    @Published var activeSession: String?\n}'
  },
  'SidebarView.swift': {
    before: 'import SwiftUI\n\nvar sidebarWidth: CGFloat {\n    settings.sidebarWidth\n}',
    after: 'import SwiftUI\n\nvar sidebarWidth: CGFloat {\n    settings.sidebarCollapsed ? 0 : settings.sidebarWidth\n}'
  }
};

export function snapshotFile(file) {
  const versions = fileVersions[file.name];
  return {
    name: file.name,
    path: file.path,
    before: versions.before,
    after: versions.after
  };
}

export function demoCommit(message, index) {
  const names = [
    ['GitPanel.swift', 'Models.swift', 'GitService.swift', 'git-workbench.md'],
    ['TerminalPane.swift'],
    ['SessionList.swift', 'Models.swift'],
    ['WorkspaceStore.swift', 'Models.swift'],
    ['GitPanel.swift', 'GitService.swift'],
    ['SidebarView.swift']
  ][index];
  return {
    message,
    hash: ['a3f2c91', 'e7b10d4', 'c8a7f12', 'f29de01', 'd31ab68', 'b80c6a2'][index],
    author: '曾长亮',
    time: index === 0 ? '刚刚' : `${index} 小时前`,
    files: names.map(name => snapshotFile({ name, path: name.endsWith('.md') ? 'docs' : 'Sources/ClaudeDeck' }))
  };
}

function lines(text) {
  return text === '' ? [] : text.split('\n');
}

// Match unchanged lines so additions and deletions retain their own line numbers.
export function diffLines(before, after) {
  const oldLines = lines(before);
  const newLines = lines(after);
  const lengths = Array.from({ length: oldLines.length + 1 }, () => Array(newLines.length + 1).fill(0));
  for (let oldIndex = oldLines.length - 1; oldIndex >= 0; oldIndex--) {
    for (let newIndex = newLines.length - 1; newIndex >= 0; newIndex--) {
      lengths[oldIndex][newIndex] = oldLines[oldIndex] === newLines[newIndex]
        ? lengths[oldIndex + 1][newIndex + 1] + 1
        : Math.max(lengths[oldIndex + 1][newIndex], lengths[oldIndex][newIndex + 1]);
    }
  }
  const result = [];
  let oldIndex = 0;
  let newIndex = 0;
  while (oldIndex < oldLines.length || newIndex < newLines.length) {
    if (oldIndex < oldLines.length && newIndex < newLines.length && oldLines[oldIndex] === newLines[newIndex]) {
      result.push({ kind: 'context', text: oldLines[oldIndex], oldNumber: ++oldIndex, newNumber: ++newIndex });
    } else if (oldIndex < oldLines.length && (newIndex === newLines.length || lengths[oldIndex + 1][newIndex] >= lengths[oldIndex][newIndex + 1])) {
      result.push({ kind: 'removed', text: oldLines[oldIndex], oldNumber: ++oldIndex });
    } else {
      result.push({ kind: 'added', text: newLines[newIndex], newNumber: ++newIndex });
    }
  }
  return result;
}

export function pairedLines(changes) {
  const rows = [];
  let index = 0;
  while (index < changes.length) {
    if (changes[index].kind === 'context') {
      rows.push({ before: changes[index], after: changes[index] });
      index++;
      continue;
    }
    const removed = [];
    const added = [];
    while (index < changes.length && changes[index].kind !== 'context') {
      const change = changes[index++];
      (change.kind === 'removed' ? removed : added).push(change);
    }
    for (let row = 0; row < Math.max(removed.length, added.length); row++) {
      rows.push({ before: removed[row], after: added[row] });
    }
  }
  return rows;
}

function DiffCell({ change, side }) {
  return <div className={`commit-code-line ${change?.kind || 'gap'}`}>
    <span className="commit-line-number">{change?.[side === 'before' ? 'oldNumber' : 'newNumber']}</span>
    <span className="commit-line-sign">{change?.kind === 'added' ? '+' : change?.kind === 'removed' ? '−' : ''}</span>
    <code>{change?.text || ' '}</code>
  </div>;
}

export default function CommitDetails({ commit, onClose }) {
  const [selectedPath, setSelectedPath] = useState(commit.files[0].name);
  const [view, setView] = useState('Diff');
  const [layout, setLayout] = useState('统一');
  const [version, setVersion] = useState('after');
  const file = commit.files.find(item => item.name === selectedPath);
  const changes = diffLines(file.before, file.after);
  const allChanges = commit.files.flatMap(item => diffLines(item.before, item.after));
  const additions = allChanges.filter(line => line.kind === 'added').length;
  const deletions = allChanges.filter(line => line.kind === 'removed').length;
  const fileStatus = item => item.before === '' ? 'A' : item.after === '' ? 'D' : 'M';

  return <div className="overlay commit-overlay" onClick={onClose}>
    <section className="commit-detail" role="dialog" aria-modal="true" aria-labelledby="commit-detail-title" onClick={event => event.stopPropagation()}>
      <header className="commit-detail-header">
        <div><GitCommit size={20}/><span>提交详情</span><code>{commit.hash}</code></div>
        <button onClick={onClose} aria-label="关闭提交详情" autoFocus><X size={20}/></button>
      </header>
      <div className="commit-summary">
        <h2 id="commit-detail-title">{commit.message}</h2>
        <p>{commit.author} <span>·</span> {commit.time} <span>·</span> {commit.files.length} 个文件 <span className="green">+{additions}</span><span className="red">−{deletions}</span></p>
      </div>
      <div className="commit-detail-body">
        <aside className="commit-file-list" aria-label="本次提交的文件">
          <div className="commit-list-label">本次提交的文件 <small>{commit.files.length}</small></div>
          {commit.files.map(item => <button key={item.name} className={item.name === selectedPath ? 'selected' : ''} aria-pressed={item.name === selectedPath} onClick={() => setSelectedPath(item.name)}>
            <FileCode size={18}/><span><b>{item.name}</b><small>{item.path}</small></span><em className={fileStatus(item)}>{fileStatus(item)}</em>
          </button>)}
        </aside>
        <section className="commit-file-preview">
          <div className="commit-preview-toolbar"><span title={`${file.path}/${file.name}`}>{file.path}/{file.name}</span><div className="segmented">{['Diff', '文件内容'].map(mode => <button key={mode} className={view === mode ? 'chosen' : ''} onClick={() => setView(mode)}>{mode}</button>)}</div></div>
          <div className="commit-version-toolbar">
            <span>{view === 'Diff' ? '父提交 → 本次提交' : version === 'after' ? '本次提交的完整文件' : '父提交的完整文件'}</span>
            <div className="segmented">{view === 'Diff' ? ['并排', '统一'].map(mode => <button key={mode} className={layout === mode ? 'chosen' : ''} onClick={() => setLayout(mode)}>{mode}</button>) : [['before', '提交前'], ['after', '提交后']].map(([mode, label]) => <button key={mode} className={version === mode ? 'chosen' : ''} onClick={() => setVersion(mode)}>{label}</button>)}</div>
          </div>
          <div className="commit-code-scroll">
            {view === '文件内容' ? <div className="commit-full-file">{file[version] === '' ? <p className="commit-file-empty">{version === 'before' ? '此文件在本次提交中新建，父提交中不存在。' : '此文件在本次提交中删除。'}</p> : lines(file[version]).map((text, index) => <DiffCell key={index} side={version} change={{ text, kind: 'context', oldNumber: index + 1, newNumber: index + 1 }}/>)}</div> : layout === '统一' ? <div className="commit-unified">{changes.map((change, index) => <div key={index} className={`commit-code-line ${change.kind}`}><span className="commit-line-number">{change.oldNumber}</span><span className="commit-line-number">{change.newNumber}</span><span className="commit-line-sign">{change.kind === 'added' ? '+' : change.kind === 'removed' ? '−' : ''}</span><code>{change.text || ' '}</code></div>)}</div> : <div className="commit-split"><div className="commit-split-labels"><span>父提交</span><span>本次提交</span></div>{pairedLines(changes).map((row, index) => <div className="commit-split-row" key={index}><DiffCell side="before" change={row.before}/><DiffCell side="after" change={row.after}/></div>)}</div>}
          </div>
          <footer className="commit-preview-footer"><span>{fileStatus(file) === 'A' ? '新增文件' : '修改文件'}</span><span className="green">+{changes.filter(line => line.kind === 'added').length}</span><span className="red">−{changes.filter(line => line.kind === 'removed').length}</span><span>UTF-8</span></footer>
        </section>
      </div>
      <footer className="commit-detail-footer"><span>模拟提交快照</span><button onClick={onClose}><CaretLeft/>返回提交历史</button></footer>
    </section>
  </div>;
}
