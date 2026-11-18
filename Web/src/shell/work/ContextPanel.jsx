// 工作空间右侧的详情栏：任务详情 / 变更文件 / 活动。各标签的数据都属于当前选中的对象，独立滚动。
import React, { useEffect, useRef, useState } from 'react';
import {
  ArrowCounterClockwise,
  ArrowRight,
  ArrowSquareOut,
  ArrowsClockwise,
  Briefcase,
  ChatsCircle,
  CheckCircle,
  CheckSquare,
  Circle,
  ClipboardText,
  Export,
  FileCode,
  Files,
  GitBranch,
  Info,
  Play,
  ProhibitInset,
  Stop,
  Terminal,
  Warning,
  X,
} from '@phosphor-icons/react';
import { errorText, request } from '../bridge.js';
import { IconButton, baseName, dirName, relativeTime, tildePath } from '../ui.jsx';
import { StatusPill } from './WorkChat.jsx';
import { confirmAction } from './confirm.jsx';
import { formatTime, newId, shortId, useTranscript } from './useWorks.js';

const TABS = [
  ['context', '任务详情'],
  ['files', '变更文件'],
  ['activity', '活动'],
];

const DELIVERY = {
  pending: ['等待发送', 'neutral'],
  sent: ['已发送', 'green'],
  unknown: ['结果未知', 'amber'],
  failed: ['发送失败', 'red'],
};

export function useReviewState(work, stamp) {
  const [state, setState] = useState(null);
  const [error, setError] = useState(null);
  const target = useRef(null);
  const id = work?.id ?? null;
  target.current = id;
  useEffect(() => {
    setState(null);
    setError(null);
  }, [id]);
  useEffect(() => {
    if (!id) return;
    request('review.state', { workId: id }, { timeoutMs: 120000 })
      .then((result) => {
        if (target.current === id) {
          setState(result);
          setError(null);
        }
      })
      .catch((cause) => target.current === id && setError(errorText(cause)));
  }, [id, stamp, work?.status, work?.revision]);
  return { state, error };
}

function FileList({ files, onOpen, limit }) {
  if (!files?.length) return <p className="context-empty">没有相对基线的变更。</p>;
  return (
    <>
      {files.slice(0, limit).map((file) => (
        <button className="file-row" key={file.path} title={file.path} onClick={() => onOpen(file.path)}>
          <FileCode size={14} />
          <span>
            {baseName(file.path)}
            <small>{dirName(file.path) || '.'}</small>
          </span>
          <em className={file.status === 'D' ? 'red' : ''}>
            {file.binary ? '二进制' : file.status === 'D' ? `−${file.deleted ?? 0}` : `+${file.added ?? 0}`}
          </em>
        </button>
      ))}
      {limit && files.length > limit && <p className="context-empty">另有 {files.length - limit} 个文件…</p>}
    </>
  );
}

function WorkActions({ work, notify, onExport, onOpenTerminal }) {
  const [busy, setBusy] = useState(false);
  async function run(method, confirm) {
    if (busy) return;
    if (confirm && !(await confirmAction(confirm))) return;
    setBusy(true);
    try {
      const result = await request(method, { workId: work.id, revision: work.revision, requestId: newId() });
      if (result?.accepted === false && result.message) notify(result.message, true);
    } catch (cause) {
      notify(errorText(cause), true);
    } finally {
      setBusy(false);
    }
  }
  const live = work.status === 'running' || work.status === 'waiting_user';
  const ended = work.status === 'completed' || work.status === 'cancelled';
  return (
    <div className="context-actions">
      {work.status === 'queued' && !work.startRequested && (
        <button className="primary" disabled={busy} onClick={() => run('work.start')}>
          <Play size={13} weight="fill" />
          启动 Work
        </button>
      )}
      {live && (
        <button disabled={busy} onClick={() => run('work.interrupt')}>
          <Stop size={13} />
          停止本轮
        </button>
      )}
      {(work.status === 'failed' || work.status === 'interrupted') && (
        <button className="primary" disabled={busy} onClick={() => run('work.retry')}>
          <ArrowsClockwise size={13} />
          重试
        </button>
      )}
      <button onClick={onExport}>
        <Export size={13} />
        导出任务卡 / 执行记录
      </button>
      {work.sessionId && !work.processAlive && (
        <button onClick={onOpenTerminal} title="执行器没有持有这个会话时，可以在终端或图形聊天里打开它">
          <Terminal size={13} />
          在会话中打开
        </button>
      )}
      {!ended && (
        <button
          className="danger"
          disabled={busy || work.cancelling}
          onClick={() =>
            run('work.cancel', {
              title: `取消 ${work.displayId}？`,
              text: '执行会被停止，Work 标记为已取消。工作树和分支保留，不会自动删除。',
              confirmLabel: '取消 Work',
              cancelLabel: '保留',
              danger: true,
            })
          }
        >
          <ProhibitInset size={13} />
          取消 Work
        </button>
      )}
    </div>
  );
}

