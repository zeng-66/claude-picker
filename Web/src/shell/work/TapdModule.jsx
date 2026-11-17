// TAPD 模块第二栏：「我的工作」分组表格 + 双栏详情 + 评论 / 状态流转 / 创建任务。
// 交互约定见 docs/ui-refactor-v003.md §5。写 TAPD 的只有评论与流转，两者都要用户明确操作。
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowSquareOut, ArrowsClockwise, PlugsConnected, PlusCircle, Warning } from '@phosphor-icons/react';
import { errorText, request } from '../bridge.js';
import { openExternal, useStored } from '../ui.jsx';
import { formatTime, newId, shortId } from './useWorks.js';
import { ModalFrame, RunOptions } from './WorkModals.jsx';
import { petEvent } from '../pet/usePetSignals.js';
import magnifierClawd from '../../assets/clawd-official/magnifier.webp';
import racingClawd from '../../assets/clawd-official/racing-car.webp';

const refKey = (ref) => (ref ? `${ref.workspaceId}:${ref.entityType}:${ref.entityId}` : '');
const SCOPES = ['待办', '已创建', '已关注', '最近访问'];
const FIELDS = ['优先级', '迭代', '预计结束', '处理人', '创建时间'];
const DETAIL_TABS = [
  ['detail', '详细信息'],
  ['children', '子需求'],
  ['bugs', '缺陷'],
  ['tcases', '测试用例'],
  ['changes', '变更历史'],
];
const RECENT_LIMIT = 30;

function priorityTone(value = '') {
  const text = String(value).toLowerCase();
  if (text.includes('urgent') || text.includes('紧急') || text.includes('high') || text === '高') return 'high';
  return 'middle';
}
const typeMark = (type) => (type === 'bug' ? 'BUG' : type === 'task' ? 'TASK' : 'DD');
const typeLabel = (type) => (type === 'bug' ? '缺陷' : type === 'task' ? '任务' : '需求');
export function tapdUrl(ref) {
  const path =
    ref.entityType === 'bug' ? 'bugtrace/bugs/view' : ref.entityType === 'task' ? 'prong/tasks/view' : 'prong/stories/view';
  return `https://www.tapd.cn/${ref.workspaceId}/${path}/${ref.entityId}`;
}
const firstChar = (name) => (name ? String(name).replace(/;+$/, '').slice(0, 1) : '—');
const cleanOwner = (value) => (value ? String(value).replace(/;+$/, '') : '');

/// 列表行要的摘要（收藏 / 最近访问存这一份，不必重新拉列表就能显示）。
function summaryOf(item) {
  return {
    ref: item.ref,
    shortId: item.shortId ?? shortId(item.ref.entityId),
    type: item.type ?? item.ref.entityType,
    title: item.title,
    status: item.status ?? null,
    priority: item.priority ?? null,
    owner: item.owner ?? null,
    iterationName: item.iterationName ?? item.iteration?.name ?? null,
    due: item.due ?? null,
    created: item.created ?? null,
    workspaceName: item.workspaceName ?? null,
  };
}

