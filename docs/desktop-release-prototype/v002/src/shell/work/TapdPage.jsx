// TAPD 待办：分配给当前账号的需求与缺陷。只读；导入只创建本地 Work，不改 TAPD 的任何状态。
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ArrowsClockwise,
  BookOpen,
  Bug,
  Gear,
  Info,
  MagnifyingGlass,
  Paperclip,
  PlugsConnected,
  PlusCircle,
  Warning,
} from '@phosphor-icons/react';
import { errorText, request } from '../bridge.js';
import { IconButton, useStored } from '../ui.jsx';
import { formatTime, newId, shortId } from './useWorks.js';
import { ModalFrame, RunOptions } from './WorkModals.jsx';

const refKey = (ref) => (ref ? `${ref.workspaceId}:${ref.entityType}:${ref.entityId}` : '');

function priorityTone(value = '') {
  const text = String(value).toLowerCase();
  if (text.includes('urgent') || text.includes('紧急') || text.includes('high') || text === '高') return 'orange';
  return 'neutral';
}

export function ImportModal({ detail, projects, mappings, runtime, notify, onClose, onCreated, onOpenWork }) {
  const ref = detail.ref;
  const candidates = (mappings[ref.workspaceId] ?? []).filter((path) => projects.some((item) => item.path === path));
  // 只有唯一的映射候选时才预选；没有或有多个都要用户明确选择，不默认取第一个。
  const [projectPath, setProjectPath] = useState(candidates.length === 1 ? candidates[0] : '');
  const [title, setTitle] = useState(detail.title);
  const [objective, setObjective] = useState(`实现 TAPD ${detail.type === 'bug' ? '缺陷' : '需求'}「${detail.title}」所描述的内容。`);
  const [start, setStart] = useState(false);
  const [options, setOptions] = useState({ isolation: 'worktree', permissionMode: runtime.mode, model: '' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [existing, setExisting] = useState(detail.existingWorks ?? []);
  const [newRound, setNewRound] = useState(false);
  const requestId = useRef(newId());
  const blocked = existing.length > 0 && !newRound;
  const ready = title.trim() && objective.trim() && projectPath && !busy && !blocked;

  async function create() {
    if (!ready) return;
    setBusy(true);
    setError(null);
    try {
      const result = await request(
        'tapd.import',
        { ref, projectPath, title: title.trim(), objective: objective.trim(), start, newRound, requestId: requestId.current, ...options },
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
      onClose();
    } catch (cause) {
      setError(errorText(cause)); // 输入保留
      setBusy(false);
    }
  }

  return (
    <ModalFrame title="创建开发任务" onClose={onClose}>
      <div className="import-source">
        <span className="tapd-logo">T</span>
        <div>
          <small>
            TAPD {detail.type} · workspace {ref.workspaceId} · #{ref.entityId}
          </small>
          <h3>{detail.title}</h3>
        </div>
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
        Work 名称（只改本地名称，不改 TAPD 标题）
        <input value={title} onChange={(event) => setTitle(event.target.value)} />
      </label>
      <label className="field">
        工作目标
        <textarea rows={3} value={objective} onChange={(event) => setObjective(event.target.value)} />
        <small>需求描述的快照会随目标一起交给执行器，并注明它是外部资料。</small>
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
      <RunOptions runtime={runtime} value={options} onChange={setOptions} />
      <label className="check-option">
        <input type="checkbox" checked={start} onChange={(event) => setStart(event.target.checked)} />
        创建后启动（按执行槽排队；不勾选则保留为待启动）
      </label>
      <div className="source-note">
        <Info size={13} />
        只创建本地 Work。TAPD 的状态、排期与工时不会被修改。
      </div>
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
          {busy ? '正在创建…' : '创建 Work'}
        </button>
      </div>
    </ModalFrame>
  );
}

export default function TapdPage({ projects, runtime, notify, focusRef, onOpenSettings, onOpenWork, onWorkCreated }) {
  const [config, setConfig] = useState(null);
  const [workspace, setWorkspace] = useStored('tapdWorkspace', '');
  const [query, setQuery] = useStored('tapdQuery', '');
  const [statusFilter, setStatusFilter] = useState('');
  const [list, setList] = useState(null);
  const [listError, setListError] = useState(null);
  const [loading, setLoading] = useState(false);
  const [selected, setSelected] = useStored('tapdSelected', null);
  const [detail, setDetail] = useState(null);
  const [detailError, setDetailError] = useState(null);
  const [importing, setImporting] = useState(false);
  const listToken = useRef(0);
  const detailToken = useRef(0);

  const enabledWorkspaces = (config?.settings?.workspaces ?? []).filter((item) => item.enabled !== false);
  const mappings = Object.fromEntries((config?.settings?.workspaces ?? []).map((item) => [item.id, item.projects ?? []]));

  useEffect(() => {
    request('tapd.settings')
      .then(setConfig)
      .catch((cause) => setListError(errorText(cause)));
  }, []);

  const load = useCallback(
    (page = 1, idQuery = null) => {
      const token = ++listToken.current; // 新的请求让旧结果作废：返回顺序与请求顺序相反时也不会被覆盖
      setLoading(true);
      request('tapd.todos', { workspaceId: workspace || undefined, page, query: idQuery ?? undefined }, { timeoutMs: 120000 })
        .then((result) => {
          if (token !== listToken.current) return;
          setList((current) =>
            page > 1 && current ? { ...result, items: [...current.items, ...result.items] } : result,
          );
          setListError(null);
        })
        .catch((cause) => {
          if (token !== listToken.current) return;
          setListError(errorText(cause)); // 保留旧数据，只标记这次刷新失败
        })
        .finally(() => token === listToken.current && setLoading(false));
    },
    [workspace],
  );

  const enabled = config?.settings?.enabled === true;
  useEffect(() => {
    if (enabled) load(1);
  }, [enabled, workspace, load]);

  // 外部要求定位到某个 TAPD 对象（Work 详情里的来源入口）。
  useEffect(() => {
    if (focusRef) setSelected(focusRef);
  }, [refKey(focusRef)]);

  useEffect(() => {
    if (!selected || !enabled) {
      setDetail(null);
      return;
    }
    const token = ++detailToken.current;
    setDetail(null);
    setDetailError(null);
    request('tapd.detail', { ref: selected }, { timeoutMs: 120000 })
      .then((result) => token === detailToken.current && setDetail(result))
      .catch((cause) => token === detailToken.current && setDetailError(errorText(cause)));
  }, [refKey(selected), enabled]);

  const trimmed = query.trim();
  const numeric = /^\d+$/.test(trimmed);
  const items = (list?.items ?? []).filter((item) => {
    if (statusFilter && item.status !== statusFilter) return false;
    if (!trimmed || list?.byId) return true;
    return item.title.includes(trimmed) || item.ref.entityId.includes(trimmed) || item.shortId.includes(trimmed);
  });
  const statuses = [...new Set((list?.items ?? []).map((item) => item.status).filter(Boolean))];

  if (config && !enabled) {
    return (
      <section className="page tapd-page">
        <div className="empty">
          <PlugsConnected size={30} />
          <h3>TAPD 连接未启用</h3>
          <p>在设置里启用 TAPD 连接并选择要显示的项目后，这里会列出分配给你的待办。</p>
          <button className="primary" onClick={onOpenSettings}>
            打开 TAPD 连接设置
          </button>
        </div>
      </section>
    );
  }

  return (
    <section className="page tapd-page">
      <div className="page-heading">
        <div>
          <div className="eyebrow">CONNECTED WORKSPACE</div>
          <h1>TAPD 待办</h1>
          <p>把需求带入工作空间。这里只读取，导入不会修改 TAPD。</p>
        </div>
        <div>
          {list?.fetchedAt && (
            <span className="sync-label">
              {list.user?.name ?? ''} · 更新于 {formatTime(list.fetchedAt)}
            </span>
          )}
          <button className="secondary" disabled={loading} onClick={() => load(1, numeric && list?.byId ? trimmed : null)}>
            <ArrowsClockwise size={14} className={loading ? 'spin' : ''} /> {loading ? '读取中…' : '刷新'}
          </button>
          <IconButton icon={Gear} label="TAPD 连接设置" onClick={onOpenSettings} />
        </div>
      </div>

      <div className="tapd-toolbar">
        <div className="project-filters" role="group" aria-label="TAPD 项目">
          <button className={workspace === '' ? 'active' : ''} onClick={() => setWorkspace('')}>
            全部项目
          </button>
          {enabledWorkspaces.map((item) => (
            <button key={item.id} className={workspace === item.id ? 'active' : ''} onClick={() => setWorkspace(item.id)}>
              {item.name}
            </button>
          ))}
        </div>
        {statuses.length > 0 && (
          <label className="inline-select">
            <select aria-label="按业务状态筛选" value={statusFilter} onChange={(event) => setStatusFilter(event.target.value)}>
              <option value="">全部状态</option>
              {statuses.map((value) => (
                <option key={value}>{value}</option>
              ))}
            </select>
          </label>
        )}
        <label className="search-box">
          <MagnifyingGlass size={14} />
          <input
            aria-label="搜索 TAPD 待办"
            placeholder="筛选标题，或输入编号后回车查询"
            value={query}
            onChange={(event) => {
              setQuery(event.target.value);
              if (list?.byId) load(1); // 离开编号查询，回到我的待办
            }}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && !event.nativeEvent.isComposing && numeric) load(1, trimmed);
            }}
          />
        </label>
      </div>

      {listError && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {list ? '刷新失败，显示的是上次读取的内容：' : ''}
          {listError}
        </div>
      )}
      {(list?.errors ?? []).map((item) => (
        <div className="pane-note warn" key={item.workspaceId}>
          <Warning size={14} />
          项目 {item.workspaceId} 读取失败：{item.message}
          {item.detail ? `（${item.detail}）` : ''}
        </div>
      ))}

      <div className="tapd-columns">
        <div className="story-list">
          <div className="list-label">
            <span>{list?.byId ? `编号 ${trimmed} 的查询结果` : '分配给我的待办'}</span>
            <span>{items.length} 项</span>
          </div>
          {!list && !listError && <div className="pane-note">正在读取待办…</div>}
          {list && items.length === 0 && (
            <div className="empty-state">
              <MagnifyingGlass size={18} />
              {trimmed || statusFilter ? '没有匹配的待办' : '当前没有分配给你的待办'}
              {(trimmed || statusFilter || workspace) && (
                <button
                  className="link-button"
                  onClick={() => {
                    setQuery('');
                    setStatusFilter('');
                    setWorkspace('');
                  }}
                >
                  回到全部
                </button>
              )}
            </div>
          )}
          {items.map((item) => (
            <button
              key={refKey(item.ref)}
              className={`story-row ${refKey(item.ref) === refKey(selected) ? 'selected' : ''}`}
              onClick={() => setSelected(item.ref)}
            >
              <span className={`entity-icon ${item.type === 'bug' ? 'red' : ''}`}>
                {item.type === 'bug' ? <Bug size={15} /> : <BookOpen size={15} />}
              </span>
              <div>
                <div className="story-id">
                  {item.workspaceName ?? item.ref.workspaceId} <span>/</span> #{item.shortId}
                </div>
                <h3>{item.title}</h3>
                <div className="story-meta">
                  {item.priority && <span className={`pill ${priorityTone(item.priority)}`}>{item.priority}</span>}
                  {item.modified && <span>更新 {item.modified.slice(0, 16)}</span>}
                </div>
              </div>
              <span className="pill neutral">{item.status ?? '—'}</span>
            </button>
          ))}
          {list?.hasMore && !list.byId && (
            <button className="secondary full" disabled={loading} onClick={() => load((list.page ?? 1) + 1)}>
              {loading ? '读取中…' : '加载更多'}
            </button>
          )}
        </div>

        <aside className="story-detail">
          {!selected && <p className="context-empty">在左侧选择一条待办查看详情。</p>}
          {selected && detailError && (
            <div className="pane-note error" role="alert">
              <Warning size={14} />
              {detailError}
            </div>
          )}
          {selected && !detail && !detailError && <div className="pane-note">正在读取详情…</div>}
          {detail && (
            <>
              <div className="detail-type">
                <span className="tapd-logo">T</span>TAPD {detail.type === 'bug' ? '缺陷' : detail.type === 'task' ? '任务' : '需求'}
                <code title={detail.ref.entityId}>#{shortId(detail.ref.entityId)}</code>
              </div>
              <h2>{detail.title}</h2>
              <dl className="metadata">
                <div>
                  <dt>业务状态</dt>
                  <dd>
                    <span className="pill blue">{detail.status ?? '—'}</span>
                  </dd>
                </div>
                <div>
                  <dt>负责人</dt>
                  <dd>{detail.owner?.replace(/;+$/, '') || '—'}</dd>
                </div>
                <div>
                  <dt>所属迭代</dt>
                  <dd>{detail.iteration?.name ?? (detail.iteration?.id ? `迭代 ${detail.iteration.id}` : '—')}</dd>
                </div>
                <div>
                  <dt>计划时间</dt>
                  <dd className={detail.begin || detail.due ? '' : 'muted'}>
                    {detail.begin || detail.due ? `${detail.begin ?? '—'} → ${detail.due ?? '—'}` : '待 TAPD 排期'}
                  </dd>
                </div>
                <div>
                  <dt>完整 ID</dt>
                  <dd>
                    <code>{detail.ref.entityId}</code>
                  </dd>
                </div>
              </dl>
              <div className="detail-section">
                <h3>描述</h3>
                {detail.descriptionText ? (
                  <pre className="tapd-description">{detail.descriptionText}</pre>
                ) : (
                  <p className="muted">没有描述。</p>
                )}
                {detail.imageCount > 0 && (
                  <p className="muted">描述里有 {detail.imageCount} 张图片，图片内容没有被读取。</p>
                )}
              </div>
              <div className="detail-section">
                <h3>附件</h3>
                {detail.attachments.state === 'failed' ? (
                  <p className="red">附件清单读取失败：{detail.attachments.message}</p>
                ) : detail.attachments.items.length === 0 ? (
                  <p className="muted">没有附件。</p>
                ) : (
                  detail.attachments.items.map((file) => (
                    <div className="attachment" key={file.id ?? file.name}>
                      <Paperclip size={13} />
                      {file.name ?? '未命名附件'}
                      <small>仅列出，内容未读取</small>
                    </div>
                  ))
                )}
              </div>
              <div className="detail-section">
                <h3>评论</h3>
                {detail.comments.state === 'failed' ? (
                  <p className="red">评论读取失败：{detail.comments.message}</p>
                ) : detail.comments.items.length === 0 ? (
                  <p className="muted">没有评论。</p>
                ) : (
                  detail.comments.items.slice(0, 8).map((comment) => (
                    <div className="tapd-comment" key={comment.id}>
                      <small>
                        {comment.author} · {comment.created}
                      </small>
                      <p>{comment.text}</p>
                    </div>
                  ))
                )}
              </div>
              {detail.existingWorks.length > 0 && (
                <div className="detail-section">
                  <h3>已关联的 Work</h3>
                  {detail.existingWorks.map((work) => (
                    <button className="link-button" key={work.id} onClick={() => onOpenWork(work.id)}>
                      {work.displayId} · {work.title}（{work.statusLabel}）
                    </button>
                  ))}
                </div>
              )}
              <div className="source-note">
                <Info size={13} />
                导入会创建本地 Work，TAPD 状态保持独立。
              </div>
              <button className="primary full" onClick={() => setImporting(true)}>
                <PlusCircle size={14} /> 创建开发任务
              </button>
            </>
          )}
        </aside>
      </div>
      {importing && detail && (
        <ImportModal
          detail={detail}
          projects={projects}
          mappings={mappings}
          runtime={runtime}
          notify={notify}
          onClose={() => setImporting(false)}
          onOpenWork={(id) => {
            setImporting(false);
            onOpenWork(id);
          }}
          onCreated={onWorkCreated}
        />
      )}
    </section>
  );
}