function WorkDetail({ work, review, transcript, home, notify, onOpenFile, onOpenReview, onOpenSource, onExport, onOpenTerminal }) {
  const tapd = work.tapdRefs?.[0];
  const run = work.run;
  const evidence = transcript?.evidence ?? [];
  const checks = evidence.filter((item) => item.kind === 'check');
  const currentTree = review?.tree;
  const passedNow = checks.some((item) => item.detail?.state === 'passed' && item.tree === currentTree);
  const reviewed = evidence.some((item) => item.kind === 'review');
  const deliveries = (work.deliveries ?? []).filter((item) => item.target !== 'wecom-notice');
  const [snapshot, setSnapshot] = useState(null);
  const [checking, setChecking] = useState(false);

  useEffect(() => setSnapshot(null), [work.id]);

  async function checkSnapshot() {
    setChecking(true);
    try {
      setSnapshot(await request('tapd.snapshotCheck', { workId: work.id }, { timeoutMs: 90000 }));
    } catch (cause) {
      notify(errorText(cause), true);
    } finally {
      setChecking(false);
    }
  }

  const check = (done, text) => (
    <div className="checkline">
      {done ? <CheckCircle size={14} className="green" /> : <Circle size={14} />}
      {text}
    </div>
  );

  return (
    <>
      <div className="context-section">
        <div className="section-title">
          {tapd ? <ClipboardText size={14} /> : work.origin === 'wecom' ? <ChatsCircle size={14} /> : <Briefcase size={14} />}
          {tapd ? '关联需求' : work.origin === 'wecom' ? '企业微信发起' : '本地 Work'}
          <span className="pill neutral">{work.displayId}</span>
        </div>
        {tapd ? (
          <button className="source-box" onClick={onOpenSource}>
            <div>
              <span className="tapd-logo">T</span>
              <span>TAPD {tapd.entityType}</span>
              <code title={tapd.entityId}>#{shortId(tapd.entityId)}</code>
            </div>
            <strong>{tapd.title || work.title}</strong>
            <small>workspace {tapd.workspaceId}</small>
          </button>
        ) : work.origin === 'wecom' ? (
          <button className="source-box" onClick={onOpenSource}>
            <div>
              <ChatsCircle size={13} />
              <span>企业微信 · WorkBuddy</span>
            </div>
            <strong>{work.title}</strong>
            <small>查看原始消息、澄清与回执</small>
          </button>
        ) : (
          <p className="context-empty">在本应用里创建的独立 Work，没有外部来源。</p>
        )}
        <dl className="metadata">
          {tapd && (
            <div>
              <dt>业务状态</dt>
              <dd>
                <span className="pill blue">{snapshot?.businessStatus ?? tapd.businessStatus ?? '—'}</span>
                <small>{snapshot ? '刚刚读取' : '导入时'}</small>
                <button className="link-button" disabled={checking} onClick={checkSnapshot}>
                  {checking ? '读取中…' : '读取最新'}
                </button>
              </dd>
            </div>
          )}
          <div>
            <dt>AI 执行状态</dt>
            <dd>
              <StatusPill work={work} />
            </dd>
          </div>
          <div>
            <dt>项目</dt>
            <dd title={work.project?.path}>{work.project?.name ?? '项目不可用'}</dd>
          </div>
          <div>
            <dt>创建</dt>
            <dd>{relativeTime(work.createdAt)}</dd>
          </div>
        </dl>
        {snapshot?.changed && (
          <div className="pane-note warn" role="status">
            <Warning size={14} />
            <span>
              TAPD 上的需求在导入后有更新（
              {[snapshot.titleChanged && '标题', snapshot.descriptionChanged && '描述', snapshot.statusChanged && '状态']
                .filter(Boolean)
                .join('、') || '内容'}
              ）。正在执行的目标不会被自动覆盖；如果影响范围，请在对话里说明或新建一轮。
            </span>
          </div>
        )}
        {work.statusReason && <p className="status-reason">{work.statusReason}</p>}
      </div>

      <div className="context-section">
        <div className="section-title">
          <GitBranch size={14} />
          执行环境
        </div>
        <div className="code-box" title={work.workspacePath ?? ''}>
          <GitBranch size={13} />
          <code>{work.branch ?? (work.workspacePath ? '（无分支）' : '启动时创建')}</code>
        </div>
        <div className="environment-row">
          <span>工作目录</span>
          <b title={work.workspacePath ?? ''}>
            {work.workspacePath ? tildePath(work.workspacePath, home) : '尚未准备'}
          </b>
        </div>
        <div className="environment-row">
          <span>隔离方式</span>
          <b>{work.isolation === 'worktree' ? '独立 Git worktree' : '项目目录（未隔离）'}</b>
        </div>
        <div className="environment-row">
          <span>执行器</span>
          <b>{work.executor === 'antigravity' ? 'Antigravity (ACP)' : 'Claude Code'}</b>
        </div>
        {(transcript?.segments?.length ?? 0) > 1 && (
          <div className="environment-row">
            <span>会话接力</span>
            <b>共 {transcript.segments.length} 段跨引擎执行</b>
          </div>
        )}
        {run && (
          <div className="environment-row">
            <span>当前轮次</span>
            <b>
              第 {run.attempt} 轮 · {run.status}
              {run.exitCode != null ? ` · 退出码 ${run.exitCode}` : ''}
            </b>
          </div>
        )}
        {work.baseCommit && (
          <div className="environment-row">
            <span>基线提交</span>
            <b>
              <code>{work.baseCommit.slice(0, 10)}</code>
            </b>
          </div>
        )}
      </div>

      <div className="context-section">
        <div className="section-title">
          <Files size={14} />
          本次变更
          {review?.files && <span className="tiny-count">{review.files.length}</span>}
          <IconButton icon={ArrowRight} label="打开变更审阅" onClick={onOpenReview} />
        </div>
        {!review ? (
          <p className="context-empty">正在读取…</p>
        ) : !review.prepared ? (
          <p className="context-empty">{review.reason}</p>
        ) : !review.isRepository ? (
          <p className="context-empty">执行目录不是 Git 仓库，无法列出差异。</p>
        ) : (
          <FileList files={review.files} onOpen={onOpenFile} limit={6} />
        )}
      </div>

      <div className="context-section">
        <div className="section-title">
          <CheckSquare size={14} />
          交付检查
        </div>
        {check(Boolean(work.workspacePath), work.isolation === 'worktree' ? '执行目录已隔离（独立工作树）' : '执行目录已准备（未隔离）')}
        {check(
          passedNow,
          checks.length === 0 ? '验证：未运行' : passedNow ? '验证：当前版本通过' : '验证：没有针对当前版本的通过记录',
        )}
        {check(reviewed && !review?.acceptedStale, review?.acceptedStale ? '审阅：通过后代码又有变化' : reviewed ? '审阅：已通过' : '审阅：未进行')}
        {deliveries.length === 0 ? (
          check(false, tapd ? 'TAPD 回填：未请求' : work.origin === 'wecom' ? '原会话汇报：未请求' : '结果投递：无外部来源')
        ) : (
          deliveries.map((item) => (
            <div className="checkline" key={item.id} title={item.error ?? ''}>
              {item.status === 'sent' ? <CheckCircle size={14} className="green" /> : <Circle size={14} />}
              {item.target === 'tapd' ? 'TAPD 回填' : '原会话汇报'}
              <span className={`pill ${DELIVERY[item.status]?.[1] ?? 'neutral'}`}>
                {DELIVERY[item.status]?.[0] ?? item.status}
              </span>
            </div>
          ))
        )}
      </div>

      <div className="context-section">
        <WorkActions work={work} notify={notify} onExport={onExport} onOpenTerminal={onOpenTerminal} />
      </div>
      <div className="context-tip">
        <Info size={13} />
        执行状态、TAPD 业务状态与结果投递分别记录：Work 完成不代表需求已验收、发布或上线。
      </div>
    </>
  );
}