export default function TapdModule({
  workspace,
  workspaces,
  config,
  projects,
  runtime,
  notify,
  focusRef,
  onOpenSettings,
  onOpenWork,
  onWorkCreated,
  query = '',
  submitRef,
}) {
  const enabled = config?.settings?.enabled === true;
  const [scope, setScope] = useStored('tapdScope', '待办');
  const [statusFilter, setStatusFilter] = useState('');
  const [priorityFilter, setPriorityFilter] = useState('');
  const [showFilters, setShowFilters] = useState(false);
  const [showFields, setShowFields] = useState(false);
  const [fields, setFields] = useStored('tapdFields', FIELDS);
  const [collapsed, setCollapsed] = useStored('tapdCollapsed', {});
  const [starred, setStarred] = useStored('tapdStarred', []);
  const [recent, setRecent] = useStored('tapdRecent', []);
  const [list, setList] = useState(null);
  const [listError, setListError] = useState(null);
  const [loading, setLoading] = useState(false);
  const [selected, setSelected] = useStored('tapdSelected', null);
  const listToken = useRef(0);
  const pageRef = useRef(null);
  const listScroll = useRef(0);

  const remote = scope === '待办' || scope === '已创建';
  const workspaceId = workspace === 'all' ? undefined : workspace;
  const trimmed = query.trim();
  const numeric = /^\d+$/.test(trimmed);

  const load = useCallback(
    (page = 1, idQuery = null) => {
      const token = ++listToken.current; // 新请求让旧结果作废，返回顺序颠倒也不会被覆盖
      setLoading(true);
      request(
        'tapd.todos',
        { workspaceId, page, query: idQuery ?? undefined, scope: scope === '已创建' ? 'created' : 'todo' },
        { timeoutMs: 120000 },
      )
        .then((result) => {
          if (token !== listToken.current) return;
          setList((current) =>
            page > 1 && current ? { ...result, items: [...current.items, ...result.items] } : { ...result, query: idQuery },
          );
          setListError(null);
        })
        .catch((cause) => {
          if (token !== listToken.current) return;
          setListError(errorText(cause)); // 保留旧数据，只标记这次刷新失败
        })
        .finally(() => token === listToken.current && setLoading(false));
    },
    [workspaceId, scope],
  );

  useEffect(() => {
    if (!enabled || !remote) return;
    setList(null);
    load(1);
  }, [enabled, remote, load]);

  // 第一栏搜索框：输入即筛选；纯数字回车按编号向 TAPD 查询；离开编号查询时回到列表。
  useEffect(() => {
    if (!submitRef) return undefined;
    submitRef.current = (value) => {
      const text = String(value ?? '').trim();
      if (remote && /^\d+$/.test(text)) {
        setSelected(null);
        load(1, text);
      }
    };
    return () => {
      submitRef.current = null;
    };
  }, [remote, load]);
  useEffect(() => {
    if (remote && list?.byId && trimmed !== list.query) load(1);
  }, [trimmed]);

  // 今天到期的待办：桌宠每天提醒一次（deadline）。
  useEffect(() => {
    if (scope !== '待办' || !list?.items?.length) return;
    const now = new Date();
    const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
    if (!list.items.some((item) => item.due?.startsWith(today))) return;
    try {
      if (localStorage.getItem('cp.pet.deadline') === today) return;
      localStorage.setItem('cp.pet.deadline', today);
    } catch {}
    petEvent('deadline');
  }, [list, scope]);

  // 外部要求定位到某个 TAPD 对象（Work 详情里的来源入口）。
  useEffect(() => {
    if (focusRef) setSelected(focusRef);
  }, [refKey(focusRef)]);

  function openItem(item) {
    listScroll.current = pageRef.current?.scrollTop ?? 0;
    pageRef.current?.scrollTo({ top: 0 });
    setSelected(item.ref);
    setRecent((current) =>
      [summaryOf(item), ...current.filter((entry) => refKey(entry.ref) !== refKey(item.ref))].slice(0, RECENT_LIMIT),
    );
  }

  function closeDetail() {
    setSelected(null);
    window.requestAnimationFrame(() => pageRef.current?.scrollTo({ top: listScroll.current }));
  }

  const source = remote ? list?.items ?? [] : scope === '已关注' ? starred : recent;
  const inWorkspace = (item) => !workspaceId || item.ref.workspaceId === workspaceId;
  const items = source.filter((item) => {
    if (!inWorkspace(item)) return false;
    if (statusFilter && item.status !== statusFilter) return false;
    if (priorityFilter && item.priority !== priorityFilter) return false;
    if (!trimmed || (remote && list?.byId)) return true;
    return (
      item.title.includes(trimmed) || item.ref.entityId.includes(trimmed) || String(item.shortId).includes(trimmed)
    );
  });
  const statuses = [...new Set(source.map((item) => item.status).filter(Boolean))];
  const priorities = [...new Set(source.map((item) => item.priority).filter(Boolean))];
  const groups = useMemo(() => {
    const order = workspaces.map((item) => item.id);
    const names = Object.fromEntries(workspaces.map((item) => [item.id, item.name]));
    const map = new Map();
    for (const item of items) {
      const id = item.ref.workspaceId;
      if (!map.has(id)) map.set(id, { id, name: names[id] ?? item.workspaceName ?? id, rows: [] });
      map.get(id).rows.push(item);
    }
    return [...map.values()].sort((a, b) => {
      const ai = order.indexOf(a.id);
      const bi = order.indexOf(b.id);
      return (ai < 0 ? 999 : ai) - (bi < 0 ? 999 : bi);
    });
  }, [items, workspaces]);

  const isStarred = (ref) => starred.some((entry) => refKey(entry.ref) === refKey(ref));
  function toggleStar(item) {
    setStarred((current) =>
      isStarred(item.ref)
        ? current.filter((entry) => refKey(entry.ref) !== refKey(item.ref))
        : [summaryOf(item), ...current],
    );
  }

  if (config && !enabled) {
    return (
      <main className="module-page tapd-page">
        <div className="empty">
          <PlugsConnected size={30} />
          <h3>TAPD 连接未启用</h3>
          <p>在设置里启用 TAPD 连接并选择要显示的项目后，这里会列出分配给你的待办。</p>
          <button className="primary" onClick={onOpenSettings}>
            打开 TAPD 连接设置
          </button>
        </div>
      </main>
    );
  }

  return (
    <main ref={pageRef} className="module-page tapd-page">
      {selected ? (
        <TapdDetail
          key={refKey(selected)}
          refValue={selected}
          workspaceName={workspaces.find((item) => item.id === selected.workspaceId)?.name}
          projects={projects}
          mappings={Object.fromEntries((config?.settings?.workspaces ?? []).map((item) => [item.id, item.projects ?? []]))}
          runtime={runtime}
          notify={notify}
          starred={isStarred(selected)}
          onToggleStar={toggleStar}
          onBack={closeDetail}
          onOpen={openItem}
          onOpenWork={onOpenWork}
          onWorkCreated={onWorkCreated}
          onChanged={(summary) => {
            // 详情里流转了状态：列表 / 收藏 / 最近访问里同步这一行。
            const patch = (entry) => (refKey(entry.ref) === refKey(summary.ref) ? { ...entry, ...summary } : entry);
            setList((current) => (current ? { ...current, items: current.items.map(patch) } : current));
            setStarred((current) => current.map(patch));
            setRecent((current) => current.map(patch));
          }}
        />
      ) : (
        <>
          <header className="tapd-heading">
            <h2>我的工作</h2>
            <div>
              {remote && list?.fetchedAt && (
                <span className="sync-label">
                  {list.user?.name ?? ''} · 更新于 {formatTime(list.fetchedAt)}
                </span>
              )}
              {remote && (
                <button
                  className="secondary"
                  disabled={loading}
                  onClick={() => load(1, numeric && list?.byId ? trimmed : null)}
                >
                  <ArrowsClockwise size={14} className={loading ? 'spin' : ''} /> {loading ? '读取中…' : '刷新'}
                </button>
              )}
            </div>
          </header>
          <div className="tapd-toolbar">
            <nav aria-label="我的工作分类">
              {SCOPES.map((item) => (
                <button
                  key={item}
                  className={scope === item ? 'active' : ''}
                  onClick={() => {
                    setScope(item);
                    setStatusFilter('');
                    setPriorityFilter('');
                  }}
                >
                  {item}
                </button>
              ))}
            </nav>
            <div>
              <span>共 {items.length} 个</span>
              <button aria-expanded={showFilters} onClick={() => setShowFilters(!showFilters)}>
                筛选
              </button>
              <button aria-expanded={showFields} onClick={() => setShowFields(!showFields)}>
                字段
              </button>
            </div>
          </div>
          {showFilters && (
            <div className="module-filters">
              <select aria-label="TAPD 任务状态" value={statusFilter} onChange={(event) => setStatusFilter(event.target.value)}>
                <option value="">全部状态</option>
                {statuses.map((value) => (
                  <option key={value}>{value}</option>
                ))}
              </select>
              <select
                aria-label="任务优先级"
                value={priorityFilter}
                onChange={(event) => setPriorityFilter(event.target.value)}
              >
                <option value="">全部优先级</option>
                {priorities.map((value) => (
                  <option key={value}>{value}</option>
                ))}
              </select>
              <button
                onClick={() => {
                  setStatusFilter('');
                  setPriorityFilter('');
                }}
              >
                重置筛选
              </button>
            </div>
          )}
          {showFields && (
            <div className="tapd-field-picker">
              {FIELDS.map((field) => (
                <label key={field}>
                  <input
                    type="checkbox"
                    checked={fields.includes(field)}
                    onChange={() =>
                      setFields((current) =>
                        current.includes(field)
                          ? current.filter((item) => item !== field)
                          : FIELDS.filter((item) => item === field || current.includes(item)),
                      )
                    }
                  />
                  {field}
                </label>
              ))}
            </div>
          )}
          {remote && listError && (
            <div className="pane-note error" role="alert">
              <Warning size={14} />
              {list ? '刷新失败，显示的是上次读取的内容：' : ''}
              {listError}
            </div>
          )}
          {remote &&
            (list?.errors ?? []).map((item) => (
              <div className="pane-note warn" key={item.workspaceId}>
                <Warning size={14} />
                项目 {item.workspaceId} 读取失败：{item.message}
                {item.detail ? `（${item.detail}）` : ''}
              </div>
            ))}
          {remote && !list && !listError && (
            <div className="tapd-loading">
              <img src={racingClawd} alt="" />
              <span>正在读取 TAPD…</span>
            </div>
          )}
          {list?.byId && remote && <p className="module-empty">编号 {trimmed} 的查询结果</p>}
          {groups.map((group) => (
            <section className="tapd-group" key={group.id}>
              <button
                className="tapd-group-heading"
                aria-expanded={!collapsed[group.id]}
                onClick={() => setCollapsed((current) => ({ ...current, [group.id]: !current[group.id] }))}
              >
                <span>{collapsed[group.id] ? '▸' : '▾'}</span>
                {group.name}
                <small>({group.rows.length})</small>
              </button>
              {!collapsed[group.id] && (
                <div className="tapd-table-scroll">
                  <table className="tapd-table">
                    <thead>
                      <tr>
                        <th>标题</th>
                        <th>状态</th>
                        {fields.map((field) => (
                          <th key={field}>{field}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {group.rows.map((item) => (
                        <tr key={refKey(item.ref)}>
                          <td>
                            <button className="tapd-task-title" onClick={() => openItem(item)}>
                              <span className={`tapd-type ${item.type === 'bug' ? 'bug' : ''}`}>{typeMark(item.type)}</span>
                              <span>
                                {item.title}
                                <small>#{item.shortId}</small>
                              </span>
                            </button>
                          </td>
                          <td>
                            <span className="tapd-status">{item.status ?? '—'}</span>
                          </td>
                          {fields.map((field) => (
                            <td key={field}>
                              {field === '优先级' ? (
                                item.priority ? (
                                  <span className={`tapd-priority ${priorityTone(item.priority)}`}>{item.priority}</span>
                                ) : (
                                  '—'
                                )
                              ) : field === '迭代' ? (
                                item.iterationName ?? '—'
                              ) : field === '预计结束' ? (
                                item.due ?? '—'
                              ) : field === '处理人' ? (
                                item.owner ? (
                                  <span className="tapd-owner">
                                    <span className="tapd-avatar">{firstChar(item.owner)}</span>
                                    {cleanOwner(item.owner)}
                                  </span>
                                ) : (
                                  '—'
                                )
                              ) : (
                                item.created?.slice(0, 16) ?? '—'
                              )}
                            </td>
                          ))}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </section>
          ))}
          {(!remote || list) && !items.length && (
            <div className="tapd-empty">
              <img src={magnifierClawd} alt="" />
              <p>
                {trimmed || statusFilter || priorityFilter
                  ? '当前筛选下没有任务项。'
                  : scope === '已关注'
                    ? '还没有关注的工作项。在详情里点 ☆ 关注。'
                    : scope === '最近访问'
                      ? '还没有打开过工作项。'
                      : scope === '已创建'
                        ? '没有你创建的需求或缺陷。'
                        : '当前没有分配给你的待办。'}
              </p>
              {(statusFilter || priorityFilter) && (
                <button
                  className="link-button"
                  onClick={() => {
                    setStatusFilter('');
                    setPriorityFilter('');
                  }}
                >
                  清除筛选
                </button>
              )}
            </div>
          )}
          {remote && list?.hasMore && !list.byId && (
            <button className="secondary full" disabled={loading} onClick={() => load((list.page ?? 1) + 1)}>
              {loading ? '读取中…' : '加载更多'}
            </button>
          )}
        </>
      )}
    </main>
  );
}

function TapdDetail({
  refValue,
  workspaceName,
  projects,
  mappings,
  runtime,
  notify,
  starred,
  onToggleStar,
  onBack,
  onOpen,
  onOpenWork,
  onWorkCreated,
  onChanged,
}) {
  const [detail, setDetail] = useState(null);
  const [error, setError] = useState(null);
  const [tab, setTab] = useState('detail');
  const [related, setRelated] = useState({});
  const [meta, setMeta] = useState(null);
  const [transition, setTransition] = useState(null);
  const [creating, setCreating] = useState(false);
  const [drafts, setDrafts] = useStored('tapdCommentDrafts', {});
  const [posting, setPosting] = useState(false);
  const [commentError, setCommentError] = useState(null);
  const commentRequest = useRef(newId());
  const key = refKey(refValue);
  const draft = drafts[key] ?? '';

  const loadDetail = useCallback(() => {
    setError(null);
    return request('tapd.detail', { ref: refValue }, { timeoutMs: 120000 })
      .then((result) => {
        setDetail(result);
        return result;
      })
      .catch((cause) => setError(errorText(cause)));
  }, [key]);

  useEffect(() => {
    loadDetail();
    request('tapd.fields', { ref: refValue }, { timeoutMs: 120000 })
      .then(setMeta)
      .catch(() => setMeta({ statuses: [], resolutions: [], members: [], labels: {} }));
  }, [key]);

  useEffect(() => {
    if (tab === 'detail' || related[tab]) return;
    setRelated((current) => ({ ...current, [tab]: { loading: true } }));
    request('tapd.related', { ref: refValue, kind: tab }, { timeoutMs: 120000 })
      .then((result) => setRelated((current) => ({ ...current, [tab]: { items: result.items ?? [] } })))
      .catch((cause) => setRelated((current) => ({ ...current, [tab]: { error: errorText(cause) } })));
  }, [tab, key]);

  const tabs = DETAIL_TABS.filter(([id]) => refValue.entityType === 'story' || !['children', 'tcases'].includes(id));
  const statusLabel = (raw) => meta?.statuses?.find((item) => item.key === raw)?.label ?? detail?.status ?? raw;

  async function postComment() {
    const body = draft.trim();
    if (!body || posting) return;
    setPosting(true);
    setCommentError(null);
    try {
      const result = await request('tapd.comment', { ref: refValue, body, requestId: commentRequest.current }, { timeoutMs: 120000 });
      commentRequest.current = newId();
      setDrafts((current) => {
        const next = { ...current };
        delete next[key];
        return next;
      });
      notify(result.verified ? '评论已发表（已回读确认）' : '评论已发表');
      loadDetail();
    } catch (cause) {
      setCommentError(errorText(cause)); // 保留输入
    } finally {
      setPosting(false);
    }
  }

  if (error && !detail) {
    return (
      <section className="tapd-detail" aria-label="TAPD 工作项详情">
        <header className="tapd-detail-bar">
          <strong>#{shortId(refValue.entityId)}</strong>
          <button onClick={onBack}>返回列表 →</button>
        </header>
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      </section>
    );
  }
  if (!detail) {
    return (
      <section className="tapd-detail" aria-label="TAPD 工作项详情">
        <header className="tapd-detail-bar">
          <strong>#{shortId(refValue.entityId)}</strong>
          <button onClick={onBack}>返回列表 →</button>
        </header>
        <div className="tapd-loading">
          <img src={racingClawd} alt="" />
          <span>正在读取详情…</span>
        </div>
      </section>
    );
  }

  const summary = summaryOf({ ...detail, shortId: shortId(detail.ref.entityId) });
  const owner = cleanOwner(detail.owner);
  const basic = [
    ['状态', detail.status ?? '—'],
    ['类型', typeLabel(detail.type)],
    ['迭代', detail.iteration?.name ?? (detail.iteration?.id ? `迭代 ${detail.iteration.id}` : '—')],
    ['优先级', detail.priority ?? '—'],
    ...(detail.type === 'bug' ? [['严重程度', detail.severity ?? '—']] : []),
    ['处理人', owner || '—'],
    ['创建人', detail.creator ?? '—'],
    ['创建时间', detail.created?.slice(0, 16) ?? '—'],
    ['计划时间', detail.begin || detail.due ? `${detail.begin ?? '—'} → ${detail.due ?? '—'}` : '—'],
    ['最近更新', detail.modified?.slice(0, 16) ?? '—'],
    ['完整 ID', detail.ref.entityId],
  ];

  return (
    <section className="tapd-detail" aria-label="TAPD 工作项详情">
      {creating && (
        <CreateTaskDialog
          detail={{ ...detail, workspaceName }}
          projects={projects}
          mappings={mappings}
          runtime={runtime}
          notify={notify}
          onClose={() => setCreating(false)}
          onOpenWork={(id) => {
            setCreating(false);
            onOpenWork(id);
          }}
          onCreated={(work) => {
            setCreating(false);
            onWorkCreated(work);
          }}
        />
      )}
      {transition && (
        <TransitionDialog
          detail={detail}
          meta={meta}
          target={transition}
          fromLabel={statusLabel(detail.rawStatus)}
          notify={notify}
          onClose={() => setTransition(null)}
          onDone={async () => {
            setTransition(null);
            const next = await loadDetail();
            if (next) onChanged({ ref: next.ref, status: next.status, owner: next.owner });
          }}
        />
      )}
      <header className="tapd-detail-bar">
        <span className="tapd-status">{detail.status ?? '—'}</span>
        <strong>ID: {shortId(detail.ref.entityId)}</strong>
        <button onClick={() => openExternal(tapdUrl(detail.ref))} title="在浏览器打开 TAPD">
          <ArrowSquareOut size={13} /> 打开 TAPD
        </button>
        <button onClick={onBack} aria-label="关闭任务详情">
          返回列表 →
        </button>
      </header>
      <div className="tapd-detail-grid">
        <article className="tapd-detail-main">
          <h3>
            <span className={`tapd-type ${detail.type === 'bug' ? 'bug' : ''}`}>{typeMark(detail.type)}</span>
            {detail.title}
            <button
              aria-label={starred ? '取消关注任务' : '关注任务'}
              title={starred ? '取消关注（只在本机记录）' : '关注（只在本机记录）'}
              onClick={() => onToggleStar(summary)}
            >
              {starred ? '★' : '☆'}
            </button>
          </h3>
          <nav className="tapd-detail-tabs" aria-label="任务详情页签">
            {tabs.map(([id, label]) => (
              <button key={id} className={tab === id ? 'active' : ''} onClick={() => setTab(id)}>
                {label}
                {related[id]?.items ? ` (${related[id].items.length})` : ''}
              </button>
            ))}
          </nav>
          {tab === 'detail' ? (
            <>
              <div className="tapd-description">
                {detail.descriptionText ? <pre>{detail.descriptionText}</pre> : <p className="muted">没有描述。</p>}
                {detail.imageCount > 0 && <p className="muted">描述里有 {detail.imageCount} 张图片，图片内容没有被读取。</p>}
              </div>
              <details className="tapd-section">
                <summary>附件 ({detail.attachments.items.length})</summary>
                {detail.attachments.state === 'failed' ? (
                  <p className="red">附件清单读取失败：{detail.attachments.message}</p>
                ) : detail.attachments.items.length === 0 ? (
                  <p>暂无附件</p>
                ) : (
                  detail.attachments.items.map((file) => (
                    <p key={file.id ?? file.name}>
                      {file.name ?? '未命名附件'} <small className="muted">仅列出，内容未读取</small>
                    </p>
                  ))
                )}
              </details>
              <details className="tapd-section" open>
                <summary>评论 ({detail.comments.items.length})</summary>
                {detail.comments.state === 'failed' ? (
                  <p className="red">评论读取失败：{detail.comments.message}</p>
                ) : detail.comments.items.length === 0 ? (
                  <p>暂无评论</p>
                ) : (
                  detail.comments.items.map((comment) => (
                    <div className="tapd-comment" key={comment.id}>
                      <small>
                        {comment.author} · {comment.created}
                      </small>
                      <p>{comment.text}</p>
                    </div>
                  ))
                )}
              </details>
              <section className="tapd-workflow">
                <h4>工作流</h4>
                <div>
                  <span className="current">{detail.status ?? '—'}（当前）</span>
                </div>
                <label className="tapd-transition">
                  流转到
                  <select
                    aria-label="流转到"
                    value=""
                    disabled={!meta?.statuses?.length}
                    onChange={(event) => {
                      const option = meta.statuses.find((item) => item.key === event.target.value);
                      if (option) setTransition(option);
                    }}
                  >
                    <option value="">{meta ? (meta.statuses?.length ? '选择目标状态…' : '读取不到状态列表') : '读取中…'}</option>
                    {(meta?.statuses ?? [])
                      .filter((item) => item.key !== detail.rawStatus)
                      .map((item) => (
                        <option key={item.key} value={item.key}>
                          {item.label}
                        </option>
                      ))}
                  </select>
                </label>
                <p>
                  处理人 <strong>{owner || '—'}</strong>
                </p>
                <small>流转会直接修改 TAPD 上的状态，提交前会再确认一次。</small>
              </section>
              {detail.existingWorks.length > 0 && (
                <section className="tapd-section tapd-linked">
                  <h4>已关联的 Work</h4>
                  {detail.existingWorks.map((work) => (
                    <button className="link-button" key={work.id} onClick={() => onOpenWork(work.id)}>
                      {work.displayId} · {work.title}（{work.statusLabel}）
                    </button>
                  ))}
                </section>
              )}
            </>
          ) : (
            <RelatedTab kind={tab} state={related[tab]} onOpen={onOpen} />
          )}
        </article>
        <aside className="tapd-basic" aria-label="基础信息">
          <h4>基础信息</h4>
          <dl>
            {basic.map(([label, value]) => (
              <React.Fragment key={label}>
                <dt>{label}</dt>
                <dd>{value}</dd>
              </React.Fragment>
            ))}
          </dl>
        </aside>
      </div>
      {commentError && (
        <div className="pane-note error tapd-comment-error" role="alert">
          <Warning size={14} />
          {commentError}
        </div>
      )}
      <form
        className="tapd-comment-form"
        onSubmit={(event) => {
          event.preventDefault();
          postComment();
        }}
      >
        <span className="tapd-avatar">我</span>
        <textarea
          aria-label="任务评论"
          rows={1}
          placeholder="输入评论，⌘↩ 发表（支持 Markdown，会写入 TAPD）"
          value={draft}
          onChange={(event) => setDrafts((current) => ({ ...current, [key]: event.target.value }))}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              event.preventDefault();
              postComment();
            }
          }}
        />
        <button disabled={!draft.trim() || posting}>{posting ? '发表中…' : '发表评论'}</button>
        <button type="button" className="tapd-create-work" onClick={() => setCreating(true)}>
          <PlusCircle size={14} /> 创建任务
        </button>
      </form>
    </section>
  );
}

function RelatedTab({ kind, state, onOpen }) {
  if (!state || state.loading) return <div className="tapd-tab-empty">正在读取…</div>;
  if (state.error)
    return (
      <div className="pane-note error" role="alert">
        <Warning size={14} />
        {state.error}
      </div>
    );
  if (!state.items.length) {
    const label = { children: '子需求', bugs: '关联缺陷', tcases: '测试用例', changes: '变更记录' }[kind];
    return <div className="tapd-tab-empty">暂无{label}。</div>;
  }
  if (kind === 'changes')
    return (
      <ol className="tapd-changes">
        {state.items.map((item, index) => (
          <li key={item.id ?? index}>
            <small>
              {item.author ?? '—'} · {item.created ?? ''}
            </small>
            {item.changes.length ? (
              item.changes.map((change, i) => (
                <p key={i}>
                  <b>{change.field}</b>：{change.before || '（空）'} → {change.after || '（空）'}
                </p>
              ))
            ) : (
              <p>{item.summary ?? '—'}</p>
            )}
          </li>
        ))}
      </ol>
    );
  if (kind === 'tcases')
    return (
      <ul className="tapd-related">
        {state.items.map((item, index) => (
          <li key={item.id ?? index}>
            <span>{item.name ?? item.id}</span>
            <span className="tapd-status">{item.result ?? item.status ?? '—'}</span>
          </li>
        ))}
      </ul>
    );
  return (
    <ul className="tapd-related">
      {state.items.map((item) => (
        <li key={refKey(item.ref)}>
          <button className="tapd-task-title" onClick={() => onOpen(item)}>
            <span className={`tapd-type ${item.type === 'bug' ? 'bug' : ''}`}>{typeMark(item.type)}</span>
            <span>
              {item.title}
              <small>#{item.shortId}</small>
            </span>
          </button>
          <span className="tapd-status">{item.status ?? '—'}</span>
        </li>
      ))}
    </ul>
  );
}

function TransitionDialog({ detail, meta, target, fromLabel, notify, onClose, onDone }) {
  const isBug = detail.type === 'bug';
  const [resolution, setResolution] = useState('');
  const [changeOwner, setChangeOwner] = useState(false);
  const [owner, setOwner] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const requestId = useRef(newId());
  const ready = !busy && (!changeOwner || owner);

  async function submit() {
    if (!ready) return;
    setBusy(true);
    setError(null);
    try {
      const result = await request(
        'tapd.transition',
        {
          ref: detail.ref,
          to: target.key,
          toLabel: target.label,
          fromLabel,
          owner: changeOwner ? owner : undefined,
          resolution: isBug && resolution ? resolution : undefined,
          requestId: requestId.current,
        },
        { timeoutMs: 120000 },
      );
      notify(`已流转到 ${target.label}${result.verified ? '（已回读确认）' : ''}`);
      petEvent('lgtm');
      onDone();
    } catch (cause) {
      setError(errorText(cause)); // 弹窗不关，状态不变
      requestId.current = newId();
      setBusy(false);
    }
  }

  return (
    <ModalFrame title="流转状态" onClose={onClose}>
      <p className="transition-summary">
        将 <b>#{shortId(detail.ref.entityId)}</b> 从「{fromLabel}」流转到「<b>{target.label}</b>」？这会修改 TAPD 上的状态。
      </p>
      {isBug && (meta?.resolutions?.length ?? 0) > 0 && (
        <label className="field">
          解决方法（目标状态要求时填写）
          <select value={resolution} onChange={(event) => setResolution(event.target.value)}>
            <option value="">不填写</option>
            {meta.resolutions.map((item) => (
              <option key={item.key} value={item.key}>
                {item.label}
              </option>
            ))}
          </select>
        </label>
      )}
      <label className="check-option">
        <input type="checkbox" checked={changeOwner} onChange={(event) => setChangeOwner(event.target.checked)} />
        同时修改处理人
      </label>
      {changeOwner && (
        <label className="field">
          新处理人
          <select value={owner} onChange={(event) => setOwner(event.target.value)}>
            <option value="">请选择…</option>
            {(meta?.members ?? []).map((name) => (
              <option key={name}>{name}</option>
            ))}
          </select>
        </label>
      )}
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      <div className="modal-footer">
        <button onClick={onClose}>取消</button>
        <button className="primary" disabled={!ready} onClick={submit}>
          {busy ? '正在流转…' : '确认流转'}
        </button>
      </div>
    </ModalFrame>
  );
}

/// 创建任务：TAPD 工作项 → 本地 Work（docs §5.4）。只创建本地 Work，不改 TAPD。
function CreateTaskDialog({ detail, projects, mappings, runtime, notify, onClose, onCreated, onOpenWork }) {
  const ref = detail.ref;
  const candidates = (mappings[ref.workspaceId] ?? []).filter((path) => projects.some((item) => item.path === path));
  const [projectPath, setProjectPath] = useState(candidates.length === 1 ? candidates[0] : '');
  const [title, setTitle] = useState(`${shortId(ref.entityId)} ${detail.title}`);
  const [supplement, setSupplement] = useState('');
  const [advanced, setAdvanced] = useState(false);
  const [options, setOptions] = useState({ isolation: 'worktree', permissionMode: runtime.mode, model: '' });
  const [start, setStart] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [existing, setExisting] = useState(detail.existingWorks ?? []);
  const [newRound, setNewRound] = useState(false);
  const requestId = useRef(newId());
  const blocked = existing.length > 0 && !newRound;
  const ready = title.trim() && projectPath && !busy && !blocked;

  async function create() {
    if (!ready) return;
    setBusy(true);
    setError(null);
    const base = `实现 TAPD ${typeLabel(detail.type)}「${detail.title}」所描述的内容。`;
    const objective = supplement.trim() ? `${base}\n\n补充说明：\n${supplement.trim()}` : base;
    try {
      const result = await request(
        'tapd.import',
        { ref, projectPath, title: title.trim(), objective, start, newRound, requestId: requestId.current, ...options },
        { timeoutMs: 120000 },
      );
      if (!result.created) {
        setExisting(result.existing ?? []);
        setNewRound(false);
        setBusy(false);
        return;
      }
      notify(`已创建 ${result.work.displayId}${start ? '，已请求启动' : '，等待启动'}`);
      onCreated(result.work);
    } catch (cause) {
      setError(errorText(cause)); // 输入保留
      setBusy(false);
    }
  }

  return (
    <ModalFrame title="创建任务" onClose={onClose}>
      <div className="tapd-create-source">
        <small>
          来源 · {detail.workspaceName ?? ref.workspaceId} · TAPD #{shortId(ref.entityId)}
        </small>
        <strong>{detail.title}</strong>
        {detail.descriptionText && <p>{detail.descriptionText.slice(0, 160)}</p>}
      </div>
      {existing.length > 0 && (
        <div className="pane-note warn" role="status">
          <Warning size={14} />
          <div>
            这个 TAPD 对象已经关联了 Work：
            {existing.map((work) => (
              <button className="link-button" key={work.id} onClick={() => onOpenWork(work.id)}>
                {work.displayId}（{work.statusLabel}）
              </button>
            ))}
            <label className="inline-check">
              <input type="checkbox" checked={newRound} onChange={(event) => setNewRound(event.target.checked)} />
              仍然新建一个 Work（明确开启新一轮）
            </label>
          </div>
        </div>
      )}
      <label className="field">
        任务名称
        <input maxLength={160} value={title} onChange={(event) => setTitle(event.target.value)} />
      </label>
      <label className="field">
        补充内容
        <textarea
          rows={5}
          placeholder="补充实现要求、注意事项或验收标准…"
          value={supplement}
          onChange={(event) => setSupplement(event.target.value)}
        />
      </label>
      <label className="field">
        本地项目
        <select value={projectPath} onChange={(event) => setProjectPath(event.target.value)}>
          <option value="">请选择执行这个需求的本地项目…</option>
          {projects.map((project) => (
            <option key={project.path} value={project.path}>
              {project.title}
              {candidates.includes(project.path) ? '（已映射）' : ''}
            </option>
          ))}
        </select>
        {candidates.length > 1 && <small>这个 TAPD 项目映射了多个本地仓库，请明确选择一个。</small>}
      </label>
      <button className="link-button" aria-expanded={advanced} onClick={() => setAdvanced(!advanced)}>
        {advanced ? '收起高级选项' : '高级选项（执行目录、权限、模型）'}
      </button>
      {advanced && <RunOptions runtime={runtime} value={options} onChange={setOptions} />}
      <label className="check-option">
        <input type="checkbox" checked={start} onChange={(event) => setStart(event.target.checked)} />
        创建后立即启动（按执行槽排队；不勾选则保留为待启动）
      </label>
      <p className="tapd-create-hint">创建后进入 Work 中心，保留 TAPD 来源与补充内容。只创建本地 Work，不会修改 TAPD。</p>
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
      <div className="modal-footer">
        <button onClick={onClose}>取消</button>
        <button className="primary" disabled={!ready} onClick={create}>
          <PlusCircle size={14} />
          {busy ? '正在创建…' : '创建并进入 Work'}
        </button>
      </div>
    </ModalFrame>
  );
}
