import React, { Suspense, lazy, useEffect, useRef, useState } from 'react';
import { ArrowSquareOut, CaretDown, CaretRight, FileCode, Terminal, X } from '@phosphor-icons/react';
import { errorText, isNative, request } from './bridge.js';
import { IconButton } from './ui.jsx';

const MarkdownRenderer = lazy(() => import('../MarkdownRenderer.jsx'));
const FILE_READ_LIMIT = 1024 * 1024;
const EXAMPLE_FILES = [
  { path: 'Web/src/shell/Sidebar.jsx', line: 4 },
  { path: 'docs/交互说明.md' },
  { path: 'Web/src/shell/clawd-mark.png' },
  { path: 'docs/设计评审.docx' },
];
const EXAMPLE_URL = 'https://docs.pi.dev/latest/cli';
const MORE_FILES = [
  ['文档与表格', ['docs/评审摘要.pdf', 'docs/周报.xlsx', 'docs/评审演示.pptx', 'data/任务清单.csv', 'data/运行记录.tsv']],
  ['文本与配置', ['notes/待办.txt', 'logs/build.log', 'config/app.json', 'config/settings.yaml', 'config/manifest.xml', 'config/defaults.toml', 'site/index.html']],
  ['媒体与归档', ['media/提示音.wav', 'media/界面演示.mp4', 'artifacts/评审资料.zip']],
];

function readDelimited(content, delimiter) {
  const rows = [];
  let row = [];
  let cell = '';
  let quoted = false;
  for (let index = 0; index < content.length && rows.length <= 200; index += 1) {
    const char = content[index];
    if (char === '"') {
      if (quoted && content[index + 1] === '"') {
        cell += '"';
        index += 1;
      } else if (quoted || !cell) {
        quoted = !quoted;
      } else {
        cell += char;
      }
    } else if (!quoted && (char === delimiter || char === '\n' || char === '\r')) {
      row.push(cell);
      cell = '';
      if (char === delimiter) continue;
      rows.push(row);
      row = [];
      if (char === '\r' && content[index + 1] === '\n') index += 1;
    } else {
      cell += char;
    }
  }
  if (cell || row.length) rows.push([...row, cell]);
  return rows;
}

function PreviewTable({ rows }) {
  const columns = Math.min(30, Math.max(0, ...rows.slice(0, 200).map((row) => row.length)));
  if (!columns) return <p className="pane-note">没有表格数据。</p>;
  const header = rows[0];
  return (
    <div className="terminal-file-table">
      <table>
        <thead><tr>{Array.from({ length: columns }, (_, index) => <th key={index}>{header[index] || `列 ${index + 1}`}</th>)}</tr></thead>
        <tbody>{rows.slice(1, 200).map((row, index) => (
          <tr key={index}>{Array.from({ length: columns }, (_, col) => <td key={col}>{row[col]}</td>)}</tr>
        ))}</tbody>
      </table>
      {(rows.length > 200 || rows.some((row) => row.length > 30)) && <p>预览最多显示 200 行、30 列。</p>}
    </div>
  );
}

function OpenWithMenu({ projectPath, filePath, onSelect, onError }) {
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [apps, setApps] = useState([]);
  const [loadError, setLoadError] = useState(null);
  const root = useRef(null);
  const opener = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    let current = true;
    setLoading(true);
    setLoadError(null);
    request('file.openWithApps', { projectPath, filePath })
      .then((result) => {
        if (!current) return;
        setApps(result?.apps ?? []);
        setLoading(false);
      })
      .catch((cause) => {
        if (!current) return;
        setApps([]);
        setLoadError(errorText(cause));
        setLoading(false);
      });
    const dismiss = (event) => { if (!root.current?.contains(event.target)) setOpen(false); };
    document.addEventListener('pointerdown', dismiss);
    return () => {
      current = false;
      document.removeEventListener('pointerdown', dismiss);
    };
  }, [open, projectPath, filePath]);

  useEffect(() => {
    if (open && !loading) {
      root.current?.querySelector('[role=menuitem]')?.focus();
    }
  }, [open, loading, apps.length]);

  function close() {
    setOpen(false);
    opener.current?.focus();
  }

  async function pick(app) {
    close();
    try {
      const result = await request('file.openWith', { projectPath, filePath, appPath: app.path });
      onSelect(result?.appName || app.name, Boolean(result?.demo));
    } catch (cause) {
      onError(errorText(cause));
    }
  }

  return (
    <div className="terminal-open-with project-menu-wrap" ref={root}>
      <button ref={opener} type="button" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        <ArrowSquareOut size={14} aria-hidden="true" /> 打开方式 <CaretDown size={12} aria-hidden="true" />
      </button>
      {open && (
        <div className="dropdown" role="menu" aria-label="选择 Mac 应用" data-blocking onKeyDown={(event) => {
          if (event.key === 'Escape') {
            event.stopPropagation();
            close();
            return;
          }
          const options = [...event.currentTarget.querySelectorAll('[role=menuitem]')];
          if (!options.length) return;
          const index = options.indexOf(event.target);
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            options[(index + (event.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length]?.focus();
          } else if (event.key === 'Home') {
            event.preventDefault();
            options[0]?.focus();
          } else if (event.key === 'End') {
            event.preventDefault();
            options[options.length - 1]?.focus();
          }
        }}>
          {loading ? (
            <div className="pane-note" role="status">正在读取应用…</div>
          ) : loadError ? (
            <div className="pane-note error" role="alert">{loadError}</div>
          ) : !apps.length ? (
            <div className="pane-note">没有找到可打开此文件的应用</div>
          ) : (
            apps.map((app) => (
              <button key={app.path || app.name} type="button" role="menuitem" title={app.path || app.name}
                onClick={() => pick(app)}>
                <span>{app.name}</span>
                {app.isDefault && <em className="open-with-default">默认</em>}
              </button>
            ))
          )}
        </div>
      )}
    </div>
  );
}

