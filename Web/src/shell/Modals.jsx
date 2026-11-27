// 弹窗：模型上下文 / MCP 服务 / 添加目录 / 新建会话 / 重命名会话 / 界面设置。
import EngineIcon from './EngineIcon.jsx';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ArrowsClockwise,
  CaretRight,
  FolderOpen,
  GitBranch,
  Monitor,
  Plus,
  PlugsConnected,
  TreeStructure,
  Warning,
  X,
} from '@phosphor-icons/react';
import { errorText, request } from './bridge.js';
import { resumeCommand } from './session-info.js';
import { contextNumbers } from './Composer.jsx';
import { IconButton, tildePath, useDialogFocus } from './ui.jsx';
import { tapdTaskId, unifiedWorktreeName, untitledWorktreeBranch, validWorktreeComponent, worktreeTitleSlug } from './worktree-name.js';

function ModalFrame({ title, wide = false, className = '', onClose, dismissOnBackdrop = true, children }) {
  const focus = useDialogFocus(onClose);
  return (
    <div className="modal-backdrop" onClick={dismissOnBackdrop ? onClose : undefined}>
      <section
        {...focus}
        className={`modal${wide ? ' information-dialog' : ''}${className ? ' ' + className : ''}`}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="modal-header">
          <h2>{title}</h2>
          <IconButton icon={X} label="关闭弹窗" disabled={!onClose} onClick={onClose} />
        </div>
        {children}
      </section>
    </div>
  );
}

// ---------- 模型上下文 ----------

const PART_COLORS = ['#a798b6', '#8ba8ba', '#d3a37e', '#a3b391', '#b5a88a'];

export function ContextModal({ context, modelLabel, onClose }) {
  const { total, used, percent, k } = contextNumbers(context);
  const parts = (context?.parts ?? []).filter((part) => part.value > 0);
  return (
    <ModalFrame title="模型上下文" wide onClose={onClose}>
      <p className="modal-description">
        {context?.sessionId ? '当前会话最近一次请求的上下文窗口分布' : '还没有打开会话'}
      </p>
      <div className="context-summary">
        <div>
          <span>{context?.model || modelLabel}</span>
          <strong>
            {k(used)}
            <small>k / {k(total)}k</small>
          </strong>
          <p>
            已使用 {percent.toFixed(1)}% · 剩余 {k(total - used)}k
          </p>
        </div>
        <div className="context-large-ring" style={{ '--context-progress': `${percent}%` }}>
          <span>
            {percent.toFixed(0)}
            <small>%</small>
          </span>
        </div>
      </div>
      <div className="context-allocation" aria-label="上下文分布">
        {parts.map((part, index) => (
          <span
            key={part.label}
            style={{
              width: `${(part.value / total) * 100}%`,
              background: PART_COLORS[index % PART_COLORS.length],
            }}
          />
        ))}
      </div>
      <div className="context-breakdown">
        {parts.map((part, index) => (
          <div key={part.label}>
            <span>
              <i style={{ background: PART_COLORS[index % PART_COLORS.length] }} />
              {part.label}
            </span>
            <strong>{k(part.value)}k</strong>
            <small>{((part.value / total) * 100).toFixed(1)}%</small>
          </div>
        ))}
        <div>
          <span>
            <i className="remaining-color" />
            可用上下文
          </span>
          <strong>{k(total - used)}k</strong>
          <small>{(100 - percent).toFixed(1)}%</small>
        </div>
      </div>
      <div className="information-note">
        数值取自会话记录里最近一次模型请求的 token 用量（输入 + 缓存），窗口容量按模型推断。
      </div>
    </ModalFrame>
  );
}

// ---------- MCP 服务 ----------

const STATUS_TEXT = {
  connected: '已连接',
  failed: '未连接',
  auth: '需要认证',
  pending: '待批准',
  disabled: '已停用',
  checking: '检查中',
};

