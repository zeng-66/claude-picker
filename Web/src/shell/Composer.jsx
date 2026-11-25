// 输入区：提示词 + 模式 / 模型 / 推理强度 / 快速模式 / 上下文环 + 发送。
// 停靠在第二栏底部与悬浮窗共用同一份输入内容。
import EngineIcon from './EngineIcon.jsx';
import React from 'react';
import { ArrowUp, CaretDown, Check, Lightning } from '@phosphor-icons/react';
import { request } from './bridge.js';

export function contextNumbers(context) {
  const total = context?.total || 200000;
  const used = Math.min(context?.used ?? 0, total);
  const percent = total ? (used / total) * 100 : 0;
  const k = (value) => (value / 1000).toFixed(1);
  return { total, used, percent, k };
}

export function ContextMeter({ context, onOpen }) {
  const { total, used, percent, k } = contextNumbers(context);
  return (
    <button
      type="button"
      className="context-meter"
      aria-label={`上下文占用 ${k(used)}k / ${k(total)}k`}
      onClick={onOpen}
    >
      <span
        className="context-ring"
        style={{
          '--context-progress': `${percent}%`,
          '--context-color': percent >= 80 ? '#d68f87' : percent >= 60 ? '#cfb36d' : '#a6b991',
        }}
      />
      <span className="context-tooltip" role="tooltip">
        <strong>上下文窗口</strong>
        <span>
          {k(used)}k / {k(total)}k · {percent.toFixed(1)}%
        </span>
        <small>{context?.sessionId ? `剩余 ${k(total - used)}k` : '打开会话后显示占用'}</small>
      </span>
    </button>
  );
}

