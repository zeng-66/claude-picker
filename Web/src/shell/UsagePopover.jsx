import React, { useEffect, useRef, useState } from 'react';
import { ArrowsClockwise, CaretRight, ChartBar, Swap, X } from '@phosphor-icons/react';
import { request } from './bridge.js';

function quotaRows(usage) {
  return [
    {
      id: 'codex',
      label: 'Codex',
      limits: (usage?.codex ?? []).map(({ minutes, percent, reset }) => [
        minutes === 10080
          ? '每周'
          : minutes % 60 === 0
            ? `${minutes / 60} 小时`
            : `${minutes} 分钟`,
        percent,
        reset,
      ]),
    },
    {
      id: 'claude',
      label: 'Claude',
      limits: [
        ['5 小时', usage?.session?.percent, usage?.session?.reset],
        ['每周', usage?.weekly?.percent, usage?.weekly?.reset],
      ].filter((limit) => Number.isFinite(limit[1])),
    },
    { id: 'antigravity', label: 'Antigravity', limits: [] },
  ];
}

function QuotaMeter({ limit, remaining, summary = false, showReset = false }) {
  if (!limit) return <small>—</small>;
  const [label, used, reset] = limit;
  const percent = remaining ? 100 - used : used;
  return (
    <span
      className={`cli-quota-meter${summary ? ' is-summary' : ''}`}
      title={`${label} · ${reset} 重置`}
    >
      {!summary && <small>{label}</small>}
      <span className="cli-quota-track" aria-hidden="true">
        <i style={{ width: `${percent}%` }} />
      </span>
      <strong>{percent}%</strong>
      {showReset && <small>{reset} 重置</small>}
    </span>
  );
}

function EngineIdentity({ row, icon }) {
  return (
    <span className="cli-quota-engine">
      <img src={icon} alt="" />
      <span>
        {row.label}
        {row.plan && <small> · {row.plan}</small>}
      </span>
    </span>
  );
}

