import React, { useEffect, useRef, useState } from 'react';
import { ArrowsClockwise, CaretRight, Swap, X } from '@phosphor-icons/react';
import { request } from './bridge.js';

function formatAmount(balance) {
  if (!balance || !Number.isFinite(balance.total)) return null;
  const symbol = balance.symbol || (balance.currency === 'USD' ? '$' : '¥');
  return `${symbol}${balance.total.toFixed(2)}`;
}

function quotaRows(usage) {
  const balance = usage?.deepseek && Number.isFinite(usage.deepseek.total) ? usage.deepseek : null;
  const plan = usage?.codexPlan
    ? String(usage.codexPlan).replace(/^./, (c) => c.toUpperCase())
    : null;
  const agyCredits = Number.isFinite(usage?.antigravityCredits)
    ? `积分 ${usage.antigravityCredits}`
    : null;
  return [
    {
      id: 'claude',
      label: 'Claude',
      limits: [
        ['5 小时', usage?.session?.percent, usage?.session?.reset],
        ['每周', usage?.weekly?.percent, usage?.weekly?.reset],
      ].filter((limit) => Number.isFinite(limit[1])),
    },
    {
      id: 'codex',
      label: 'Codex',
      plan,
      updated: usage?.codexUpdated,
      error: usage?.codexError,
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
      id: 'dsh',
      label: 'DeepSeek',
      kind: 'balance',
      balance,
      error: usage?.deepseekError,
      limits: [],
    },
    {
      id: 'antigravity',
      label: 'Antigravity',
      plan: agyCredits,
      updated: usage?.antigravityUpdated,
      error: usage?.antigravityError,
      limits: (usage?.antigravity ?? []).map(({ label, percent, reset }) => [
        label,
        percent,
        reset,
      ]),
    },
  ]
    .map((row) => ({
      ...row,
      limits: row.limits.filter((limit) => Number.isFinite(limit[1])).sort((a, b) => b[1] - a[1]),
    }))
    .sort((a, b) => {
      const rank = (r) => {
        if (r.limits.length) return 100 + r.limits[0][1];
        if (r.balance) return 50;
        if (!r.unsupported) return 10;
        return 0;
      };
      return rank(b) - rank(a);
    });
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

function BalanceSummary({ balance }) {
  const amount = formatAmount(balance);
  if (!amount) return <small>—</small>;
  return (
    <span
      className="cli-quota-meter is-summary is-amount"
      title={`DeepSeek 余额 ${amount}${balance.available === false ? '（不可用）' : ''}`}
    >
      <strong>{amount}</strong>
    </span>
  );
}

function BalanceDetails({ balance }) {
  if (!balance) return null;
  const symbol = balance.symbol || (balance.currency === 'USD' ? '$' : '¥');
  return (
    <div className="cli-usage-limits">
      <span className="cli-quota-meter is-amount">
        <small>总余额</small>
        <strong>{`${symbol}${balance.total.toFixed(2)}`}</strong>
      </span>
      <span className="cli-quota-meter is-amount">
        <small>充值</small>
        <strong>{`${symbol}${(balance.toppedUp ?? 0).toFixed(2)}`}</strong>
      </span>
      {Number(balance.granted) > 0 && (
        <span className="cli-quota-meter is-amount">
          <small>赠送</small>
          <strong>{`${symbol}${balance.granted.toFixed(2)}`}</strong>
        </span>
      )}
    </div>
  );
}

function rowStatusText(row) {
  if (row.kind === 'balance') {
    if (row.balance) {
      const amount = formatAmount(row.balance);
      return row.balance.available === false ? `${amount} · 不可用` : `${amount} 可用`;
    }
    return row.error || '未配置密钥';
  }
  if (row.limits.length) {
    return `${row.limits[0][2]} 重置`;
  }
  if (row.error) {
    return row.error;
  }
  if (row.unsupported) {
    return '暂不支持查询';
  }
  return '额度不可用';
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

  const panelNote = error || usage?.note || usage?.codexError || usage?.deepseekError;

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
        {rows.map((row) => (
          <span className="cli-quota-badge" key={row.id} title={row.label}>
            <img src={engineIcons[row.id]} alt={row.label} />
            {row.kind === 'balance' ? (
              <BalanceSummary balance={row.balance} />
            ) : (
              <QuotaMeter limit={row.limits[0]} remaining={remaining} summary />
            )}
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
          {panelNote && (
            <p className="pane-note" role="status">
              {panelNote}
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
                      {(row.updated || row.balance?.updated) && (
                        <small>{row.updated || row.balance.updated} 更新</small>
                      )}
                      <small>{rowStatusText(row)}</small>
                      {compact &&
                        (row.kind === 'balance' ? (
                          <BalanceSummary balance={row.balance} />
                        ) : (
                          <QuotaMeter limit={row.limits[0]} remaining={remaining} summary />
                        ))}
                      <CaretRight size={12} />
                    </button>
                    {(!compact || expanded === row.id) &&
                      (row.kind === 'balance' ? (
                        <BalanceDetails balance={row.balance} />
                      ) : (
                        row.limits.length > 0 && (
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
                        )
                      ))}
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
                      {row.kind === 'balance' ? (
                        row.balance ? (
                          <BalanceDetails balance={row.balance} />
                        ) : (
                          <div className="cli-usage-limits">
                            <small>{rowStatusText(row)}</small>
                          </div>
                        )
                      ) : row.limits.length > 0 ? (
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
                      ) : (
                        <div className="cli-usage-limits">
                          <small>{rowStatusText(row)}</small>
                        </div>
                      )}
                    </div>
                  ))}
                </>
              ) : (
                <>
                  <p>各引擎的额度跟随其 CLI 登录账户或已配置的 API 密钥。</p>
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
