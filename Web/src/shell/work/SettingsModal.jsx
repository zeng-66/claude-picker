// 设置：界面与会话 / TAPD 连接 / 企业微信机器人 / MCP 服务 / 智能体能力。
// 界面偏好即时生效；连接类配置要点「保存」，有未保存修改时切页或关闭会先确认。
import React, { useEffect, useRef, useState } from 'react';
import {
  CaretRight,
  Cat,
  ChatCircleDots,
  CheckCircle,
  FolderOpen,
  Info,
  PlugsConnected,
  PuzzlePiece,
  Robot,
  SlidersHorizontal,
  SquaresFour,
  Warning,
  XCircle,
} from '@phosphor-icons/react';
import { errorText, isNative, request } from '../bridge.js';
import VersionUpdates from './VersionUpdates.jsx';
import { openExternal, relativeTime } from '../ui.jsx';
import { confirmAction } from './confirm.jsx';
import { DeepSeekStatus } from './DeepSeekMaintenance.jsx';
import { ModalFrame } from './WorkModals.jsx';
import { NavigationSettings } from '../ModuleViews.jsx';
import EngineIcon from '../EngineIcon.jsx';
import { PetSettings } from '../pet/PetSettings.jsx';

const PAGE_GROUPS = [
  ['偏好', [
    ['appearance', '界面与会话', SlidersHorizontal],
    ['cli', 'CLI 引擎', Robot],
    ['navigation', '顶部页签', SquaresFour],
    ['pet', '桌宠', Cat],
  ]],
  ['集成', [
    ['tapd', 'TAPD 连接', PlugsConnected],
    ['wecom', '企业微信机器人', ChatCircleDots],
    ['mcp', 'MCP 服务', PuzzlePiece],
  ]],
  ['应用', [
    ['agent', '智能体能力', Robot],
    ['updates', '版本更新', Info],
  ]],
];

/// 「可安装」目录：安装命令登记在原生端白名单里，这里只按 ID 触发，执行前展示完整命令并确认。
function Installables({ notify }) {
  const [items, setItems] = useState(null);
  const [busy, setBusy] = useState(null);
  const [log, setLog] = useState(null);
  const load = () => request('cli.installables', {}, { timeoutMs: 60000 }).then(setItems).catch((cause) => notify(errorText(cause), true));
  useEffect(() => { load(); }, []);
  async function install(item) {
    const ok = await confirmAction({
      title: `${item.path ? '重新安装' : '安装'} ${item.label}`,
      text: `将在本机执行官方安装命令：\n${item.install}\n安装脚本来自 ${item.homepage ?? '官方站点'}，会写入你的用户目录。`,
      confirmLabel: '执行安装',
      cancelLabel: '取消',
    });
    if (!ok) return;
    setBusy(item.id);
    setLog(null);
    try {
      const result = await request('cli.install', { id: item.id }, { timeoutMs: 660000 });
      setLog({ id: item.id, ...result });
      notify(result.ok ? `${item.label} 已安装：${result.version ?? result.path}` : `${item.label} 安装未完成`, !result.ok);
      load();
    } catch (cause) {
      notify(errorText(cause), true);
    } finally {
      setBusy(null);
    }
  }
  if (!items) return <p>正在读取可安装列表…</p>;
  return (
    <div className="cli-status-list">
      {items.map((item) => (
        <div key={item.id} className="cli-status-row installable-row">
          <div className="cli-engine-identity">
            <EngineIcon id={item.id} size={19} decorative />
            <div>
              <b>{item.label}</b>
              <code title={item.path || item.note}>
                {item.path ? `${item.command} · ${item.version ?? '已安装'}` : item.note}
              </code>
            </div>
          </div>
          {item.install && (
            <button type="button" disabled={busy != null} onClick={() => install(item)}>
              {busy === item.id ? '正在安装…' : item.path ? '重新安装 / 更新' : '安装'}
            </button>
          )}
          {item.homepage && (
            <button type="button" title={item.homepage} onClick={() => openExternal(item.homepage)}>文档</button>
          )}
          <small>{item.note}</small>
          {log?.id === item.id && !log.ok && <pre>{log.log}</pre>}
        </div>
      ))}
    </div>
  );
}

