// 全部操作页：按分类铺开的 Git 命令入口。
import React from 'react';
import { CaretRight, Terminal } from '@phosphor-icons/react';

export default function AllActionsPage({ operations, query, onOpen }) {
  return (
    <div className="operation-grid">
      {Object.entries(operations).map(([cat, items]) => (
        <section key={cat}>
          <h3>{cat}</h3>
          {items
            .filter((x) => x.toLowerCase().includes(query.toLowerCase()))
            .map((x) => (
              <button
                key={x}
                onClick={() => onOpen(x, /reset|clean|恢复文件/.test(x) ? 'danger' : 'action')}
              >
                <Terminal size={16} />
                {x}
                <CaretRight />
              </button>
            ))}
        </section>
      ))}
      <section>
        <h3>Git 命令入口</h3>
        <p>低频命令与组合参数使用命令预览。</p>
        <button onClick={() => onOpen('自定义 Git 命令', 'command')}>
          <Terminal />
          输入 Git 命令
          <CaretRight />
        </button>
      </section>
    </div>
  );
}
