// Work 的图形会话：事件流 + 业务问题 / 工具权限卡片 + 输入区。
// 这里显示的每一条都来自执行器的结构化事件；忙、待回答、待审阅都是领域状态，不靠输出猜。
import EngineIcon from '../EngineIcon.jsx';
import React, { Suspense, lazy, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowCounterClockwise,
  ArrowDown,
  ArrowRight,
  ArrowUp,
  Briefcase,
  CaretDown,
  CaretRight,
  ChatCircleDots,
  Check,
  CheckCircle,
  CircleNotch,
  GitBranch,
  GitDiff,
  Info,
  MinusSquare,
  Play,
  ProhibitInset,
  ShieldWarning,
  SidebarSimple,
  Stop,
  Warning,
  WarningCircle,
  Wrench,
} from '@phosphor-icons/react';
import { errorText, request } from '../bridge.js';
import { IconButton, baseName } from '../ui.jsx';
import { confirmAction } from './confirm.jsx';
import { formatTime, newId, sourceLabel, statusOf, useDraft, useTranscript } from './useWorks.js';

const MarkdownRenderer = lazy(() => import('../../MarkdownRenderer.jsx'));

export function StatusPill({ work }) {
  const status = statusOf(work);
  return (
    <span className={`pill ${status.tone}`}>
      <i className={`dot ${work.status === 'running' ? 'pulse' : ''}`} />
      {status.label}
    </span>
  );
}

export function toolSummary(name, input) {
  if (!input || typeof input !== 'object') return '';
  if (input.file_path) return baseName(input.file_path);
  if (input.notebook_path) return baseName(input.notebook_path);
  if (input.command) return String(input.command).split('\n')[0].slice(0, 90);
  if (input.pattern) return String(input.pattern).slice(0, 90);
  if (input.url) return String(input.url).slice(0, 90);
  if (input.query) return String(input.query).slice(0, 90);
  if (input.description) return String(input.description).slice(0, 90);
  if (input.prompt) return String(input.prompt).slice(0, 90);
  return '';
}

function resultText(content) {
  if (content == null) return '';
  if (typeof content === 'string') return content;
  if (Array.isArray(content))
    return content.map((part) => (typeof part === 'string' ? part : (part?.text ?? ''))).join('\n');
  return JSON.stringify(content, null, 2);
}

/// 事件流 → 可渲染的条目。工具调用与结果按 toolUseId 配对；消息的送达状态合并到对应的用户消息上。
function buildItems(events) {
  const items = [];
  const tools = new Map();
  const messages = new Map();
  const attentions = new Map();
  for (const event of events) {
    const p = event.payload ?? {};
    switch (event.kind) {
      case 'user': {
        const item = { type: 'user', key: event.seq, at: event.at, ...p };
        if (p.messageId) messages.set(p.messageId, item);
        items.push(item);
        break;
      }
      case 'message_state': {
        const item = messages.get(p.messageId);
        if (item) item.state = p.state;
        break;
      }
      case 'assistant':
        items.push({ type: 'assistant', key: event.seq, at: event.at, text: p.text ?? '' });
        break;
      case 'tool_use': {
        if (p.name === 'AskUserQuestion') break; // 由问题卡片呈现
        const item = { type: 'tool', key: event.seq, at: event.at, name: p.name, input: p.input, result: null };
        tools.set(p.toolUseId, item);
        items.push(item);
        break;
      }
      case 'tool_result': {
        const item = tools.get(p.toolUseId);
        if (item) item.result = { isError: Boolean(p.isError), text: resultText(p.content) };
        break;
      }
      case 'attention': {
        const item = { type: 'attention', key: event.seq, at: event.at, attentionId: p.attentionId };
        attentions.set(p.attentionId, item);
        items.push(item);
        break;
      }
      case 'attention_resolved': {
        const item = attentions.get(p.attentionId);
        if (item) item.resolved = p;
        break;
      }
      case 'turn_result':
        items.push({ type: 'turn', key: event.seq, at: event.at, ...p });
        break;
      case 'status':
        items.push({ type: 'status', key: event.seq, at: event.at, ...p });
        break;
      case 'error':
        items.push({ type: 'error', key: event.seq, at: event.at, ...p });
        break;
      case 'session':
        items.push({ type: 'session', key: event.seq, at: event.at, ...p });
        break;
      default:
        break;
    }
  }
  return items;
}

