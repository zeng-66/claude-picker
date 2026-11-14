// 实时编辑器：左侧 textarea，右侧复用预览渲染器。
import React from 'react';
import {
  MarkdownPreview,
  SourceLines,
  DiagramPreview,
  HtmlPreview,
  CsvPreview,
} from './PreviewRenderer.jsx';
import { languageFor } from './file-meta.jsx';

export function LivePreview({ file, content }) {
  if (file.kind === 'markdown') return <MarkdownPreview content={content} />;
  if (file.kind === 'diagram') return <DiagramPreview content={content} />;
  if (file.kind === 'html') return <HtmlPreview content={content} />;
  if (file.kind === 'csv') return <CsvPreview content={content} />;
  return <SourceLines content={content} />;
}

export function LiveEditor({ file, content, onChange }) {
  return (
    <div className="live-editor">
      <section className="editor-pane">
        <header>
          <span>编辑器</span>
          <small>
            {content.split('\n').length} 行 · {languageFor(file)}
          </small>
        </header>
        <textarea
          aria-label={`编辑 ${file.path}`}
          value={content}
          onChange={(event) => onChange(event.target.value)}
          spellCheck="false"
        />
      </section>
      <section className="live-preview-pane">
        <header>
          <span className="live-dot" />
          实时预览<small>{file.kind === 'diagram' ? 'Mermaid' : languageFor(file)}</small>
        </header>
        <div className={`live-preview-content ${file.kind}`}>
          <LivePreview file={file} content={content} />
        </div>
      </section>
    </div>
  );
}

export default LiveEditor;