export default function Composer({
  runtime,
  providers = [],
  active,
  context,
  prompt,
  onPrompt,
  onSend,
  sending,
  runtimeMenu,
  onRuntimeMenu,
  onOpenContext,
  onHandoff,
}) {
  const currentProvider = runtime.provider ?? 'claude';
  const providerLabel = { antigravity: 'Antigravity', codex: 'Codex', dsh: 'DeepSeek' }[currentProvider] ?? 'Claude';
  const otherProvider = currentProvider === 'antigravity' ? 'claude' : 'antigravity';
  const otherLabel = otherProvider === 'antigravity' ? 'Antigravity' : 'Claude Code';
  const otherAvailable =
    providers.length === 0 || providers.some((p) => p.id === otherProvider && p.available);
  const settings = [
    { id: 'mode', label: '模式', value: runtime.mode, values: runtime.modes },
    { id: 'model', label: '模型', value: runtime.model, values: runtime.models },
    { id: 'effort', label: '推理强度', value: runtime.effort, values: runtime.efforts },
  ];
  const labelOf = (setting) =>
    setting.values.find((item) => item.id === setting.value)?.label ?? setting.value;

  return (
    <form
      className="terminal-input"
      onSubmit={(event) => {
        event.preventDefault();
        onSend();
      }}
    >
      <textarea
        aria-label="输入提示词"
        value={prompt}
        onChange={(event) => onPrompt(event.target.value)}
        onKeyDown={(event) => {
          // 回车发送，Shift+回车换行；输入法组词期间的回车交给输入法。
          if (event.key !== 'Enter' || event.shiftKey || event.nativeEvent.isComposing) return;
          if (event.keyCode === 229) return;
          event.preventDefault();
          onSend();
        }}
        placeholder="继续对话，或输入 / 查看命令"
      />
      <div className="terminal-controls">
        <div className="runtime-options">
          <div className="runtime-setting">
            <button
              type="button"
              className="runtime-value provider-pill"
              title="执行引擎"
              aria-label={`引擎：${providerLabel}`}
              aria-expanded={runtimeMenu === 'provider'}
              onClick={() => onRuntimeMenu(runtimeMenu === 'provider' ? null : 'provider')}
            >
              <EngineIcon id={currentProvider} />
              {providerLabel}
            </button>
            {runtimeMenu === 'provider' && (
              <div className="runtime-popover" role="menu" aria-label="选择执行引擎">
                {active?.sessionId ? (
                  <button
                    type="button"
                    role="menuitem"
                    disabled={!otherAvailable}
                    onClick={() => {
                      onRuntimeMenu(null);
                      onHandoff?.(otherProvider);
                    }}
                  >
                    <EngineIcon id={otherProvider} />
                转到 {otherLabel} 接力继续…
                  </button>
                ) : (
                  [
                    { id: 'claude', label: 'Claude Code' },
                    { id: 'antigravity', label: 'Antigravity' },
                    { id: 'codex', label: 'Codex' },
                    { id: 'dsh', label: 'DeepSeek' },
                  ].map((item) => {
                    const ok =
                      providers.length === 0 ||
                      providers.some((p) => p.id === item.id && p.available);
                    return (
                      <button
                        type="button"
                        role="menuitemradio"
                        key={item.id}
                        disabled={!ok}
                        aria-checked={currentProvider === item.id}
                        onClick={() => {
                          request('app.runtime', { key: 'provider', value: item.id });
                          onRuntimeMenu(null);
                        }}
                      >
                        <EngineIcon id={item.id} />
                        {item.label}
                        {!ok ? '（未安装）' : ''}
                        {currentProvider === item.id && <Check size={12} />}
                      </button>
                    );
                  })
                )}
              </div>
            )}
          </div>
          {settings.map((setting) => (
            <div className="runtime-setting" key={setting.id}>
              <button
                type="button"
                className="runtime-value"
                title={setting.label}
                aria-label={`${setting.label}：${labelOf(setting)}`}
                aria-expanded={runtimeMenu === setting.id}
                onClick={() => onRuntimeMenu(runtimeMenu === setting.id ? null : setting.id)}
              >
                {labelOf(setting)}
              </button>
              {runtimeMenu === setting.id && (
                <div className="runtime-popover" role="menu" aria-label={`选择${setting.label}`}>
                  {setting.values.map((item) => (
                    <button
                      type="button"
                      role="menuitemradio"
                      aria-checked={setting.value === item.id}
                      key={item.id}
                      onClick={() => {
                        request('app.runtime', { key: setting.id, value: item.id });
                        onRuntimeMenu(null);
                      }}
                    >
                      {item.label}
                      {setting.value === item.id && <Check size={12} />}
                    </button>
                  ))}
                </div>
              )}
            </div>
          ))}
          {runtime.supportsFast !== false && (
            <button
              type="button"
              className={`fast-toggle ${runtime.fast ? 'fast-on' : ''}`}
              title={`快速模式：${runtime.fast ? '开启' : '关闭'}`}
              aria-label={`快速模式${runtime.fast ? '开启' : '关闭'}`}
              aria-pressed={runtime.fast}
              onClick={() => request('app.runtime', { key: 'fast', value: !runtime.fast })}
            >
              <Lightning size={13} weight={runtime.fast ? 'fill' : 'regular'} />
            </button>
          )}
          <ContextMeter context={context} onOpen={onOpenContext} />
        </div>
        <button className="send" aria-label="发送" disabled={!prompt.trim() || sending}>
          <ArrowUp size={16} />
        </button>
      </div>
    </form>
  );
}

