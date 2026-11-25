import React, { useMemo, useRef, useState } from 'react';
import { CaretDown, CaretUp } from '@phosphor-icons/react';

const marks = { add: '+', del: '−', context: ' ' };

function groupHunks(hunks) {
  let changeCount = 0;
  return hunks.map(({ header, lines }) => {
    const blocks = [];
    for (const line of lines) {
      const changed = line[0] !== 'context';
      if (blocks.at(-1)?.changed !== changed) {
        blocks.push({ changed, number: changed ? ++changeCount : null, lines: [] });
      }
      blocks.at(-1).lines.push(line);
    }
    return { header, blocks };
  });
}

function ChangedText({ line, other }) {
  const value = line[3];
  if (!other || line[0] === 'context') return value;
  const comparison = other[3];
  let start = 0;
  let end = 0;
  const length = Math.min(value.length, comparison.length);
  while (start < length && value[start] === comparison[start]) start++;
  while (
    end < length - start &&
    value[value.length - end - 1] === comparison[comparison.length - end - 1]
  )
    end++;
  const stop = value.length - end;
  return (
    <>
      {value.slice(0, start)}
      {start < stop && <mark>{value.slice(start, stop)}</mark>}
      {value.slice(stop)}
    </>
  );
}

function DiffLine({ line, other, side }) {
  if (!line) return <div className="code-line blank" aria-hidden="true" />;
  const [kind, left, right] = line;
  return (
    <div className={`code-line ${kind}`}>
      {side !== 'right' && <span>{left}</span>}
      {side !== 'left' && <span>{right}</span>}
      {side === 'unified' && <em>{marks[kind]}</em>}
      <code>
        <ChangedText line={line} other={other} />
      </code>
    </div>
  );
}

function PairedBlock({ block }) {
  const removed = block.changed ? block.lines.filter((line) => line[0] === 'del') : block.lines;
  const added = block.changed ? block.lines.filter((line) => line[0] === 'add') : block.lines;
  const count = Math.max(removed.length, added.length);
  const leftHeight = (100 * removed.length) / count;
  const rightHeight = (100 * added.length) / count;
  const tone = !removed.length ? 'added' : !added.length ? 'removed' : 'paired';
  return (
    <div className="paired-diff-block">
      {Array.from({ length: count }, (_, index) => (
        <div className="paired-diff-row" key={index}>
          <DiffLine line={removed[index]} other={added[index]} side="left" />
          <span className="paired-diff-gutter" aria-hidden="true" />
          <DiffLine line={added[index]} other={removed[index]} side="right" />
        </div>
      ))}
      {block.changed && count > 0 && (
        <svg
          className={`paired-diff-ribbon ${tone}`}
          viewBox="0 0 24 100"
          preserveAspectRatio="none"
          aria-hidden="true"
        >
          <path
            d={`M0 0 H24 V${rightHeight} C14 ${rightHeight} 10 ${leftHeight} 0 ${leftHeight} Z`}
          />
        </svg>
      )}
    </div>
  );
}

export default function DiffView({ hunks, mode, action, sides = ['原版本', '当前版本'] }) {
  const groups = useMemo(() => groupHunks(hunks), [hunks]);
  const total = groups.reduce(
    (count, section) => count + section.blocks.filter((block) => block.changed).length,
    0,
  );
  const [current, setCurrent] = useState(1);
  const active = Math.min(current, total);
  const changeNodes = useRef(new Map());
  const split = mode === '并排';

  function jump(number) {
    if (number < 1 || number > total) return;
    setCurrent(number);
    changeNodes.current.get(number)?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  function navigate(event) {
    if (event.key !== 'F7') return;
    event.preventDefault();
    jump(active + (event.shiftKey ? -1 : 1));
  }

  return (
    <section className="review-diff" aria-label="代码差异" tabIndex={0} onKeyDown={navigate}>
      <div className="review-diff-controls">
        <button
          type="button"
          aria-label="上一处差异"
          title="上一处差异 · Shift+F7"
          disabled={active <= 1}
          onClick={() => jump(active - 1)}
        >
          <CaretUp size={14} />
        </button>
        <button
          type="button"
          aria-label="下一处差异"
          title="下一处差异 · F7"
          disabled={active >= total}
          onClick={() => jump(active + 1)}
        >
          <CaretDown size={14} />
        </button>
        <span role="status" aria-label="差异位置">
          {active} / {total} 处差异
        </span>
        {action && <div className="review-diff-action">{action}</div>}
      </div>
      {split && (
        <div className="paired-diff-head">
          <span>{sides[0]}</span>
          <i />
          <span>{sides[1]}</span>
        </div>
      )}
      {groups.map(({ header, blocks }, index) => (
        <div className="review-diff-section" key={index}>
          <div className="hunk">
            <code>{header}</code>
          </div>
          <div className={`code-diff ${split ? 'review-diff-paired' : 'review-diff-unified'}`}>
            {blocks.map((block, blockIndex) => (
              <div
                className={`review-diff-block${block.number === active ? ' current' : ''}`}
                key={blockIndex}
                data-change={block.number || undefined}
                ref={(element) => {
                  if (!block.number) return;
                  if (element) changeNodes.current.set(block.number, element);
                  else changeNodes.current.delete(block.number);
                }}
              >
                {split ? (
                  <PairedBlock block={block} />
                ) : (
                  block.lines.map((line, row) => <DiffLine key={row} line={line} side="unified" />)
                )}
              </div>
            ))}
          </div>
        </div>
      ))}
    </section>
  );
}