function CliEngines({ settings, providers, onChange, notify }) {
  const [refreshed, setRefreshed] = useState(null);
  const [refreshing, setRefreshing] = useState(false);
  const list = refreshed ?? providers;
  const preferences = settings.cliPreferences ?? {};
  const installed = list.filter((engine) => engine.path || engine.available);
  const available = installed.filter((engine) => engine.available && preferences[engine.id]?.enabled !== false);

  async function refresh() {
    setRefreshing(true);
    try {
      const snapshot = await request('app.state');
      setRefreshed(snapshot.providers ?? []);
    } catch (error) {
      notify(errorText(error), true);
    } finally {
      setRefreshing(false);
    }
  }

  return (
    <div className="connection-settings">
      <h3>CLI 引擎</h3>
      <section className="settings-card" aria-label="会话默认设置">
        <h4>会话默认设置</h4>
      <div className="field" role="group" aria-label="新会话的默认打开方式">
        打开方式
        <div className="segmented settings-mode-options">
          {[
            ['terminal', '原生终端'],
            ['structured', '结构化聊天'],
            ['chat', 'Swttch 图形聊天'],
          ].map(([value, label]) => (
            <button
              key={value}
              type="button"
              className={(settings.interactionMode ?? 'terminal') === value ? 'chosen' : ''}
              aria-pressed={(settings.interactionMode ?? 'terminal') === value}
              onClick={() => onChange({ interactionMode: value })}
            >
              {label}
            </button>
          ))}
        </div>
        <small>
          用于新会话及尚未记录打开方式的旧会话。右键会话可切换界面，切换会结束当前回合。引擎不支持所选方式时使用终端。
        </small>
      </div>
      <label className="field">默认新会话引擎 <select
          value={available.some((engine) => engine.id === settings.defaultProvider) ? settings.defaultProvider : ''}
          onChange={(event) => onChange({ defaultProvider: event.target.value })}>
          <option value="" disabled>请选择可用引擎</option>
          {available.map((engine) => <option key={engine.id} value={engine.id}>{engine.label}</option>)}
        </select>
      </label>
      </section>
      <section className="settings-card" aria-label="Claude 提示缓存">
        <h4>Claude 提示缓存</h4>
        <label className="follow-session-setting">
          <span>显示缓存倒计时（估算）</span>
          <input type="checkbox" role="switch" checked={settings.promptCacheEnabled !== false}
            onChange={(event) => onChange({ promptCacheEnabled: event.target.checked })} />
        </label>
        <label className="field">缓存时长 <select value={settings.promptCacheMinutes ?? 5}
          disabled={settings.promptCacheEnabled === false}
          onChange={(event) => onChange({ promptCacheMinutes: Number(event.target.value) })}>
          {[5, 10, 15, 30, 60].map((minutes) => <option key={minutes} value={minutes}>{minutes} 分钟</option>)}
        </select></label>
      </section>
      <section className="settings-card" aria-label="已安装的引擎">
      <div className="settings-card-header">
        <h4>已安装的引擎</h4>
        <button type="button" disabled={refreshing} onClick={refresh}>{refreshing ? '检测中…' : '重新检测'}</button>
      </div>
      <div className="cli-status-list">
        {installed.map((engine) => <div key={engine.id} className="cli-status-row">
          <div className="cli-engine-identity">
            <EngineIcon id={engine.id} size={19} decorative />
            <div>
              <b>{engine.label}</b>{settings.defaultProvider === engine.id && <span className="cli-engine-default">默认</span>}
              <code title={engine.path}>
                <i className={`cli-engine-state ${engine.available ? 'green' : 'red'}`} aria-hidden="true" />
                {engine.command} · {engine.status ?? (engine.available ? '可启动' : '不可用')}
              </code>
            </div>
          </div>
          <label className="cli-engine-enabled">
            <input type="checkbox" role="switch" aria-label={`启用 ${engine.label}`}
              checked={preferences[engine.id]?.enabled !== false}
              onChange={(event) => {
                const enabled = event.target.checked;
                const patch = { cliPreferences: { ...preferences, [engine.id]: { ...preferences[engine.id], enabled } } };
                if (!enabled && settings.defaultProvider === engine.id) {
                  const fallback = available.find((candidate) => candidate.id !== engine.id);
                  if (fallback) patch.defaultProvider = fallback.id;
                }
                onChange(patch);
              }} />
            启用
          </label>
          <select aria-label={`${engine.label} 的新会话打开方式`}
            value={preferences[engine.id]?.mode ?? 'inherit'}
            onChange={(event) => onChange({
              cliPreferences: { ...preferences, [engine.id]: { ...preferences[engine.id], mode: event.target.value } },
            })}>
            <option value="inherit">跟随默认</option>
            {(preferences[engine.id]?.modes ?? ['terminal']).map((mode) => (
              <option key={mode} value={mode}>{MODE_LABEL[mode] ?? mode}</option>
            ))}
          </select>
        </div>)}
        {!installed.length && <p>未检测到可执行文件</p>}
      </div>
      </section>
      <section className="settings-card" aria-label="引擎维护">
      <h4>DeepSeek Harness 维护</h4>
      <label className="follow-session-setting">
        <span>启动时与每 6 小时检查 DeepSeek 新版本和环境，有问题时提示升级</span>
        <input type="checkbox" role="switch" checked={settings.deepseekAutoCheck !== false}
          onChange={(event) => onChange({ deepseekAutoCheck: event.target.checked })} />
      </label>
      <DeepSeekStatus notify={notify} />
      </section>
      <section className="settings-card" aria-label="可安装引擎和会话扫描">
      <h4>可安装</h4>
      {list.filter((engine) => !installed.includes(engine)).map((engine) => (
        <div className="cli-engine-identity" key={engine.id}>
          <EngineIcon id={engine.id} size={19} decorative />
          <div><b>{engine.label}</b><code>{engine.command} · {engine.status ?? '未安装'}</code></div>
        </div>
      ))}
      <Installables notify={notify} />
      <label className="follow-session-setting">
        <span>扫描 Antigravity 历史会话</span>
        <input type="checkbox" role="switch" checked={settings.scanAntigravity !== false}
          onChange={(event) => onChange({ scanAntigravity: event.target.checked })} />
      </label>
      </section>
    </div>
  );
}

function Appearance({ settings, capacity, onChange, notify }) {
  const [slots, setSlots] = useState(capacity.slots);
  useEffect(() => setSlots(capacity.slots), [capacity.slots]);
  return (
    <>
      <h3>界面与会话</h3>
      <p>这些偏好即时生效，不影响正在执行的 Work。</p>
      <label className="font-slider">
        界面字号
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
      <label className="font-slider">
        终端字号
        <input
          type="range"
          aria-label="终端字号（只影响原生终端）"
          min="9"
          max="22"
          step="0.5"
          value={settings.termFontSize}
          onChange={(event) => onChange({ termFontSize: Number(event.target.value) })}
        />
        <output>{settings.termFontSize.toFixed(1)}</output>
      </label>
      <div className="field" role="group" aria-label="默认布局">
        默认布局
        <div className="segmented">
          {[
            ['A', '工作空间'],
            ['B', '任务看板'],
            ['C', '专注对话'],
          ].map(([value, label]) => (
            <button
              key={value}
              type="button"
              className={(settings.layout ?? 'A') === value ? 'chosen' : ''}
              onClick={() => onChange({ layout: value, contextOpen: value !== 'C' })}
            >
              {label}
            </button>
          ))}
        </div>
        <small>工作空间：会话 + 详情；任务看板：启动时先看 Work 中心；专注对话：详情默认收起、会话居中。</small>
      </div>
      <div className="field">
        同时执行的 Work 数量
        <div className="slots-row">
          <input
            type="number"
            min="1"
            max="8"
            aria-label="同时执行的 Work 数量"
            value={slots}
            onChange={(event) => setSlots(Number(event.target.value))}
          />
          <button
            disabled={slots === capacity.slots || !(slots >= 1 && slots <= 8)}
            onClick={() =>
              request('work.settings', { slots })
                .then(() => notify(`执行槽已设为 ${slots}`))
                .catch((cause) => notify(errorText(cause), true))
            }
          >
            保存
          </button>
        </div>
        <small>超过这个数量的 Work 会排队。等待回答或审阅的 Work 不占执行槽。</small>
      </div>
      <label className="follow-session-setting">
        <span>打开会话时，Git 工作台跟随该会话的分支</span>
        <input
          type="checkbox"
          role="switch"
          aria-label="跟随会话分支"
          checked={settings.followSessionBranch}
          onChange={(event) => onChange({ followSessionBranch: event.target.checked })}
        />
      </label>
      <small className="setting-hint">工作区干净且同仓库没有其它会话在运行时才自动签出，否则只提示，不改动仓库。</small>
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
    </>
  );
}

