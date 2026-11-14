// 预览分派：真实内容走桥（file.read），Markdown / Mermaid / HTML / CSV / 代码 /
// JSON / YAML 走文本预览，图片与 PDF 走各自的可视化组件。
// 图片 / PDF 的字节由 Swift 侧塞进 FileContent.content（data URL），这里直接消费。
import React, { lazy, Suspense, useEffect, useRef, useState } from 'react';
import { request } from '../bridge/client.js';
import { fileNameOf, projectPathFor, syntaxFor } from './file-meta.jsx';

const MarkdownRenderer = lazy(() => import('../MarkdownRenderer.jsx'));
const MermaidDiagram = lazy(() => import('../MermaidDiagram.jsx'));

/** 文本超过 1 MB 先让用户确认（T5 硬要求）；8 MB 以上不再塞进预览。 */
const LARGE_FILE_BYTES = 1024 * 1024;
const READ_LIMIT_BYTES = 8 * 1024 * 1024;
/** 单文件最多渲染这么多行，避免 8 MB 文本把 React 挂住。 */
const MAX_RENDER_LINES = 4000;
/** 单行最长渲染字符数，压缩过的 JS 一行可能上百万字符。 */
const MAX_LINE_CHARS = 2000;

const TOKEN_COLORS = {
  comment: '#6f747d',
  string: '#a3c9a8',
  number: '#d4b56f',
  keyword: '#c9a2d9',
  key: '#8fb8d8',
  tag: '#d8a087',
  attr: '#c9c1a3',
};

const KEYWORDS = {
  js: /\b(?:const|let|var|function|return|if|else|for|of|in|import|from|export|default|class|new|await|async|try|catch|throw|typeof|instanceof|null|undefined|true|false)\b/g,
  swift:
    /\b(?:let|var|func|return|if|else|guard|for|in|while|struct|enum|class|protocol|extension|import|async|await|throws|try|throw|nil|true|false|self|static|private|public|init)\b/g,
  py: /\b(?:def|class|return|if|elif|else|for|in|while|import|from|as|with|try|except|raise|None|True|False|self|lambda|yield)\b/g,
  shell: /\b(?:if|then|else|fi|for|in|do|done|function|export|return|echo|set|local)\b/g,
  css: /@[\w-]+/g,
};