/// 原生终端下方的快捷设置条：引擎 / 模式 / 模型 / 推理强度 / 快速模式。
export function RuntimeBar({
  runtime,
  providers = [],
  active,
  runtimeMenu,
  onRuntimeMenu,
  onHandoff,
}) {
  const currentProvider = runtime.provider ?? 'claude';
  const providerLabel = { antigravity: 'Antigravity', codex: 'Codex', dsh: 'DeepSeek' }[currentProvider] ?? 'Claude';
  const otherProvider = currentProvider === 'antigravity' ? 'claude' : 'antigravity';
  const otherLabel = otherProvider === 'antigravity' ? 'Antigravity' : 'Claude Code';
  const otherAvailable =
    providers.length === 0 || providers.some((p) => p.id === otherProvider && p.available);
  const settings = [
    { id: 'mode', label: '模式', value: runtime.mode, values: runtime.modes },
    { id: 'model', label: '模型', value: runtime.model, values: runtime.models },
    { id: 'effort', label: '推理强度', value: runtime.effort, values: runtime.efforts },
  ];
  const labelOf = (setting) => setting.values.find((item) => item.id === setting.value)?.label ?? setting.value;
  return (
    <div className="runtime-bar runtime-options" role="toolbar" aria-label="运行参数">
      <div className="runtime-setting">
        <button
          type="button"
          className="runtime-bar-item"
          aria-label={`引擎：${providerLabel}`}
          aria-expanded={runtimeMenu === 'provider'}
          onClick={() => onRuntimeMenu(runtimeMenu === 'provider' ? null : 'provider')}
        >
          <span>引擎</span>
          <b>
            <EngineIcon id={currentProvider} />
            {providerLabel}
          </b>
          <CaretDown size={10} />
        </button>
        {runtimeMenu === 'provider' && (
          <div className="runtime-popover" role="menu" aria-label="选择执行引擎">
            {active?.sessionId ? (
              <button
                type="button"
                role="menuitem"
                disabled={!otherAvailable}
                onClick={() => {
                  onRuntimeMenu(null);
                  onHandoff?.(otherProvider);
                }}
              >
                <EngineIcon id={otherProvider} />
                转到 {otherLabel} 接力继续…
              </button>
            ) : (
              [
                { id: 'claude', label: 'Claude Code' },
                { id: 'antigravity', label: 'Antigravity' },
                { id: 'codex', label: 'Codex' },
                { id: 'dsh', label: 'DeepSeek' },
              ].map((item) => {
                const ok =
                  providers.length === 0 ||
                  providers.some((p) => p.id === item.id && p.available);
                return (
                  <button
                    type="button"
                    role="menuitemradio"
                    key={item.id}
                    disabled={!ok}
                    aria-checked={currentProvider === item.id}
                    onClick={() => {
                      request('app.runtime', { key: 'provider', value: item.id });
                      onRuntimeMenu(null);
                    }}
                  >
                    <EngineIcon id={item.id} />
                    {item.label}
                    {!ok ? '（未安装）' : ''}
                    {currentProvider === item.id && <Check size={12} />}
                  </button>
                );
              })
            )}
          </div>
        )}
      </div>
      {settings.map((setting) => (
        <div className="runtime-setting" key={setting.id}>
          <button
            type="button"
            className="runtime-bar-item"
            aria-label={`${setting.label}：${labelOf(setting)}`}
            aria-expanded={runtimeMenu === setting.id}
            onClick={() => onRuntimeMenu(runtimeMenu === setting.id ? null : setting.id)}
          >
            <span>{setting.label}</span>
            <b>{labelOf(setting)}</b>
            <CaretDown size={10} />
          </button>
          {runtimeMenu === setting.id && (
            <div className="runtime-popover" role="menu" aria-label={`选择${setting.label}`}>
              {setting.values.map((item) => (
                <button
                  type="button"
                  role="menuitemradio"
                  aria-checked={setting.value === item.id}
                  key={item.id}
                  onClick={() => {
                    request('app.runtime', { key: setting.id, value: item.id });
                    onRuntimeMenu(null);
                  }}
                >
                  {item.label}
                  {setting.value === item.id && <Check size={12} />}
                </button>
              ))}
            </div>
          )}
        </div>
      ))}
      {runtime.supportsFast !== false && (
        <button
          type="button"
          className={`runtime-bar-item ${runtime.fast ? 'fast-on' : ''}`}
          aria-label={`快速模式${runtime.fast ? '开启' : '关闭'}`}
          aria-pressed={runtime.fast}
          onClick={() => request('app.runtime', { key: 'fast', value: !runtime.fast })}
        >
          <span>快速模式</span>
          <b>{runtime.fast ? '开启' : '关闭'}</b>
        </button>
      )}
    </div>
  );
}