function SecretField({ label, saved, placeholder, onSave, onClear, hint }) {
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  async function save() {
    if (!value.trim() || busy) return;
    setBusy(true);
    setError(null);
    try {
      await onSave(value.trim());
      setValue('');
    } catch (cause) {
      setError(errorText(cause)); // 输入保留，便于改正
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="field">
      {label}
      <div className="slots-row">
        <input
          type="password"
          autoComplete="off"
          aria-label={label}
          style={{ flex: 1 }}
          placeholder={saved ? '已保存在钥匙串（输入新值可替换）' : placeholder}
          value={value}
          onChange={(event) => setValue(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.nativeEvent.isComposing) save();
          }}
        />
        <button disabled={!value.trim() || busy} onClick={save}>
          {busy ? '保存中…' : saved ? '替换' : '保存'}
        </button>
        {saved && onClear && (
          <button
            onClick={async () => {
              if (
                await confirmAction({
                  title: `清除${label}？`,
                  text: '会从钥匙串里删除，之后需要重新填写。',
                  confirmLabel: '清除',
                  danger: true,
                })
              )
                onClear();
            }}
          >
            清除
          </button>
        )}
      </div>
      {hint && <small>{hint}</small>}
      {error && <small className="field-error">{error}</small>}
    </div>
  );
}

const MCP_STAGE = {
  input: '项目 ID',
  credential: '凭据',
  launch: '启动服务',
  handshake: 'MCP 握手',
  tools: '工具发现',
  project: '项目试读',
  saved: '已保存',
};

