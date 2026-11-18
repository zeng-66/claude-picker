// 变更审阅：相对基线的实际差异、验证记录、确认变更与交付入口。
// 「确认变更」记录的是对当前这一版代码的认可；代码再变，之前的认可就不再代表当前代码。
import React, { useEffect, useRef, useState } from 'react';
import {
  ArrowSquareOut,
  ArrowsClockwise,
  Check,
  CheckCircle,
  CircleNotch,
  FileCode,
  GitDiff,
  GitPullRequest,
  Play,
  Warning,
  XCircle,
} from '@phosphor-icons/react';
import { errorText, request } from '../bridge.js';
import { baseName, dirName, useStored } from '../ui.jsx';
import DiffView from '../DiffView.jsx';
import { parsePatch } from '../diff.js';
import { formatTime, newId, useTranscript } from './useWorks.js';
import { useReviewState } from './ContextPanel.jsx';

const CHECK_STATE = {
  passed: ['通过', 'green'],
  failed: ['失败', 'red'],
  timeout: ['超时', 'amber'],
  error: ['未能运行', 'red'],
  running: ['运行中', 'blue'],
};

const STATUS_TEXT = { A: '新增', M: '修改', D: '删除', R: '重命名', C: '复制', T: '类型变更' };

function FileDiff({ work, file, tree }) {
  const [result, setResult] = useState(null);
  const [error, setError] = useState(null);
  const [mode, setMode] = useStored('reviewDiffMode', '统一');
  const token = useRef(0);
  useEffect(() => {
    if (!file) return;
    const current = ++token.current;
    setResult(null);
    setError(null);
    request('review.diff', { workId: work.id, path: file.path }, { timeoutMs: 120000 })
      .then((value) => current === token.current && setResult(value))
      .catch((cause) => current === token.current && setError(errorText(cause)));
  }, [work.id, file?.path, tree]);

  if (!file)
    return (
      <div className="empty">
        <GitDiff size={28} />
        <h3>选择一个文件查看差异</h3>
      </div>
    );
  const parsed = result?.patch ? parsePatch(result.patch) : null;
  return (
    <>
      <div className="diff-toolbar">
        <div>
          <FileCode size={15} />
          <strong title={file.path}>{file.path}</strong>
          <span>
            {STATUS_TEXT[file.status] ?? file.status}
            {file.oldPath ? `（原 ${file.oldPath}）` : ''} · 相对基线
          </span>
        </div>
        <div className="diff-stats">
          {!file.binary && (
            <>
              <span>+{file.added ?? 0}</span>
              <b>−{file.deleted ?? 0}</b>
            </>
          )}
          <div className="segmented" role="group" aria-label="差异视图">
            {['统一', '并排'].map((value) => (
              <button key={value} className={mode === value ? 'chosen' : ''} onClick={() => setMode(value)}>
                {value}
              </button>
            ))}
          </div>
        </div>
      </div>
      <div className="diff-scroll">
        {error && (
          <div className="pane-note error">
            <Warning size={14} />
            {error}
          </div>
        )}
        {!result && !error && <div className="pane-note">正在读取差异…</div>}
        {result?.error && <div className="pane-note error">{result.error}</div>}
        {result?.tooLarge && (
          <div className="pane-note">
            这个文件的差异太大（{Math.round(result.bytes / 1024)} KB），不在这里展开。请到「工作区」页或用外部工具查看。
          </div>
        )}
        {result?.binary && <div className="pane-note">二进制文件：没有可显示的文本差异。</div>}
        {parsed && !result.binary && parsed.hunks.length === 0 && (
          <div className="pane-note">
            {file.status === 'D' ? '文件已删除。' : file.status === 'R' ? '只是重命名，内容没有变化。' : '没有文本差异（可能只改了文件模式）。'}
          </div>
        )}
        {parsed && !result.binary && <DiffView hunks={parsed.hunks} mode={mode} />}
        {parsed?.truncated && <div className="pane-note">差异很长，只显示了前面的部分。</div>}
      </div>
    </>
  );
}

