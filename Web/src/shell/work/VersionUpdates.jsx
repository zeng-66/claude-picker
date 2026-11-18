import React, { useEffect, useState } from 'react';
import { errorText, request } from '../bridge.js';

export default function VersionUpdates() {
  const [status, setStatus] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    let mounted = true;
    request('update.status')
      .then((value) => {
        if (mounted) setStatus(value);
      })
      .catch((cause) => {
        if (mounted) setError(errorText(cause));
      });
    return () => {
      mounted = false;
    };
  }, []);
  async function run(method) {
    setBusy(true);
    setError('');
    try {
      setStatus(await request(method, {}, { timeoutMs: 600000 }));
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <h3>版本更新</h3>
      <p>获取 main 分支最新构建的正式版。下载完成后退出应用并安装。</p>
      {status && (
        <>
          <div className="field">
            当前版本{' '}
            <strong>
              {status.version} · {status.platform}
            </strong>
          </div>
          <div className="field">
            当前提交 <code>{status.commit?.slice(0, 12) || '本地构建'}</code>
          </div>
          <div className="field">
            更新来源 <code>zeng-66/claude-picker · main</code>
          </div>
        </>
      )}
      <div className="settings-inline">
        <button className="primary" disabled={busy} onClick={() => run('update.check')}>
          {busy ? '处理中…' : '检查更新'}
        </button>
        {status?.state === 'available' && (
          <button disabled={busy} onClick={() => run('update.download')}>
            下载更新
          </button>
        )}
        {status?.state === 'ready' && (
          <button disabled={busy} onClick={() => run('update.install')}>
            退出并安装
          </button>
        )}
      </div>
      <div aria-live="polite">
        {status?.state === 'available' && (
          <p>
            发现新版本 {status.latestVersion} · {status.latestCommit?.slice(0, 12)}
          </p>
        )}
        {status?.state === 'current' && <p>已是 main 最新构建。</p>}
        {status?.state === 'unpublished' && <p>main 最新安装包尚未发布，请稍后重新检查。</p>}
        {status?.state === 'ready' && (
          <p>安装包已下载并通过 SHA-256 校验。安装前请保存工作并结束正在执行的任务。</p>
        )}
        {status?.state === 'installing' && <p>正在启动安装程序…</p>}
        {status?.preview && <p>浏览器演示模式，更新流程使用演示数据。</p>}
        {error && (
          <p className="pane-note error" role="alert">
            {error}
          </p>
        )}
      </div>
    </>
  );
}