export function TerminalExample({ session, onOpenFile }) {
  const directory = session.cwd || session.projectPath;
  function showFile(file) {
    onOpenFile({
      ...file,
      sessionId: session.sessionId,
      projectPath: directory,
      displayPath: `${directory.replace(/\/$/, '')}/${file.path}`,
    });
  }
  function fileLink(file) {
    return (
      <button type="button" key={file.path} className="terminal-example-path" title={file.path} onClick={() => showFile(file)}>
        <FileCode size={14} aria-hidden="true" /> <code>{file.path}{file.line && `:${file.line}`}</code>
      </button>
    );
  }
  return (
    <div className="terminal-example" aria-label="终端交互示例">
      <header><strong>{session.label}</strong><span>浏览器演示</span></header>
      <div className="terminal-example-result">
        <span>更新了</span>
        {EXAMPLE_FILES.map(fileLink)}
      </div>
      <details className="terminal-example-command terminal-file-examples">
        <summary><CaretRight size={13} aria-hidden="true" /> 常见文件类型</summary>
        {MORE_FILES.map(([name, paths]) => (
          <div className="terminal-example-result" key={name}>
            <span>{name}</span>{paths.map((path) => fileLink({ path }))}
          </div>
        ))}
      </details>
      <div className="terminal-example-result">
        <span>参考文档</span>
        <a href={EXAMPLE_URL} target="_blank" rel="noopener noreferrer">
          {EXAMPLE_URL} <ArrowSquareOut size={13} aria-hidden="true" />
        </a>
      </div>
      <details className="terminal-example-command">
        <summary>
          <CaretRight size={13} aria-hidden="true" />
          <Terminal size={14} aria-hidden="true" />
          <code>npm run build</code>
          <span>已完成</span>
        </summary>
        <pre>{'› vite build\n✓ 资源构建完成'}</pre>
      </details>
    </div>
  );
}