/// TAPD MCP 一键配置：握手、工具发现、逐项目只读试读，全部通过才保存。
function TapdMcpSetup({ info, dirty, onSaved, notify }) {
  const [ids, setIds] = useState('');
  const [token, setToken] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null);
  const [refreshError, setRefreshError] = useState(null);
  const [refreshing, setRefreshing] = useState(false);
  const demo = import.meta.env.DEV && !isNative() && new URLSearchParams(location.search).has('review');
  const [scenario, setScenario] = useState('success');
  const pre = info.prerequisites;
  const server = info.settings.mcp;
  const [command, setCommand] = useState(server?.command ?? 'uvx');
  const [args, setArgs] = useState((server?.args ?? ['--from', pre.mcpPackage ?? 'mcp-server-tapd', 'mcp-server-tapd']).join('\n'));
  const [webBase, setWebBase] = useState(server?.webBase ?? 'https://www.tapd.cn');
  const serverTouched = useRef(false);
  const canVerify = !dirty && !busy && !refreshError && ids.trim() && (pre.tokenSet || token.trim()) && command.trim();

  async function refreshSettings() {
    setRefreshing(true);
    try {
      await onSaved();
      setRefreshError(null);
    } catch (cause) {
      setRefreshError(errorText(cause));
    } finally {
      setRefreshing(false);
    }
  }

  async function run() {
    if (!canVerify) return;
    setBusy(true);
    setResult(null);
    try {
      const outcome = await request(
        'tapd.mcpSetup',
        {
          workspaceIds: ids,
          ...(demo ? { demoScenario: scenario } : {}),
          ...(token.trim() ? { token: token.trim() } : {}),
          ...(serverTouched.current ? {
            server: { command: command.trim(), args: args.split('\n').map((arg) => arg.trim()).filter(Boolean), webBase: webBase.trim() },
          } : {}),
        },
        { timeoutMs: 240000 },
      );
      setResult(outcome);
      if (outcome.ok) {
        setToken('');
        setIds('');
        notify(outcome.message);
        serverTouched.current = false;
        await refreshSettings();
      }
    } catch (cause) {
      setResult({ ok: false, stage: 'launch', message: errorText(cause) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="settings-card tapd-mcp-setup" aria-label="MCP 配置">
      <div className="settings-card-header">
        <h4>MCP 配置</h4>
        <span className="pill neutral">默认连接方式</span>
      </div>
      <div className="tapd-connection-summary">
        <code>{pre.mcpPackage}</code>
        <span>本地 stdio · {pre.mcpCommand ? '启动命令可用' : '检查 uvx 或配置启动命令'}</span>
        <span>{pre.tokenSet ? '已配置令牌' : '待配置令牌'}</span>
      </div>
      <p>
        填写 TAPD 项目链接中的数字 ID 和具备项目读取权限的个人令牌。应用会启动 MCP、发现工具并逐个试读项目，通过后保存并启用 MCP。
      </p>
      <label className="field">
        项目 ID
        <textarea rows={2} disabled={busy} value={ids} placeholder="例如 20355782, 69850123" onChange={(event) => setIds(event.target.value)} />
        <small>可用换行、空格或逗号分隔多个 ID。</small>
      </label>
      <label className="field">
        TAPD 个人令牌
        <input type="password" autoComplete="off" disabled={busy} value={token} placeholder={pre.tokenSet ? '留空沿用已有令牌' : '在 TAPD「个人设置 → 个人令牌」里生成'}
          onChange={(event) => setToken(event.target.value)} />
      </label>
      <details className="settings-disclosure">
        <summary>MCP 启动设置</summary>
        <fieldset className="settings-fieldset" disabled={busy} onChange={() => { serverTouched.current = true; }}>
          <label className="field">启动命令<input value={command} onChange={(event) => setCommand(event.target.value)} /></label>
          <label className="field">启动参数（每行一项）
            <textarea rows={3} value={args} onChange={(event) => setArgs(event.target.value)} />
          </label>
          <label className="field">TAPD 网页地址
            <input type="url" value={webBase} onChange={(event) => setWebBase(event.target.value)} />
          </label>
        </fieldset>
      </details>
      {demo && (
        <label className="field">
          演示连接结果
          <select value={scenario} disabled={busy} onChange={(event) => setScenario(event.target.value)}>
            <option value="success">验证成功</option>
            <option value="handshake">MCP 握手失败</option>
            <option value="project">项目试读失败</option>
          </select>
        </label>
      )}
      <div className="settings-card-header">
        <small>{dirty ? '请先保存或放弃其他 TAPD 设置。' : info.settings.mcpCheckedAt ? `最近验证 ${new Date(info.settings.mcpCheckedAt).toLocaleString()}` : ''}</small>
        <button className="primary" disabled={!canVerify} onClick={run}>
          {busy ? (demo ? '正在验证…' : '正在验证…（首次需下载服务）') : result?.ok === false ? '重新验证并保存' : '验证并保存'}
        </button>
      </div>
      {busy && <p className="setting-hint" role="status">正在检查 MCP 服务和项目读取权限…</p>}
      {refreshError && (
        <div className="pane-note error" role="alert">
          <span>配置已保存，读取最新设置失败。{refreshError}</span>
          <button disabled={refreshing} onClick={refreshSettings}>{refreshing ? '读取中…' : '重新读取'}</button>
        </div>
      )}
      {result && (
        <div className={`pane-note ${result.ok ? '' : 'error'}`} role={result.ok ? 'status' : 'alert'}>
          {result.ok ? <CheckCircle size={14} className="green" /> : <XCircle size={14} className="red" />}
          <div>
            <b>{MCP_STAGE[result.stage] ?? result.stage}：{result.message}</b>
            {result.detail && <small> {result.detail}</small>}
            {!result.ok && <small> 原有配置未改动，修正后可重试。</small>}
            {(result.projects ?? []).length > 0 && (
              <ul>
                {result.projects.map((item) => (
                  <li key={item.id}>
                    {item.ok ? '✓' : '✗'} {item.id}
                    {item.name ? ` · ${item.name}` : ''}
                    {item.message ? ` · ${item.message}` : ''}
                  </li>
                ))}
              </ul>
            )}
            {(result.scenarios ?? []).length > 0 && <McpScenarios scenarios={result.scenarios} />}
          </div>
        </div>
      )}
    </section>
  );
}

function McpScenarios({ scenarios }) {
  return (
    <div className="mcp-scenarios">
      {scenarios.map((item) => (
        <span key={item.id} className={`pill ${item.available ? 'neutral' : 'red'}`}
          title={item.available ? '服务提供所需工具' : `缺少工具：${item.missing.join('、')}`}>
          {item.available ? '✓' : '✗'} {item.label}{item.write ? '（写）' : ''}
        </span>
      ))}
    </div>
  );
}

function Tapd({ projects, notify, onDirty }) {
  const [info, setInfo] = useState(null);
  const [form, setForm] = useState(null);
  const [test, setTest] = useState(null);
  const [testing, setTesting] = useState(false);
  const [loadingWorkspaces, setLoadingWorkspaces] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    request('tapd.settings')
      .then((result) => {
        setInfo(result);
        setForm(result.settings);
      })
      .catch((cause) => setError(errorText(cause)));
  }, []);

  const dirty = Boolean(info && form && JSON.stringify(form) !== JSON.stringify(info.settings));
  useEffect(() => onDirty(dirty), [dirty]);

  async function save() {
    setSaving(true);
    setError(null);
    try {
      const result = await request('tapd.settings', { patch: form });
      setInfo(result); // 以回读的值为准
      setForm(result.settings);
      notify('TAPD 连接设置已保存');
    } catch (cause) {
      setError(errorText(cause)); // 失败时保留表单
    } finally {
      setSaving(false);
    }
  }

  async function runTest() {
    setTesting(true);
    setTest(null);
    try {
      setTest(await request('tapd.test', {}, { timeoutMs: 90000 }));
    } catch (cause) {
      setTest({ connected: false, message: errorText(cause) });
    } finally {
      setTesting(false);
    }
  }

  async function loadWorkspaces() {
    setLoadingWorkspaces(true);
    setError(null);
    try {
      const result = await request('tapd.workspaces', {}, { timeoutMs: 90000 });
      setForm((current) => {
        const known = new Map((current.workspaces ?? []).map((item) => [item.id, item]));
        return {
          ...current,
          workspaces: result.workspaces.map((item) => ({
            id: item.id,
            name: item.name,
            enabled: known.get(item.id)?.enabled ?? false,
            projects: known.get(item.id)?.projects ?? [],
          })),
        };
      });
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setLoadingWorkspaces(false);
    }
  }

  if (!form) return error ? <div className="pane-note error">{error}</div> : <div className="pane-note">正在读取…</div>;
  const pre = info.prerequisites;
  const updateWorkspace = (id, patch) =>
    setForm((current) => ({
      ...current,
      workspaces: current.workspaces.map((item) => (item.id === id ? { ...item, ...patch } : item)),
    }));

  return (
    <div className="connection-settings">
      <h3>TAPD 连接</h3>
      <p>{isNative() ? '通过 TAPD MCP 读取分配给你的待办。桌面版将个人令牌保存在 macOS 钥匙串。' : '浏览器使用演示数据验证连接流程，请使用示例令牌。'}</p>
      <TapdMcpSetup
        info={info}
        dirty={dirty}
        notify={notify}
        onSaved={() =>
          request('tapd.settings').then((result) => {
            setInfo(result);
            setForm(result.settings);
          })
        }
      />
      <section className="settings-card" aria-label="TAPD 待办与项目">
      <div className="settings-card-header">
        <h4>待办与项目</h4>
        <label className="check-option">
          <input type="checkbox" role="switch" checked={form.enabled === true} onChange={(event) => setForm({ ...form, enabled: event.target.checked })} />
          启用 TAPD 待办
        </label>
      </div>
      <p>选择要显示待办的 TAPD 项目，并登记导入时可选的本地仓库。</p>
      <button disabled={loadingWorkspaces} onClick={loadWorkspaces}>
        {loadingWorkspaces ? '正在读取…' : form.workspaces?.length ? '重新读取我参与的项目' : '读取我参与的项目'}
      </button>
      {(form.workspaces ?? []).map((item) => (
        <div className="workspace-row" key={item.id}>
          <label className="check-option">
            <input type="checkbox" checked={item.enabled !== false}
              onChange={(event) => updateWorkspace(item.id, { enabled: event.target.checked })} />
            <b>{item.name}</b><code>{item.id}</code>
          </label>
          <div className="mapping-chips">
            {(item.projects ?? []).map((path) => {
              const project = projects.find((entry) => entry.path === path);
              return (
                <span className={`pill ${project ? 'neutral' : 'red'}`} key={path} title={path}>
                  {project?.title ?? '目录已不在列表'}
                  <button aria-label={`移除映射 ${project?.title ?? path}`}
                    onClick={() => updateWorkspace(item.id, { projects: item.projects.filter((entry) => entry !== path) })}>×</button>
                </span>
              );
            })}
            <select aria-label={`为 ${item.name} 添加本地项目`} value=""
              onChange={(event) => {
                const path = event.target.value;
                if (path && !(item.projects ?? []).includes(path))
                  updateWorkspace(item.id, { projects: [...(item.projects ?? []), path] });
              }}>
              <option value="">添加映射…</option>
              {projects.filter((project) => !(item.projects ?? []).includes(project.path)).map((project) => (
                <option key={project.path} value={project.path}>{project.title}</option>
              ))}
            </select>
          </div>
        </div>
      ))}
      <label className="check-option">
        <input type="checkbox" checked={form.syncOnLaunch !== false}
          onChange={(event) => setForm({ ...form, syncOnLaunch: event.target.checked })} />
        打开「TAPD 待办」时读取我的待办
      </label>
      <div className="static-rule">
        <CheckCircle size={14} className="green" />
        回填先预览，经确认后添加评论。
      </div>
      </section>
      <details className="settings-card settings-disclosure">
      <summary>兼容设置 · tapd-cli</summary>
      <p>按编号查询和「已创建」可以使用本机的 tapd-cli。</p>
      <label className="field">待办读取方式
        <select value={form.transport ?? 'mcp'} onChange={(event) => setForm({ ...form, transport: event.target.value })}>
          <option value="mcp" disabled={!form.mcpCheckedAt}>MCP（默认）</option>
          <option value="cli">tapd-cli</option>
        </select>
      </label>
      <div className="prereq-list">
        <div>
          {pre.cli ? <CheckCircle size={14} className="green" /> : <XCircle size={14} className="red" />}
          tapd-cli：{pre.cli ?? '没有找到'}
        </div>
        <div>
          {pre.tokenSet ? <CheckCircle size={14} className="green" /> : <XCircle size={14} className="red" />}
          个人令牌：
          {pre.tokenSource === 'keychain'
            ? '已保存在钥匙串'
            : pre.tokenSource === 'env'
              ? '使用登录 shell 的 TAPD_TOKEN'
              : '未设置'}
        </div>
        <div>
          <CheckCircle size={14} className="green" />
          API 地址：{pre.endpoint}
        </div>
      </div>
      <SecretField
        label="TAPD 个人令牌"
        saved={pre.tokenSource === 'keychain'}
        placeholder="在 TAPD「个人设置 → 个人令牌」里生成"
        hint="保存后优先使用这里的令牌；清除后回到登录 shell 的 TAPD_TOKEN（如果有）。"
        onSave={async (token) => {
          const result = await request('tapd.setToken', { token });
          setInfo((current) => ({ ...current, prerequisites: result.prerequisites }));
          setTest(null);
          notify('TAPD 令牌已保存到钥匙串');
        }}
        onClear={async () => {
          const result = await request('tapd.clearToken');
          setInfo((current) => ({ ...current, prerequisites: result.prerequisites }));
          setTest(null);
        }}
      />
      <label className="field">
        API 地址（留空使用 https://api.tapd.cn）
        <input
          value={form.endpoint ?? ''}
          placeholder="https://api.tapd.cn"
          onChange={(event) => setForm({ ...form, endpoint: event.target.value })}
        />
      </label>
      <label className="field">
        tapd-cli 路径（留空自动查找）
        <input
          value={form.cliPath ?? ''}
          placeholder="~/.local/bin/tapd-cli"
          onChange={(event) => setForm({ ...form, cliPath: event.target.value })}
        />
      </label>
      <div className="settings-inline">
        <button disabled={testing || dirty} title={dirty ? '先保存修改再测试' : ''} onClick={runTest}>
          {testing ? '正在测试…' : '测试连接'}
        </button>
        {test &&
          (test.connected ? (
            <span className="green">
              <CheckCircle size={14} /> 已连接：
              {test.user ? `${test.user.name}（${test.user.nick}）` : `TAPD MCP ${test.server?.name ?? ''} ${test.server?.version ?? ''}`}
            </span>
          ) : (
            <span className="red">
              <XCircle size={14} /> {test.message}
              {test.detail ? `：${test.detail}` : ''}
            </span>
          ))}
        {test?.scenarios && <McpScenarios scenarios={test.scenarios} />}
      </div>
      </details>
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      <div className="settings-actions">
        <button disabled={!dirty || saving} onClick={() => setForm(info.settings)}>
          放弃修改
        </button>
        <button className="primary" disabled={!dirty || saving} onClick={save}>
          {saving ? '正在保存…' : '保存'}
        </button>
      </div>
    </div>
  );
}