export function McpModal({ projectPath, notify, onClose }) {
  const [mcpProvider, setMcpProvider] = useState('claude');
  const [servers, setServers] = useState(null);
  const [status, setStatus] = useState({});
  const [tools, setTools] = useState({});
  const [selectedId, setSelectedId] = useState('');
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState('');
  const [endpoint, setEndpoint] = useState('');
  const [transport, setTransport] = useState('stdio');
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState('');
  const [confirmRemove, setConfirmRemove] = useState(false);

  // 插件 / claude.ai 连接器提供的服务不在配置文件里，只能从健康检查结果里拿到。
  const [extra, setExtra] = useState([]);
  const loadStatus = useCallback(() => {
    setStatus({ loaded: false });
    request('mcp.status', { projectPath, provider: mcpProvider }, { timeoutMs: 90000 })
      .then((result) => {
        const statuses = result?.statuses ?? result ?? {};
        setExtra(Array.isArray(result?.extra) ? result.extra : []);
        setStatus((current) => ({ ...current, ...statuses, loaded: true }));
      })
      .catch(() => setStatus((current) => ({ ...current, loaded: true })));
  }, [projectPath, mcpProvider]);

  const load = useCallback(
    async (select) => {
      try {
        const list = await request('mcp.list', { projectPath, provider: mcpProvider });
        setServers(list);
        setSelectedId((current) => {
          const wanted = select ?? current;
          return list.some((item) => item.id === wanted) ? wanted : (list[0]?.id ?? '');
        });
        setError(null);
      } catch (cause) {
        setServers([]);
        setError(errorText(cause));
      }
    },
    [projectPath, mcpProvider],
  );

  useEffect(() => {
    load();
    loadStatus();
  }, [load, loadStatus]);

  const allServers = servers
    ? [...servers, ...extra.filter((item) => !servers.some((server) => server.name === item.name))]
    : null;
  const selected = allServers?.find((item) => item.id === selectedId) ?? null;

  // 列表刚加载、还没选中任何服务时，健康检查带回的外部服务也可以作为默认选中项
  useEffect(() => {
    if (!selectedId && allServers?.length) setSelectedId(allServers[0].id);
  }, [selectedId, allServers?.length]);

  // 选中服务时按需发现工具（直接与服务握手，结果缓存到关闭弹窗为止）
  useEffect(() => {
    if (!selected || !selected.enabled || selected.scope === 'external' || tools[selected.id])
      return;
    setTools((current) => ({ ...current, [selected.id]: { loading: true, tools: [] } }));
    request('mcp.tools', { projectPath, provider: mcpProvider, id: selected.id }, { timeoutMs: 45000 })
      .then((result) => setTools((current) => ({ ...current, [selected.id]: result })))
      .catch((cause) =>
        setTools((current) => ({
          ...current,
          [selected.id]: { tools: [], error: errorText(cause) },
        })),
      );
  }, [selected?.id, selected?.enabled]);

  const stateOf = (server) => {
    if (!server.enabled) return 'disabled';
    if (status[server.id]) return status[server.id];
    return status.loaded ? 'failed' : 'checking';
  };
  const connectedCount = (allServers ?? []).filter(
    (server) => stateOf(server) === 'connected',
  ).length;
  const selectedTools = selected ? tools[selected.id] : null;

  async function act(label, method, params, done) {
    setBusy(label);
    setError(null);
    try {
      const result = await request(
        method,
        { projectPath, provider: mcpProvider, ...params },
        { timeoutMs: 90000 },
      );
      if (done) notify(done);
      return result ?? true;
    } catch (cause) {
      setError(errorText(cause));
      return null;
    } finally {
      setBusy('');
    }
  }

  return (
    <ModalFrame title="MCP 服务" dismissOnBackdrop={false} wide onClose={onClose}>
      <div className="segmented" style={{ marginBottom: 10 }} role="tablist" aria-label="选择 MCP 配置引擎">
        {[
          ['claude', 'Claude Code 配置'],
          ['antigravity', 'Antigravity 配置'],
        ].map(([id, label]) => (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={mcpProvider === id}
            className={mcpProvider === id ? 'chosen' : ''}
            onClick={() => {
              setMcpProvider(id);
              setSelectedId('');
              setAdding(false);
              setConfirmRemove(false);
              setError(null);
            }}
          >
            {label}
          </button>
        ))}
      </div>
      <p className="modal-description">
        {mcpProvider === 'antigravity'
          ? '管理 Antigravity 全局 MCP 配置（~/.gemini/config/mcp_config.json）。仅支持 stdio 与 Streamable HTTP，不支持旧版 SSE。'
          : '查看工具能力、连接状态与服务配置。连接状态由应用直接与服务握手检查；改动写入 Claude Code 的配置文件，对新开的会话生效。'}
      </p>
      <div className="mcp-heading">
        <span>
          {connectedCount} / {allServers?.length ?? 0} 个服务已连接
          {!status.loaded ? ' · 正在检查连接…' : ''}
        </span>
        <div style={{ display: 'flex', gap: 6 }}>
          {mcpProvider === 'antigravity' && (
            <button
              disabled={busy === 'import'}
              onClick={async () => {
                const res = await act('import', 'mcp.importFromClaude', {});
                if (!res) return;
                const msg = `已从 Claude 导入 ${res.imported ?? 0} 个服务`
                  + (res.skippedSse ? `（跳过 ${res.skippedSse} 个旧版 SSE）` : '');
                notify(msg);
                await load();
                loadStatus();
              }}
            >
              {busy === 'import' ? '导入中…' : '从 Claude 导入'}
            </button>
          )}
          <button onClick={() => setAdding(!adding)}>
            <Plus size={14} />
            添加服务
          </button>
        </div>
      </div>
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      {adding && (
        <form
          className="mcp-add-form"
          onSubmit={async (event) => {
            event.preventDefault();
            if (!name.trim() || !endpoint.trim()) return;
            const result = await act(
              'add',
              'mcp.add',
              { name: name.trim(), transport, endpoint: endpoint.trim() },
              `已添加 MCP 服务 ${name.trim()}`,
            );
            if (!result) return;
            setAdding(false);
            setName('');
            setEndpoint('');
            await load(result.id);
            loadStatus();
          }}
        >
          <label>
            名称
            <input
              aria-label="MCP 服务名称"
              value={name}
              onChange={(event) => setName(event.target.value)}
              placeholder="例如：project-docs"
            />
          </label>
          <label>
            传输方式
            <select
              aria-label="MCP 传输方式"
              value={transport}
              onChange={(event) => setTransport(event.target.value)}
            >
              <option value="stdio">stdio</option>
              <option value="http">HTTP</option>
            </select>
          </label>
          <label className="mcp-endpoint-field">
            {transport === 'http' ? '服务地址' : '启动命令'}
            <input
              aria-label="MCP 服务地址或命令"
              value={endpoint}
              onChange={(event) => setEndpoint(event.target.value)}
              placeholder={
                transport === 'http' ? 'https://example.com/mcp' : 'npx -y @scope/mcp-server'
              }
            />
          </label>
          <button className="primary" disabled={!name.trim() || !endpoint.trim() || busy === 'add'}>
            {busy === 'add' ? '正在添加…' : '添加'}
          </button>
        </form>
      )}
      <div className="mcp-workspace">
        <div className="mcp-server-list">
          {(allServers ?? []).map((server) => (
            <button
              key={server.id}
              className={selectedId === server.id ? 'selected' : ''}
              onClick={() => {
                setSelectedId(server.id);
                setConfirmRemove(false);
              }}
            >
              <span
                className={`mcp-status ${
                  { connected: 'connected', disabled: 'disabled', checking: 'disabled' }[
                    stateOf(server)
                  ] ?? 'disconnected'
                }`}
              />
              <span>
                <strong>{server.name}</strong>
                <small>
                  {STATUS_TEXT[stateOf(server)]} · {server.transport}
                </small>
              </span>
            </button>
          ))}
        </div>
        {selected ? (
          <div className="mcp-detail">
            <div className="mcp-detail-heading">
              <h3>{selected.name}</h3>
              <label className="mcp-enable">
                启用
                <input
                  type="checkbox"
                  role="switch"
                  aria-label={`启用 ${selected.name}`}
                  checked={selected.enabled}
                  disabled={busy === 'toggle' || selected.scope === 'external'}
                  onChange={async (event) => {
                    const enabled = event.target.checked;
                    const ok = await act(
                      'toggle',
                      'mcp.setEnabled',
                      { id: selected.id, enabled },
                      `${enabled ? '已启用' : '已停用'} ${selected.name}`,
                    );
                    if (!ok) return;
                    setTools(({ [selected.id]: _dropped, ...rest }) => rest);
                    await load();
                    loadStatus();
                  }}
                />
              </label>
            </div>
            <p>{selected.description}</p>
            <dl>
              <dt>传输方式</dt>
              <dd>{selected.transport}</dd>
              <dt>配置</dt>
              <dd>{selected.endpoint}</dd>
              <dt>状态</dt>
              <dd>{STATUS_TEXT[stateOf(selected)]}</dd>
            </dl>
            <div className="mcp-actions">
              <button
                disabled={!selected.enabled || busy === 'reconnect'}
                onClick={async () => {
                  const result = await act('reconnect', 'mcp.reconnect', { id: selected.id });
                  if (!result) return;
                  setStatus((current) => ({ ...current, [selected.id]: result.status }));
                  setTools((current) => ({ ...current, [selected.id]: result }));
                  notify(
                    result.status === 'connected'
                      ? `${selected.name} 已连接`
                      : `${selected.name} ${STATUS_TEXT[result.status] ?? '未连接'}`,
                  );
                }}
              >
                <ArrowsClockwise size={13} />
                {busy === 'reconnect' ? '正在连接…' : '重新连接'}
              </button>
              {confirmRemove ? (
                <>
                  <button
                    className="danger"
                    onClick={async () => {
                      setConfirmRemove(false);
                      const ok = await act(
                        'remove',
                        'mcp.remove',
                        { id: selected.id },
                        `已移除 MCP 服务 ${selected.name}`,
                      );
                      if (ok) await load();
                    }}
                  >
                    确认移除
                  </button>
                  <button onClick={() => setConfirmRemove(false)}>取消</button>
                </>
              ) : (
                <button
                  disabled={!selected.removable || busy === 'remove'}
                  title={selected.removable ? '' : '由插件或 claude.ai 提供的服务不能在这里移除'}
                  onClick={() => setConfirmRemove(true)}
                >
                  移除服务
                </button>
              )}
            </div>
            <h4>
              可用工具 <span>{selectedTools?.tools?.length ?? 0}</span>
            </h4>
            {selectedTools?.loading ? (
              <p className="information-note">正在发现工具…</p>
            ) : selectedTools?.tools?.length ? (
              <div className="mcp-tools">
                {selectedTools.tools.map((toolName) => (
                  <code key={toolName}>{toolName}</code>
                ))}
              </div>
            ) : (
              <p className="information-note">
                {!selected.enabled
                  ? '服务已停用。'
                  : selected.scope === 'external'
                    ? '由插件或 claude.ai 连接器提供，工具清单请在会话里用 /mcp 查看。'
                    : selectedTools?.error
                      ? `暂无已发现的工具（${selectedTools.error}）`
                      : '暂无已发现的工具。'}
              </p>
            )}
          </div>
        ) : (
          <div className="mcp-empty">
            {servers === null ? '正在读取 MCP 配置…' : '添加服务以查看工具与配置。'}
          </div>
        )}
      </div>
    </ModalFrame>
  );
}

