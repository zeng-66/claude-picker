// 差异渲染：统一 / 并排两种视图，标记与配色沿用原型的 .code-diff。
import React from 'react';
import { splitRows } from './diff.js';

const MARK = { add: '+', del: '−', context: ' ' };

function UnifiedLines({ lines }) {
  return lines.map((line, index) => (
    <div className={`code-line ${line[0]}`} key={index}>
      <span>{line[1]}</span>
      <span>{line[2]}</span>
      <em>{MARK[line[0]]}</em>
      <code>{line[3]}</code>
    </div>
  ));
}

function SplitSide({ rows, side }) {
  return (
    <div>
      {rows.map((row, index) => {
        const line = row[side];
        if (!line) return <div className="code-line blank" key={index} />;
        return (
          <div className={`code-line ${line[0]}`} key={index}>
            <span>{side === 0 ? line[1] : line[2]}</span>
            <code>{line[3]}</code>
          </div>
        );
      })}
    </div>
  );
}

/// hunks: parsePatch 的结果；action 只出现在第一个 hunk 条上（暂存 / 取消暂存）。
export default function DiffView({ hunks, mode, action }) {
  return hunks.map((hunk, index) => {
    const rows = mode === '并排' ? splitRows(hunk.lines) : null;
    return (
      <React.Fragment key={index}>
        <div className="hunk">
          <code>{hunk.header}</code>
          {index === 0 && action}
        </div>
        <div className={`code-diff ${rows ? 'split-diff' : ''}`}>
          {rows ? (
            <>
              <SplitSide rows={rows} side={0} />
              <SplitSide rows={rows} side={1} />
            </>
          ) : (
            <UnifiedLines lines={hunk.lines} />
          )}
        </div>
      </React.Fragment>
    );
  });
}
