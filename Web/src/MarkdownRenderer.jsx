import React, { lazy, Suspense } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { request } from './shell/bridge.js';

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

// 外壳 WebView 没有导航拦截，链接不能让页面自己跳走：
// http(s) 交给系统浏览器，本机绝对路径在访达中定位，其它（相对路径、锚点）只显示不跳转。
function Link({ href = '', children, node: _node, ...props }) {
  const local = href.startsWith('file://') ? decodeURIComponent(href.slice(7)) : href.startsWith('/') ? href : null;
  const external = /^https?:\/\//i.test(href);
  return (
    <a
      {...props}
      href={href}
      title={external ? href : local ? `在访达中显示：${local}` : href}
      onClick={(event) => {
        event.preventDefault();
        if (external) request('app.openURL', { url: href }).catch(() => {});
        else if (local) request('app.revealInFinder', { path: local.split('#')[0] }).catch(() => {});
      }}
    >
      {children}
    </a>
  );
}

export default function MarkdownRenderer({ content }) {
  return (
    <ReactMarkdown remarkPlugins={[remarkGfm]} components={{ code: CodeBlock, a: Link }}>
      {content}
    </ReactMarkdown>
  );
}
