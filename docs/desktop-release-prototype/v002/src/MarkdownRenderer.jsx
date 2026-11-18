import React, { lazy, Suspense } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';

const MermaidDiagram = lazy(() => import('./MermaidDiagram.jsx'));

function CodeBlock({ className, children, ...props }) {
  const language = className?.replace('language-', '');
  if (language === 'mermaid') {
    return (
      <Suspense fallback={<div className="mermaid-loading">正在载入图表…</div>}>
        <MermaidDiagram chart={String(children).trim()} />
      </Suspense>
    );
  }
  return (
    <code className={className} {...props}>
      {children}
    </code>
  );
}

export default function MarkdownRenderer({ content }) {
  return (
    <ReactMarkdown remarkPlugins={[remarkGfm]} components={{ code: CodeBlock }}>
      {content}
    </ReactMarkdown>
  );
}