// ---------- 添加目录 ----------

export function DirectoryModal({ notify, onClose, onAdded }) {
  const [path, setPath] = useState('');
  const [error, setError] = useState(null);
  const trimmed = path.trim();

  async function add(target) {
    try {
      const result = await request('app.addDirectory', { path: target });
      notify(`已添加目录 ${tildePath(result.path, null).split('/').pop()}`);
      onAdded(result.path);
      onClose();
    } catch (cause) {
      setError(errorText(cause));
    }
  }

  return (
    <ModalFrame title="添加目录" dismissOnBackdrop={false} onClose={onClose}>
      <p className="modal-description">输入一个目录路径，或从访达里选择，添加到左侧项目列表。</p>
      <div className="field">
        <span>目录路径</span>
        <div className="path-input">
          <input
            autoFocus
            aria-label="目录路径"
            placeholder="~/project/my-project"
            value={path}
            onChange={(event) => {
              setPath(event.target.value);
              setError(null);
            }}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && trimmed && !event.nativeEvent.isComposing) add(trimmed);
            }}
          />
          <button
            type="button"
            title="从访达选择目录"
            aria-label="从访达选择目录"
            onClick={async () => {
              const picked = await request('app.pickDirectory', {}, { timeoutMs: 600000 }).catch(
                () => null,
              );
              if (picked?.path) add(picked.path);
            }}
          >
            <FolderOpen size={14} />
            选择…
          </button>
        </div>
      </div>
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      <div className="modal-footer">
        <button onClick={onClose}>取消</button>
        <button
          className="primary"
          disabled={!trimmed.replace(/\/+$/, '').split('/').pop()}
          onClick={() => add(trimmed)}
        >
          添加
        </button>
      </div>
    </ModalFrame>
  );
}

