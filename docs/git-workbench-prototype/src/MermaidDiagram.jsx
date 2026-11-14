import React, { useEffect, useId, useState } from 'react';
import './mermaid-diagram.css';

let counter = 0;

export default function MermaidDiagram({ chart }) {
  const reactId = useId();
  const [svg, setSvg] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    let active = true;

    async function renderDiagram() {
      try {
        const module = await import('mermaid');
        const mermaid = module.default;
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: 'strict',
          theme: 'dark',
          themeVariables: {
            background: '#17181b',
            primaryColor: '#342b26',
            primaryTextColor: '#e6d1c2',
            primaryBorderColor: '#b98365',
            lineColor: '#8e948f',
            secondaryColor: '#20252b',
            tertiaryColor: '#24262b',
            fontFamily: 'Inter, sans-serif'
          }
        });
        const id = `mermaid-preview-${reactId.replaceAll(':', '')}-${counter++}`;
        const result = await mermaid.render(id, chart);
        if (active) {
          setSvg(result.svg);
          setError('');
        }
      } catch (renderError) {
        if (active) {
          setError('图表语法尚未完成，请继续编辑。');
        }
      }
    }

    renderDiagram();
    return () => {
      active = false;
    };
  }, [chart, reactId]);

  return <figure className="mermaid-diagram" aria-label="Mermaid 图表">
    {error ? <div className="mermaid-error">{error}</div> : svg ? <div className="mermaid-svg" dangerouslySetInnerHTML={{ __html: svg }}/> : <div className="mermaid-loading">正在绘制图表…</div>}
  </figure>;
}
