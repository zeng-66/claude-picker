// 分支管理页：本地 / 远程分支、ahead/behind、上游追踪；切换写操作仍走「暂不支持」。
import React, { useCallback, useEffect, useState } from 'react';
import { transportKind } from '../bridge/client.js';
import { projectRequest } from '../bridge/project-request.js';
import {
  currentProjectId,
  describeError,
  onProjectChange,
  projectPathFor,
  toBranches,
  uiStyles,
} from '../bridge/dto.js';
import { CloudArrowUp, DotsThree, GitBranch, GitMerge } from '@phosphor-icons/react';

const SWITCH_LOCKED = '暂不支持：切换分支（写操作由后续任务卡接入）';

function trackText(item) {
  if (item.upstreamGone) return '上游 ' + item.upstream + ' 已被删除';
  const parts = [];
  if (item.ahead) parts.push('领先 ' + item.ahead + ' 个提交');
  if (item.behind) parts.push('落后 ' + item.behind + ' 个提交');
  const track = parts.length ? parts.join(' · ') : '与上游一致';
  if (item.upstream) return track + ' · ' + item.upstream;
  return parts.length ? track : '没有设置上游';
}

export default function BranchesPage({
  branches,
  query,
  branch,
  onSwitchBranch,
  onNotify,
  onOpen,
}) {
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
        toBranches(
          await projectRequest('git.branches', {
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
    ? (branches ?? []).map((name) => ({ name, isRemote: false, isCurrent: name === branch }))
    : (items ?? []);
  const local = rows.filter((item) => !item.isRemote);
  const remote = rows.filter((item) => item.isRemote);
  const matches = (item) => String(item.name).toLowerCase().includes(query.toLowerCase());

  const switchTo = (name) => {
    if (demo) {
      onSwitchBranch(name);
      onNotify('演示：已切换到 ' + name);
      return;
    }
    setNotice(SWITCH_LOCKED);
  };

  return (
    <>
      <div className="list-caption">
        本地分支 <span>{local.length}</span>
      </div>
      {loading && !items && <div className="empty-small">正在读取分支…</div>}
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

      {local.filter(matches).map((item) => (
        <div className="entity-row" key={item.name}>
          <GitBranch size={23} />
          <div>
            <b>{item.name}</b>
            <p>
              {demo
                ? item.isCurrent
                  ? '当前工作分支'
                  : '关联 origin/' + item.name
                : trackText(item)}
            </p>
          </div>
          {item.isCurrent ? (
            <span className="badge">当前分支</span>
          ) : (
            <button onClick={() => switchTo(item.name)}>切换分支</button>
          )}
          <button
            onClick={() =>
              demo
                ? onOpen('合并 ' + item.name + ' 到 ' + branch)
                : setNotice('暂不支持：合并分支（写操作不在 T4 范围）')
            }
          >
            <GitMerge />
            合并
          </button>
          <button
            onClick={() =>
              demo
                ? onOpen('分支操作：重命名 / 删除 / 变基 / 设置上游')
                : setNotice('暂不支持：重命名 / 删除 / 变基 / 设置上游')
            }
          >
            <DotsThree />
          </button>
        </div>
      ))}
      {!loading && !error && local.length > 0 && local.filter(matches).length === 0 && (
        <div className="empty-small">没有匹配的本地分支</div>
      )}

      <div className="list-caption">远程分支</div>
      {remote.length === 0 && <div className="empty-small">还没有远程分支（先 fetch 一次）</div>}
      {remote.filter(matches).map((item) => (
        <div className="entity-row" key={item.name}>
          <CloudArrowUp size={23} />
          <div>
            <b>{item.shortName || item.name}</b>
            <p>{demo ? '默认分支 · 最新同步于刚刚' : (item.lastCommit || '') + ' · 跟踪分支'}</p>
          </div>
          <button
            onClick={() => {
              const name = String(item.shortName || item.name).replace(/^origin\//, '');
              if (demo) onOpen('检出 ' + item.name);
              else setNotice('暂不支持：从 ' + item.name + ' 检出本地分支 ' + name);
            }}
          >
            检出本地分支
          </button>
        </div>
      ))}
    </>
  );
}
