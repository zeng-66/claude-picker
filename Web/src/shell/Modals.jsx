// 弹窗：模型上下文 / MCP 服务 / 添加目录 / 新建会话 / 界面设置。
import React, { useCallback, useEffect, useState } from 'react';
import {
  ArrowsClockwise,
  CaretRight,
  FolderOpen,
  GitBranch,
  Plus,
  PlugsConnected,
  TreeStructure,
  Warning,
  X,
} from '@phosphor-icons/react';
import { errorText, request } from './bridge.js';
import { contextNumbers } from './Composer.jsx';
import { IconButton, tildePath } from './ui.jsx';

function ModalFrame({ title, wide = false, onClose, children }) {
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <section
        className={`modal ${wide ? 'information-dialog' : ''}`}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="modal-header">
          <h2>{title}</h2>
          <IconButton icon={X} label="关闭弹窗" onClick={onClose} />
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
    request('mcp.status', { projectPath }, { timeoutMs: 90000 })
      .then((result) => {
        const statuses = result?.statuses ?? result ?? {};
        setExtra(Array.isArray(result?.extra) ? result.extra : []);
        setStatus((current) => ({ ...current, ...statuses, loaded: true }));
      })
      .catch(() => setStatus((current) => ({ ...current, loaded: true })));
  }, [projectPath]);

  const load = useCallback(
    async (select) => {
      try {
        const list = await request('mcp.list', { projectPath });
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
    [projectPath],
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
    request('mcp.tools', { projectPath, id: selected.id }, { timeoutMs: 45000 })
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
      const result = await request(method, { projectPath, ...params }, { timeoutMs: 90000 });
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
    <ModalFrame title="MCP 服务" wide onClose={onClose}>
      <p className="modal-description">
        查看工具能力、连接状态与服务配置。连接状态由应用直接与服务握手检查；改动写入 Claude Code
        的配置文件，对新开的会话生效。
      </p>
      <div className="mcp-heading">
        <span>
          {connectedCount} / {allServers?.length ?? 0} 个服务已连接
          {!status.loaded ? ' · 正在检查连接…' : ''}
        </span>
        <button onClick={() => setAdding(!adding)}>
          <Plus size={14} />
          添加服务
        </button>
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
    <ModalFrame title="添加目录" onClose={onClose}>
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

export function SessionModal({
  project,
  home,
  branch,
  isRepository,
  initialMode,
  onClose,
  onCreated,
  notify,
}) {
  const [title, setTitle] = useState('');
  const [mode, setMode] = useState(isRepository ? initialMode : 'current');
  const [target, setTarget] = useState('feature/new-task');
  const [error, setError] = useState(null);
  const [creating, setCreating] = useState(false);
  const worktree = mode === 'worktree';
  const ready = Boolean(title.trim()) && (!worktree || Boolean(target.trim())) && !creating;

  async function create() {
    if (!ready) return;
    setCreating(true);
    setError(null);
    try {
      const result = await request(
        'session.create',
        {
          projectPath: project.path,
          title: title.trim(),
          mode,
          ...(worktree ? { branch: target.trim() } : {}),
        },
        { timeoutMs: 90000 },
      );
      notify(worktree ? `已在工作树 ${target.trim()} 中创建会话` : '会话已创建');
      onCreated(result);
      onClose();
    } catch (cause) {
      setError(errorText(cause));
      setCreating(false);
    }
  }

  return (
    <ModalFrame title="新建会话" onClose={onClose}>
      <p className="modal-description">在 {project.title} 中开始新的工作。</p>
      <label className="field">
        会话名称
        <input
          autoFocus
          placeholder="例如：优化订单列表"
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.nativeEvent.isComposing) create();
          }}
        />
      </label>
      <div className="mode-choice">
        {[
          ['current', '当前分支', GitBranch],
          ['worktree', '独立工作树', TreeStructure],
        ].map(([value, label, Icon]) => (
          <button
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
      </div>
      {worktree && (
        <label className="field">
          新分支名称
          <input value={target} onChange={(event) => setTarget(event.target.value)} />
        </label>
      )}
      <dl className="session-summary">
        <dt>项目</dt>
        <dd>{tildePath(project.path, home)}</dd>
        <dt>基准分支</dt>
        <dd>{branch ?? (isRepository ? 'detached HEAD' : '不是 Git 仓库')}</dd>
        <dt>工作目录</dt>
        <dd>{worktree ? `.worktrees/${worktreeSlug(target)}` : '项目根目录'}</dd>
        {worktree && (
          <>
            <dt>目标分支</dt>
            <dd>{target}</dd>
          </>
        )}
      </dl>
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
            ['chat', '图形聊天（实验）'],
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
          图形聊天使用 Swttch 界面和应用自带的本地服务，消息、工具审批都在第二栏里完成。切换时会结束另一种方式下运行中的会话（历史保留）。
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