// ---------- 新建会话 ----------

export function worktreeSlug(branch) {
  return (
    String(branch)
      .trim()
      .replace(/[^A-Za-z0-9._-]+/g, '-')
      .replace(/^-+|-+$/g, '') || 'worktree'
  );
}

// 统一模式（设置里配置了工作树命令）的任务字段：任务标识必填，子任务可选；TAPD 取完整 ID。
function useUnifiedTask(title, tapd) {
  const [task, setTask] = useState(tapd?.id ? String(tapd.id) : '');
  const [touched, setTouched] = useState(Boolean(tapd?.id));
  const [subtask, setSubtask] = useState('');
  const value = touched ? task.trim() : (task.trim() || tapdTaskId(title));
  return {
    task: value,
    subtask: subtask.trim(),
    setTask: (next) => { setTask(next); setTouched(true); },
    setSubtask,
    taskOk: validWorktreeComponent(value),
    subtaskOk: !subtask.trim() || validWorktreeComponent(subtask.trim()),
    name: unifiedWorktreeName(title, value, subtask.trim()),
  };
}

function UnifiedTaskFields({ unified, disabled }) {
  return (
    <div className="cli-worktree-grid">
      <label className="field">任务标识
        <input required disabled={disabled} value={unified.task} spellCheck={false} placeholder="TAPD 完整 ID 或稳定的英文标识"
          aria-invalid={Boolean(unified.task) && !unified.taskOk}
          onChange={(event) => unified.setTask(event.target.value)} />
        {unified.task && !unified.taskOk && <small className="field-error">只能用字母、数字、点、横线、下划线，字母或数字开头</small>}
      </label>
      <label className="field">子任务（可选）
        <input disabled={disabled} value={unified.subtask} spellCheck={false} placeholder="并行独立子任务时填写"
          aria-invalid={!unified.subtaskOk}
          onChange={(event) => unified.setSubtask(event.target.value)} />
      </label>
    </div>
  );
}

