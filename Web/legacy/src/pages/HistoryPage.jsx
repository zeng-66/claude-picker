// 提交历史页：提交列表，展开可看 `git.show` 的真实文件列表与补丁。
import React, { useCallback, useEffect, useState } from 'react';
import { transportKind } from '../bridge/client.js';
import { projectRequest } from '../bridge/project-request.js';
import {
  currentProjectId,
  describeError,
  formatTime,
  onProjectChange,
  projectPathFor,
  toCommits,
  uiStyles,
} from '../bridge/dto.js';
import { DotsThree, FileCode, GitCommit } from '@phosphor-icons/react';

const HISTORY_LIMIT = 30;

export default function HistoryPage({ history, query, onOpenCommit, onOpen }) {
  const demo = transportKind() === 'mock';
  const [commits, setCommits] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState('');
  const [openHash, setOpenHash] = useState(null);
  const [detail, setDetail] = useState(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState(null);

  const load = useCallback(async () => {
    if (demo) return;
    setLoading(true);
    setError(null);
    setOpenHash(null);
    setDetail(null);
    try {
      const result = await projectRequest('git.log', {
        projectPath: projectPathFor(currentProjectId()),
        limit: HISTORY_LIMIT,
      });
      setCommits(toCommits(result));
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

  const toggleDetail = async (commit) => {
    if (demo) {
      onOpenCommit(commit);
      return;
    }
    if (openHash === commit.hash) {
      setOpenHash(null);
      setDetail(null);
      return;
    }
    setOpenHash(commit.hash);
    setDetail(null);
    setDetailError(null);
    setDetailLoading(true);
    try {
      setDetail(
        await projectRequest(
          'git.show',
          { projectPath: projectPathFor(currentProjectId()), hash: commit.hash },
          { timeoutMs: 60000 },
        ),
      );
    } catch (cause) {
      setDetailError(describeError(cause));
    } finally {
      setDetailLoading(false);
    }
  };

  const rows = demo ? history : (commits ?? []);
  const visible = rows.filter(
    (x) =>
      String(x.message ?? '')
        .toLowerCase()
        .includes(query.toLowerCase()) || String(x.hash ?? '').includes(query),
  );

  return (
    <div className="history-list">
      {loading && !commits && <div className="empty-small">正在读取提交历史…</div>}
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
        <div className="empty-small">这个仓库还没有提交</div>
      )}
      {rows.length > 0 && visible.length === 0 && <div className="empty-small">没有匹配的提交</div>}

      {visible.map((x, i) => (
        <React.Fragment key={x.hash ?? i}>
          <div className="history-row">
            <GitCommit size={22} className="orange" />
            <div>
              <b>{x.message}</b>
              <p>
                {x.author} · {x.time || formatTime(x.date)} <code>{x.shortHash || x.hash}</code>
              </p>
            </div>
            {i === 0 && <span className="badge">HEAD</span>}
            <button onClick={() => toggleDetail(x)}>
              <FileCode />
              {openHash === x.hash ? '收起' : '差异'}
            </button>
            <button
              onClick={() => {
                if (demo) onOpen('提交操作：Cherry-pick / Revert / Reset / 创建分支');
                else
                  setNotice(
                    '暂不支持：Cherry-pick / Revert / Reset / 创建分支（写操作不在 T4 范围）',
                  );
              }}
            >
              <DotsThree />
            </button>
          </div>
          {openHash === x.hash && (
            <div style={uiStyles.detailPanel}>
              {detailLoading && <div className="empty-small">正在读取提交详情…</div>}
              {detailError && (
                <div className="empty-small" role="alert" style={uiStyles.notice}>
                  <b>{detailError.title}</b>
                  <div>{detailError.message}</div>
                  {detailError.detail && <pre style={uiStyles.detail}>{detailError.detail}</pre>}
                </div>
              )}
              {detail && (
                <>
                  <div>
                    <b>{detail.commit?.shortHash || detail.commit?.hash}</b>{' '}
                    <span style={uiStyles.muted}>
                      {detail.commit?.author} · {formatTime(detail.commit?.date)} ·{' '}
                      {detail.files?.length ?? 0} 个文件 · +{detail.additions ?? 0} −
                      {detail.deletions ?? 0}
                    </span>
                  </div>
                  <div style={{ marginTop: 8 }}>
                    {(detail.files ?? []).map((file) => (
                      <div key={file.path} style={{ display: 'flex', gap: 8, padding: '2px 0' }}>
                        <span style={{ flex: 1 }}>{file.path}</span>
                        {file.binary ? (
                          <span style={uiStyles.muted}>二进制</span>
                        ) : (
                          <>
                            <span className="green">+{file.additions ?? 0}</span>
                            <span className="red">−{file.deletions ?? 0}</span>
                          </>
                        )}
                      </div>
                    ))}
                  </div>
                  {detail.patch ? (
                    <pre style={uiStyles.patch}>{detail.patch}</pre>
                  ) : (
                    <div className="empty-small">这个提交没有文本补丁</div>
                  )}
                </>
              )}
            </div>
          )}
        </React.Fragment>
      ))}
    </div>
  );
}
