// 工作台的其余页签：提交历史 / 分支 / 工作树 / 更多（合并与冲突、Stash、操作日志）。
import React, { useCallback, useEffect, useState } from 'react';
import {
  ArrowLeft,
  CaretRight,
  Check,
  ClockCounterClockwise,
  Copy,
  FileCode,
  GitBranch,
  GitCommit,
  GitMerge,
  Plus,
  Stack,
  Trash,
  TreeStructure,
  Warning,
} from '@phosphor-icons/react';
import { errorText, request } from './bridge.js';
import { parsePatch, splitFiles } from './diff.js';
import DiffView from './DiffView.jsx';
import { baseName, relativeTime, tildePath, useStored } from './ui.jsx';

/// 读一份数据并跟着 epoch（任何 Git 写操作之后自增）刷新。
function useGitData(method, projectPath, epoch, params) {
  const [state, setState] = useState({ data: null, error: null, loading: true });
  const key = JSON.stringify(params ?? {});
  useEffect(() => {
    if (!projectPath) return undefined;
    let alive = true;
    request(method, { projectPath, ...(params ?? {}) }, { timeoutMs: 60000 })
      .then((data) => alive && setState({ data, error: null, loading: false }))
      .catch((error) => alive && setState({ data: null, error: errorText(error), loading: false }));
    return () => {
      alive = false;
    };
  }, [method, projectPath, epoch, key]);
  return state;
}

function PageError({ text }) {
  return (
    <div className="pane-note error" role="alert">
      <Warning size={14} />
      {text}
    </div>
  );
}

function copyText(text) {
  if (navigator.clipboard?.writeText) return navigator.clipboard.writeText(text);
  const area = document.createElement('textarea');
  area.value = text;
  document.body.appendChild(area);
  area.select();
  document.execCommand('copy');
  area.remove();
  return Promise.resolve();
}

// ---------- 提交历史 ----------

const PAGE = 50;

function CommitDetail({ projectPath, commit, onBack, notify }) {
  const { data, error, loading } = useGitData('git.show', projectPath, 0, { hash: commit.hash });
  const [mode, setMode] = useStored('diffMode', '统一');
  const patches = data ? splitFiles(data.patch) : [];
  return (
    <div className="history-page commit-detail">
      <div className="page-heading">
        <button className="back-button" onClick={onBack}>
          <ArrowLeft size={14} />
          返回提交历史
        </button>
        <div className="segmented">
          {['并排', '统一'].map((item) => (
            <button
              className={mode === item ? 'chosen' : ''}
              onClick={() => setMode(item)}
              key={item}
            >
              {item}
            </button>
          ))}
        </div>
      </div>
      <div className="commit-summary">
        <h2>{commit.message}</h2>
        <small>
          {commit.author} · {relativeTime(commit.date)} ·{' '}
          <button
            className="hash-copy"
            title="复制完整哈希"
            onClick={() => copyText(commit.hash).then(() => notify('已复制提交哈希'))}
          >
            <code>{commit.shortHash}</code>
            <Copy size={11} />
          </button>
          {data && (
            <>
              {' '}
              · {data.files.length} 个文件 <b className="green">+{data.additions}</b>{' '}
              <b className="red">−{data.deletions}</b>
            </>
          )}
        </small>
      </div>
      {loading && <div className="pane-note">正在读取提交…</div>}
      {error && <PageError text={error} />}
      {data?.files.map((file) => {
        const patch = patches.find((item) => item.path === file.path)?.patch;
        const parsed = patch ? parsePatch(patch) : { hunks: [] };
        return (
          <section className="commit-file" key={file.path}>
            <div className="file-path">
              <span className="commit-file-name">
                <FileCode size={14} />
                {file.path}
              </span>
              <span>
                <b className="green">+{file.additions}</b>
                <b className="red">−{file.deletions}</b>
              </span>
            </div>
            {parsed.hunks.length ? (
              <DiffView hunks={parsed.hunks} mode={mode} />
            ) : (
              <div className="pane-note">{file.binary ? '二进制文件' : '没有文本差异'}</div>
            )}
          </section>
        );
      })}
    </div>
  );
}

