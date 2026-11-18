// Work 相关弹窗：新建 Work、交付预览、来源对话、全局搜索、导出。
import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowSquareOut,
  Briefcase,
  ChatsCircle,
  Folder,
  Info,
  MagnifyingGlass,
  Plus,
  Terminal,
  Warning,
  X,
} from '@phosphor-icons/react';
import { errorText, request } from '../bridge.js';
import { IconButton, tildePath } from '../ui.jsx';
import { confirmAction } from './confirm.jsx';
import { formatTime, newId, sourceLabel, statusOf } from './useWorks.js';

/// 弹窗外框：焦点进入弹窗并被约束在里面，Escape / 关闭按钮关闭，关闭后焦点回到触发入口。
/// `guard` 返回 false 时不关闭（有未保存修改时由调用方先确认）。
export function ModalFrame({ title, eyebrow = 'CLAUDE PICKER', wide = false, onClose, guard, children }) {
  const node = useRef(null);
  const opener = useRef(document.activeElement);

  useEffect(() => {
    const focusable = node.current?.querySelector(
      'input:not([type=checkbox]):not([type=radio]):not([disabled]), textarea:not([disabled]), select:not([disabled])',
    );
    (focusable ?? node.current)?.focus();
    const previous = opener.current;
    return () => previous?.focus?.();
  }, []);

  async function close() {
    if (guard && !(await guard())) return;
    onClose();
  }

  function onKeyDown(event) {
    if (event.key === 'Escape') {
      event.stopPropagation();
      close();
      return;
    }
    if (event.key !== 'Tab') return;
    const items = [
      ...node.current.querySelectorAll('button, input, textarea, select, a[href], [tabindex]:not([tabindex="-1"])'),
    ].filter((item) => !item.disabled && item.offsetParent !== null);
    if (!items.length) return;
    const first = items[0];
    const last = items[items.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  return (
    <div className="modal-backdrop" data-blocking onClick={close}>
      <section
        ref={node}
        tabIndex={-1}
        className={`modal work-modal ${wide ? 'wide' : ''}`}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onClick={(event) => event.stopPropagation()}
        onKeyDown={onKeyDown}
      >
        <div className="modal-header">
          <div>
            <div className="eyebrow">{eyebrow}</div>
            <h2>{title}</h2>
          </div>
          <IconButton icon={X} label="关闭弹窗" onClick={close} />
        </div>
        <div className="modal-body">{children}</div>
      </section>
    </div>
  );
}

/// 执行方式：引擎、隔离、权限模式、模型。取值都来自当前 CLI 配置里实际存在的选项。
export function RunOptions({ runtime, value, onChange, allowProject = true, lockExecutor = false }) {
  const executor = value.executor ?? 'claude';
  const catalog = runtime.catalogs?.[executor];
  const modes = catalog?.modes ?? runtime.modes ?? [];
  const models = catalog?.models ?? runtime.models ?? [];

  return (
    <div className="form-grid">
      <label className="field">
        执行引擎
        <select
          value={executor}
          disabled={lockExecutor}
          onChange={(event) => {
            const nextExec = event.target.value;
            const nextCat = runtime.catalogs?.[nextExec];
            onChange({
              ...value,
              executor: nextExec,
              permissionMode: nextCat?.defaultMode ?? nextCat?.modes?.[0]?.id ?? 'auto',
              model: '',
            });
          }}
        >
          <option value="claude">Claude Code</option>
          <option value="antigravity">Antigravity (ACP)</option>
        </select>
      </label>
      <label className="field">
        执行目录
        <select value={value.isolation} onChange={(event) => onChange({ ...value, isolation: event.target.value })}>
          <option value="worktree">独立 Git worktree（推荐）</option>
          {allowProject && <option value="project">直接在项目目录（不隔离）</option>}
        </select>
      </label>
      <label className="field">
        权限模式
        <select
          value={value.permissionMode}
          onChange={(event) => onChange({ ...value, permissionMode: event.target.value })}
        >
          {modes.map((mode) => (
            <option key={mode.id} value={mode.id}>
              {mode.label}
            </option>
          ))}
        </select>
      </label>
      <label className="field">
        模型
        <select value={value.model} onChange={(event) => onChange({ ...value, model: event.target.value })}>
          <option value="">跟随 CLI 设置</option>
          {models.map((model) => (
            <option key={model.id} value={model.id}>
              {model.label}
            </option>
          ))}
        </select>
      </label>
    </div>
  );
}

export function NewWorkModal({
  projects,
  defaultProject,
  defaultProvider = 'claude',
  adopt,
  runtime,
  home,
  notify,
  onClose,
  onCreated,
}) {
  const initialExecutor = adopt?.provider ?? defaultProvider ?? 'claude';
  const initialCatalog = runtime.catalogs?.[initialExecutor];
  const [title, setTitle] = useState('');
  const [objective, setObjective] = useState('');
  const [scope, setScope] = useState('');
  const [projectPath, setProjectPath] = useState(adopt?.projectPath ?? defaultProject ?? '');
  const [start, setStart] = useState(true);
  const [options, setOptions] = useState({
    executor: initialExecutor,
    isolation: 'worktree',
    permissionMode: initialCatalog?.defaultMode ?? runtime.mode,
    model: '',
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [touched, setTouched] = useState(false);
  const requestId = useRef(newId());
  const titleError = touched && !title.trim() ? '请填写 Work 名称' : null;
  const objectiveError = touched && !objective.trim() ? '请填写工作目标' : null;
  const projectError = touched && !projectPath ? '请选择项目' : null;
  const dirty = Boolean(title || objective || scope);

  async function create() {
    setTouched(true);
    if (!title.trim() || !objective.trim() || !projectPath || busy) return;
    setBusy(true);
    setError(null);
    try {
      const result = await request(
        'work.create',
        {
          projectPath,
          title: title.trim(),
          objective: objective.trim(),
          scope: scope.trim(),
          start,
          requestId: requestId.current, // 连点或超时重试都落到同一个 Work
          ...options,
          ...(adopt
            ? {
                adoptSessionId: adopt.sessionId,
                adoptCwd: adopt.cwd,
                adoptProvider: adopt.provider ?? initialExecutor,
                isolation: 'project',
              }
            : {}),
        },
        { timeoutMs: 60000 },
      );
      notify(`已创建 ${result.work.displayId}${start ? '，已请求启动' : '，等待启动'}`);
      onCreated(result.work);
      onClose();
    } catch (cause) {
      setError(errorText(cause)); // 失败时保留输入
      setBusy(false);
    }
  }

  return (
    <ModalFrame
      title={adopt ? '作为 Work 继续' : '新建 Work'}
      onClose={onClose}
      guard={() =>
        !dirty ||
        confirmAction({ title: '放弃还没创建的 Work？', text: '已填写的内容不会保存。', confirmLabel: '放弃', cancelLabel: '继续编辑' })
      }
    >
      {adopt && (
        <div className="source-note">
          <Terminal size={13} />
          将接管会话「{adopt.label}」，在它原来的目录里继续（{tildePath(adopt.cwd, home)}，不新建工作树）。接管前需要先关闭终端里的这个会话。
        </div>
      )}
      <label className="field">
        名称
        <input
          value={title}
          aria-invalid={Boolean(titleError)}
          placeholder="例如：检查订单同步失败原因"
          onChange={(event) => setTitle(event.target.value)}
        />
        {titleError && <small className="field-error">{titleError}</small>}
      </label>
      <label className="field">
        工作目标
        <textarea
          rows={4}
          value={objective}
          aria-invalid={Boolean(objectiveError)}
          placeholder="要达成什么结果、怎样算完成"
          onChange={(event) => setObjective(event.target.value)}
        />
        {objectiveError && <small className="field-error">{objectiveError}</small>}
      </label>
      <label className="field">
        执行范围（可选）
        <textarea
          rows={2}
          value={scope}
          placeholder="例如：只改 order 模块；不动数据库结构"
          onChange={(event) => setScope(event.target.value)}
        />
      </label>
      <label className="field">
        项目
        <select
          value={projectPath}
          disabled={Boolean(adopt)}
          aria-invalid={Boolean(projectError)}
          onChange={(event) => setProjectPath(event.target.value)}
        >
          <option value="">请选择项目…</option>
          {projects.map((project) => (
            <option key={project.path} value={project.path}>
              {project.title} — {tildePath(project.path, home)}
            </option>
          ))}
        </select>
        {projectError && <small className="field-error">{projectError}</small>}
      </label>
      <RunOptions
        runtime={runtime}
        value={adopt ? { ...options, isolation: 'project' } : options}
        onChange={setOptions}
        allowProject
        lockExecutor={Boolean(adopt)}
      />
      <label className="check-option">
        <input type="checkbox" checked={start} onChange={(event) => setStart(event.target.checked)} />
        创建后启动（执行槽已满时排队；不勾选则保留为待启动）
      </label>
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      <div className="modal-footer">
        <button onClick={onClose}>取消</button>
        <button className="primary" disabled={busy} onClick={create}>
          <Plus size={14} />
          {busy ? '正在创建…' : '创建 Work'}
        </button>
      </div>
    </ModalFrame>
  );
}

const DELIVERY_STATUS = {
  pending: ['等待发送', 'neutral'],
  sent: ['已发送', 'green'],
  unknown: ['结果未知', 'amber'],
  failed: ['发送失败', 'red'],
};

/// 交付预览：先生成可编辑的草稿并展示目标，确认后才排队发送。关闭不产生任何外部副作用，草稿保留。
export function DeliveryModal({ work, target, notify, onClose }) {
  const [preview, setPreview] = useState(null);
  const [body, setBody] = useState('');
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const saveTimer = useRef(0);
  const requestId = useRef(newId());
  const isTapd = target === 'tapd';

  function load() {
    request('delivery.preview', { workId: work.id, target }, { timeoutMs: 120000 })
      .then((result) => {
        setPreview(result);
        setBody((current) => current || result.body);
        setError(null);
      })
      .catch((cause) => setError(errorText(cause)));
  }
  useEffect(load, [work.id, target, (work.deliveries ?? []).map((item) => item.status).join(',')]);

  function edit(value) {
    setBody(value);
    window.clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(
      () => request('delivery.saveDraft', { workId: work.id, target, body: value }).catch(() => {}),
      400,
    );
  }

  async function confirm() {
    if (busy || !body.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const result = await request(
        'delivery.confirm',
        { workId: work.id, target, body, requestId: requestId.current },
        { timeoutMs: 60000 },
      );
      notify(result.duplicate ? '相同内容已经在投递队列里，没有重复排队' : '投递已排队，发送结果会显示在这里');
      requestId.current = newId();
      load();
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  }

  async function act(method, delivery) {
    try {
      const result = await request(method, { deliveryId: delivery.id }, { timeoutMs: 120000 });
      if (result?.message) notify(result.message, result.found === null);
      load();
    } catch (cause) {
      notify(errorText(cause), true);
    }
  }

  const blockers = preview?.blockers ?? [];
  const info = preview?.targetInfo;
  return (
    <ModalFrame title={isTapd ? 'TAPD 回填预览' : 'Work 结果汇报'} wide onClose={onClose}>
      {!preview && !error && <div className="pane-note">正在生成草稿…</div>}
      {preview && (
        <>
          <div className="write-target">
            {isTapd ? <span className="tapd-logo">T</span> : <ChatsCircle size={18} />}
            <div>
              <small>
                {isTapd
                  ? `TAPD ${info.entityType} · workspace ${info.workspaceId} · #${info.entityId}`
                  : `${work.displayId} · 原会话 ${info.title || info.remoteConversationId}`}
              </small>
              <b>{isTapd ? info.title : work.title}</b>
            </div>
            <span className="pill neutral">{isTapd ? '评论' : '回复'}</span>
          </div>
          <label className="field">
            {isTapd ? '回填内容（将作为一条评论添加）' : '交给 WorkBuddy 在原会话发送的内容'}
            <textarea rows={11} value={body} onChange={(event) => edit(event.target.value)} />
            <small>
              草稿根据实际的审阅与验证记录生成，可以修改；关闭后草稿保留。
              {preview.edited && (
                <button className="link-button" onClick={() => edit(preview.generated)}>
                  恢复为生成的内容
                </button>
              )}
            </small>
          </label>
          <div className="writeback-status">
            <Info size={13} />
            {isTapd
              ? `只添加评论。业务状态保持「${info.businessStatus ?? '当前状态'}」不变，不填写工时、排期或上线字段。`
              : '由 WorkBuddy 领取后在原会话发送；收到发送回执之前不会显示为已发送。'}
          </div>
          {blockers.map((text) => (
            <div className="pane-note warn" role="status" key={text}>
              <Warning size={14} />
              {text}
            </div>
          ))}
          {preview.deliveries.length > 0 && (
            <div className="delivery-history">
              <h4>投递记录</h4>
              {preview.deliveries.map((delivery) => (
                <div className="delivery-row" key={delivery.id}>
                  <span className={`pill ${DELIVERY_STATUS[delivery.status]?.[1] ?? 'neutral'}`}>
                    {DELIVERY_STATUS[delivery.status]?.[0] ?? delivery.status}
                  </span>
                  <div>
                    <p>{delivery.body.split('\n')[0]}</p>
                    <small>
                      {formatTime(delivery.updatedAt)}
                      {delivery.remoteId ? ` · 远端记录 ${delivery.remoteId}` : ''}
                      {delivery.error ? ` · ${delivery.error}` : ''}
                    </small>
                  </div>
                  {delivery.status === 'unknown' && (
                    <button onClick={() => act('delivery.verify', delivery)}>核对</button>
                  )}
                  {delivery.status === 'unknown' && !isTapd && (
                    <button onClick={() => act('delivery.markUndelivered', delivery)}>确认未收到</button>
                  )}
                  {delivery.status === 'failed' && (
                    <button onClick={() => act(isTapd ? 'delivery.retry' : 'delivery.requeue', delivery)}>重试</button>
                  )}
                </div>
              ))}
            </div>
          )}
        </>
      )}
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      <div className="modal-footer">
        <button onClick={onClose}>关闭</button>
        <button className="primary" disabled={!preview || busy || blockers.length > 0 || !body.trim()} onClick={confirm}>
          {busy ? '正在排队…' : isTapd ? '确认回填' : '交付并汇报'}
        </button>
      </div>
    </ModalFrame>
  );
}

/// 来源对话：这个 Work（或全部来源）收到的消息、澄清与创建回执。只读，不发送任何消息。
export function SourceModal({ work, onClose, onOpenWork }) {
  const [overview, setOverview] = useState(null);
  const [error, setError] = useState(null);
  useEffect(() => {
    request('source.overview')
      .then(setOverview)
      .catch((cause) => setError(errorText(cause)));
  }, []);
  const conversations = (overview?.conversations ?? []).filter(
    (item) => !work || item.id === work.sourceConversationId,
  );
  return (
    <ModalFrame title={work ? `${work.displayId} 的来源对话` : '企业微信来源对话'} wide onClose={onClose}>
      {error && (
        <div className="pane-note error">
          <Warning size={14} />
          {error}
        </div>
      )}
      {!overview && !error && <div className="pane-note">正在读取…</div>}
      {overview && conversations.length === 0 && (
        <p className="context-empty">
          {work ? '没有找到这个 Work 的来源记录。' : '还没有收到任何来源消息。WorkBuddy 接入并调用宿主接口后，消息会出现在这里。'}
        </p>
      )}
      {conversations.map((conversation) => (
        <div className="source-conversation" key={conversation.id}>
          <div className="channel-heading">
            <ChatsCircle size={15} />
            <b>{conversation.title || conversation.remoteConversationId}</b>
            <span className="pill neutral">{conversation.accountId}</span>
          </div>
          <div className="robot-chat">
            {[...conversation.events].reverse().map((event) => (
              <React.Fragment key={event.id}>
                <div className="human-bubble">
                  <small>
                    {event.actorId || '发送人未知'}
                    {!event.actorVerified && '（身份未验证）'} · {formatTime(event.at)}
                    {event.kind === 'clarification_reply' && ' · 澄清回复'}
                  </small>
                  <p>{event.text || '（无文本）'}</p>
                </div>
                {event.result && (
                  <div className="bot-bubble">
                    <small>宿主回执</small>
                    <p>
                      {event.result.state === 'created' && `已创建 ${event.result.displayId}（${event.result.project}）。${event.result.note ?? ''}`}
                      {event.result.state === 'needs_clarification' && `需要澄清：${event.result.question ?? ''}`}
                      {event.result.state === 'follow_up' && `已作为 ${event.result.displayId} 的跟进。`}
                      {event.result.state === 'rejected' && `未接受：${event.result.message ?? event.result.reason}`}
                    </p>
                  </div>
                )}
              </React.Fragment>
            ))}
          </div>
          {!work && conversation.works.length > 0 && (
            <div className="source-works">
              {conversation.works.map((item) => (
                <button className="link-button" key={item.id} onClick={() => onOpenWork(item.id)}>
                  {item.displayId} · {item.title}
                </button>
              ))}
            </div>
          )}
        </div>
      ))}
      <p className="setting-hint">这里是已收到事件的记录视图，不会向企业微信发送任何消息。</p>
      <div className="modal-footer">
        <button className="primary" onClick={onClose}>
          关闭
        </button>
      </div>
    </ModalFrame>
  );
}

/// 全局搜索：项目、Work、会话。按完整身份打开，不同项目里编号或标题相同的不会混。
export function SearchModal({ state, works, onClose, onOpenWork, onOpenSession, onOpenProject }) {
  const [query, setQuery] = useState('');
  const results = useMemo(() => {
    const text = query.trim().toLowerCase();
    const match = (...fields) => !text || fields.some((field) => String(field ?? '').toLowerCase().includes(text));
    const out = [];
    for (const work of works) {
      const ref = work.tapdRefs?.[0];
      if (match(work.title, work.displayId, work.objective, work.project?.name, ref?.entityId))
        out.push({ kind: 'work', key: `w-${work.id}`, work });
    }
    for (const project of state.projects) {
      if (match(project.title, project.path)) out.push({ kind: 'project', key: `p-${project.path}`, project });
      for (const session of project.sessions) {
        if (text && match(session.title)) out.push({ kind: 'session', key: `s-${session.id}`, project, session });
      }
    }
    return out.slice(0, 60);
  }, [query, works, state.projects]);

  return (
    <ModalFrame title="搜索工作空间" onClose={onClose}>
      <label className="search-box modal-search">
        <MagnifyingGlass size={15} />
        <input
          aria-label="搜索 Work、项目或会话"
          placeholder="搜索 Work、项目、会话或 TAPD 编号"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
      </label>
      <div className="search-results">
        {results.length === 0 && <p className="context-empty">没有找到匹配项。</p>}
        {results.map((item) =>
          item.kind === 'work' ? (
            <button className="search-result" key={item.key} onClick={() => onOpenWork(item.work.id)}>
              <Briefcase size={14} />
              <span>
                {item.work.title}
                <small>
                  {item.work.displayId} · {item.work.project?.name ?? '—'} · {sourceLabel(item.work)}
                </small>
              </span>
              <span className={`pill ${statusOf(item.work).tone}`}>{statusOf(item.work).label}</span>
            </button>
          ) : item.kind === 'project' ? (
            <button className="search-result" key={item.key} onClick={() => onOpenProject(item.project)}>
              <Folder size={14} />
              <span>
                {item.project.title}
                <small>{tildePath(item.project.path, state.home)}</small>
              </span>
            </button>
          ) : (
            <button className="search-result" key={item.key} onClick={() => onOpenSession(item.project, item.session)}>
              <Terminal size={14} />
              <span>
                {item.session.title}
                <small>
                  {item.project.title} · {item.session.time}
                </small>
              </span>
            </button>
          ),
        )}
      </div>
    </ModalFrame>
  );
}

export function ExportModal({ work, notify, onClose }) {
  const [kind, setKind] = useState('taskcard');
  const [content, setContent] = useState(null);
  const [error, setError] = useState(null);
  useEffect(() => {
    setContent(null);
    request('work.export', { workId: work.id, kind }, { timeoutMs: 120000 })
      .then(setContent)
      .catch((cause) => setError(errorText(cause)));
  }, [work.id, kind]);

  async function save() {
    try {
      const result = await request('work.saveExport', { workId: work.id, kind }, { timeoutMs: 600000 });
      if (result.saved) notify(`已保存到 ${result.path}`);
    } catch (cause) {
      notify(errorText(cause), true);
    }
  }

  return (
    <ModalFrame title={`导出 ${work.displayId}`} wide onClose={onClose}>
      <div className="segmented" role="group" aria-label="导出内容">
        <button className={kind === 'taskcard' ? 'chosen' : ''} onClick={() => setKind('taskcard')}>
          任务卡
        </button>
        <button className={kind === 'record' ? 'chosen' : ''} onClick={() => setKind('record')}>
          执行记录
        </button>
      </div>
      <p className="setting-hint">
        导出的是脱敏后的 Markdown 草稿。Work 的状态仍以应用内的记录为准；在外部修改这份文件不会改变 Work，也不会重启执行。
      </p>
      {error && (
        <div className="pane-note error">
          <Warning size={14} />
          {error}
        </div>
      )}
      <pre className="export-preview">{content?.markdown ?? '正在生成…'}</pre>
      <div className="modal-footer">
        <button onClick={onClose}>关闭</button>
        <button className="primary" disabled={!content} onClick={save}>
          <ArrowSquareOut size={14} />
          保存为文件…
        </button>
      </div>
    </ModalFrame>
  );
}