export function ToolRow({ item }) {
  const [open, setOpen] = useState(false);
  const running = item.result === null;
  const failed = item.result?.isError;
  const summary = toolSummary(item.name, item.input);
  return (
    <div className={`tool-block ${open ? 'open' : ''}`}>
      <button className="tool-row" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="tool-icon">
          <Wrench size={13} />
        </span>
        <b>{item.name}</b>
        <code>{summary}</code>
        <span className={failed ? 'red' : running ? 'muted' : 'green'}>
          {running ? '运行中' : failed ? '出错' : '完成'}
        </span>
        {open ? <CaretDown size={11} /> : <CaretRight size={11} />}
      </button>
      {open && (
        <div className="tool-detail">
          <small>参数</small>
          <pre>{JSON.stringify(item.input ?? {}, null, 2)}</pre>
          <small>{running ? '结果（尚未返回）' : failed ? '错误' : '结果'}</small>
          {!running && <pre className={failed ? 'error' : ''}>{item.result.text || '（空）'}</pre>}
        </div>
      )}
    </div>
  );
}

function QuestionCard({ attention, notify }) {
  const questions = attention.body?.questions ?? [];
  // 不预选任何选项：业务口径必须是用户显式选择的。
  const [picked, setPicked] = useState({});
  const [others, setOthers] = useState({});
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const open = attention.status === 'open';

  const answerOf = (question) => {
    const other = (others[question.question] ?? '').trim();
    const chosen = picked[question.question];
    if (question.multiSelect) {
      const list = [...(chosen ?? [])];
      if (other) list.push(other);
      return list;
    }
    return chosen === '__other__' ? other : (chosen ?? '');
  };
  const complete = questions.every((question) => {
    const value = answerOf(question);
    return Array.isArray(value) ? value.length > 0 : Boolean(value);
  });

  async function submit() {
    if (!complete || busy) return;
    setBusy(true);
    setError(null);
    try {
      const answers = Object.fromEntries(questions.map((q) => [q.question, answerOf(q)]));
      const result = await request('attention.answer', {
        attentionId: attention.id,
        revision: attention.revision,
        answer: { answers, text: note.trim() || undefined },
      });
      if (!result.accepted) setError(result.message ?? '这个问题已不能回答');
      else notify('已记录回答，Work 将继续执行');
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  }

  if (!open) {
    const answers = attention.answer?.answers ?? {};
    return (
      <section className={`question-card settled ${attention.status}`}>
        <div className="question-head">
          <ChatCircleDots size={15} />
          <strong>{attention.status === 'answered' ? '已回答' : '问题已失效'}</strong>
        </div>
        {questions.map((question) => (
          <div className="question-answer" key={question.question}>
            <span>{question.question}</span>
            <b>{answers[question.question] ?? '—'}</b>
          </div>
        ))}
        {attention.status !== 'answered' && (
          <p className="muted">发起这个问题的执行轮次已结束，不能再回答。需要时请重试该 Work。</p>
        )}
      </section>
    );
  }

  return (
    <section className="question-card">
      <div className="question-head">
        <ChatCircleDots size={15} />
        <strong>需要你确认</strong>
        <span className="pill orange">业务口径</span>
      </div>
      {questions.map((question) => {
        const name = `${attention.id}-${question.question}`;
        const chosen = picked[question.question];
        return (
          <fieldset key={question.question}>
            <legend>
              {question.header && <span className="pill neutral">{question.header}</span>}
              {question.question}
            </legend>
            {(question.options ?? []).map((option) => {
              const selected = question.multiSelect
                ? (chosen ?? []).includes(option.label)
                : chosen === option.label;
              return (
                <label className={`choice ${selected ? 'selected' : ''}`} key={option.label}>
                  <input
                    type={question.multiSelect ? 'checkbox' : 'radio'}
                    name={name}
                    checked={selected}
                    onChange={() =>
                      setPicked((current) => {
                        if (!question.multiSelect) return { ...current, [question.question]: option.label };
                        const list = new Set(current[question.question] ?? []);
                        if (list.has(option.label)) list.delete(option.label);
                        else list.add(option.label);
                        return { ...current, [question.question]: [...list] };
                      })
                    }
                  />
                  <span>
                    <b>{option.label}</b>
                    {option.description && <small>{option.description}</small>}
                  </span>
                </label>
              );
            })}
            <label className={`choice other ${chosen === '__other__' ? 'selected' : ''}`}>
              {!question.multiSelect && (
                <input
                  type="radio"
                  name={name}
                  checked={chosen === '__other__'}
                  onChange={() => setPicked((current) => ({ ...current, [question.question]: '__other__' }))}
                />
              )}
              <input
                type="text"
                aria-label={`${question.question} 的其他答案`}
                placeholder="其他（自己填写）"
                value={others[question.question] ?? ''}
                onFocus={() =>
                  !question.multiSelect &&
                  setPicked((current) => ({ ...current, [question.question]: '__other__' }))
                }
                onChange={(event) =>
                  setOthers((current) => ({ ...current, [question.question]: event.target.value }))
                }
              />
            </label>
          </fieldset>
        );
      })}
      <textarea
        className="question-note"
        aria-label="补充说明"
        placeholder="补充说明（可选）"
        rows={2}
        value={note}
        onChange={(event) => setNote(event.target.value)}
      />
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      <div className="card-actions">
        <span>{complete ? 'Work 已暂停，等待你的回答' : '请为每个问题选择或填写答案'}</span>
        <button className="primary" disabled={!complete || busy} onClick={submit}>
          {busy ? '正在提交…' : '确认并继续'}
          <ArrowRight size={13} />
        </button>
      </div>
    </section>
  );
}

function PermissionCard({ attention, notify }) {
  const [busy, setBusy] = useState(false);
  const [reason, setReason] = useState('');
  const [error, setError] = useState(null);
  const [showInput, setShowInput] = useState(false);
  const input = attention.body?.input ?? {};
  const open = attention.status === 'open';
  const risk = attention.body?.risk ?? '';
  const risky = risk.includes('之外') || risk.includes('未覆盖');

  async function answer(behavior) {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const result = await request('attention.answer', {
        attentionId: attention.id,
        revision: attention.revision,
        answer: { behavior, message: behavior === 'deny' ? reason.trim() || undefined : undefined },
      });
      if (!result.accepted) setError(result.message ?? '这个请求已失效');
      else notify(behavior === 'allow' ? '已允许，仅对这一次请求生效' : '已拒绝');
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  }

  const preview = input.command ?? input.file_path ?? input.url ?? toolSummary(attention.toolName, input);
  return (
    <section className={`permission-card ${open ? '' : 'settled'}`}>
      <div className="question-head">
        <ShieldWarning size={15} />
        <strong>
          {open
            ? '请求使用工具'
            : attention.status === 'answered'
              ? attention.answer?.behavior === 'allow'
                ? '已允许'
                : '已拒绝'
              : '请求已失效'}
        </strong>
        <span className="pill neutral">{attention.toolName}</span>
        {risk && <span className={`pill ${risky ? 'red' : 'neutral'}`}>{risk}</span>}
      </div>
      {attention.body?.description && <p>{attention.body.description}</p>}
      {preview && <pre className="permission-preview">{String(preview)}</pre>}
      <button className="link-button" onClick={() => setShowInput(!showInput)}>
        {showInput ? '收起完整参数' : '查看完整参数'}
      </button>
      {showInput && <pre>{JSON.stringify(input, null, 2)}</pre>}
      {open && (
        <>
          <input
            type="text"
            className="permission-reason"
            aria-label="拒绝原因"
            placeholder="拒绝时可以说明原因（可选）"
            value={reason}
            onChange={(event) => setReason(event.target.value)}
          />
          {error && (
            <div className="pane-note error" role="alert">
              <Warning size={14} />
              {error}
            </div>
          )}
          <div className="card-actions">
            <span>只对这一次请求生效，不会沿用到之后的轮次</span>
            <div>
              <button disabled={busy} onClick={() => answer('deny')}>
                <ProhibitInset size={13} />
                拒绝
              </button>
              <button className="primary" disabled={busy} onClick={() => answer('allow')}>
                允许
              </button>
            </div>
          </div>
        </>
      )}
      {!open && attention.status !== 'answered' && (
        <p className="muted">发起这个请求的执行轮次已结束，批准不会沿用到新的轮次。</p>
      )}
    </section>
  );
}

function executorLabel(executor) {
  return { antigravity: 'Antigravity', codex: 'Codex' }[executor] ?? 'Claude Code';
}

function PromptCard({ item, executor }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="prompt-card">
      <button onClick={() => setOpen(!open)} aria-expanded={open}>
        <Briefcase size={13} />
        <span>已把工作目标与约定交给 {executorLabel(executor)}</span>
        <small>{formatTime(item.at)}</small>
        {open ? <CaretDown size={11} /> : <CaretRight size={11} />}
      </button>
      {open && <pre>{item.text}</pre>}
    </div>
  );
}