export function HistoryTab({ projectPath, branch, epoch, notify }) {
  const [commits, setCommits] = useState([]);
  const [state, setState] = useState({ loading: true, error: null, done: false });
  const [opened, setOpened] = useState(null);

  const load = useCallback(
    async (skip) => {
      setState((current) => ({ ...current, loading: true, error: null }));
      try {
        const list = await request(
          'git.log',
          { projectPath, limit: PAGE, skip },
          { timeoutMs: 60000 },
        );
        setCommits((current) => (skip ? [...current, ...list] : list));
        setState({ loading: false, error: null, done: list.length < PAGE });
      } catch (error) {
        setState({ loading: false, error: errorText(error), done: true });
      }
    },
    [projectPath],
  );

  useEffect(() => {
    load(0);
  }, [load, epoch]);

  if (opened)
    return (
      <CommitDetail
        projectPath={projectPath}
        commit={opened}
        notify={notify}
        onBack={() => setOpened(null)}
      />
    );

  return (
    <div className="history-page">
      <div className="page-heading">
        <h2>提交历史</h2>
        <span>{branch ?? ''}</span>
      </div>
      {state.error && <PageError text={state.error} />}
      {commits.map((commit) => (
        <button className="history-row" key={commit.hash} onClick={() => setOpened(commit)}>
          <GitCommit size={19} />
          <span>
            <strong>{commit.message}</strong>
            <small>
              {commit.author} · {relativeTime(commit.date)}
            </small>
          </span>
          <code>{commit.shortHash}</code>
          <CaretRight size={14} />
        </button>
      ))}
      {!state.loading && !state.error && commits.length === 0 && (
        <div className="pane-note">这个仓库还没有提交</div>
      )}
      {state.loading && <div className="pane-note">正在读取提交历史…</div>}
      {!state.loading && !state.done && (
        <button className="load-more" onClick={() => load(commits.length)}>
          加载更早的提交
        </button>
      )}
    </div>
  );
}

// ---------- 分支 ----------

export function BranchesTab({
  branches,
  branchesError,
  currentBranch,
  onNewSession,
  onCheckout,
  onBranchContext,
}) {
  const local = (branches ?? []).filter((item) => !item.isRemote);
  return (
    <div className="history-page">
      <div className="page-heading">
        <h2>本地分支</h2>
        <button onClick={() => onNewSession('current')}>
          <Plus size={14} />
          新建会话
        </button>
      </div>
      {branchesError && <PageError text={branchesError} />}
      {!branches && !branchesError && <div className="pane-note">正在读取分支…</div>}
      {local.map((item) => {
        const current = item.isCurrent || item.name === currentBranch;
        const track = [
          item.upstream ? `跟踪 ${item.upstream}` : '没有上游分支',
          item.ahead ? `领先 ${item.ahead}` : '',
          item.behind ? `落后 ${item.behind}` : '',
          item.upstreamGone ? '上游已删除' : '',
        ]
          .filter(Boolean)
          .join(' · ');
        return (
          <div
            className="history-row"
            key={item.name}
            onContextMenu={(event) => onBranchContext(event, item.name)}
          >
            <GitBranch size={18} />
            <span>
              <strong>{item.name}</strong>
              <small>{current ? `当前分支 · 工作区所在位置 · ${track}` : track}</small>
            </span>
            <code>{item.lastCommit}</code>
            <button disabled={current} onClick={() => onCheckout(item.name)}>
              {current ? <Check size={14} /> : '切换'}
            </button>
          </div>
        );
      })}
    </div>
  );
}

// ---------- 工作树 ----------

export function WorktreeTab({ projectPath, home, epoch, onCreateWorktree, runGit, worktreeLabels = {}, sessions = [] }) {
  const { data, error, loading } = useGitData('git.worktrees', projectPath, epoch);
  const [confirming, setConfirming] = useState(null);
  return (
    <div className="history-page">
      <div className="page-heading">
        <h2>工作树</h2>
        <button onClick={onCreateWorktree}>
          <Plus size={14} />
          创建工作树
        </button>
      </div>
      {error && <PageError text={error} />}
      {loading && <div className="pane-note">正在读取工作树…</div>}
      {(data ?? []).map((item, index) => (
        <div className="history-row" key={item.path}>
          <TreeStructure size={20} />
          <span>
            <strong>{worktreeLabels[item.path]?.name || baseName(item.path)}</strong>
            <small>
              {tildePath(item.path, home)}
              {index === 0 ? ' · 主工作树' : ''}
              {item.isLocked ? ' · 已锁定' : ''}
              {item.isPrunable ? ' · 目录已丢失' : ''}
            </small>
          </span>
          <code>{item.branch ?? (item.head ? item.head.slice(0, 7) : 'detached')}</code>
          {index > 0 &&
            (confirming === item.path ? (
              <>
                <small className="worktree-remove-note">
                  {(() => {
                    const form = (path) => path?.replace(/^\/private(?=\/(?:tmp|var)\/)/, '');
                    const root = form(item.path);
                    const inside = sessions.filter((session) => form(session.cwd) === root || form(session.cwd)?.startsWith(root + '/'));
                    const live = inside.filter((session) => session.running).length;
                    const parts = [];
                    if (inside.length) parts.push(`${inside.length} 个历史会话在此目录${live ? `（${live} 个正在运行）` : ''}`);
                    // 统一目录（不在项目 .worktrees 下）由工作树命令登记，移除后同一任务需先清理登记才能重建。
                    if (!item.path.startsWith(projectPath + '/.worktrees/')) parts.push('工作树命令中的任务登记会保留');
                    return parts.length ? parts.join('；') + '。' : '';
                  })()}
                </small>
                <button
                  className="danger"
                  onClick={() => {
                    setConfirming(null);
                    runGit(
                      'git.removeWorktree',
                      { input: { projectPath, path: item.path, force: false } },
                      `已移除工作树 ${baseName(item.path)}`,
                    );
                  }}
                >
                  确认移除
                </button>
                <button onClick={() => setConfirming(null)}>取消</button>
              </>
            ) : (
              <button title="移除这个工作树（分支保留）" onClick={() => setConfirming(item.path)}>
                <Trash size={13} />
                移除
              </button>
            ))}
        </div>
      ))}
    </div>
  );
}