export function CreateWorktreeModal({ projects, projectPath, settings, providers, tapd, onClose, onCreated }) {
  const [path, setPath] = useState(projectPath);
  const [branches, setBranches] = useState(null);
  const [base, setBase] = useState('');
  const [name, setName] = useState('');
  const [error, setError] = useState(null);
  const [creating, setCreating] = useState(false);
  const available = providers.filter((item) => item.available && settings.cliPreferences?.[item.id]?.enabled !== false);
  const [agent, setAgent] = useState('');
  const [createdTree, setCreatedTree] = useState(null);
  const isUnified = Boolean(settings.worktreeCommand);
  const unified = useUnifiedTask(name || tapd?.title || '', tapd);
  const [customBranch, setCustomBranch] = useState('');
  const branchInput = useRef(null);
  // 命令要求显式分支时把焦点交给分支框；放在重新渲染之后，此时 fieldset 已解除禁用。
  const [branchFocus, setBranchFocus] = useState(0);
  useEffect(() => { if (branchFocus) branchInput.current?.focus(); }, [branchFocus]);
  const worktreeName = isUnified ? (name.trim() ? unified.name : '') : worktreeTitleSlug(name);
  const branch = isUnified ? customBranch.trim() : branches ? (worktreeName || untitledWorktreeBranch(branches)) : '';
  const canSubmit = Boolean(base) && (isUnified ? unified.taskOk && unified.subtaskOk : Boolean(branch));

  useEffect(() => {
    let current = true;
    setBranches(null);
    setBase('');
    setError(null);
    request('git.branches', { projectPath: path }).then((list) => {
      if (!current) return;
      setBranches(list);
      setBase(list.find((item) => item.name === 'origin/main')?.name ?? list.find((item) => item.isCurrent)?.name ?? '');
    }).catch((cause) => { if (current) setError(errorText(cause)); });
    return () => { current = false; };
  }, [path]);

  function surface(provider) {
    const override = settings.cliPreferences?.[provider]?.mode;
    const mode = override && override !== 'inherit' ? override : settings.interactionMode;
    const supported = settings.cliPreferences?.[provider]?.modes ?? ['terminal'];
    if (!supported.includes(mode)) return '终端';
    return mode === 'structured' ? '结构化聊天' : mode === 'chat' ? 'Swttch' : '终端';
  }

  return (
    <ModalFrame title="创建工作树" dismissOnBackdrop={false} className="cli-worktree-modal" onClose={creating ? undefined : onClose}>
      <form className="cli-worktree-form" onSubmit={async (event) => {
        event.preventDefault();
        if (!canSubmit || creating) return;
        setCreating(true);
        setError(null);
        try {
          const options = { timeoutMs: 150000 };
          const input = isUnified
            ? {
              projectPath: path, baseBranch: base, task: unified.task,
              ...(unified.name ? { name: unified.name } : {}),
              ...(unified.subtask ? { subtask: unified.subtask } : {}),
              ...(branch ? { branch } : {}),
            }
            : { projectPath: path, baseBranch: base, branch };
          const tree = createdTree ?? await request('git.createWorktree', { input }, options);
          if (!createdTree) {
            setCreatedTree(tree);
            onCreated(tree, path, worktreeName);
          }
          if (agent) {
            const session = await request('session.create', {
              projectPath: path, provider: agent, mode: 'current',
              workspace: { branch: tree.branch, worktreePath: tree.path },
            }, options);
            onCreated({ ...tree, ...session }, path, worktreeName);
          }
          onClose();
        } catch (cause) {
          const text = errorText(cause);
          setError(text);
          setCreating(false);
          // 方果、蓝马等仓库要求显式分支：命令报 --branch 时把焦点交给分支输入框。
          if (isUnified && !createdTree && text.includes('--branch')) setBranchFocus((value) => value + 1);
        }
      }}>
        <fieldset disabled={creating || Boolean(createdTree)} className="cli-worktree-fields">
          <div className="cli-worktree-grid">
            <label className="field">项目
              <select value={path} onChange={(event) => { setBase(''); setPath(event.target.value); }}>
                {projects.map((item) => <option value={item.path} key={item.path}>{item.title}</option>)}
              </select>
            </label>
            <div className="field">运行于
              <span className="cli-worktree-location"><Monitor size={15} aria-hidden="true" /> 本地 Mac</span>
            </div>
          </div>
          <label className="field">起始分支
            <select disabled={!branches?.length} value={base} onChange={(event) => setBase(event.target.value)}>
              <option value="" disabled>{error && !branches ? '分支读取失败' : !branches ? '正在读取分支…' : branches.length ? '选择起始分支' : '没有可用分支'}</option>
              {branches?.map((item) => <option key={item.name} value={item.name}>{item.name}</option>)}
            </select>
          </label>
          <label className="field">工作树标题（可选）
            <input autoFocus value={name} placeholder={isUnified ? '转成英文作为目录名称；含 TAPD 编号时自动填入任务标识' : '留空时采用第一个会话标题'}
              onChange={(event) => setName(event.target.value)} />
          </label>
          {isUnified && <UnifiedTaskFields unified={unified} />}
          {isUnified && (
            <label className="field">分支（可选）
              <input ref={branchInput} value={customBranch} spellCheck={false} placeholder="留空按仓库规则生成"
                onChange={(event) => setCustomBranch(event.target.value)} />
            </label>
          )}
          {isUnified ? (
            <dl className="cli-worktree-target">
              <div><dt>任务</dt><dd><code>{unified.task ? [unified.task, unified.subtask].filter(Boolean).join('/') : '未填写'}</code></dd></div>
              <div><dt>分支</dt><dd>{branch ? <code>{branch}</code> : '按仓库规则生成'}</dd></div>
              <div><dt>本机目录</dt><dd>由工作树命令决定，已登记的任务沿用原路径</dd></div>
            </dl>
          ) : branch && (
            <dl className="cli-worktree-target">
              <div><dt>新分支</dt><dd><code>{branch}</code></dd></div>
              <div><dt>本机目录</dt><dd><code>.worktrees/{worktreeSlug(branch)}</code></dd></div>
            </dl>
          )}
        </fieldset>
        <label className="field">代理（可选）
          <span className="control-select-with-icon">
            {agent ? <EngineIcon id={agent} size={16} decorative /> : <TreeStructure size={16} aria-hidden="true" />}
            <select disabled={creating} value={agent} onChange={(event) => setAgent(event.target.value)}>
              <option value="">仅创建工作树</option>
              {available.map((item) => <option key={item.id} value={item.id}>{item.label}（{surface(item.id)}）</option>)}
            </select>
          </span>
        </label>
        {createdTree && <p className="pane-note">{createdTree.action === 'reused' ? '已复用工作树' : '工作树已创建'}：{createdTree.path}{createdTree.branch ? `（${createdTree.branch}）` : ''}</p>}
        {error && <p className="pane-note error" role="alert">{error}</p>}
        <div className="modal-footer">
          <button type="button" disabled={creating} onClick={onClose}>取消</button>
          <button type="submit" className="primary" disabled={!canSubmit || creating}>{creating ? '处理中…' : createdTree ? (agent ? '重试启动代理' : '完成') : '创建工作树'}</button>
        </div>
      </form>
    </ModalFrame>
  );
}