function Activity({ items }) {
  if (!items) return <p className="context-empty">正在读取…</p>;
  if (!items.length) return <p className="context-empty">还没有活动记录。</p>;
  return (
    <div className="activity-list">
      {items.map((item) => (
        <div className="activity-item" key={item.seq}>
          <span className="activity-dot" />
          <div>
            <strong>{item.title}</strong>
            {item.detail && <p>{item.detail}</p>}
            <small>
              {formatTime(item.at)}
              {item.actor ? ` · ${item.actor}` : ''}
            </small>
          </div>
        </div>
      ))}
    </div>
  );
}

function SessionInfo({ active, project, status, home, onOpenGit, onContinueAsWork }) {
  const files = status?.files ?? [];
  return (
    <>
      <div className="context-section">
        <div className="section-title">
          <Terminal size={14} />
          {active ? '当前会话' : '没有打开的会话'}
        </div>
        {active ? (
          <>
            <button className="source-box" disabled>
              <strong>
                <em className={`provider-badge ${active.provider ?? 'claude'}`}>
                  {active.provider === 'antigravity' ? 'A' : 'C'}
                </em>
                {active.label}
              </strong>
              <small>{tildePath(active.cwd, home)}</small>
            </button>
            <p className="context-empty">
              这是一个普通会话：可以随时讨论，不会产生持久任务。需要排队执行、审阅和交付时，把它作为 Work 继续。
            </p>
            <button onClick={onContinueAsWork}>
              <Briefcase size={13} />
              作为 Work 继续
            </button>
          </>
        ) : (
          <p className="context-empty">在左侧选一个会话或 Work，或新建一个。</p>
        )}
      </div>
      <div className="context-section">
        <div className="section-title">
          <Files size={14} />
          {project ? `${project.title} 的未提交变更` : '未提交变更'}
          <span className="tiny-count">{files.length}</span>
          <IconButton icon={ArrowRight} label="打开变更" onClick={onOpenGit} />
        </div>
        {files.length === 0 ? (
          <p className="context-empty">{status ? '工作区是干净的。' : '这个目录不是 Git 仓库，或正在读取。'}</p>
        ) : (
          files.slice(0, 12).map((file) => (
            <button className="file-row" key={file.path} title={file.path} onClick={onOpenGit}>
              <FileCode size={14} />
              <span>
                {baseName(file.path)}
                <small>{dirName(file.path) || '.'}</small>
              </span>
              <em>{file.label}</em>
            </button>
          ))
        )}
      </div>
    </>
  );
}