const BOT_STATE = {
  connected: ['已连接', 'green'],
  connecting: ['连接中', 'blue'],
  auth_failed: ['认证失败', 'red'],
  kicked: ['已被顶替', 'amber'],
  error: ['连接中断', 'amber'],
  disabled: ['未连接', 'neutral'],
};

const lines = (text) => text.split(/[\n,，、;；\s]+/).map((item) => item.trim()).filter(Boolean);

/// 单个机器人的编辑表单：凭据、模式、默认 CLI 与生效范围（人员 / 场景 / 项目三项交集）。
function WecomBotEditor({ bot, catalog, notify, onSaved, onDeleted }) {
  const [form, setForm] = useState(bot);
  const [users, setUsers] = useState((bot.scope?.users ?? []).join('\n'));
  const [initiators, setInitiators] = useState((bot.scope?.initiators ?? []).join('\n'));
  const [deciders, setDeciders] = useState((bot.scope?.deciders ?? []).join('\n'));
  const [groups, setGroups] = useState((bot.scope?.groups ?? []).map((group) => `${group.chatId} ${group.name ?? ''}`.trim()).join('\n'));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const scope = form.scope ?? {};
  const setScope = (patch) => setForm((current) => ({ ...current, scope: { ...(current.scope ?? {}), ...patch } }));
  const status = bot.status;

  async function save() {
    setBusy(true);
    setError(null);
    try {
      const payload = {
        ...form,
        scope: {
          ...scope,
          users: lines(users),
          initiators: scope.initiators == null ? null : lines(initiators),
          deciders: lines(deciders),
          groups: groups.split('\n').map((line) => line.trim()).filter(Boolean).map((line) => {
            const [chatId, ...rest] = line.split(/\s+/);
            return { chatId, name: rest.join(' ') || chatId };
          }),
        },
      };
      await request('source.saveBot', { bot: payload });
      notify(`已保存「${form.name}」`);
      onSaved();
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="wecom-bot-editor">
      <div className="robot-connection">
        <div>
          <PlugsConnected size={15} />
          <b>{form.name || '新机器人'}</b>
          <small>{status?.message ?? (status?.state === 'connected' ? '收发消息正常' : '启用并保存 Secret 后自动连接')}</small>
        </div>
        <span className={`pill ${BOT_STATE[status?.state]?.[1] ?? 'neutral'}`}>{BOT_STATE[status?.state]?.[0] ?? '未连接'}</span>
        {bot.id && (
          <button disabled={!bot.enabled || !bot.botId || !bot.secretSaved}
            onClick={() => request('source.reconnectBot', { id: bot.id }).then(() => notify('正在重新连接…'))}>
            重新连接
          </button>
        )}
      </div>
      <div className="cli-worktree-grid">
        <label className="field">名称<input value={form.name ?? ''} onChange={(event) => setForm({ ...form, name: event.target.value })} /></label>
        <label className="field">Bot ID<input value={form.botId ?? ''} autoComplete="off" onChange={(event) => setForm({ ...form, botId: event.target.value })} /></label>
        <label className="field">企业 ID（可选）<input value={form.corpId ?? ''} autoComplete="off" onChange={(event) => setForm({ ...form, corpId: event.target.value })} /></label>
        <label className="field">对话模式
          <select value={form.mode ?? 'chat'} onChange={(event) => setForm({ ...form, mode: event.target.value })}>
            <option value="chat">直接对话</option>
            <option value="work">创建和跟进 Work</option>
          </select>
        </label>
        <label className="field">默认 CLI（只影响新绑定）
          <select value={form.defaultCli ?? 'claude'} disabled={form.mode === 'work'}
            onChange={(event) => setForm({ ...form, defaultCli: event.target.value })}>
            {catalog.engines.map((engine) => <option key={engine.id} value={engine.id}>{engine.label}</option>)}
          </select>
        </label>
        <label className="check-option">
          <input type="checkbox" checked={form.enabled === true} onChange={(event) => setForm({ ...form, enabled: event.target.checked })} />
          启用
        </label>
      </div>
      {bot.id && (
        <SecretField
          label="Secret"
          saved={Boolean(bot.secretSaved)}
          placeholder="企业微信管理后台 → 智能机器人 → 获取 Secret"
          hint="每个机器人的 Secret 单独保存在钥匙串。同一组凭据只能由一处连接持有，在别处连接时这里会被顶替且不自动重连。"
          onSave={async (secret) => {
            await request('source.setBotSecret', { id: bot.id, secret });
            notify('Secret 已保存到钥匙串');
            onSaved();
          }}
          onClear={() => request('source.clearBotSecret', { id: bot.id }).then(onSaved)}
        />
      )}
      <h4>生效范围（三项同时满足才处理，空集合一律拒绝）</h4>
      <label className="check-option">
        <input type="checkbox" checked={scope.allUsers === true} onChange={(event) => setScope({ allUsers: event.target.checked })} />
        全部人员
      </label>
      {!scope.allUsers && (
        <label className="field">使用者 userid（可以对话；换行或逗号分隔）
          <textarea rows={2} value={users} onChange={(event) => setUsers(event.target.value)} />
        </label>
      )}
      <h4>角色组</h4>
      <label className="check-option">
        <input type="checkbox" checked={scope.initiators == null}
          onChange={(event) => setScope({ initiators: event.target.checked ? null : lines(initiators) })} />
        所有使用者都可以发起 Work
      </label>
      {scope.initiators != null && (
        <label className="field">任务发起人 userid（可创建、追加 Work）
          <textarea rows={2} value={initiators} onChange={(event) => setInitiators(event.target.value)} />
        </label>
      )}
      <label className="field">拍板人 userid（除发起人外，也可以在决策卡上做决定）
        <textarea rows={2} value={deciders} onChange={(event) => setDeciders(event.target.value)} />
      </label>
      <small className="setting-hint">
        同一条群消息同时 @ 了多个机器人时，按列表顺序由第一个有权限的机器人处理，其余回复由谁处理。拍板卡 30 分钟内有效，Work 确认卡 24 小时内有效。
      </small>
      <h4>场景</h4>
      <label className="check-option">
        <input type="checkbox" checked={scope.single === true} onChange={(event) => setScope({ single: event.target.checked })} />
        接受私聊
      </label>
      <label className="check-option">
        <input type="checkbox" checked={scope.allGroups === true} onChange={(event) => setScope({ allGroups: event.target.checked })} />
        全部群聊
      </label>
      {!scope.allGroups && (
        <label className="field">指定群聊（每行「群 chatid 名称」，名称仅用于展示）
          <textarea rows={2} value={groups} onChange={(event) => setGroups(event.target.value)} />
        </label>
      )}
      <label className="check-option">
        <input type="checkbox" checked={scope.allProjects === true} onChange={(event) => setScope({ allProjects: event.target.checked })} />
        全部已登记项目
      </label>
      {!scope.allProjects && (
        <div className="mapping-chips">
          {catalog.projects.map((project) => {
            const on = (scope.projects ?? []).includes(project.id);
            return (
              <label className="check-option" key={project.id} title={project.path}>
                <input type="checkbox" checked={on} onChange={() => setScope({
                  projects: on ? scope.projects.filter((id) => id !== project.id) : [...(scope.projects ?? []), project.id],
                })} />
                {project.name}
              </label>
            );
          })}
        </div>
      )}
      <small className="setting-hint">
        只选一个项目时，直接对话在该项目目录进行；多个项目时由对话说明目标。会话按企业 / 机器人 / 私聊或群聊 / 发送人 / 项目分别续聊。
        单选问题会推送待拍板卡片，也可以回复编号。
      </small>
      {error && <div className="pane-note error" role="alert"><Warning size={14} />{error}</div>}
      <div className="settings-actions">
        {bot.id && (
          <button onClick={() => request('source.deleteBot', { id: bot.id }).then(() => { notify('已删除'); onDeleted(); })}>
            删除机器人
          </button>
        )}
        <button className="primary" disabled={busy} onClick={save}>{busy ? '正在保存…' : '保存机器人'}</button>
      </div>
    </div>
  );
}

function WecomBots({ notify }) {
  const [catalog, setCatalog] = useState(null);
  const [selected, setSelected] = useState(null);
  const [error, setError] = useState(null);
  const load = () => request('source.bots').then(setCatalog).catch((cause) => setError(errorText(cause)));
  useEffect(() => {
    load();
    const timer = window.setInterval(load, 4000);
    return () => window.clearInterval(timer);
  }, []);
  if (!catalog) return error ? <div className="pane-note error">{error}</div> : null;
  const current = selected === 'new'
    ? { name: '新机器人', enabled: false, mode: 'chat', defaultCli: 'claude', scope: {} }
    : catalog.bots.find((bot) => bot.id === selected);
  return (
    <div className="wecom-bots">
      <h4>机器人列表</h4>
      {!catalog.migrated && catalog.bots.length > 0 && (
        <small className="setting-hint">保存任一机器人后，上方的单机器人设置会迁移为列表中的一项，原有 Secret 与行为保持不变。</small>
      )}
      <div className="mapping-chips">
        {catalog.bots.map((bot) => (
          <button key={bot.id} className={selected === bot.id ? 'chosen' : ''} onClick={() => setSelected(bot.id)}>
            <span className={`pill ${BOT_STATE[bot.status?.state]?.[1] ?? 'neutral'}`}>{BOT_STATE[bot.status?.state]?.[0] ?? '—'}</span>
            {bot.name}
          </button>
        ))}
        <button onClick={() => setSelected('new')}>新增机器人</button>
      </div>
      {current && (
        <WecomBotEditor
          key={selected}
          bot={current}
          catalog={catalog}
          notify={notify}
          onSaved={() => { load(); if (selected === 'new') setSelected(null); }}
          onDeleted={() => { setSelected(null); load(); }}
        />
      )}
    </div>
  );
}

function Wecom({ notify, onDirty, onOpenConversations }) {
  const [overview, setOverview] = useState(null);
  const [bot, setBot] = useState(null);
  const [form, setForm] = useState(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  function load() {
    request('source.overview')
      .then((result) => {
        setOverview(result);
        setForm((current) => current ?? result.settings);
      })
      .catch((cause) => setError(errorText(cause)));
  }
  useEffect(() => {
    load();
    const poll = () => request('source.botStatus').then(setBot).catch(() => {});
    poll();
    const timer = window.setInterval(poll, 2500);
    return () => window.clearInterval(timer);
  }, []);

  const dirty = Boolean(overview && form && JSON.stringify(form) !== JSON.stringify(overview.settings));
  useEffect(() => onDirty(dirty), [dirty]);
  const nameError = form && !(form.name.trim().length >= 1 && form.name.trim().length <= 50) ? '名称需为 1–50 个字符' : null;

  async function save() {
    if (nameError) return;
    setSaving(true);
    setError(null);
    try {
      const saved = await request('source.settings', { patch: form });
      setOverview((current) => ({ ...current, settings: saved })); // 回读保存后的值
      setForm(saved);
      notify('机器人配置已保存');
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setSaving(false);
    }
  }

  if (!form) return error ? <div className="pane-note error">{error}</div> : <div className="pane-note">正在读取…</div>;
  return (
    <>
      <div className="robot-heading">
        <div className="robot-logo">
          <ChatCircleDots size={20} />
        </div>
        <div>
          <h3>企业微信机器人</h3>
          <p>直接在企业微信与 Claude 连续对话，处理项目任务。</p>
        </div>
      </div>
      <div className="robot-connection">
        <div>
          <PlugsConnected size={15} />
          <b>智能机器人长连接</b>
          <small>{bot?.message ?? (bot?.state === 'connected' ? '收发消息正常' : '保存 Bot ID 与 Secret 并启用后自动连接')}</small>
        </div>
        <span className={`pill ${BOT_STATE[bot?.state]?.[1] ?? 'neutral'}`}>{BOT_STATE[bot?.state]?.[0] ?? '—'}</span>
        <button
          disabled={!form.enabled || !form.botId || !bot?.secretSaved}
          onClick={() => request('source.reconnect').then(() => notify('正在重新连接…'))}
        >
          重新连接
        </button>
      </div>
      <div className="robot-flow">
        <span>企业微信</span>
        <CaretRight size={12} />
        <span>{form.name || '机器人'}</span>
        <CaretRight size={12} />
        <b>{form.mode === 'work' ? '项目 / Work' : 'Claude 连续对话'}</b>
      </div>
      <label className="field">
        Bot ID
        <input
          value={form.botId ?? ''}
          autoComplete="off"
          placeholder="企业微信管理后台 → 智能机器人 → API 模式（长连接）"
          onChange={(event) => setForm({ ...form, botId: event.target.value })}
        />
      </label>
      <SecretField
        label="Secret"
        saved={Boolean(bot?.secretSaved)}
        placeholder="在同一页点「获取 Secret」"
        hint="Secret 只保存在钥匙串。一个机器人同一时间只能保持一条长连接：在另一台电脑用同一组凭据连接时，这里会被顶替断开。"
        onSave={async (secret) => {
          await request('source.setSecret', { secret });
          notify('Secret 已保存到钥匙串');
        }}
        onClear={() => request('source.clearSecret').then(() => notify('Secret 已清除'))}
      />

      <label className="field">
        机器人名称
        <input
          value={form.name}
          autoComplete="off"
          aria-invalid={Boolean(nameError)}
          onChange={(event) => setForm({ ...form, name: event.target.value })}
        />
        {nameError && <small className="field-error">{nameError}</small>}
      </label>
      <label className="check-option">
        <input type="checkbox" checked={form.enabled === true} onChange={(event) => setForm({ ...form, enabled: event.target.checked })} />
        启用企业微信对话入口
      </label>
      <small className="setting-hint">关闭后停止接收企微消息。</small>
      <label className="field">
        对话模式
        <select value={form.mode ?? 'claude'} onChange={(event) => setForm({ ...form, mode: event.target.value })}>
          <option value="claude">直接连接 Claude</option>
          <option value="work">创建和跟进 Work</option>
        </select>
      </label>
      {form.mode !== 'work' && (
        <p>企微消息直接进入 Claude，连续对话保留上下文。可操作已登记项目，工具权限和问题在当前企微对话中确认。</p>
      )}
      {form.mode === 'work' && <>
      <div className="static-rule">
        <Info size={14} />
        可按企业微信机器人连接配置接收消息。
      </div>
      <label className="check-option">
        <input type="checkbox" checked={form.autoStart === true} onChange={(event) => setForm({ ...form, autoStart: event.target.checked })} />
        来源创建的 Work 自动进入执行队列
      </label>
      <small className="setting-hint">默认关闭：群里任何人都能发起请求，Work 创建后由你在应用里启动。</small>
      <label className="check-option">
        <input
          type="checkbox"
          checked={form.remoteAnswers === true}
          onChange={(event) => setForm({ ...form, remoteAnswers: event.target.checked })}
        />
        允许在原会话里回答 Work 的业务问题
      </label>
      <small className="setting-hint">
        默认关闭。即使开启，也只接受发起该 Work 的会话的回答；工具权限请求始终只能在应用内确认。
      </small>

      <h4>工作目录自动识别</h4>
      <div className="bot-bubble">
        <small>内建行为，没有需要配置的映射</small>
        <p>
          机器人根据对话和已登记的项目索引判断目标项目（由 Claude 理解消息，不带任何工具），应用再校验项目登记与目录的实际位置。
          不配置群聊与项目的固定对应，也不需要手选目录。
        </p>
      </div>
      <div className="robot-rule">
        <CheckCircle size={14} />
        同一个群可以讨论多个项目
      </div>
      <div className="robot-rule">
        <CheckCircle size={14} />
        目标明确且项目已登记时直接创建 Work
      </div>
      <div className="robot-rule">
        <ChatCircleDots size={14} />
        目标不明确、项目未登记或目录不可用时，回到原对话追问，不猜测
      </div>

      </>}

      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      <div className="settings-actions">
        <button onClick={onOpenConversations}>查看来源对话（{overview.conversations.length}）</button>
        <button disabled={!dirty || saving} onClick={() => setForm(overview.settings)}>
          放弃修改
        </button>
        <button className="primary" disabled={!dirty || saving || Boolean(nameError)} onClick={save}>
          {saving ? '正在保存…' : '保存配置'}
        </button>
      </div>
      <WecomBots notify={notify} />
    </>
  );
}

function Agent({ notify }) {
  const [index, setIndex] = useState(null);
  const [error, setError] = useState(null);
  useEffect(() => {
    request('agent.pack', {}, { timeoutMs: 60000 })
      .then(setIndex)
      .catch((cause) => setError(errorText(cause)));
  }, []);

  async function pick() {
    const picked = await request('app.pickDirectory', {}, { timeoutMs: 600000 }).catch(() => null);
    if (!picked?.path) return;
    try {
      const result = await request('agent.pack', { path: picked.path }, { timeoutMs: 60000 });
      setIndex(result);
      if (!result.valid) notify(result.reason ?? '这个目录不是能力包', true);
    } catch (cause) {
      notify(errorText(cause), true);
    }
  }

  const skillRow = (skill) => (
    <div className={`skill-row ${skill.available ? '' : 'unavailable'}`} key={`${skill.source}:${skill.name}`} title={skill.file}>
      <b>{skill.name}</b>
      <span>{skill.available ? (skill.description ?? '（没有描述）') : skill.reason}</span>
      <code>{skill.available ? skill.version : '失效'}</code>
    </div>
  );

  return (
    <>
      <h3>智能体能力</h3>
      <p>只读地索引 agent-starter 能力包里的岗位、技能与知识入口。不会运行安装脚本，也不会修改包或任何用户级配置。</p>
      <div className="settings-inline">
        <button onClick={pick}>
          <FolderOpen size={14} />
          选择能力包目录…
        </button>
        {index?.valid && (
          <button
            onClick={() =>
              request('agent.pack', { clear: true })
                .then(setIndex)
                .catch(() => {})
            }
          >
            移除
          </button>
        )}
      </div>
      {error && <div className="pane-note error">{error}</div>}
      {index && !index.valid && (
        <p className="context-empty">{index.configured === false ? '还没有选择能力包。' : (index.reason ?? '能力包无效')}</p>
      )}
      {index?.valid && (
        <>
          <div className="code-box">
            <code>{index.path}</code>
          </div>
          <h4>岗位（包里实际存在的）</h4>
          {index.roles.length === 0 && <p className="context-empty">这个包里没有岗位目录。</p>}
          {index.roles.map((role) => (
            <div className="role-block" key={role.id}>
              <div className="role-title">
                <b>{role.title ?? role.id}</b>
                <code>roles/{role.id}</code>
                <span className="pill neutral">{role.skills.length} 个技能</span>
              </div>
              {role.skills.map(skillRow)}
            </div>
          ))}
          <h4>基础技能（template）</h4>
          {index.skills.length === 0 ? <p className="context-empty">没有基础技能。</p> : index.skills.map(skillRow)}
          <h4>知识入口</h4>
          <p className="context-empty">{index.knowledge.length ? index.knowledge.join('、') : '没有知识目录。'}</p>
          <h4>权限守卫</h4>
          <div className="static-rule disabled">
            <Info size={14} />
            {index.policy.present
              ? `包里有权限策略文件（版本 ${index.policy.version}）。本版本没有执行这份守卫：工具权限仍由每次请求时的应用内确认决定。`
              : '包里没有权限策略文件。'}
          </div>
        </>
      )}
      <h4>尚未接入</h4>
      {[
        '把选定的技能、知识与仓规注入到 Run',
        '守卫覆盖检查与权限规则回放',
        '知识改进建议',
      ].map((text) => (
        <div className="static-rule disabled" key={text}>
          <Info size={14} />
          {text}：未接入
        </div>
      ))}
      <small className="setting-hint">任务卡与执行记录的导出已经可用，入口在每个 Work 的详情里。</small>
    </>
  );
}

const MODE_LABEL = { terminal: '终端', structured: '结构化聊天', chat: 'Swttch' };

export default function SettingsModal({
  initialPage,
  settings,
  providers = [],
  capacity,
  projects,
  notify,
  onChange,
  navigation,
  onNavigationChange,
  onOpenMcp,
  onOpenConversations,
  onClose,
}) {
  const [page, setPage] = useState(initialPage ?? 'appearance');
  const [dirty, setDirty] = useState(false);

  const guard = () =>
    !dirty ||
    confirmAction({
      title: '有未保存的连接设置',
      text: '离开会丢弃这些修改。',
      confirmLabel: '放弃修改',
      cancelLabel: '继续编辑',
    });

  async function switchPage(next) {
    if (next === page) return;
    if (!(await guard())) return;
    setDirty(false);
    setPage(next);
  }

  return (
    <ModalFrame title="设置" eyebrow={null} wide className="settings-window" onClose={onClose} guard={guard}>
      <div className="settings-layout">
        <nav aria-label="设置分类">
          {PAGE_GROUPS.map(([group, pages]) => (
            <div className="settings-nav-group" role="group" aria-label={group} key={group}>
              <span aria-hidden="true">{group}</span>
              {pages.map(([value, label, Icon]) => (
                <button type="button" key={value} className={page === value ? 'active' : ''}
                  aria-current={page === value ? 'page' : undefined} onClick={() => switchPage(value)}>
                  <Icon size={16} />
                  {label}
                </button>
              ))}
            </div>
          ))}
        </nav>
        <div className="settings-detail" key={page}>
          {page === 'updates' && <VersionUpdates />}
          {page === 'cli' && <CliEngines settings={settings} providers={providers} onChange={onChange} notify={notify} />}
          {page === 'appearance' && (
            <Appearance
              settings={settings}
              capacity={capacity}
              onChange={onChange}
              notify={notify}
            />
          )}
          {page === 'navigation' && <NavigationSettings navigation={navigation} onChange={onNavigationChange} />}
          {page === 'pet' && (
            <PetSettings settings={settings.pet} onChange={(patch) => onChange({ pet: { ...settings.pet, ...patch } })} />
          )}
          {page === 'tapd' && <Tapd projects={projects} notify={notify} onDirty={setDirty} />}
          {page === 'wecom' && <Wecom notify={notify} onDirty={setDirty} onOpenConversations={onOpenConversations} />}
          {page === 'mcp' && (
            <>
              <h3>MCP 服务</h3>
              <p>为会话提供额外的工具。服务的启停、添加与移除在这里管理；改动对之后新启动的会话和 Run 生效。</p>
              <button className="settings-mcp-entry" onClick={onOpenMcp}>
                <PlugsConnected size={15} />
                查看和管理 MCP 服务
                <CaretRight size={13} />
              </button>
            </>
          )}
          {page === 'agent' && <Agent notify={notify} />}
        </div>
      </div>
    </ModalFrame>
  );
}
