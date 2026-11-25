// DeepSeek Harness 版本巡检与升级：提示条（启动 / 每 6 小时巡检发现问题时出现）与设置页里的状态行。
import React, { useState } from 'react';
import { errorText, request } from '../bridge.js';

export function reportSummary(report) {
  if (!report) return '';
  if (!report.installed) return '未检测到 dsh-tui';
  const parts = [`当前 ${report.profile ?? report.launcher ?? '未知'}`];
  if (report.latest) parts.push(`最新 ${report.latest}`);
  if (report.dsh) parts.push(`dsh ${report.dsh}`);
  return parts.join(' · ');
}

/// 升级动作：执行 `dsh-tui update` 并回传日志与升级后的巡检结果。
export function useDeepSeekUpgrade(notify) {
  const [state, setState] = useState(null);
  async function upgrade() {
    setState({ running: true });
    try {
      const result = await request('cli.deepseekUpgrade', {}, { timeoutMs: 960000 });
      setState({ running: false, result });
      notify?.(result.ok ? `DeepSeek Harness 已升级：${reportSummary(result.report)}` : '升级未完成，请查看日志', !result.ok);
      return result;
    } catch (cause) {
      setState({ running: false, error: errorText(cause) });
      notify?.(`升级失败：${errorText(cause)}`, true);
      return null;
    }
  }
  return [state, upgrade];
}

export function DeepSeekBanner({ report, onClose, notify }) {
  const [state, upgrade] = useDeepSeekUpgrade(notify);
  const done = state?.result?.ok;
  return (
    <div className="maintenance-banner" role="status">
      <b>DeepSeek Harness {report.updateAvailable ? `有新版本 ${report.latest}` : '环境需要处理'}</b>
      <span>{reportSummary(report)}</span>
      {(report.problems ?? []).map((problem) => <small key={problem}>✗ {problem}</small>)}
      {state?.result && !done && <pre>{state.result.log}</pre>}
      {state?.error && <small className="red">{state.error}</small>}
      <div>
        {!done && (
          <button className="primary" disabled={state?.running} onClick={upgrade}>
            {state?.running ? '正在升级…（可能需要几分钟）' : '升级并对齐'}
          </button>
        )}
        {!state?.running && (
          <button onClick={() => {
            request('cli.deepseekDismiss', { signature: report.signature }).catch(() => {});
            onClose();
          }}>
            {done ? '完成' : '忽略此版本'}
          </button>
        )}
        {!state?.running && !done && <button onClick={onClose}>稍后</button>}
      </div>
    </div>
  );
}

export function DeepSeekStatus({ notify }) {
  const [report, setReport] = useState(null);
  const [checking, setChecking] = useState(false);
  const [state, upgrade] = useDeepSeekUpgrade(notify);
  async function check() {
    setChecking(true);
    try {
      setReport(await request('cli.deepseekCheck', {}, { timeoutMs: 120000 }));
    } catch (cause) {
      notify(errorText(cause), true);
    } finally {
      setChecking(false);
    }
  }
  const current = state?.result?.report ?? report;
  return (
    <div className="deepseek-status">
      <button type="button" disabled={checking || state?.running} onClick={check}>
        {checking ? '检查中…' : '检查 DeepSeek 更新'}
      </button>
      {current && <span>{reportSummary(current)}</span>}
      {current?.installed && (current.needsAttention ? (
        <button type="button" className="primary" disabled={state?.running} onClick={upgrade}>
          {state?.running ? '正在升级…' : current.updateAvailable ? `升级到 ${current.latest}` : '重新对齐'}
        </button>
      ) : <span className="green">已是最新，环境正常</span>)}
      {(current?.problems ?? []).map((problem) => <small key={problem} className="red">✗ {problem}</small>)}
      {state?.result && !state.result.ok && <pre>{state.result.log}</pre>}
    </div>
  );
}