export default function ContextPanel({
  work,
  active,
  project,
  gitStatus,
  home,
  tab,
  onTab,
  onClose,
  notify,
  onOpenFile,
  onOpenReview,
  onOpenGit,
  onOpenSource,
  onExport,
  onOpenTerminal,
  onContinueAsWork,
}) {
  const marker = work ? `${work.revision}:${work.status}:${(work.deliveries ?? []).map((d) => d.status).join(',')}` : '';
  const { data } = useTranscript(work?.id ?? null, marker);
  const { state: review, error: reviewError } = useReviewState(work, marker);
  const [revertingUndo, setRevertingUndo] = useState(false);
  const checkpoints = data?.checkpoints ?? [];
  const latestCheckpoint = checkpoints[checkpoints.length - 1] ?? null;
  const canUndoRevert =
    Boolean(work) &&
    work.status !== 'running' &&
    work.status !== 'waiting_user' &&
    latestCheckpoint?.phase === 'undo';

  async function undoLastRevert() {
    if (!work || !latestCheckpoint || revertingUndo) return;
    const ok = await confirmAction({
      title: '撤销上次代码回退？',
      text: `将恢复到自动备份点「${latestCheckpoint.label}」。`,
      confirmLabel: '确认恢复',
      cancelLabel: '取消',
    });
    if (!ok) return;
    setRevertingUndo(true);
    try {
      const res = await request(
        'checkpoint.revert',
        { workId: work.id, checkpointId: latestCheckpoint.id, requestId: newId() },
        { timeoutMs: 120000 },
      );
      notify(`已恢复回退前的代码（还原 ${res.affectedCount ?? 0} 个文件）`);
    } catch (cause) {
      notify(errorText(cause), true);
    } finally {
      setRevertingUndo(false);
    }
  }

  return (
    <>
      <div className="panel-tabs" role="tablist">
        {TABS.map(([value, label]) => (
          <button
            key={value}
            role="tab"
            aria-selected={tab === value}
            className={tab === value ? 'active' : ''}
            onClick={() => onTab(value)}
          >
            {label}
          </button>
        ))}
        <IconButton icon={X} label="关闭详情" onClick={onClose} />
      </div>
      <div className="context-content">
        {!work ? (
          tab === 'activity' ? (
            <p className="context-empty padded">活动记录属于 Work。普通会话的历史在会话本身里。</p>
          ) : (
            <SessionInfo
              active={active}
              project={project}
              status={gitStatus}
              home={home}
              onOpenGit={onOpenGit}
              onContinueAsWork={onContinueAsWork}
            />
          )
        ) : tab === 'files' ? (
          <div className="context-section">
            <div className="section-title">
              <Files size={14} />
              相对基线的变更
              {review?.files && <span className="tiny-count">{review.files.length}</span>}
            </div>
            {checkpoints.length > 0 && (
              <div className="checkpoint-summary-bar">
                <span>代码检查点：{checkpoints.length} 个</span>
                {canUndoRevert && (
                  <button
                    type="button"
                    className="turn-revert-btn"
                    disabled={revertingUndo}
                    onClick={undoLastRevert}
                  >
                    <ArrowCounterClockwise size={11} />
                    {revertingUndo ? '恢复中…' : '撤销上次代码回退'}
                  </button>
                )}
              </div>
            )}
            {reviewError && (
              <div className="pane-note error">
                <Warning size={14} />
                {reviewError}
              </div>
            )}
            {!review ? (
              <p className="context-empty">正在读取…</p>
            ) : !review.prepared ? (
              <p className="context-empty">{review.reason}</p>
            ) : !review.isRepository ? (
              <p className="context-empty">执行目录不是 Git 仓库，无法列出差异。</p>
            ) : (
              <>
                <FileList files={review.files} onOpen={onOpenFile} />
                {review.files.length > 0 && (
                  <div className="change-summary">
                    <span>+{review.added}</span>
                    <b>−{review.deleted}</b>
                  </div>
                )}
              </>
            )}
            <button className="primary full" onClick={onOpenReview}>
              <ArrowSquareOut size={13} />
              打开变更审阅
            </button>
          </div>
        ) : tab === 'activity' ? (
          <Activity items={data?.activity} />
        ) : (
          <WorkDetail
            work={work}
            review={review}
            transcript={data}
            home={home}
            notify={notify}
            onOpenFile={onOpenFile}
            onOpenReview={onOpenReview}
            onOpenSource={onOpenSource}
            onExport={onExport}
            onOpenTerminal={onOpenTerminal}
          />
        )}
      </div>
    </>
  );
}
