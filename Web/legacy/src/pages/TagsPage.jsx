// 标签 Tags 页：真实 tag 列表（名称 / 指向 / 创建时间），推送与检出仍走「暂不支持」。
import React, { useCallback, useEffect, useState } from 'react';
import { transportKind } from '../bridge/client.js';
import { projectRequest } from '../bridge/project-request.js';
import {
  currentProjectId,
  describeError,
  onProjectChange,
  projectPathFor,
  toTags,
  uiStyles,
} from '../bridge/dto.js';
import { DotsThree, Tag } from '@phosphor-icons/react';

export default function TagsPage({ tags, query, onOpen }) {
  const demo = transportKind() === 'mock';
  const [items, setItems] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState('');

  const load = useCallback(async () => {
    if (demo) return;
    setLoading(true);
    setError(null);
    try {
      setItems(
        toTags(
          await projectRequest('git.tags', {
            projectPath: projectPathFor(currentProjectId()),
          }),
        ),
      );
    } catch (cause) {
      setError(describeError(cause));
    } finally {
      setLoading(false);
    }
  }, [demo]);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => onProjectChange(load), [load]);

  const rows = demo
    ? (tags ?? []).map((name, i) => ({ name, shortHash: 'a3f2c91', i }))
    : (items ?? []);
  const visible = rows.filter((item) =>
    String(item.name).toLowerCase().includes(query.toLowerCase()),
  );
  const locked = (what) =>
    demo ? onOpen(what) : setNotice('暂不支持：' + what + '（写操作不在 T4 范围）');

  return (
    <>
      {loading && !items && <div className="empty-small">正在读取标签…</div>}
      {error && (
        <div className="empty-small" role="alert" style={uiStyles.notice}>
          <b>{error.title}</b>
          <div>{error.message}</div>
          {error.detail && <pre style={uiStyles.detail}>{error.detail}</pre>}
          <button type="button" style={uiStyles.retry} onClick={load}>
            重试
          </button>
        </div>
      )}
      {notice && <div className="empty-small">{notice}</div>}
      {!loading && !error && rows.length === 0 && (
        <div className="empty-small">这个仓库还没有标签</div>
      )}
      {rows.length > 0 && visible.length === 0 && <div className="empty-small">没有匹配的标签</div>}

      {visible.map((item, i) => (
        <div className="entity-row" key={item.name}>
          <Tag size={23} />
          <div>
            <b>{item.name}</b>
            <p>
              {demo ? '发布版本' : '标签'} · {i === 0 ? '最新标签' : '历史标签'} ·{' '}
              <code>{item.shortHash}</code>
              {item.subject ? ' · ' + item.subject : ''}
              {item.time ? ' · ' + item.time : ''}
            </p>
          </div>
          <button onClick={() => locked('推送标签 ' + item.name)}>推送标签</button>
          <button onClick={() => locked('检出标签 ' + item.name)}>检出</button>
          <button onClick={() => locked('标签操作：删除 / 复制引用')}>
            <DotsThree />
          </button>
        </div>
      ))}
    </>
  );
}