// ---------- 更多：合并与冲突 ----------

function ConflictPage({ projectPath, epoch, branches, currentBranch, runGit, onBack }) {
  const { data, error, loading } = useGitData('git.mergeState', projectPath, epoch);
  const [confirmAbort, setConfirmAbort] = useState(false);
  const others = (branches ?? []).filter((item) => !item.isCurrent && item.name !== currentBranch);
  return (
    <div className="history-page">
      <div className="page-heading">
        <button className="back-button" onClick={onBack}>
          <ArrowLeft size={14} />
          更多 Git 操作
        </button>
        <span>{currentBranch ?? ''}</span>
      </div>
      <h2 className="sub-heading">合并与冲突</h2>
      {error && <PageError text={error} />}
      {loading && <div className="pane-note">正在读取合并状态…</div>}
      {data?.merging && (
        <>
          <div className="merge-banner" role="status">
            <GitMerge size={15} />
            <span>
              正在合并{data.head ? ` ${data.head}` : ''}，
              {data.conflicts.length
                ? `还有 ${data.conflicts.length} 个文件冲突`
                : '冲突已全部解决'}
            </span>
            <button
              className="primary"
              disabled={data.conflicts.length > 0}
              onClick={() => runGit('git.mergeContinue', {}, '合并已完成')}
            >
              继续合并
            </button>
            {confirmAbort ? (
              <>
                <button
                  className="danger"
                  onClick={() => {
                    setConfirmAbort(false);
                    runGit('git.mergeAbort', {}, '已终止合并，工作区恢复到合并前');
                  }}
                >
                  确认终止
                </button>
                <button onClick={() => setConfirmAbort(false)}>取消</button>
              </>
            ) : (
              <button onClick={() => setConfirmAbort(true)}>终止合并</button>
            )}
          </div>
          {data.conflicts.map((path) => (
            <div className="history-row" key={path}>
              <Warning size={18} />
              <span>
                <strong>{baseName(path)}</strong>
                <small>{path}</small>
              </span>
              <button
                onClick={() =>
                  runGit(
                    'git.resolveConflict',
                    { filePath: path, strategy: 'ours' },
                    `已采用当前分支的 ${baseName(path)}`,
                  )
                }
              >
                采用当前分支
              </button>
              <button
                onClick={() =>
                  runGit(
                    'git.resolveConflict',
                    { filePath: path, strategy: 'theirs' },
                    `已采用传入分支的 ${baseName(path)}`,
                  )
                }
              >
                采用传入分支
              </button>
              <button
                title="已在编辑器里手工解决后使用"
                onClick={() =>
                  runGit(
                    'git.resolveConflict',
                    { filePath: path, strategy: 'mark' },
                    `已标记 ${baseName(path)} 为已解决`,
                  )
                }
              >
                标记已解决
              </button>
            </div>
          ))}
        </>
      )}
      {data && !data.merging && (
        <>
          <div className="pane-note">
            当前没有进行中的合并。选择一个分支合并到 {currentBranch ?? '当前分支'}：
          </div>
          {others.map((item) => (
            <div className="history-row" key={item.name}>
              <GitBranch size={18} />
              <span>
                <strong>{item.name}</strong>
                <small>{item.isRemote ? '远程分支' : '本地分支'}</small>
              </span>
              <button
                onClick={() =>
                  runGit('git.merge', { branch: item.name }, `已将 ${item.name} 合并到当前分支`)
                }
              >
                <GitMerge size={13} />
                合并
              </button>
            </div>
          ))}
        </>
      )}
    </div>
  );
}

// ---------- 更多：Stash ----------

