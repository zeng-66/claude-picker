// 合并与冲突页：冲突文件的双栏对比与解决动作。
import React from 'react';
import { Warning } from '@phosphor-icons/react';

export default function ConflictPage({
  live,
  branch,
  resolved,
  conflictChoice,
  onChoose,
  onResolve,
  onNotify,
  onOpen,
}) {
  // 冲突检测还没接桥，真实仓库下不能拿演示冲突冒充。
  if (live)
    return (
      <div className="empty-small">合并冲突检测待接入：请暂时在终端里使用 git status 查看</div>
    );
  return (
    <div className="conflict">
      <div className="conflict-banner">
        <Warning size={22} />
        <div>
          <b>
            {resolved
              ? '冲突已解决，可以继续合并'
              : conflictChoice
                ? '已选择：' + conflictChoice + ' · 等待确认解决'
                : '演示场景：1 个文件存在合并冲突'}
          </b>
          <p>feature/terminal-tabs → {branch}</p>
        </div>
      </div>
      <h3>Sources/ClaudeDeck/TerminalPane.swift</h3>
      <div className="conflict-columns">
        <div>
          <h4>当前更改 · OURS</h4>
          <pre>let terminalPadding = 12\nview.padding = terminalPadding</pre>
          <button onClick={() => onChoose('采用当前更改')}>采用当前更改</button>
        </div>
        <div>
          <h4>传入更改 · THEIRS</h4>
          <pre>let terminalPadding = 16\nview.padding = terminalPadding</pre>
          <button onClick={() => onChoose('采用传入更改')}>采用传入更改</button>
        </div>
      </div>
      <div className="conflict-actions">
        <button onClick={() => onChoose('保留双方更改')}>保留双方</button>
        <button
          className="primary"
          disabled={!conflictChoice || resolved}
          onClick={() => {
            onResolve(true);
            onNotify('演示：冲突已解决');
          }}
        >
          标记为已解决
        </button>
        <button onClick={() => onOpen('终止合并')}>终止合并</button>
      </div>
    </div>
  );
}
