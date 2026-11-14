// Stash 暂存页：暂存记录的应用、弹出与删除。
import React from 'react';
import { Stack, Trash } from '@phosphor-icons/react';

export default function StashPage({ live, stash, query, branch, onApply, onPop, onOpen }) {
  // 真实仓库的 Stash 列表还没接桥（git.stashes 未实现），不展示演示数据。
  if (live)
    return <div className="empty-small">Stash 列表待接入：请暂时在终端里使用 git stash list</div>;
  return stash
    .filter((x) => x.includes(query))
    .map((x, i) => (
      <div className="entity-row" key={i}>
        <Stack size={23} />
        <div>
          <b>{x}</b>
          <p>
            stash@{'{' + i + '}'} · {branch} · 2 个文件
          </p>
        </div>
        <button onClick={onApply}>应用 Apply</button>
        <button onClick={() => onPop(i)}>弹出 Pop</button>
        <button title="删除暂存" onClick={() => onOpen('删除 Stash', 'danger')}>
          <Trash />
        </button>
      </div>
    ));
}