const MESSAGE_STATE = {
  accepted: '已接受，等待送达',
  delivered: '已送达',
  failed: '送达失败，未自动重发',
};

function StateCard({ work, capacity, onAction, onOpenReview, busy }) {
  const reason = work.statusReason;
  if (work.cancelling)
    return (
      <div className="work-state-card">
        <CircleNotch size={15} className="spin" />
        <p>正在停止执行，停下后标记为已取消…</p>
      </div>
    );
  switch (work.status) {
    case 'queued':
      return work.startRequested ? (
        <div className="work-state-card">
          <CircleNotch size={15} className="spin" />
          <p>
            已请求启动，等待执行槽（{capacity.running} / {capacity.slots} 在执行）。
          </p>
        </div>
      ) : (
        <div className="work-state-card">
          <Info size={15} />
          <p>Work 已创建，尚未启动。启动后会准备执行目录并交给 {executorLabel(work.executor)}。</p>
          <button className="primary" disabled={busy} onClick={() => onAction('start')}>
            <Play size={13} weight="fill" />
            启动 Work
          </button>
        </div>
      );
    case 'running':
      return (
        <div className="work-state-card running">
          <CircleNotch size={15} className="spin" />
          <p>{reason || '正在执行…'}</p>
        </div>
      );
    case 'waiting_user':
      return null;
    case 'waiting_review':
      return (
        <section className="review-card">
          <div>
            <CheckCircle size={16} />
            <strong>本轮已结束，等待你审阅</strong>
          </div>
          <p>查看相对基线的实际变更与验证记录，确认后 Work 才算完成。需要修改可以直接在下方继续说明。</p>
          <div className="card-actions">
            <span />
            <button className="primary" onClick={onOpenReview}>
              <GitDiff size={13} />
              审阅变更
              <ArrowRight size={13} />
            </button>
          </div>
        </section>
      );
    case 'failed':
    case 'interrupted':
      return (
        <div className={`work-state-card ${work.status === 'failed' ? 'failed' : 'warn'}`}>
          <WarningCircle size={15} />
          <p>{reason || (work.status === 'failed' ? '执行失败' : '执行已中断，结果未知')}</p>
          <button className="primary" disabled={busy} onClick={() => onAction('retry')}>
            重试
          </button>
        </div>
      );
    case 'completed':
      return (
        <div className="work-state-card done">
          <CheckCircle size={15} />
          <p>{reason || '结果已确认。'}这不代表业务验收、发布或上线。</p>
          <button onClick={onOpenReview}>
            <GitDiff size={13} />
            查看变更与交付
          </button>
        </div>
      );
    case 'cancelled':
      return (
        <div className="work-state-card">
          <ProhibitInset size={15} />
          <p>{reason || '已取消。'}</p>
        </div>
      );
    default:
      return null;
  }
}

