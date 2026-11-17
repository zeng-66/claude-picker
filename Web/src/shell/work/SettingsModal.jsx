// 设置：界面与会话 / TAPD 连接 / 企业微信机器人 / MCP 服务 / 智能体能力。
// 界面偏好即时生效；连接类配置要点「保存」，有未保存修改时切页或关闭会先确认。
import React, { useEffect, useState } from 'react';
import {
  CaretRight,
  Cat,
  ChatCircleDots,
  CheckCircle,
  Copy,
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
import { errorText, request } from '../bridge.js';
import VersionUpdates from './VersionUpdates.jsx';
import { relativeTime } from '../ui.jsx';
import { confirmAction } from './confirm.jsx';
import { ModalFrame } from './WorkModals.jsx';
import { NavigationSettings } from '../ModuleViews.jsx';
import { PetSettings } from '../pet/PetSettings.jsx';

const PAGES = [
  ['appearance', '界面与会话', SlidersHorizontal],
  ['navigation', '顶部页签', SquaresFour],
  ['pet', '桌宠', Cat],
  ['tapd', 'TAPD 连接', PlugsConnected],
  ['wecom', '企业微信机器人', ChatCircleDots],
  ['mcp', 'MCP 服务', PuzzlePiece],
  ['agent', '智能体能力', Robot],
  ['updates', '版本更新', Info],
];

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
      <div className="field" role="group" aria-label="普通会话的交互方式">
        普通会话的交互方式
        <div className="segmented">
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
        <small>
          切换会结束另一种方式下运行中的普通会话（历史保留），切换前会再确认一次。Work 始终由结构化执行器驱动，不受这个选项影响；同一个会话不会被两种方式同时持有。
        </small>
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
    <>
      <h3>TAPD 连接</h3>
      <p>通过本机的 tapd-cli 读取分配给你的待办。个人令牌保存在 macOS 钥匙串里，不会写进设置文件、日志，也不会再显示出来。</p>
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
              <CheckCircle size={14} /> 已连接：{test.user.name}（{test.user.nick}）
            </span>
          ) : (
            <span className="red">
              <XCircle size={14} /> {test.message}
              {test.detail ? `：${test.detail}` : ''}
            </span>
          ))}
      </div>
      <label className="check-option">
        <input type="checkbox" checked={form.enabled === true} onChange={(event) => setForm({ ...form, enabled: event.target.checked })} />
        启用 TAPD 待办
      </label>

      <h4>项目与本地仓库</h4>
      <p>
        勾选要显示待办的 TAPD 项目，并为它登记可能对应的本地项目（可多个）。这个映射只用于导入时的候选，
        与企业微信机器人无关。
      </p>
      <button disabled={loadingWorkspaces} onClick={loadWorkspaces}>
        {loadingWorkspaces ? '正在读取…' : form.workspaces?.length ? '重新读取我参与的项目' : '读取我参与的项目'}
      </button>
      {(form.workspaces ?? []).map((item) => (
        <div className="workspace-row" key={item.id}>
          <label className="check-option">
            <input
              type="checkbox"
              checked={item.enabled !== false}
              onChange={(event) => updateWorkspace(item.id, { enabled: event.target.checked })}
            />
            <b>{item.name}</b>
            <code>{item.id}</code>
          </label>
          <div className="mapping-chips">
            {(item.projects ?? []).map((path) => {
              const project = projects.find((entry) => entry.path === path);
              return (
                <span className={`pill ${project ? 'neutral' : 'red'}`} key={path} title={path}>
                  {project?.title ?? '目录已不在列表'}
                  <button
                    aria-label={`移除映射 ${project?.title ?? path}`}
                    onClick={() => updateWorkspace(item.id, { projects: item.projects.filter((entry) => entry !== path) })}
                  >
                    ×
                  </button>
                </span>
              );
            })}
            <select
              aria-label={`为 ${item.name} 添加本地项目`}
              value=""
              onChange={(event) => {
                const path = event.target.value;
                if (path && !(item.projects ?? []).includes(path))
                  updateWorkspace(item.id, { projects: [...(item.projects ?? []), path] });
              }}
            >
              <option value="">添加映射…</option>
              {projects
                .filter((project) => !(item.projects ?? []).includes(project.path))
                .map((project) => (
                  <option key={project.path} value={project.path}>
                    {project.title}
                  </option>
                ))}
            </select>
          </div>
        </div>
      ))}

      <h4>同步与回填</h4>
      <label className="check-option">
        <input
          type="checkbox"
          checked={form.syncOnLaunch !== false}
          onChange={(event) => setForm({ ...form, syncOnLaunch: event.target.checked })}
        />
        打开「TAPD 待办」时读取我的待办（读取失败会显示出来；这不是自动接单）
      </label>
      <div className="static-rule">
        <CheckCircle size={14} className="green" />
        回填始终先预览、由你确认后才写入，且只添加评论。这一项不能关闭。
      </div>
      <div className="static-rule disabled">
        <Info size={14} />
        按规则自动创建 Work：本版本没有提供，不会自动接单。
      </div>
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
    </>
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

function Wecom({ notify, onDirty, onOpenConversations }) {
  const [overview, setOverview] = useState(null);
  const [bot, setBot] = useState(null);
  const [form, setForm] = useState(null);
  const [command, setCommand] = useState(null);
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
    request('source.mcpCommand').then(setCommand).catch(() => {});
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
  const commandLine = command ? [command.command, ...command.args].map((part) => (part.includes(' ') ? `"${part}"` : part)).join(' ') : '';
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
        hint="Secret 只保存在钥匙串。一个机器人同一时间只能保持一条长连接：在别处（例如另一台电脑或 WorkBuddy）用同一组凭据连接时，这里会被顶替断开。"
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
        接收方式（群内 @ / 私聊）由 WorkBuddy 一侧决定，应用不配置也不臆测。
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

      <h4>通过 WorkBuddy 接入（可选）</h4>
      <p>
        不用上面的机器人长连接、改由 WorkBuddy 收发时，把下面的命令作为 MCP 工具服务添加到 WorkBuddy（stdio）。
        {overview.lastSeen ? `最近一次调用：${relativeTime(overview.lastSeen)}。` : '目前还没有收到过调用。'}
      </p>
      <div className="code-box copy-box">
        <code>{commandLine || '正在读取…'}</code>
        <button
          aria-label="复制命令"
          title="复制命令"
          onClick={() => navigator.clipboard?.writeText(commandLine).then(() => notify('已复制'))}
        >
          <Copy size={13} />
        </button>
      </div>
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
        '检测 / 应用 WorkBuddy 同步（会修改用户级配置，需要单独验证）',
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

export default function SettingsModal({
  initialPage,
  settings,
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
    <ModalFrame title="设置" wide onClose={onClose} guard={guard}>
      <div className="settings-layout">
        <nav aria-label="设置分类">
          {PAGES.map(([value, label, Icon]) => (
            <button key={value} className={page === value ? 'active' : ''} onClick={() => switchPage(value)}>
              <Icon size={15} />
              {label}
            </button>
          ))}
        </nav>
        <div className="settings-detail">
          {page === 'updates' && <VersionUpdates />}
          {page === 'appearance' && <Appearance settings={settings} capacity={capacity} onChange={onChange} notify={notify} />}
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
      <div className="modal-footer">
        <button
          className="primary"
          onClick={async () => {
            if (await guard()) onClose();
          }}
        >
          完成
        </button>
      </div>
    </ModalFrame>
  );
}