export default function ReviewTab({ work, notify, initialFile, onDelivery, onBack }) {
  const marker = `${work.revision}:${work.status}`;
  const [stamp, setStamp] = useState(0);
  const { state, error } = useReviewState(work, `${marker}:${stamp}`);
  const { data } = useTranscript(work.id, `${marker}:${stamp}`);
  const [selected, setSelected] = useState(initialFile ?? null);
  const [command, setCommand] = useStored(`checkCommand:${work.projectId}`, '');
  const [openCheck, setOpenCheck] = useState(null);
  const [busy, setBusy] = useState(false);
  const acceptId = useRef(newId());

  useEffect(() => {
    if (initialFile) setSelected(initialFile);
  }, [initialFile]);

  // 审阅页可见时定期重读：执行器或用户随时可能改动文件，差异和「是否仍是已审阅的版本」要跟着变。
  useEffect(() => {
    const timer = window.setInterval(() => !document.hidden && setStamp((value) => value + 1), 6000);
    return () => window.clearInterval(timer);
  }, []);

  const files = state?.files ?? [];
  const file = files.find((item) => item.path === selected) ?? files[0] ?? null;
  const evidence = data?.evidence ?? [];
  const checks = evidence.filter((item) => item.kind === 'check');
  const tapd = work.tapdRefs?.[0];
  const canAccept = work.status === 'waiting_review' && state?.prepared;
  const completed = work.status === 'completed';

  async function accept() {
    if (!canAccept || busy) return;
    setBusy(true);
    try {
      await request(
        'review.accept',
        { workId: work.id, runId: work.currentRunId, tree: state.tree ?? undefined, requestId: acceptId.current },
        { timeoutMs: 120000 },
      );
      notify('已确认当前版本的变更，Work 完成');
    } catch (cause) {
      notify(errorText(cause), true);
      acceptId.current = newId();
      setStamp((value) => value + 1); // 代码变了：重新读取，让用户看到最新差异
    } finally {
      setBusy(false);
    }
  }

  async function runCheck() {
    const line = command.trim();
    if (!line) return;
    try {
      await request('evidence.runCheck', { workId: work.id, command: line });
      notify('验证命令已开始运行，结果会记录在这里');
      setStamp((value) => value + 1);
    } catch (cause) {
      notify(errorText(cause), true);
    }
  }

  if (error)
    return (
      <div className="pane-note error">
        <Warning size={14} />
        {error}
      </div>
    );
  if (!state) return <div className="pane-note">正在读取这个 Work 的变更…</div>;
  if (!state.prepared)
    return (
      <div className="empty">
        <GitDiff size={30} />
        <h3>还没有可审阅的内容</h3>
        <p>{state.reason}</p>
        <button onClick={onBack}>返回对话</button>
      </div>
    );

  return (
    <section className="review-page">
      <div className="git-layout">
        <aside className="git-files">
          <div className="section-title">
            <GitDiff size={14} />
            相对基线的变更
            <span className="tiny-count">{files.length}</span>
            <button className="icon-button" title="重新读取" aria-label="重新读取" onClick={() => setStamp((value) => value + 1)}>
              <ArrowsClockwise size={13} />
            </button>
          </div>
          {!state.isRepository && <p className="context-empty">执行目录不是 Git 仓库：无法列出差异，也无法把审阅绑定到代码版本。</p>}
          {state.isRepository && files.length === 0 && <p className="context-empty">相对基线没有任何变更。</p>}
          {files.map((item) => (
            <button
              key={item.path}
              className={`file-row ${file?.path === item.path ? 'selected' : ''}`}
              title={item.path}
              onClick={() => setSelected(item.path)}
            >
              <FileCode size={14} />
              <span>
                {baseName(item.path)}
                <small>{dirName(item.path) || '.'}</small>
              </span>
              <em className={item.status === 'D' ? 'red' : ''}>
                {item.binary ? '二进制' : `${STATUS_TEXT[item.status] ?? item.status} +${item.added ?? 0} −${item.deleted ?? 0}`}
              </em>
            </button>
          ))}
          {state.isRepository && (
            <p className="version-line" title={`tree ${state.tree ?? ''}`}>
              基线 <code>{(state.base ?? '—').slice(0, 9)}</code> → 当前 tree <code>{(state.tree ?? '—').slice(0, 9)}</code>
              {state.headMoved ? `，HEAD ${String(state.head).slice(0, 9)}` : '，尚未提交'}
            </p>
          )}

          <div className="git-divider" />
          <div className="section-title">
            <CheckCircle size={14} />
            验证记录
          </div>
          {checks.length === 0 && <p className="context-empty">未运行：应用内还没有验证命令的执行记录。</p>}
          <div className="validation">
            {checks.map((check) => {
              const detail = check.detail ?? {};
              const [label, tone] = CHECK_STATE[detail.state] ?? ['未知', 'neutral'];
              const stale = detail.state !== 'running' && check.tree !== state.tree;
              return (
                <div key={check.id} className="check-row">
                  <button onClick={() => setOpenCheck(openCheck === check.id ? null : check.id)} aria-expanded={openCheck === check.id}>
                    {detail.state === 'passed' ? (
                      <Check size={13} className="green" />
                    ) : detail.state === 'running' ? (
                      <CircleNotch size={13} className="spin" />
                    ) : (
                      <XCircle size={13} className="red" />
                    )}
                    <code>{detail.command}</code>
                    <span className={`pill ${stale ? 'amber' : tone}`}>{stale ? `${label} · 旧版本` : label}</span>
                  </button>
                  {openCheck === check.id && (
                    <div className="check-detail">
                      <small>
                        退出码 {detail.exitCode ?? '—'} · {formatTime(detail.startedAt)} → {formatTime(detail.endedAt)} · tree{' '}
                        {(check.tree ?? '—').slice(0, 9)}
                        {stale && '（之后代码又有变化，需要重新运行）'}
                      </small>
                      <pre>{detail.output || detail.launchError || '（没有输出）'}</pre>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
          <form
            className="check-form"
            onSubmit={(event) => {
              event.preventDefault();
              runCheck();
            }}
          >
            <input
              aria-label="验证命令"
              placeholder="在执行目录里运行的验证命令，如 ./gradlew test"
              value={command}
              onChange={(event) => setCommand(event.target.value)}
            />
            <button disabled={!command.trim()} title="在这个 Work 的执行目录里运行，并把结果记为证据">
              <Play size={12} weight="fill" />
              运行
            </button>
          </form>
        </aside>
        <div className="diff-panel">
          <FileDiff work={work} file={file} tree={state.tree} />
        </div>
      </div>
      <footer className="review-footer">
        <div>
          {completed && !state.acceptedStale ? (
            <CheckCircle size={16} className="green" />
          ) : (
            <GitPullRequest size={16} />
          )}
          <span>
            {completed
              ? state.acceptedStale
                ? '确认之后代码又有变化：之前的确认只对当时的版本有效。'
                : `已确认这一版变更（tree ${(state.acceptedTree ?? '').slice(0, 9) || '未绑定版本'}）。`
              : work.status === 'waiting_review'
                ? '看完差异后确认变更；需要修改就回到对话继续说明。'
                : `当前状态「${work.statusLabel}」，进入待审阅后才能确认变更。`}
          </span>
        </div>
        <div>
          <button className="secondary" onClick={onBack}>
            返回对话
          </button>
          <button className="secondary" disabled={!canAccept || busy} onClick={accept}>
            <Check size={14} />
            {completed ? '已确认变更' : busy ? '正在确认…' : '确认变更'}
          </button>
          {tapd && (
            <button className="primary" onClick={() => onDelivery('tapd')}>
              <ArrowSquareOut size={14} />
              预览 TAPD 回填
            </button>
          )}
          {work.origin === 'wecom' && (
            <button className="primary" onClick={() => onDelivery('wecom')}>
              <ArrowSquareOut size={14} />
              预览 Work 汇报
            </button>
          )}
        </div>
      </footer>
    </section>
  );
}
