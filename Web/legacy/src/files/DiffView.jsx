// 差异视图：统一 / 并排两种排布，二进制与文本各一套渲染。
import React from 'react';
import { diffLines, pairedLines } from '../CommitDetails.jsx';

export function BinaryDiff({ file, change }) {
  return (
    <div className="binary-diff">
      <div className="binary-diff-summary">
        <span className="tree-status">{change.label}</span>
        <div>
          <b>{file.path.split('/').pop()}</b>
          <p>{change.state === 'deleted' ? '文件已删除' : '二进制文件已加入变更'}</p>
        </div>
      </div>
      <div className="binary-diff-grid">
        <div>
          <span>父提交</span>
          {change.before ? (
            <img src={change.before} alt="父提交中的文件" />
          ) : (
            <div className="binary-empty">此前没有此文件</div>
          )}
        </div>
        <div>
          <span>当前工作区</span>
          {change.after ? (
            <img src={change.after} alt="当前工作区中的文件" />
          ) : (
            <div className="binary-empty">文件已删除</div>
          )}
        </div>
      </div>
    </div>
  );
}

export function CodeDiff({ change, layout }) {
  const rows = diffLines(change.before || '', change.after || '');
  const additions = rows.filter((row) => row.kind === 'added').length;
  const deletions = rows.filter((row) => row.kind === 'removed').length;
  return (
    <div className="code-diff">
      <div className="code-diff-summary">
        <span>{change.label === '?' ? '未跟踪文件' : '工作区变更'}</span>
        <span className="green">+{additions}</span>
        <span className="red">−{deletions}</span>
      </div>
      {layout === '统一' ? (
        <div className="file-unified-diff">
          {rows.map((row, index) => (
            <div key={index} className={`commit-code-line ${row.kind}`}>
              <span className="commit-line-number">{row.oldNumber}</span>
              <span className="commit-line-number">{row.newNumber}</span>
              <span className="commit-line-sign">
                {row.kind === 'added' ? '+' : row.kind === 'removed' ? '−' : ''}
              </span>
              <code>{row.text || ' '}</code>
            </div>
          ))}
        </div>
      ) : (
        <div className="file-split-diff">
          <div className="commit-split-labels">
            <span>HEAD</span>
            <span>工作区</span>
          </div>
          {pairedLines(rows).map((row, index) => (
            <div className="commit-split-row" key={index}>
              <DiffCell change={row.before} side="before" />
              <DiffCell change={row.after} side="after" />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export function DiffCell({ change, side }) {
  return (
    <div className={`commit-code-line ${change?.kind || 'gap'}`}>
      <span className="commit-line-number">
        {change?.[side === 'before' ? 'oldNumber' : 'newNumber']}
      </span>
      <span className="commit-line-sign">
        {change?.kind === 'added' ? '+' : change?.kind === 'removed' ? '−' : ''}
      </span>
      <code>{change?.text || ' '}</code>
    </div>
  );
}

export function ChangeDiff({ file, change, layout }) {
  if (change.binary || file.kind === 'image' || file.kind === 'pdf')
    return <BinaryDiff file={file} change={change} />;
  return <CodeDiff change={change} layout={layout} />;
}

export default ChangeDiff;