export function TerminalFilePreview({ target, draft, onEdit, onClose }) {
  const { projectPath, path, displayPath, line } = target;
  const [file, setFile] = useState(null);
  const [error, setError] = useState(null);
  const [editing, setEditing] = useState(Boolean(draft && draft.status !== 'saved'));
  const [pageIndex, setPageIndex] = useState(0);
  const [openFeedback, setOpenFeedback] = useState(null);
  const selectedLine = useRef(null);
  const editable = file && !file.isBinary && !file.truncated && typeof file.content === 'string';
  const useDraft = draft && (draft.status !== 'saved' || !(file?.modifiedAt > draft.modifiedAt));
  const content = useDraft ? draft.content : file?.content;
  const canOpenWith = Boolean(file && !error);

  useEffect(() => {
    let current = true;
    setFile(null);
    setError(null);
    setPageIndex(0);
    setOpenFeedback(null);
    request('file.read', { projectPath, filePath: path, maxBytes: FILE_READ_LIMIT })
      .then((result) => { if (current) setFile(result); })
      .catch((cause) => { if (current) setError(errorText(cause)); });
    return () => { current = false; };
  }, [projectPath, path]);

  useEffect(() => {
    selectedLine.current?.scrollIntoView({ block: 'nearest' });
  }, [file, editing, line]);

  function renderFile() {
    if (error) return <p role="alert">{error}</p>;
    if (!file) return <p role="status">读取文件中…</p>;
    const filename = path.split('/').at(-1);
    if (file.kind === 'image' && file.content)
      return <div className="image-preview"><img src={file.content} alt={filename} /></div>;
    if (file.kind === 'pdf' && file.previewImage)
      return <div className="image-preview"><img src={file.previewImage} alt={`${filename} · 第 1 页`} /></div>;
    if (file.kind === 'pdf' && file.content)
      return <object className="terminal-file-pdf" data={file.content} type="application/pdf" aria-label={filename}>当前环境无法内嵌预览 PDF，可使用「打开方式」查看。</object>;
    if (file.kind === 'audio' && file.content)
      return <div className="terminal-file-media"><audio src={file.content} controls preload="metadata" aria-label={filename} /></div>;
    if (file.kind === 'video' && file.content)
      return <div className="terminal-file-media"><video src={file.content} controls preload="metadata" playsInline aria-label={filename} /></div>;
    if (file.kind === 'delimited' || file.kind === 'csv')
      return <PreviewTable rows={readDelimited(content ?? '', /\.tsv$/i.test(path) ? '\t' : ',')} />;
    if (file.kind === 'spreadsheet' && file.sheets?.length) {
      const sheet = file.sheets[Math.min(pageIndex, file.sheets.length - 1)];
      return (
        <>
          <div className="terminal-file-subnav" aria-label="工作表">
            {file.sheets.map((item, index) => (
              <button type="button" key={`${item.name}-${index}`} aria-pressed={index === pageIndex} onClick={() => setPageIndex(index)}>{item.name}</button>
            ))}
          </div>
          <PreviewTable rows={sheet.rows} />
        </>
      );
    }
    if (file.kind === 'presentation' && file.slides?.length) {
      const slide = file.slides[Math.min(pageIndex, file.slides.length - 1)];
      return (
        <>
          <div className="terminal-file-subnav" aria-label="幻灯片导航">
            <button type="button" disabled={pageIndex === 0} onClick={() => setPageIndex(pageIndex - 1)}>上一页</button>
            <span>{pageIndex + 1} / {file.slides.length}</span>
            <button type="button" disabled={pageIndex === file.slides.length - 1} onClick={() => setPageIndex(pageIndex + 1)}>下一页</button>
          </div>
          <div className="terminal-file-slide"><h3>{slide.title}</h3><p>{slide.body}</p></div>
        </>
      );
    }
    if (file.kind === 'archive' && file.entries)
      return <PreviewTable rows={[['文件名', '大小'], ...file.entries]} />;
    if ((file.kind === 'markdown' || file.kind === 'document') && typeof content === 'string')
      return (
        <article className="document terminal-file-document">
          <Suspense fallback={<p>正在渲染…</p>}><MarkdownRenderer content={content} /></Suspense>
        </article>
      );
    if (file.content == null || file.isBinary)
      return <p>{file.truncated ? '该文件超出当前预览范围，可使用「打开方式」查看。' : '该文件格式暂不支持预览。'}</p>;
    return (
      <pre tabIndex={0} aria-label="文件内容">
        {content.split('\n').map((text, index) => {
          const number = index + 1;
          return (
            <span key={number} className={number === line ? 'is-target' : undefined} ref={number === line ? selectedLine : null}>
              <span aria-hidden="true">{number}</span><code>{text || ' '}</code>
            </span>
          );
        })}
      </pre>
    );
  }

  return (
    <section className="workbench terminal-file-preview" aria-label="终端文件预览">
      <header>
        <FileCode size={17} aria-hidden="true" />
        <div>
          <h2>{path.split('/').at(-1)}</h2>
          <small title={displayPath}>{displayPath}{line ? `:${line}` : ''}</small>
        </div>
        <IconButton icon={X} label="关闭文件预览" onClick={onClose} />
      </header>
      {(editable || canOpenWith) && (
        <div className="terminal-file-toolbar">
          {editable && <div className="segmented" aria-label="文件查看方式">
            <button type="button" aria-pressed={!editing} className={!editing ? 'chosen' : ''} onClick={() => setEditing(false)}>预览</button>
            <button type="button" aria-pressed={editing} className={editing ? 'chosen' : ''} onClick={() => setEditing(true)}>编辑</button>
          </div>}
          {editable && <small role="status">
            {draft?.status === 'saving' ? '正在自动保存…' : draft?.status === 'error' ? '自动保存失败' : useDraft ? '已自动保存' : '编辑后自动保存'}
          </small>}
          {canOpenWith && (
            <OpenWithMenu
              projectPath={projectPath}
              filePath={path}
              onSelect={(appName, demo) => setOpenFeedback({
                error: false,
                text: demo || !isNative() ? `已选择 ${appName} · 浏览器演示` : `已通过 ${appName} 打开`,
              })}
              onError={(message) => setOpenFeedback({ error: true, text: message })}
            />
          )}
        </div>
      )}
      {draft?.error && <p role="alert">{draft.error}</p>}
      {openFeedback && (
        <p className={`terminal-open-result${openFeedback.error ? ' is-error' : ''}`} role={openFeedback.error ? 'alert' : 'status'}>
          {openFeedback.text}
        </p>
      )}
      {editing && editable ? (
        <textarea className="file-editor" aria-label="编辑文件内容" spellCheck={false}
          value={content} onChange={(event) => onEdit(event.target.value, useDraft ? draft.modifiedAt ?? file.modifiedAt : file.modifiedAt)}
          onKeyDown={(event) => {
            if ((event.metaKey || event.ctrlKey) && event.key === 's') {
              event.preventDefault();
            }
          }} />
      ) : renderFile()}
    </section>
  );
}
