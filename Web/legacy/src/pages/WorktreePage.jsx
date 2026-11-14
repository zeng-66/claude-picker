// 工作树页：真实 `git worktree list` + 当前分支标记；切换上下文仍走「暂不支持」。
import React, { useCallback, useEffect, useState } from 'react';
import { transportKind } from '../bridge/client.js';
import { projectRequest } from '../bridge/project-request.js';
import {
  currentProjectId,
  describeError,
  projectPathFor,
  toStatus,
  toWorktrees,
  uiStyles,
} from '../bridge/dto.js';
import { DotsThree, TreeStructure } from '@phosphor-icons/react';

export default function WorktreePage({ repo, branch, query, worktrees, onNotify, onOpen }) {
  const demo = transportKind() === 'mock';
  const [items, setItems] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    if (demo) return;
    setLoading(true);
    setError(null);
    try {
      const projectPath = projectPathFor(repo || currentProjectId());
      // worktree 列表里没有「谁是当前」的字段，用 status 的当前分支比对；
      // 分离 HEAD 时退回第一项（`git worktree list` 的主工作树总在第一位）。
      const [list, status] = await Promise.all([
        projectRequest('git.worktrees', { projectPath }),
        projectRequest('git.status', { projectPath }),
      ]);
      const snapshot = toStatus(status);
      setItems(
        toWorktrees(list, null).map((item, index) => ({
          ...item,
          isCurrent: snapshot.branch ? item.branch === snapshot.branch : index === 0,
        })),
      );
    } catch (cause) {
      setError(describeError(cause));
    } finally {
      setLoading(false);
    }
  }, [demo, repo]);

  useEffect(() => {
    load();
  }, [load]);

  const rows = demo
    ? (worktrees ?? []).map((name, i) => ({
        name,
        path: '',
        branch: i ? 'feature/terminal-tabs' : branch,
        isCurrent: i === 0,
      }))
    : (items ?? []);
  const visible = rows.filter((item) =>
    String(item.name + ' ' + item.path + ' ' + (item.branch ?? ''))
      .toLowerCase()
      .includes(query.toLowerCase()),
  );

  return (
    <>
      {loading && !items && <div className="empty-small">正在读取工作树…</div>}
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
      {!loading && !error && rows.length === 0 && <div className="empty-small">还没有工作树</div>}
      {rows.length > 0 && visible.length === 0 && (
        <div className="empty-small">没有匹配的工作树</div>
      )}

      {visible.map((item) => (
        <div className="entity-row" key={item.path || item.name}>
          <TreeStructure size={23} />
          <div>
            <b>
              {item.name} {item.isCurrent && <span className="badge">当前</span>}
            </b>
            <p>
              {demo ? '~/project/' + repo : item.path}
              {item.branch ? ' · ' + item.branch : ' · 分离 HEAD'}
              {item.shortHead ? ' · ' + item.shortHead : ''}
              {item.isLocked ? ' · 已锁定' : ''}
              {item.isPrunable ? ' · 可清理' : ''}
            </p>
          </div>
          <button
            onClick={() =>
              demo
                ? onNotify('演示：已切换工作树上下文')
                : onNotify('暂不支持：切换工作树上下文（只读链路，T4 未接会话切换）')
            }
          >
            打开工作树
          </button>
          <button
            onClick={() =>
              demo
                ? onOpen('工作树：锁定 / 移动 / 移除 / 清理')
                : onNotify('暂不支持：锁定 / 移动 / 移除 / 清理工作树')
            }
          >
            <DotsThree />
          </button>
        </div>
      ))}
    </>
  );
}
