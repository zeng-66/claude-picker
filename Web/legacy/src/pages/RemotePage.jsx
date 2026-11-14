// 远程仓库页：真实 remote 列表（fetch / push 地址、协议），编辑与新增仍走「暂不支持」。
import React, { useCallback, useEffect, useState } from 'react';
import { transportKind } from '../bridge/client.js';
import { projectRequest } from '../bridge/project-request.js';
import {
  currentProjectId,
  describeError,
  projectPathFor,
  toRemotes,
  uiStyles,
} from '../bridge/dto.js';
import { CloudArrowUp, DotsThree } from '@phosphor-icons/react';

export default function RemotePage({ repo, onOpen }) {
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
      const projectPath = projectPathFor(repo || currentProjectId());
      setItems(toRemotes(await projectRequest('git.remotes', { projectPath })));
    } catch (cause) {
      setError(describeError(cause));
    } finally {
      setLoading(false);
    }
  }, [demo, repo]);

  useEffect(() => {
    load();
  }, [load]);

  const locked = (what) =>
    demo ? onOpen(what) : setNotice('暂不支持：' + what + '（写操作不在 T4 范围）');

  return (
    <>
      {loading && !items && <div className="empty-small">正在读取远程仓库…</div>}
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

      {demo && (
        <div className="entity-row">
          <CloudArrowUp size={23} />
          <div>
            <b>origin</b>
            <p>git@github.com:example/{repo}.git</p>
          </div>
          <span className="badge">SSH</span>
          <button onClick={() => onOpen('编辑远程 origin')}>编辑</button>
          <button onClick={() => onOpen('远程操作：添加 / 移除 / 修改 URL / Prune')}>
            <DotsThree />
          </button>
        </div>
      )}

      {!demo &&
        (items ?? []).map((item) => (
          <div className="entity-row" key={item.name}>
            <CloudArrowUp size={23} />
            <div>
              <b>{item.name}</b>
              <p>
                {item.fetchURL}
                {item.pushURL && item.pushURL !== item.fetchURL
                  ? '（push: ' + item.pushURL + '）'
                  : ''}
              </p>
            </div>
            <span className="badge">{item.protocol}</span>
            <button onClick={() => locked('编辑远程 ' + item.name)}>编辑</button>
            <button onClick={() => locked('远程操作：添加 / 移除 / 修改 URL / Prune')}>
              <DotsThree />
            </button>
          </div>
        ))}

      {!demo && !loading && !error && (items ?? []).length === 0 && (
        <div className="empty-small">这个仓库还没有配置远程</div>
      )}

      <div className="remote-empty">
        <CloudArrowUp size={36} />
        <h3>让本地与远程保持同步</h3>
        <p>管理 Fetch / Push 地址、跟踪分支与同步策略。</p>
        <button onClick={() => locked('添加远程仓库')}>添加远程仓库</button>
      </div>
    </>
  );
}