export function SessionModal({
  project,
  home,
  branch,
  isRepository,
  workspace,
  initialMode,
  providers = [],
  cliPreferences = {},
  defaultProvider = 'claude',
  interactionMode = 'terminal',
  worktreeCommand = '',
  onClose,
  onCreated,
  notify,
}) {
  const [provider, setProvider] = useState(defaultProvider);
  const [title, setTitle] = useState('');
  const [mode, setMode] = useState(isRepository ? initialMode : 'current');
  const isUnified = Boolean(worktreeCommand);
  const [target, setTarget] = useState(isUnified ? '' : 'feature/new-task');
  const unified = useUnifiedTask(title, null);
  const [error, setError] = useState(null);
  const [creating, setCreating] = useState(false);
  const worktree = mode === 'worktree';
  const engineOptions = [
    ['claude', 'Claude Code', 'C', 'claude · 终端、结构化聊天与 Swttch'],
    ['antigravity', 'Antigravity', 'A', 'agy · 终端与 ACP 结构化聊天'],
    ['codex', 'Codex CLI', 'Cx', 'codex · 终端与 App Server 结构化聊天'],
    ['dsh', 'DeepSeek Harness', 'Ds', 'dsh-TUI · 原生终端'],
  ];
  const [, engineLabel] = engineOptions.find(([id]) => id === provider) ?? engineOptions[0];
  const providerInfo = providers.find((item) => item.id === provider);
  const providerEnabled = cliPreferences[provider]?.enabled !== false;
  const providerAvailable = providerEnabled && Boolean(providerInfo?.available);
  const worktreeReady = isUnified ? unified.taskOk && unified.subtaskOk : Boolean(target.trim());
  const ready = (!worktree || worktreeReady) && providerAvailable && !creating;
  const supportedModes = cliPreferences[provider]?.modes ?? ['terminal'];
  const preferredMode = cliPreferences[provider]?.mode && cliPreferences[provider].mode !== 'inherit'
    ? cliPreferences[provider].mode
    : interactionMode;
  const defaultSurface = supportedModes.includes(preferredMode) ? preferredMode : 'terminal';
  const [surfaceChoice, setSurfaceChoice] = useState(null);
  const surface = surfaceChoice && supportedModes.includes(surfaceChoice) ? surfaceChoice : defaultSurface;

  async function create() {
    if (!ready) return;
    setCreating(true);
    setError(null);
    try {
      const result = await request(
        'session.create',
        {
          projectPath: project.path,
          ...(title.trim() ? { title: title.trim() } : {}),
          mode,
          provider,
          openMode: surface,
          ...(workspace ? { workspace } : {}),
          ...(worktree && target.trim() ? { branch: target.trim() } : {}),
          ...(worktree && isUnified ? {
            // 与表单展示的「基准分支」一致；不传时 ai-worktree 只能在恰好一个远端时自己推断。
            ...(branch ? { baseBranch: branch } : {}),
            task: unified.task,
            ...(unified.name ? { name: unified.name } : {}),
            ...(unified.subtask ? { subtask: unified.subtask } : {}),
          } : {}),
        },
        { timeoutMs: 150000 },
      );
      const provName = engineLabel;
      const treeName = result.branch ?? target.trim();
      notify(!worktree ? `${provName} 会话已创建`
        : result.worktreeAction === 'reused' ? `已复用工作树 ${treeName}，并创建 ${provName} 会话`
        : `已在工作树 ${treeName} 中创建 ${provName} 会话`);
      onCreated({ ...result, firstSessionTitle: title.trim() });
      onClose();
    } catch (cause) {
      setError(errorText(cause));
      setCreating(false);
    }
  }

  return (
    <ModalFrame title="新建会话" dismissOnBackdrop={false} onClose={onClose}>
      <p className="modal-description">在 {project.title} 中开始新的工作。</p>
      <div className="field">
        执行 CLI 引擎
        <div className="mode-choice" style={{ marginTop: 6 }}>
          {engineOptions.map(([value, label, badge, desc]) => {
            const info = providers.find((item) => item.id === value);
            const enabled = cliPreferences[value]?.enabled !== false;
            const ok = Boolean(info?.available);
            return (
              <button
                type="button"
                key={value}
                className={provider === value ? 'selected' : ''}
                onClick={() => setProvider(value)}
              >
                <strong>
                  <EngineIcon id={value} size={16} />
                  {label}
                  {!enabled ? '（已停用）' : !ok ? `（${info?.status ?? '不可用'}）` : ''}
                </strong>
                <small>{desc}</small>
              </button>
            );
          })}
        </div>
      </div>
      <label className="field">
        打开方式
        <select aria-label="打开方式" value={surface} onChange={(event) => setSurfaceChoice(event.target.value)}>
          {supportedModes.map((value) => (
            <option key={value} value={value}>
              {{ terminal: '原生终端', structured: '结构化聊天', chat: 'Swttch 图形聊天' }[value] ?? value}
            </option>
          ))}
        </select>
      </label>
      <label className="field">
        会话名称（可选）
        <input
          autoFocus
          placeholder="留空则根据对话内容自动生成，之后可重命名"
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.nativeEvent.isComposing) create();
          }}
        />
      </label>
      {!workspace && <div className="mode-choice">
        {[
          ['current', '当前分支', GitBranch],
          ['worktree', '独立工作树', TreeStructure],
        ].map(([value, label, Icon]) => (
          <button
            type="button"
            key={value}
            className={mode === value ? 'selected' : ''}
            disabled={value === 'worktree' && !isRepository}
            title={value === 'worktree' && !isRepository ? '这个目录不是 Git 仓库' : ''}
            onClick={() => setMode(value)}
          >
            <Icon size={19} />
            <strong>{label}</strong>
            <small>{value === 'current' ? '继续在项目目录中工作' : '在独立目录中并行任务'}</small>
          </button>
        ))}
      </div>}
      {worktree && isUnified && <UnifiedTaskFields unified={unified} />}
      {worktree && (
        <label className="field">
          {isUnified ? '分支（可选）' : '新分支名称'}
          <input value={target} spellCheck={false} placeholder={isUnified ? '留空按仓库规则生成' : ''}
            onChange={(event) => setTarget(event.target.value)} />
        </label>
      )}
      <dl className="session-summary">
        <dt>项目</dt>
        <dd>{tildePath(project.path, home)}</dd>
        <dt>执行引擎</dt>
        <dd>{engineLabel} ({providerInfo?.command ?? provider})</dd>
        <dt>{workspace ? '绑定分支' : '基准分支'}</dt>
        <dd>{workspace?.branch ?? branch ?? (isRepository ? 'detached HEAD' : '不是 Git 仓库')}</dd>
        <dt>工作目录</dt>
        <dd>{workspace ? tildePath(workspace.worktreePath ?? project.path, home)
          : worktree ? (isUnified ? '由工作树命令决定，已登记的任务沿用原路径' : `.worktrees/${worktreeSlug(target)}`)
          : '项目根目录'}</dd>
        {worktree && (
          <>
            <dt>目标分支</dt>
            <dd>{target.trim() || (isUnified ? '按仓库规则生成' : '')}</dd>
          </>
        )}
      </dl>
      {!providerAvailable && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {!providerEnabled ? `已停用 ${engineLabel}，请在 CLI 引擎设置中启用。` : provider === 'dsh' ? (
            <span>
              找到 dsh-TUI，但未检测到 DeepSeek Harness (dsh)。<button type="button" onClick={() => window.dispatchEvent(new Event('claude-picker:open-cli-settings'))}>打开 CLI 配置</button>
            </span>
          ) : `未检测到 ${engineLabel}，请先安装并登录。`}
        </div>
      )}
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      <div className="modal-footer">
        <button onClick={onClose}>取消</button>
        <button className="primary" disabled={!ready} onClick={create}>
          <Plus size={15} />
          {creating ? '正在创建…' : '创建会话'}
        </button>
      </div>
    </ModalFrame>
  );
}

