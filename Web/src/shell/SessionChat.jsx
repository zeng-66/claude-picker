// 会话级结构化聊天：第二栏里渲染 CLI 结构化协议的事件流（消息、工具记录、审批、中断）。
// 数据全部来自原生 SessionChatHub；界面只做展示和转发，不猜测 CLI 输出。
import React, { Suspense, lazy, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { ArrowDown, ArrowUp, CaretDown, Check, CircleNotch, Lightning, ProhibitInset, ShieldWarning, Stop, Warning, WarningCircle } from '@phosphor-icons/react';
import { errorText, on, request } from './bridge.js';
import { ToolRow, toolSummary } from './work/WorkChat.jsx';
import { confirmAction } from './work/confirm.jsx';
import EngineIcon from './EngineIcon.jsx';
import { ContextMeter } from './Composer.jsx';

const MarkdownRenderer = lazy(() => import('../MarkdownRenderer.jsx'));

const PROVIDER_LABEL = { claude: 'Claude Code', antigravity: 'Antigravity', codex: 'Codex', dsh: 'DeepSeek' };
const PHASE_LABEL = {
  starting: '正在连接',
  ready: '就绪',
  running: '正在回复',
  awaiting: '等待审批',
  stopping: '正在中断',
  exited: '执行器已关闭',
  failed: '连接失败',
  closed: '未连接',
};

function resultText(content) {
  if (content == null) return '';
  if (typeof content === 'string') return content;
  if (Array.isArray(content))
    return content.map((part) => (typeof part === 'string' ? part : (part?.text ?? part?.content?.text ?? ''))).join('\n');
  return JSON.stringify(content, null, 2);
}

function formatClock(seconds) {
  if (!seconds) return '';
  const date = new Date(seconds * 1000);
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
}

/// 事件 → 条目：工具调用与结果按 toolUseId 配对，审批与其结果按 requestId 配对。
export function buildSessionItems(events) {
  const items = [];
  const tools = new Map();
  const approvals = new Map();
  for (const event of events) {
    const p = event.payload ?? {};
    const key = event.seq;
    switch (event.kind) {
      case 'user':
        items.push({ type: 'user', key, at: event.at, text: p.text ?? '' });
        break;
      case 'assistant':
        if (p.text) items.push({ type: 'assistant', key, at: event.at, text: p.text });
        break;
      case 'tool_use': {
        const item = { type: 'tool', key, at: event.at, name: p.name ?? 'tool', input: p.input, result: p.history ? { isError: false, text: '（历史记录）' } : null };
        if (p.toolUseId) tools.set(p.toolUseId, item);
        items.push(item);
        break;
      }
      case 'tool_result': {
        const item = tools.get(p.toolUseId);
        if (item) item.result = { isError: Boolean(p.isError), text: resultText(p.content) };
        break;
      }
      case 'permission': {
        const item = { type: 'permission', key, at: event.at, ...p, resolved: null };
        approvals.set(p.requestId, item);
        items.push(item);
        break;
      }
      case 'permission_resolved': {
        const item = approvals.get(p.requestId);
        if (item) item.resolved = p;
        break;
      }
      case 'turn_result':
        items.push({ type: 'turn', key, at: event.at, ...p });
        break;
      case 'status':
        items.push({ type: 'status', key, at: event.at, text: p.text });
        break;
      case 'error':
        items.push({ type: 'error', key, at: event.at, message: p.message });
        break;
      default:
        break;
    }
  }
  // 回合结束后仍未答复的审批视为失效。
  let settled = false;
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const item = items[index];
    if (item.type === 'turn') settled = true;
    if (item.type === 'permission' && !item.resolved && settled) item.expired = true;
  }
  return items;
}

const OPEN_MODES = [
  ['terminal', '改用终端打开'],
  ['chat', '改用 Swttch 图形聊天'],
];