export default function UsagePopover({ usage, engineIcons }) {
  const [open, setOpen] = useState(false);
  const [remaining, setRemaining] = useState(false);
  const [compact, setCompact] = useState(false);
  const [expanded, setExpanded] = useState(null);
  const [page, setPage] = useState('summary');
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState(null);
  const root = useRef(null);
  const trigger = useRef(null);
  const rows = quotaRows(usage);
  const mostUsed = (row) => row.limits.reduce((a, b) => (!a || b[1] > a[1] ? b : a), null);

  useEffect(() => {
    if (!open) return;
    request('app.refreshUsage', { onlyIfEmpty: true }).catch(() => {});
    const outside = (event) => {
      if (!root.current?.contains(event.target)) setOpen(false);
    };
    const escape = (event) => {
      if (event.key === 'Escape') {
        setOpen(false);
        trigger.current?.focus();
      }
    };
    document.addEventListener('pointerdown', outside);
    document.addEventListener('keydown', escape);
    return () => {
      document.removeEventListener('pointerdown', outside);
      document.removeEventListener('keydown', escape);
    };
  }, [open]);

  async function refresh() {
    setRefreshing(true);
    setError(null);
    try {
      await request('app.refreshUsage');
    } catch {
      setError('刷新失败');
    } finally {
      setRefreshing(false);
    }
  }

  return (
    <div className="cli-usage" ref={root}>
      <button
        className="cli-usage-trigger"
        type="button"
        ref={trigger}
        aria-expanded={open}
        aria-label="使用额度"
        onClick={() => {
          setOpen(!open);
          if (!open) setPage('summary');
        }}
      >
        <ChartBar size={14} />
        <span>{remaining ? '剩余' : '已用'}</span>
        {rows.map((row) => (
          <span className="cli-quota-badge" key={row.id} title={row.label}>
            <img src={engineIcons[row.id]} alt={row.label} />
            <QuotaMeter
              limit={compact ? mostUsed(row) : row.limits[0]}
              remaining={remaining}
              summary
            />
          </span>
        ))}
      </button>
      {open && (
        <section className="cli-usage-panel" role="region" aria-label="使用量">
          <header>
            <strong>
              {page === 'accounts' ? '管理账户' : page === 'history' ? '使用详情与历史' : '使用量'}
            </strong>
            {page === 'summary' && <small>所有引擎{usage?.updated && ` · ${usage.updated}`}</small>}
            <button aria-label="刷新额度" disabled={refreshing || usage?.loading} onClick={refresh}>
              <ArrowsClockwise size={14} />
            </button>
            <div className="cli-usage-header-actions">
              {page === 'summary' && (
                <button
                  aria-label={remaining ? '显示已用额度' : '显示剩余额度'}
                  onClick={() => setRemaining(!remaining)}
                >
                  {remaining ? '剩余' : '已用'} <Swap size={12} />
                </button>
              )}
              <button aria-label="关闭额度面板" onClick={() => setOpen(false)}>
                <X size={14} />
              </button>
            </div>
          </header>
          {(error || usage?.note || usage?.codexError) && (
            <p className="pane-note" role="status">
              {error || usage?.note || usage?.codexError}
            </p>
          )}
          {page === 'summary' ? (
            <>
              <div className="cli-usage-mode" role="group" aria-label="额度显示密度">
                <button aria-pressed={!compact} onClick={() => setCompact(false)}>
                  详细
                </button>
                <button aria-pressed={compact} onClick={() => setCompact(true)}>
                  精简
                </button>
              </div>
              <div className="cli-usage-rows">
                {rows.map((row) => (
                  <div key={row.id}>
                    <button
                      className="cli-usage-row"
                      aria-expanded={expanded === row.id}
                      onClick={() => setExpanded(expanded === row.id ? null : row.id)}
                    >
                      <EngineIdentity row={row} icon={engineIcons[row.id]} />
                      {row.id === 'codex' && usage?.codexUpdated && (
                        <small>{usage.codexUpdated} 更新</small>
                      )}
                      <small>
                        {row.limits.length
                          ? `${(compact ? mostUsed(row) : row.limits[0])[2]} 重置`
                          : '额度不可用'}
                      </small>
                      {compact && (
                        <QuotaMeter limit={mostUsed(row)} remaining={remaining} summary />
                      )}
                      <CaretRight size={12} />
                    </button>
                    {(!compact || expanded === row.id) && (
                      <div className="cli-usage-limits">
                        {row.limits.map((limit) => (
                          <QuotaMeter
                            key={limit[0]}
                            limit={limit}
                            remaining={remaining}
                            showReset={expanded === row.id}
                          />
                        ))}
                      </div>
                    )}
                  </div>
                ))}
              </div>
              <div className="cli-usage-links">
                <button onClick={() => setPage('history')}>
                  使用详情与历史 <CaretRight size={12} />
                </button>
                <button onClick={() => setPage('accounts')}>
                  管理账户 <CaretRight size={12} />
                </button>
              </div>
            </>
          ) : (
            <div className="cli-usage-subpage">
              <button onClick={() => setPage('summary')}>← 返回用量</button>
              {page === 'history' ? (
                <>
                  <p>当前额度快照</p>
                  {rows.map((row) => (
                    <div key={row.id}>
                      <EngineIdentity row={row} icon={engineIcons[row.id]} />
                      <div className="cli-usage-limits">
                        {row.limits.map((limit) => (
                          <QuotaMeter
                            key={limit[0]}
                            limit={limit}
                            remaining={remaining}
                            showReset
                          />
                        ))}
                      </div>
                    </div>
                  ))}
                </>
              ) : (
                <>
                  <p>各引擎的额度跟随其 CLI 登录账户。</p>
                  <button
                    onClick={() => {
                      setOpen(false);
                      window.dispatchEvent(new Event('claude-picker:open-cli-settings'));
                    }}
                  >
                    打开 CLI 配置
                  </button>
                </>
              )}
            </div>
          )}
        </section>
      )}
    </div>
  );
}