// ---------- 重命名会话 ----------

export function SessionInfoModal({ session, projectPath, providerLabel, onCopy, onClose }) {
  const engine = providerLabel ?? 'Claude Code';
  const id = session.originalSessionId;
  const command = resumeCommand(session.provider ?? 'claude', id);
  const details = [
    session.title, `引擎 ${engine}`, `会话 ID ${id ?? '尚未获取'}`,
    `分支 ${session.branch ?? '未绑定'}`, `工作目录 ${session.cwd ?? projectPath}`, command,
  ].filter(Boolean).join('\n');

  return (
    <ModalFrame title="会话信息" onClose={onClose}>
      <div>
        <dl className="session-summary">
          <dt>名称</dt><dd>{session.title}</dd>
          <dt>执行引擎</dt><dd>{engine}</dd>
          <dt>绑定分支</dt><dd>{session.branch ?? '未绑定'}</dd>
          <dt>工作目录</dt><dd>{session.cwd ?? projectPath}</dd>
        </dl>
        <label className="field">会话 ID<input readOnly value={id ?? ''} placeholder="尚未获取引擎会话 ID" onFocus={(event) => event.target.select()} /></label>
        {command && <label className="field">恢复命令<input readOnly value={command} onFocus={(event) => event.target.select()} /></label>}
        <p className="modal-description">在原环境的工作目录运行恢复命令。另一台设备需有该引擎的会话历史。</p>
      </div>
      <div className="modal-footer">
        <button disabled={!id} onClick={() => onCopy(id, '会话 ID')}>复制会话 ID</button>
        <button disabled={!command} onClick={() => onCopy(command, '恢复命令')}>复制恢复命令</button>
        <button className="primary" onClick={() => onCopy(details, '会话信息')}>复制会话信息</button>
      </div>
    </ModalFrame>
  );
}