/// 输入框下方的快捷切换，参照 Claude Code / Codex 桌面端：按钮只显示当前值，菜单向上弹出，可分组。
function ChipMenu({ label, display, icon, sections, open, onToggle, onPick, disabled, title, shortcut }) {
  return (
    <div className="runtime-setting">
      <button
        type="button"
        className="composer-chip interactive"
        aria-label={`${label}：${display}`}
        aria-expanded={open}
        disabled={disabled}
        title={[title, shortcut].filter(Boolean).join(' · ')}
        onClick={onToggle}
      >
        {icon}
        {display}
        <CaretDown size={10} />
      </button>
      {open && (
        <div className="runtime-popover session-chat-menu" role="menu" aria-label={`选择${label}`}>
          {sections.map((section) => (
            <div key={section.key} role="group" aria-label={section.title}>
              {sections.length > 1 && <div className="menu-heading">{section.title}</div>}
              {section.items.map((item) => (
                <button type="button" role="menuitemradio" aria-checked={item.id === section.value} key={item.id}
                  disabled={Boolean(item.disabled)}
                  onClick={() => onPick(section.key, item.id)}>
                  {item.icon}
                  {item.label}
                  {item.id === section.value && <Check size={12} />}
                </button>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

const labelOf = (items, value) => (items ?? []).find((item) => item.id === value)?.label ?? value;

function ApprovalCard({ item, sessionId, onError }) {
  const [busy, setBusy] = useState(false);
  const open = !item.resolved && !item.expired;
  const input = item.input ?? {};
  const preview = input.command ?? input.file_path ?? input.url ?? toolSummary(item.toolName, input);
  const [showInput, setShowInput] = useState(false);

  async function answer(allow) {
    if (busy) return;
    setBusy(true);
    try {
      await request('sessionChat.respond', { sessionId, requestId: item.requestId, allow });
    } catch (cause) {
      onError(errorText(cause));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className={`permission-card ${open ? '' : 'settled'}`}>
      <div className="question-head">
        <ShieldWarning size={15} />
        <strong>
          {open ? '请求使用工具' : item.resolved ? (item.resolved.allow ? '已允许' : '已拒绝') : '请求已失效'}
        </strong>
        <span className="pill neutral">{item.toolName}</span>
      </div>
      {item.description && <p>{String(item.description)}</p>}
      {preview && <pre className="permission-preview">{String(preview)}</pre>}
      <button className="link-button" onClick={() => setShowInput(!showInput)}>
        {showInput ? '收起完整参数' : '查看完整参数'}
      </button>
      {showInput && <pre>{JSON.stringify(input, null, 2)}</pre>}
      {open && (
        <div className="card-actions">
          <span>只对这一次请求生效</span>
          <div>
            <button disabled={busy} onClick={() => answer(false)}>
              <ProhibitInset size={13} />
              拒绝
            </button>
            <button className="primary" disabled={busy} onClick={() => answer(true)}>
              允许
            </button>
          </div>
        </div>
      )}
    </section>
  );
}

export default function SessionChat({
  sessionId,
  provider,
  label,
  supportedModes = ['terminal'],
  providers = [],
  cliPreferences = {},
  onHandoff,
  notify,
}) {
  const [events, setEvents] = useState([]);
  const [phase, setPhase] = useState('starting');
  const [info, setInfo] = useState({});
  const [live, setLive] = useState('');
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  const [notice, setNotice] = useState(null);
  const [unseen, setUnseen] = useState(false);
  const [runtime, setRuntime] = useState({ modes: [], models: [], efforts: [] });
  const [menu, setMenu] = useState(null);
  const [context, setContext] = useState(null);
  const scroller = useRef(null);
  const atBottom = useRef(true);
  const currentId = useRef(sessionId);
  currentId.current = sessionId;

  useEffect(() => {
    let alive = true;
    setEvents([]);
    setLive('');
    setNotice(null);
    atBottom.current = true;
    request('sessionChat.snapshot', { sessionId })
      .then((snapshot) => {
        if (!alive) return;
        setEvents(snapshot.events ?? []);
        setPhase(snapshot.phase ?? 'closed');
        setInfo(snapshot.info ?? {});
        setLive(snapshot.streaming ?? '');
        if (snapshot.runtime) setRuntime(snapshot.runtime);
        setContext(snapshot.context ?? null);
      })
      .catch((cause) => alive && setNotice(errorText(cause)));
    const off = on('session-chat', (detail) => {
      if (detail.sessionId !== currentId.current) return;
      if (detail.event) {
        setEvents((list) => (list.some((item) => item.seq === detail.event.seq) ? list : [...list, detail.event]));
        if (detail.event.kind === 'assistant' || detail.event.kind === 'turn_result') setLive('');
      }
      if (typeof detail.delta === 'string') setLive((text) => text + detail.delta);
      if (detail.state) {
        setPhase(detail.state.phase);
        if (detail.state.info) setInfo(detail.state.info);
        if (detail.state.runtime) setRuntime(detail.state.runtime);
        if (detail.state.context) setContext(detail.state.context);
      }
    });
    return () => {
      alive = false;
      off();
    };
  }, [sessionId]);

  const items = useMemo(() => buildSessionItems(events), [events]);
  const busy = phase === 'running' || phase === 'awaiting' || phase === 'stopping';

  useLayoutEffect(() => {
    const node = scroller.current;
    if (!node) return;
    if (atBottom.current) node.scrollTop = node.scrollHeight;
    else if (items.length) setUnseen(true);
  }, [items.length, live]);

  // Markdown 延迟渲染会撑高内容：停在底部时随内容高度变化继续贴底。
  useEffect(() => {
    const node = scroller.current;
    const inner = node?.firstElementChild;
    if (!node || !inner || typeof ResizeObserver === 'undefined') return undefined;
    const observer = new ResizeObserver(() => {
      if (atBottom.current) {
        node.scrollTop = node.scrollHeight;
        setUnseen(false);
      }
    });
    observer.observe(inner);
    return () => observer.disconnect();
  }, [sessionId]);

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

  async function send() {
    const text = draft.trim();
    if (!text || sending || busy) return;
    setSending(true);
    setNotice(null);
    try {
      await request('sessionChat.send', { sessionId, text }, { timeoutMs: 60000 });
      setDraft('');
      atBottom.current = true;
    } catch (cause) {
      setNotice(errorText(cause)); // 输入保留
    } finally {
      setSending(false);
    }
  }

  async function pickRuntime(key, value) {
    setMenu(null);
    try {
      await request('sessionChat.runtime', { sessionId, key, value }, { timeoutMs: 30000 });
    } catch (cause) {
      setNotice(errorText(cause));
    }
  }

  async function switchSurface(mode) {
    setMenu(null);
    if (busy) {
      const ok = await confirmAction({
        title: '切换打开方式',
        text: '当前回合还在进行。切换前会先中断这一轮并等待执行器释放会话。',
        confirmLabel: '中断并切换',
        cancelLabel: '取消',
      });
      if (!ok) return;
    }
    try {
      await request('session.setOpenMode', { sessionId, mode }, { timeoutMs: 45000 });
    } catch (cause) {
      setNotice(`切换失败，已保留当前界面：${errorText(cause)}`);
    }
  }

  async function interrupt() {
    try {
      await request('sessionChat.interrupt', { sessionId });
    } catch (cause) {
      setNotice(errorText(cause));
    }
  }

  const engine = PROVIDER_LABEL[provider] ?? provider;
  const handoffItems = ['claude', 'antigravity', 'codex', 'dsh']
    .filter((id) => id !== provider)
    .map((id) => {
      const enabled = cliPreferences?.[id]?.enabled !== false;
      const available = providers.length === 0 || providers.some((p) => p.id === id && p.available);
      const ok = enabled && available;
      return {
        id: `handoff:${id}`,
        label: `转到 ${PROVIDER_LABEL[id] ?? id} 接力继续${!available ? '（未安装）' : !enabled ? '（已停用）' : ''}`,
        icon: <EngineIcon id={id} />,
        disabled: !ok,
      };
    });
  // 与 Claude Code 桌面端一致：⌘⇧M 权限模式、⌘⇧I 模型、⌘⇧E 推理强度（同一个模型菜单里的分组）；Esc 关闭菜单。
  function onKeyDown(event) {
    if (event.key === 'Escape' && menu) {
      setMenu(null);
      return;
    }
    if (!(event.metaKey || event.ctrlKey) || !event.shiftKey) return;
    const key = event.key.toLowerCase();
    const target = key === 'm' ? 'mode' : key === 'i' || key === 'e' ? 'model' : null;
    if (!target) return;
    event.preventDefault();
    setMenu(menu === target ? null : target);
  }
  return (
    <div className="work-chat session-chat" onKeyDown={onKeyDown}>
      <div className="session-chat-head">
        <EngineIcon id={provider} />
        <strong title={label}>{label}</strong>
        <span className={`pill ${phase === 'failed' ? 'red' : busy ? 'blue' : 'neutral'}`}>
          <i className={`dot ${busy ? 'pulse' : ''}`} />
          {PHASE_LABEL[phase] ?? phase}
        </span>
        <span className="session-chat-meta">
          {engine}
          {info.model ? ` · ${info.model}` : ''}
          {info.cliVersion ? ` · ${String(info.cliVersion).slice(0, 40)}` : ''}
        </span>
      </div>
      <div className="conversation" ref={scroller} onScroll={onScroll}>
        <div className="conversation-inner">
          {items.length === 0 && <div className="pane-note">还没有消息。输入后按 Enter 发送。</div>}
          {items.map((item) => {
            switch (item.type) {
              case 'user':
                return (
                  <div className="user-message" key={item.key}>
                    <div className="message-meta">
                      你<span>{formatClock(item.at)}</span>
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
              case 'permission':
                return <ApprovalCard item={item} sessionId={sessionId} onError={setNotice} key={item.key} />;
              case 'turn': {
                const aborted = String(item.terminalReason ?? item.subtype ?? '').startsWith('aborted');
                return (
                  <div className="turn-divider" key={item.key}>
                    <span>
                      {aborted ? '本轮已中断' : item.isError ? '本轮出错' : '本轮结束'}
                      {item.durationMs ? ` · ${(item.durationMs / 1000).toFixed(0)} 秒` : ''} · {formatClock(item.at)}
                    </span>
                  </div>
                );
              }
              case 'status':
                return (
                  <div className="session-note" key={item.key}>
                    {item.text}
                  </div>
                );
              case 'error':
                return (
                  <div className="pane-note error chat-error" role="alert" key={item.key}>
                    <WarningCircle size={14} />
                    <div>
                      <b>{item.message}</b>
                    </div>
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
        </div>
        {unseen && (
          <button className="new-messages" onClick={jumpToBottom}>
            <ArrowDown size={12} />
            跳到最新
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
            aria-label={`发送给 ${engine} 的消息`}
            rows={2}
            value={draft}
            placeholder={busy ? '当前回合进行中，可先中断…' : `给 ${engine} 发消息…`}
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key !== 'Enter' || event.shiftKey || event.nativeEvent.isComposing) return;
              if (event.keyCode === 229) return;
              event.preventDefault();
              send();
            }}
          />
          <div className="composer-tools">
            <div className="session-chat-switches">
              <ChipMenu
                label="打开方式"
                display="结构化聊天"
                icon={<EngineIcon id={provider} />}
                sections={[
                  { key: 'surface', title: '打开方式', value: 'structured',
                    items: [{ id: 'structured', label: `${engine} · 结构化聊天`, icon: <EngineIcon id={provider} /> },
                      ...OPEN_MODES.filter(([id]) => supportedModes.includes(id)).map(([id, text]) => ({ id, label: text }))] },
                  { key: 'handoff', title: '跨引擎接力', value: '', items: handoffItems },
                ]}
                open={menu === 'surface'}
                disabled={sessionId.startsWith('pending-')}
                title={sessionId.startsWith('pending-') ? '取得原始会话 ID 后可以切换' : '与终端共用同一个原始会话 ID，或接力到其他 CLI'}
                onToggle={() => setMenu(menu === 'surface' ? null : 'surface')}
                onPick={(sectionKey, id) => {
                  if (sectionKey === 'handoff') {
                    setMenu(null);
                    onHandoff?.(id.replace(/^handoff:/, ''));
                  } else if (id === 'structured') {
                    setMenu(null);
                  } else {
                    switchSurface(id);
                  }
                }}
              />
              {(runtime.modes ?? []).length > 0 && (
                <ChipMenu
                  label={provider === 'codex' ? '权限' : '权限模式'}
                  display={labelOf(runtime.modes, runtime.mode) ?? '默认'}
                  sections={[{ key: 'mode', title: '权限模式', value: runtime.mode, items: runtime.modes }]}
                  open={menu === 'mode'}
                  shortcut="⌘⇧M"
                  title={provider === 'codex' ? '从下一回合起生效' : '运行中即时切换'}
                  onToggle={() => setMenu(menu === 'mode' ? null : 'mode')}
                  onPick={pickRuntime}
                />
              )}
              {((runtime.models ?? []).length > 0 || (runtime.efforts ?? []).length > 0) && (
                <ChipMenu
                  label="模型"
                  display={[labelOf(runtime.models, runtime.model) ?? '默认模型',
                    (runtime.efforts ?? []).length > 0 ? labelOf(runtime.efforts, runtime.effort) : null].filter(Boolean).join(' · ')}
                  sections={[
                    { key: 'model', title: '模型', value: runtime.model, items: runtime.models ?? [] },
                    { key: 'effort', title: '推理强度', value: runtime.effort, items: runtime.efforts ?? [] },
                  ].filter((section) => section.items.length > 0)}
                  open={menu === 'model'}
                  shortcut="⌘⇧I 模型 · ⌘⇧E 推理强度"
                  title={provider === 'claude' ? '推理强度在空闲时按原会话重新接续后生效' : provider === 'codex' ? '从下一回合起生效' : '运行中即时切换'}
                  onToggle={() => setMenu(menu === 'model' ? null : 'model')}
                  onPick={pickRuntime}
                />
              )}
              {(provider === 'codex' || runtime.supportsFast) && (
                <button
                  type="button"
                  className={`composer-chip interactive ${runtime.fast ? 'fast-on' : ''}`}
                  aria-label={`快速模式${runtime.fast ? '开启' : '关闭'}`}
                  aria-pressed={Boolean(runtime.fast)}
                  title="快速模式（service_tier=fast，下一回合起生效）"
                  onClick={() => pickRuntime('fast', runtime.fast ? 'false' : 'true')}
                >
                  <Lightning size={12} weight={runtime.fast ? 'fill' : 'regular'} />
                  快速
                </button>
              )}
            </div>
            <div>
              {context?.used != null && (
                <ContextMeter context={{ used: context.used, total: context.total || 200000, sessionId }} onOpen={() => {}} />
              )}
              {busy && (
                <button type="button" className="send stop" aria-label="中断当前回合" title="中断当前回合" onClick={interrupt}>
                  <Stop size={14} weight="fill" />
                </button>
              )}
              <button className="send" aria-label="发送消息" disabled={!draft.trim() || sending || busy}>
                {sending ? <CircleNotch size={15} className="spin" /> : <ArrowUp size={16} />}
              </button>
            </div>
          </div>
        </form>
        {notice && (
          <div className="pane-note error" role="alert">
            <Warning size={14} />
            {notice}
          </div>
        )}
        <div className="composer-foot">
          <span>⌘⇧M 权限模式 · ⌘⇧I 模型 · ⌘⇧E 推理强度</span>
          <span>Enter 发送 · Shift+Enter 换行</span>
        </div>
      </div>
    </div>
  );
}