export default function WorkChat({
  work,
  capacity,
  notify,
  focus,
  contextOpen,
  onToggleContext,
  onCollapse,
  onOpenReview,
  onOpenSource,
}) {
  const marker = `${work.revision}:${work.attentionId ?? ''}:${work.status}`;
  const { data, live, error } = useTranscript(work.id, marker);
  const [draft, setDraft, clearDraft] = useDraft('chat', work.id);
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState(null);
  const [acting, setActing] = useState(false);
  const [revertingId, setRevertingId] = useState(null);
  const [execMenuOpen, setExecMenuOpen] = useState(false);
  const pendingMessage = useRef(null);
  const scroller = useRef(null);
  const atBottom = useRef(true);
  const [unseen, setUnseen] = useState(false);

  const events = data?.events ?? [];
  const items = useMemo(() => buildItems(events), [events]);
  const attentions = useMemo(
    () => new Map((data?.attentions ?? []).map((item) => [item.id, item])),
    [data?.attentions],
  );

  // 查看即已读；不改变待回答 / 待审阅本身。
  useEffect(() => {
    if (work.unread) request('work.seen', { workId: work.id }).catch(() => {});
  }, [work.id, work.unread]);

  // 换了 Work：回到底部，未发送成功的消息身份不沿用到别的 Work。
  useEffect(() => {
    atBottom.current = true;
    setUnseen(false);
    setSendError(null);
    setExecMenuOpen(false);
    pendingMessage.current = null;
  }, [work.id]);

  // 在底部时跟随新内容；正在看历史时保持位置，只给出「新消息」入口。
  useLayoutEffect(() => {
    const node = scroller.current;
    if (!node) return;
    if (atBottom.current) node.scrollTop = node.scrollHeight;
    else if (items.length) setUnseen(true);
  }, [items.length, live, data?.attentions?.length, work.status]);

  function onScroll() {
    const node = scroller.current;
    if (!node) return;
    atBottom.current = node.scrollHeight - node.scrollTop - node.clientHeight < 48;
    if (atBottom.current) setUnseen(false);
  }

  function jumpToBottom() {
    const node = scroller.current;
    if (!node) return;
    node.scrollTop = node.scrollHeight;
    atBottom.current = true;
    setUnseen(false);
  }

  async function act(kind) {
    if (acting) return;
    setActing(true);
    try {
      const method = { start: 'work.start', retry: 'work.retry', interrupt: 'work.interrupt' }[kind];
      const result = await request(method, { workId: work.id, revision: work.revision, requestId: newId() });
      if (result?.accepted === false && result.message) notify(result.message, true);
    } catch (cause) {
      notify(errorText(cause), true);
    } finally {
      setActing(false);
    }
  }

  const ended = work.status === 'completed' || work.status === 'cancelled';
  const notStarted = work.status === 'queued' && !work.startRequested && !work.sessionId;
  const blockedReason = ended
    ? `${statusOf(work).label}的 Work 不再接收消息`
    : work.status === 'waiting_user'
      ? '请先回答上面的问题'
      : notStarted
        ? '启动后才能继续对话'
        : null;
  const canStop = work.status === 'running' || work.status === 'waiting_user';
  const currentExecutor = work.executor ?? 'claude';

  async function revertToCheckpoint(checkpointId, labelText = '本轮前') {
    if (!checkpointId || revertingId || canStop) return;
    const confirmed = await confirmAction({
      title: `回退代码到「${labelText}」？`,
      text: '会将工作目录还原到该轮开始前的代码快照（回退前会自动创建备份点以便撤销，下一轮也会通知智能体以磁盘最新代码为准）。',
      confirmLabel: '确认回退',
      cancelLabel: '取消',
    });
    if (!confirmed) return;
    setRevertingId(checkpointId);
    try {
      const result = await request(
        'checkpoint.revert',
        { workId: work.id, checkpointId, requestId: newId() },
        { timeoutMs: 120000 },
      );
      notify(
        result.affectedCount > 0
          ? `已回退代码（还原 ${result.affectedCount} 个文件）`
          : '当前代码已与该快照一致',
      );
    } catch (cause) {
      if (cause?.code === 'CONFLICT') {
        const forceOk = await confirmAction({
          title: '检测到外部未保存改动，仍要强制回退？',
          text: errorText(cause),
          confirmLabel: '强制覆盖并回退',
          cancelLabel: '保留当前代码',
          danger: true,
        });
        if (forceOk) {
          try {
            const forced = await request(
              'checkpoint.revert',
              { workId: work.id, checkpointId, force: true, requestId: newId() },
              { timeoutMs: 120000 },
            );
            notify(`已强制回退代码（还原 ${forced.affectedCount ?? 0} 个文件）`);
          } catch (inner) {
            notify(errorText(inner), true);
          }
        }
      } else {
        notify(errorText(cause), true);
      }
    } finally {
      setRevertingId(null);
    }
  }

  async function switchWorkExecutor(nextExecutor) {
    setExecMenuOpen(false);
    if (nextExecutor === currentExecutor || acting || canStop || ended) return;
    setActing(true);
    try {
      const res = await request('work.switchExecutor', {
        workId: work.id,
        executor: nextExecutor,
      });
      if (res?.changed) {
        notify(`已切换执行引擎至 ${executorLabel(nextExecutor)}，下一轮自动同步前情上下文`);
      }
    } catch (cause) {
      notify(errorText(cause), true);
    } finally {
      setActing(false);
    }
  }

  async function send() {
    const text = draft.trim();
    if (!text || sending || blockedReason) return;
    // 同一条内容重试时沿用同一个 messageId：超时后重发不会变成两条消息。
    if (!pendingMessage.current || pendingMessage.current.text !== text)
      pendingMessage.current = { id: newId(), text };
    setSending(true);
    setSendError(null);
    try {
      await request('work.send', { workId: work.id, messageId: pendingMessage.current.id, text });
      pendingMessage.current = null;
      clearDraft();
      atBottom.current = true;
    } catch (cause) {
      setSendError(errorText(cause)); // 输入保留，可以改完再发
    } finally {
      setSending(false);
    }
  }

  const tapd = work.tapdRefs?.[0];
  return (
    <div className={`work-chat ${focus ? 'focus' : ''}`}>
      <div className="chat-heading">
        <div>
          <div className="eyebrow">
            <Briefcase size={12} />
            {work.displayId}
            <span className="slash">/</span>
            <span>{executorLabel(currentExecutor)}</span>
            <span className="slash">/</span>
            <span>{sourceLabel(work)}</span>
            <span className="slash">/</span>
            <span>{work.project?.name ?? '项目不可用'}</span>
          </div>
          <h1 title={work.title}>{work.title}</h1>
        </div>
        <div className="heading-actions">
          <StatusPill work={work} />
          <IconButton icon={MinusSquare} label="收起对话 ⌘J" onClick={onCollapse} />
          <IconButton icon={SidebarSimple} label={contextOpen ? '关闭详情' : '展开详情'} onClick={onToggleContext} />
        </div>
      </div>

      <div className="conversation" ref={scroller} onScroll={onScroll}>
        <div className="conversation-inner">
          {(tapd || work.origin === 'wecom') && (
            <button className="source-chip" onClick={onOpenSource}>
              {tapd ? `TAPD ${tapd.entityType} #${tapd.entityId}` : '企业微信 · WorkBuddy 原始对话'}
              <span>{tapd ? tapd.title : '查看来源消息与回执'}</span>
              <ArrowRight size={12} />
            </button>
          )}
          {error && (
            <div className="pane-note error" role="alert">
              <Warning size={14} />
              读取会话记录失败：{error}
            </div>
          )}
          {!data && !error && <div className="pane-note">正在读取会话记录…</div>}
          {items.map((item) => {
            switch (item.type) {
              case 'user':
                if (item.origin === 'prompt') return <PromptCard item={item} executor={currentExecutor} key={item.key} />;
                return (
                  <div className={`user-message ${item.origin === 'system' ? 'system' : ''}`} key={item.key}>
                    <div className="message-meta">
                      {item.origin === 'system' ? '系统' : '你'}
                      <span>{formatTime(item.at)}</span>
                      {item.state && item.state !== 'delivered' && (
                        <em className={item.state === 'failed' ? 'red' : ''}>{MESSAGE_STATE[item.state]}</em>
                      )}
                    </div>
                    <p>{item.text}</p>
                  </div>
                );
              case 'assistant':
                return (
                  <div className="assistant-message" key={item.key}>
                    <Suspense fallback={<p>{item.text}</p>}>
                      <div className="markdown-preview">
                        <MarkdownRenderer content={item.text} />
                      </div>
                    </Suspense>
                  </div>
                );
              case 'tool':
                return <ToolRow item={item} key={item.key} />;
              case 'attention': {
                const attention = attentions.get(item.attentionId);
                if (!attention) return null;
                return attention.kind === 'question' ? (
                  <QuestionCard attention={attention} notify={notify} key={item.key} />
                ) : (
                  <PermissionCard attention={attention} notify={notify} key={item.key} />
                );
              }
              case 'turn':
                return (
                  <div className="turn-divider" key={item.key}>
                    <span>
                      {item.isError
                        ? String(item.terminalReason ?? '').startsWith('aborted')
                          ? '本轮已停止'
                          : '本轮出错'
                        : '本轮结束'}
                      {item.durationMs ? ` · ${(item.durationMs / 1000).toFixed(0)} 秒` : ''} · {formatTime(item.at)}
                    </span>
                    {item.preCheckpointId && !canStop && (
                      <button
                        type="button"
                        className="turn-revert-btn"
                        disabled={Boolean(revertingId)}
                        title="把工作目录代码还原到这一轮开始前的状态"
                        onClick={() => revertToCheckpoint(item.preCheckpointId, formatTime(item.at) + ' 轮次开始前')}
                      >
                        <ArrowCounterClockwise size={11} />
                        {revertingId === item.preCheckpointId ? '正在回退…' : '回退到此轮前'}
                      </button>
                    )}
                  </div>
                );
              case 'status':
                if (!item.executorSwitch && !item.checkpointReverted) return null;
                return (
                  <div className="session-note" key={item.key}>
                    {item.reason} · {formatTime(item.at)}
                  </div>
                );
              case 'error':
                return (
                  <div className="pane-note error chat-error" role="alert" key={item.key}>
                    <WarningCircle size={14} />
                    <div>
                      <b>{item.message}</b>
                      {item.detail && <pre>{item.detail}</pre>}
                    </div>
                  </div>
                );
              case 'session':
                return (
                  <div className="session-note" key={item.key}>
                    {executorLabel(item.executor ?? currentExecutor)} {item.cliVersion ?? ''} · {item.model ?? '默认模型'} · 权限模式{' '}
                    {item.permissionMode ?? '—'}
                  </div>
                );
              default:
                return null;
            }
          })}
          {live && (
            <div className="assistant-message streaming">
              <p>{live}</p>
            </div>
          )}
          {data && (
            <StateCard
              work={work}
              capacity={capacity}
              busy={acting}
              onAction={act}
              onOpenReview={onOpenReview}
            />
          )}
        </div>
        {unseen && (
          <button className="new-messages" onClick={jumpToBottom}>
            <ArrowDown size={12} />
            新消息
          </button>
        )}
      </div>

      <div className="composer-wrap">
        <form
          className="composer"
          onSubmit={(event) => {
            event.preventDefault();
            send();
          }}
        >
          <textarea
            aria-label={`发送给 ${executorLabel(currentExecutor)} 的消息`}
            rows={2}
            value={draft}
            disabled={Boolean(blockedReason)}
            placeholder={
              blockedReason ??
              (work.status === 'waiting_review' ? '需要修改就继续说明，会开启新的一轮…' : '继续描述需求或补充说明…')
            }
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => {
              // 输入法组词期间的回车交给输入法，不发送半成品。
              if (event.key !== 'Enter' || event.shiftKey || event.nativeEvent.isComposing) return;
              if (event.keyCode === 229) return;
              event.preventDefault();
              send();
            }}
          />
          <div className="composer-tools">
            <div>
              <div className="executor-chip-wrap">
                <button
                  type="button"
                  className="composer-chip interactive"
                  disabled={canStop || ended || acting}
                  aria-expanded={execMenuOpen}
                  title={
                    canStop
                      ? '本轮执行结束后可切换执行引擎'
                      : '在非运行态可无缝切换执行引擎（下一轮自动同步前情上下文）'
                  }
                  onClick={() => setExecMenuOpen((v) => !v)}
                >
                  <EngineIcon id={currentExecutor} />
                  引擎：{executorLabel(currentExecutor)}
                  <CaretDown size={10} />
                </button>
                {execMenuOpen && (
                  <div className="executor-chip-menu" role="menu" aria-label="切换 Work 执行引擎">
                    {[
                      ['claude', 'Claude Code'],
                      ['antigravity', 'Antigravity (ACP)'],
                      ['codex', 'Codex (App Server)'],
                    ].map(([id, label]) => (
                      <button
                        type="button"
                        role="menuitemradio"
                        key={id}
                        aria-checked={currentExecutor === id}
                        onClick={() => switchWorkExecutor(id)}
                      >
                        <span>{label}</span>
                        {currentExecutor === id && <Check size={12} />}
                      </button>
                    ))}
                  </div>
                )}
              </div>
              <span className="composer-chip" title="创建 Work 时确定；运行中的 Work 暂不支持切换">
                权限模式：{work.permissionMode ?? '跟随 CLI 设置'}
              </span>
              <span className="composer-chip" title="创建 Work 时确定；运行中的 Work 暂不支持切换">
                模型：{work.model ?? '跟随 CLI 设置'}
              </span>
            </div>
            <div>
              {canStop && (
                <button
                  type="button"
                  className="send stop"
                  aria-label="停止生成"
                  title="停止当前轮次（Work 保留，可继续或重试）"
                  disabled={acting}
                  onClick={() => act('interrupt')}
                >
                  <Stop size={14} weight="fill" />
                </button>
              )}
              <button
                className="send"
                aria-label="发送消息"
                disabled={!draft.trim() || sending || Boolean(blockedReason)}
              >
                {sending ? <CircleNotch size={15} className="spin" /> : <ArrowUp size={16} />}
              </button>
            </div>
          </div>
        </form>
        {sendError && (
          <div className="pane-note error" role="alert">
            <Warning size={14} />
            发送失败：{sendError}（内容已保留，可以再次发送）
          </div>
        )}
        <div className="composer-foot">
          <span title={work.workspacePath ?? ''}>
            <GitBranch size={11} />
            {work.workspacePath
              ? work.isolation === 'worktree'
                ? `独立工作树 · ${work.branch ?? '—'}`
                : '项目目录（未隔离）'
              : '执行目录在启动时准备'}
          </span>
          <span>Enter 发送 · Shift+Enter 换行</span>
        </div>
      </div>
    </div>
  );
}