export function RenameSessionModal({ session, onClose, notify }) {
  const [title, setTitle] = useState(session.named ? session.title : '');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function save(next) {
    if (saving) return;
    setSaving(true);
    setError(null);
    try {
      await request('app.renameSession', { sessionId: session.id, title: next.trim() });
      notify(next.trim() ? '会话已重命名' : '已恢复为自动标题');
      onClose();
    } catch (cause) {
      setError(errorText(cause));
      setSaving(false);
    }
  }

  return (
    <ModalFrame title="重命名会话" dismissOnBackdrop={false} onClose={onClose}>
      <p className="modal-description">
        {session.named ? '当前使用自定义名称。' : `当前为自动标题：${session.title}`}
      </p>
      <label className="field">
        会话名称
        <input
          autoFocus
          placeholder="留空则使用根据对话自动生成的标题"
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.nativeEvent.isComposing) save(title);
          }}
        />
      </label>
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      <div className="modal-footer">
        {session.named && (
          <button disabled={saving} onClick={() => save('')}>
            恢复自动标题
          </button>
        )}
        <button onClick={onClose}>取消</button>
        <button className="primary" disabled={saving} onClick={() => save(title)}>
          保存
        </button>
      </div>
    </ModalFrame>
  );
}

// ---------- 界面设置 ----------

export function SettingsModal({ settings, onChange, onOpenMcp, onClose }) {
  return (
    <ModalFrame title="界面设置" onClose={onClose}>
      <p className="modal-description">调整字号、信息密度与工作区布局。</p>
      <section className="original-settings-section">
        <h3>界面字号</h3>
        <label className="font-slider">
          字号
          <input
            type="range"
            aria-label="界面字号"
            min="9"
            max="20"
            step="0.5"
            value={settings.appFontSize}
            onChange={(event) => onChange({ appFontSize: Number(event.target.value) })}
          />
          <output>{settings.appFontSize.toFixed(1)}</output>
        </label>
        <p className="font-preview" style={{ fontSize: settings.appFontSize }}>
          预览：Claude Code · 会话列表 · 侧边栏
        </p>
      </section>
      <section className="original-settings-section">
        <h3>终端字号</h3>
        <label className="font-slider">
          字号
          <input
            type="range"
            aria-label="终端字号"
            min="9"
            max="22"
            step="0.5"
            value={settings.termFontSize}
            onChange={(event) => onChange({ termFontSize: Number(event.target.value) })}
          />
          <output>{settings.termFontSize.toFixed(1)}</output>
        </label>
      </section>
      <section className="original-settings-section">
        <h3>会话交互方式</h3>
        <div className="segmented" role="group" aria-label="会话交互方式">
          {[
            ['terminal', '原生终端'],
            ['structured', '结构化聊天'],
            ['chat', 'Swttch 图形聊天'],
          ].map(([value, label]) => (
            <button
              key={value}
              type="button"
              className={(settings.interactionMode ?? 'terminal') === value ? 'chosen' : ''}
              onClick={() => onChange({ interactionMode: value })}
            >
              {label}
            </button>
          ))}
        </div>
        <p>
          新会话的默认打开方式。结构化聊天直接驱动 Claude、Antigravity、Codex 的结构化协议；Swttch 使用应用自带的本地服务，仅支持 Claude。已有会话按各自记录打开，右键会话可单独切换。
        </p>
      </section>
      <section className="original-settings-section">
        <h3>会话与分支</h3>
        <label className="follow-session-setting">
          <span>打开会话时，Git 工作台跳到该会话的分支</span>
          <input
            type="checkbox"
            role="switch"
            aria-label="跟随会话分支"
            checked={settings.followSessionBranch}
            onChange={(event) => onChange({ followSessionBranch: event.target.checked })}
          />
        </label>
        <p>
          分支取自会话记录里最后的
          gitBranch。工作区干净且同仓库没有其它会话在运行时自动签出，否则只在 Git
          工作台顶部提示，不改动仓库。
        </p>
      </section>
      <section className="original-settings-section">
        <h3>工具服务</h3>
        <button className="settings-mcp-entry" onClick={onOpenMcp}>
          <PlugsConnected size={15} />
          查看和管理 MCP 服务
          <CaretRight size={13} />
        </button>
      </section>
      <div className="field" role="group" aria-label="信息密度">
        信息密度
        <div className="segmented">
          {[
            ['comfortable', '舒适'],
            ['compact', '紧凑'],
          ].map(([value, label]) => (
            <button
              key={value}
              type="button"
              className={settings.density === value ? 'chosen' : ''}
              onClick={() => onChange({ density: value })}
            >
              {label}
            </button>
          ))}
        </div>
      </div>
      {[
        ['sidebar', '显示项目侧栏'],
        ['terminal', '显示终端'],
        ['workbench', '显示工作台'],
      ].map(([key, label]) => (
        <label className="settings-row" key={key}>
          {label}
          <input
            type="checkbox"
            checked={settings[key]}
            onChange={(event) => onChange({ [key]: event.target.checked })}
          />
        </label>
      ))}
      <div className="modal-footer">
        <button className="primary" onClick={onClose}>
          完成
        </button>
      </div>
    </ModalFrame>
  );
}