function StashPage({ projectPath, epoch, changed, runGit, onBack }) {
  const { data, error, loading } = useGitData('git.stashes', projectPath, epoch);
  const [message, setMessage] = useState('');
  const [untracked, setUntracked] = useState(true);
  const [confirming, setConfirming] = useState(null);
  return (
    <div className="history-page">
      <div className="page-heading">
        <button className="back-button" onClick={onBack}>
          <ArrowLeft size={14} />
          更多 Git 操作
        </button>
        <span>{changed} 项未提交变更</span>
      </div>
      <h2 className="sub-heading">Stash 暂存</h2>
      <form
        className="stash-form"
        onSubmit={(event) => {
          event.preventDefault();
          runGit(
            'git.stashSave',
            { message: message.trim() || undefined, includeUntracked: untracked },
            '已保存当前变更到 Stash',
          ).then((ok) => ok && setMessage(''));
        }}
      >
        <input
          aria-label="Stash 说明"
          placeholder="说明（可选），例如：切分支前的半成品"
          value={message}
          onChange={(event) => setMessage(event.target.value)}
        />
        <label>
          <input
            type="checkbox"
            checked={untracked}
            onChange={(event) => setUntracked(event.target.checked)}
          />
          包含未跟踪文件
        </label>
        <button className="primary" disabled={!changed}>
          <Plus size={13} />
          保存当前变更
        </button>
      </form>
      {error && <PageError text={error} />}
      {loading && <div className="pane-note">正在读取 Stash…</div>}
      {data?.length === 0 && <div className="pane-note">还没有 Stash 记录</div>}
      {(data ?? []).map((item) => (
        <div className="history-row" key={item.ref}>
          <Stack size={19} />
          <span>
            <strong>{item.message}</strong>
            <small>
              {item.ref} · {relativeTime(item.date)}
            </small>
          </span>
          <button
            title="恢复变更并保留这条记录"
            onClick={() => runGit('git.stashApply', { index: item.index }, `已应用 ${item.ref}`)}
          >
            应用
          </button>
          <button
            title="恢复变更并移除这条记录"
            onClick={() =>
              runGit('git.stashPop', { index: item.index }, `已恢复并移除 ${item.ref}`)
            }
          >
            弹出
          </button>
          {confirming === item.ref ? (
            <>
              <button
                className="danger"
                onClick={() => {
                  setConfirming(null);
                  runGit('git.stashDrop', { index: item.index }, `已删除 ${item.ref}`);
                }}
              >
                确认删除
              </button>
              <button onClick={() => setConfirming(null)}>取消</button>
            </>
          ) : (
            <button title="删除这条记录（无法恢复）" onClick={() => setConfirming(item.ref)}>
              <Trash size={13} />
            </button>
          )}
        </div>
      ))}
    </div>
  );
}

// ---------- 更多：操作日志 ----------

function LogPage({ projectPath, epoch, log, onBack }) {
  const { data, error, loading } = useGitData('git.reflog', projectPath, epoch, { limit: 60 });
  return (
    <div className="history-page">
      <div className="page-heading">
        <button className="back-button" onClick={onBack}>
          <ArrowLeft size={14} />
          更多 Git 操作
        </button>
      </div>
      <h2 className="sub-heading">操作日志</h2>
      <div className="menu-title">本次运行</div>
      {log.length === 0 && <div className="pane-note">本次运行还没有执行过操作</div>}
      {log.map((entry, index) => (
        <div className="log-row" key={index}>
          <code>{entry.time}</code>
          <span className={entry.failed ? 'red' : ''}>{entry.text}</span>
        </div>
      ))}
      <div className="menu-title">仓库引用日志（git reflog）</div>
      {error && <PageError text={error} />}
      {loading && <div className="pane-note">正在读取引用日志…</div>}
      {(data ?? []).map((entry) => (
        <div className="log-row" key={entry.selector}>
          <code>{entry.hash}</code>
          <span>{entry.message}</span>
          <small>{relativeTime(entry.date)}</small>
        </div>
      ))}
    </div>
  );
}

export function MoreTab(props) {
  const { page, onPage } = props;
  if (page === '合并与冲突') return <ConflictPage {...props} onBack={() => onPage(null)} />;
  if (page === 'Stash 暂存') return <StashPage {...props} onBack={() => onPage(null)} />;
  if (page === '操作日志') return <LogPage {...props} onBack={() => onPage(null)} />;
  return (
    <div className="history-page">
      <div className="page-heading">
        <h2>更多 Git 操作</h2>
      </div>
      {[
        ['合并与冲突', GitMerge, '合并分支、解决冲突、终止或继续合并'],
        ['Stash 暂存', Stack, '临时保存未提交的变更，稍后恢复'],
        ['操作日志', ClockCounterClockwise, '本次运行的操作与仓库引用日志'],
      ].map(([name, Icon, hint]) => (
        <button className="history-row" key={name} onClick={() => onPage(name)}>
          <Icon size={20} />
          <span>
            <strong>{name}</strong>
            <small>{hint}</small>
          </span>
          <CaretRight size={15} />
        </button>
      ))}
    </div>
  );
}