const PATTERNS = {
  json: [
    [/(\"(?:[^\"\\]|\\.)*\")(?=\s*:)/g, 'key'],
    [/(\"(?:[^\"\\]|\\.)*\")/g, 'string'],
    [/(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/g, 'number'],
    [/\b(true|false|null)\b/g, 'keyword'],
  ],
  yaml: [
    [/(^\s*(?:-\s*)?[\w.$-]+)(?=\s*:)/g, 'key'],
    [/(#.*$)/g, 'comment'],
    [/('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")/g, 'string'],
    [/(-?\d+(?:\.\d+)?)/g, 'number'],
  ],
  html: [
    [/(<!--.*?-->)/g, 'comment'],
    [/(<\/?[\w-]+)/g, 'tag'],
    [/([\w-]+)(?==)/g, 'attr'],
    [/(\"[^\"]*\")/g, 'string'],
  ],
  generic: [
    [/(\/\/.*$|#(?![\w{]).*$|\/\*.*?\*\/)/g, 'comment'],
    [/('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"|`(?:[^`\\]|\\.)*`)/g, 'string'],
    [/(-?\b\d+(?:\.\d+)?\b)/g, 'number'],
  ],
};

function stylesFor(lang) {
  return PATTERNS[lang] ?? PATTERNS.generic;
}

/** 单行着色：按语言套几条正则，返回 React 节点；不拼 HTML，避免注入。 */
function highlightLine(line, lang) {
  if (lang === 'text' || !line) return line;
  const rules = stylesFor(lang);
  const matches = [];
  rules.forEach(([pattern, tone]) => {
    pattern.lastIndex = 0;
    let hit;
    while ((hit = pattern.exec(line))) {
      if (!hit[0].length) {
        pattern.lastIndex += 1;
        continue;
      }
      matches.push({ start: hit.index, end: hit.index + hit[0].length, tone });
      if (matches.length > 400) break;
    }
  });
  const keywords = KEYWORDS[lang];
  if (keywords) {
    keywords.lastIndex = 0;
    let hit;
    while ((hit = keywords.exec(line))) {
      if (!hit[0].length) {
        keywords.lastIndex += 1;
        continue;
      }
      matches.push({ start: hit.index, end: hit.index + hit[0].length, tone: 'keyword' });
      if (matches.length > 400) break;
    }
  }
  if (!matches.length) return line;
  matches.sort((a, b) => a.start - b.start || b.end - a.end);
  const nodes = [];
  let cursor = 0;
  matches.forEach((match) => {
    if (match.start < cursor) return;
    if (match.start > cursor) nodes.push(line.slice(cursor, match.start));
    nodes.push(
      <span key={`${match.start}-${nodes.length}`} style={{ color: TOKEN_COLORS[match.tone] }}>
        {line.slice(match.start, match.end)}
      </span>,
    );
    cursor = match.end;
  });
  if (cursor < line.length) nodes.push(line.slice(cursor));
  return nodes;
}

function formatTime(value) {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString('zh-CN', { hour12: false });
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function isDataURL(value) {
  return typeof value === 'string' && value.startsWith('data:');
}

export function MarkdownPreview({ content, modifiedAt, truncated }) {
  return (
    <div className="markdown-document">
      <Suspense fallback={<div className="markdown-loading">正在渲染 Markdown…</div>}>
        <MarkdownRenderer content={content} />
      </Suspense>
      <div className="markdown-footer">
        {content.split('\n').length} 行 · Markdown
        {modifiedAt ? ` · 修改于 ${formatTime(modifiedAt)}` : ''}
        {truncated ? ' · 已截断' : ''}
      </div>
    </div>
  );
}

export function SourceLines({ content, path = '', truncated }) {
  const lines = content.split('\n');
  const visible = lines.slice(0, MAX_RENDER_LINES);
  const lang = syntaxFor(path);
  return (
    <div className="source-lines">
      {visible.map((line, index) => {
        const shown =
          line.length > MAX_LINE_CHARS ? `${line.slice(0, MAX_LINE_CHARS)} …（本行已截断）` : line;
        return (
          <div className="source-row" key={index}>
            <span>{index + 1}</span>
            <code>{highlightLine(shown, lang) || ' '}</code>
          </div>
        );
      })}
      {(lines.length > MAX_RENDER_LINES || truncated) && (
        <div className="empty-tree" style={{ padding: '10px 0' }}>
          {lines.length > MAX_RENDER_LINES
            ? `仅显示前 ${MAX_RENDER_LINES} 行（共 ${lines.length} 行）`
            : '内容已截断'}
        </div>
      )}
    </div>
  );
}

export function DiagramPreview({ content }) {
  return (
    <div className="diagram-preview">
      <Suspense fallback={<div className="mermaid-loading">正在载入图表…</div>}>
        <MermaidDiagram chart={content} />
      </Suspense>
    </div>
  );
}

export function HtmlPreview({ content }) {
  return (
    <iframe
      className="html-preview"
      title="HTML 实时预览"
      sandbox="allow-scripts"
      srcDoc={content}
    />
  );
}

export function CsvPreview({ content }) {
  const rows = content
    .replace(/^\uFEFF/, '')
    .split(/\r?\n/)
    .filter(Boolean)
    .map((row) => row.split(','));
  const header = rows[0] || [];
  return (
    <div className="csv-view">
      <table>
        <thead>
          <tr>
            {header.map((cell, index) => (
              <th key={`${cell}-${index}`}>{cell}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.slice(1).map((row, rowIndex) => (
            <tr key={rowIndex}>
              {row.map((cell, index) => (
                <td key={`${cell}-${index}`}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <p>
        {Math.max(rows.length - 1, 0)} 行数据 · {header.length} 列
      </p>
    </div>
  );
}

export function TextPreview({ file, content, viewMode, change, modifiedAt, truncated }) {
  const deleted = change?.state === 'deleted';
  let preview;

  if (file.kind === 'markdown')
    preview =
      viewMode === 'source' ? (
        <SourceLines content={content} path={file.path} truncated={truncated} />
      ) : (
        <MarkdownPreview content={content} modifiedAt={modifiedAt} truncated={truncated} />
      );
  else if (file.kind === 'diagram')
    preview =
      viewMode === 'source' ? (
        <SourceLines content={content} path={file.path} truncated={truncated} />
      ) : (
        <DiagramPreview content={content} />
      );
  else if (file.kind === 'html')
    preview =
      viewMode === 'source' ? (
        <SourceLines content={content} path={file.path} truncated={truncated} />
      ) : (
        <HtmlPreview content={content} />
      );
  else if (file.kind === 'csv')
    preview =
      viewMode === 'source' ? (
        <SourceLines content={content} path={file.path} truncated={truncated} />
      ) : (
        <CsvPreview content={content} />
      );
  else preview = <SourceLines content={content} path={file.path} truncated={truncated} />;

  return (
    <>
      {deleted && (
        <div className="deleted-file-banner">此文件已从工作区删除，以下内容来自父提交。</div>
      )}
      {preview}
    </>
  );
}

export function ImagePreview({ file, zoom, src }) {
  const [size, setSize] = useState(null);
  const url = src ?? file.src;
  if (!url) return <BinaryNotice file={file} reason="图片数据没有随文件返回。" />;
  return (
    <div className="image-viewer">
      <div className="image-stage">
        <img
          src={url}
          alt={file.path}
          style={{ transform: `scale(${zoom})` }}
          onLoad={(event) =>
            setSize(`${event.currentTarget.naturalWidth} × ${event.currentTarget.naturalHeight} px`)
          }
        />
      </div>
      <div className="image-info">
        <div>
          <b>{fileNameOf(file)}</b>
          <span>
            图片 · {size ?? file.dimensions ?? '尺寸未知'}
            {url.startsWith('data:') ? ' · data URL' : ''}
          </span>
        </div>
        <span>{file.size ?? ''}</span>
      </div>
    </div>
  );
}

export function PdfPreview({ file, src }) {
  return (
    <div
      className="pdf-viewer"
      style={{ flexDirection: 'column', gap: 8, padding: 12, alignItems: 'stretch' }}
    >
      {src ? (
        <object
          data={src}
          type="application/pdf"
          aria-label={`PDF 预览：${file.path}`}
          style={{ flex: 1, width: '100%', minHeight: 320, border: '1px solid #33353c' }}
        >
          <div className="binary-empty">当前环境无法内嵌 PDF，请用系统默认程序打开。</div>
        </object>
      ) : (
        <div className="binary-empty">PDF 数据没有随文件返回，无法内嵌预览。</div>
      )}
      <div className="empty-tree" style={{ padding: 0 }}>
        PDF 只读预览 · 若上方空白，请用系统默认程序打开：{file.path}
      </div>
    </div>
  );
}

function BinaryNotice({ file, reason }) {
  return (
    <div className="empty-tree" style={{ padding: 30, lineHeight: 1.9 }}>
      <b>{fileNameOf(file)}</b>
      <p>{reason}</p>
      <p>这类文件不在预览里解码，请用系统默认程序打开：{file.path}</p>
    </div>
  );
}

function LargeFileConfirm({ file, size, onConfirm }) {
  return (
    <div className="empty-tree" style={{ padding: 30, lineHeight: 1.9 }}>
      <b>{fileNameOf(file)}</b>
      <p>文件 {formatBytes(size)}，超过 1 MB。直接加载会让第三栏变慢，确认要预览吗？</p>
      <button className="tree-file" style={{ paddingLeft: 0 }} onClick={onConfirm}>
        继续加载
      </button>
    </div>
  );
}

export default function PreviewRenderer({ file, content, viewMode, change, zoom }) {
  const projectPath = file.projectPath ?? projectPathFor(file);
  const [state, setState] = useState({ status: projectPath ? 'loading' : 'static' });
  const [reloadToken, setReloadToken] = useState(0);
  const confirmed = useRef(new Set());

  useEffect(() => {
    setState({ status: projectPath ? 'loading' : 'static' });
  }, [file.path, projectPath, reloadToken]);

  useEffect(() => {
    if (!projectPath) return undefined;
    let cancelled = false;
    (async () => {
      try {
        if (file.kind !== 'image' && file.kind !== 'pdf') {
          const stat = await request('file.stat', { projectPath, filePath: file.path });
          if (cancelled) return;
          if (!stat?.exists) {
            setState({ status: 'missing' });
            return;
          }
          if (stat.isDirectory) {
            setState({ status: 'error', message: '这是一个目录，无法预览。' });
            return;
          }
          if (stat.size > LARGE_FILE_BYTES && !confirmed.current.has(file.path)) {
            setState({ status: 'confirm', size: stat.size });
            return;
          }
        }
        const result = await request('file.read', {
          projectPath,
          filePath: file.path,
          maxBytes: READ_LIMIT_BYTES,
        });
        if (!cancelled) setState({ status: 'ready', result });
      } catch (error) {
        if (!cancelled) {
          setState({
            status: 'error',
            message: error?.message ?? '读取失败',
            code: error?.code,
          });
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [projectPath, file.path, file.kind, reloadToken]);

  if (!projectPath || state.status === 'static') {
    return <TextPreview file={file} content={content} viewMode={viewMode} change={change} />;
  }

  if (state.status === 'loading') {
    return <div className="empty-tree">正在读取文件…</div>;
  }

  if (state.status === 'missing') {
    return (
      <div className="empty-tree" style={{ padding: 30, lineHeight: 1.9 }}>
        <b>{fileNameOf(file)}</b>
        <p>文件不存在（可能已删除或被移动）。</p>
        <button
          className="tree-file"
          style={{ paddingLeft: 0 }}
          onClick={() => setReloadToken((v) => v + 1)}
        >
          重新读取
        </button>
      </div>
    );
  }

  if (state.status === 'error') {
    return (
      <div className="empty-tree" style={{ padding: 30, lineHeight: 1.9 }}>
        读取失败：{state.message}
        {state.code ? `（${state.code}）` : ''}
        <button
          className="tree-file"
          style={{ paddingLeft: 0 }}
          onClick={() => setReloadToken((v) => v + 1)}
        >
          重试
        </button>
      </div>
    );
  }

  if (state.status === 'confirm') {
    return (
      <LargeFileConfirm
        file={file}
        size={state.size}
        onConfirm={() => {
          confirmed.current.add(file.path);
          setReloadToken((v) => v + 1);
        }}
      />
    );
  }

  const result = state.result ?? {};
  const text = result.content ?? '';

  if (file.kind === 'image') {
    const src = isDataURL(text) ? text : file.src;
    const sized = result.size ? { ...file, size: formatBytes(result.size) } : file;
    return <ImagePreview file={sized} zoom={zoom} src={src} />;
  }

  if (file.kind === 'pdf') {
    return <PdfPreview file={file} src={isDataURL(text) ? text : null} />;
  }

  if (result.isBinary) {
    return <BinaryNotice file={file} reason="这是二进制文件，没有可用的文本预览。" />;
  }

  if (!text && result.truncated) {
    return (
      <div className="empty-tree" style={{ padding: 30, lineHeight: 1.9 }}>
        <b>{fileNameOf(file)}</b>
        <p>
          文件 {formatBytes(result.size)}，超过 {formatBytes(READ_LIMIT_BYTES)}{' '}
          预览上限，未加载内容。
        </p>
        <p>请用系统默认程序打开：{file.path}</p>
      </div>
    );
  }

  return (
    <TextPreview
      file={file}
      content={text}
      viewMode={viewMode}
      change={change}
      modifiedAt={result.modifiedAt}
      truncated={Boolean(result.truncated)}
    />
  );
}
