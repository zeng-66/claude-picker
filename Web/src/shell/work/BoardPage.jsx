// Work 中心：看板 / 列表。列、数量、执行容量都来自领域状态；卡片不能靠拖动改变状态。
import EngineIcon from '../EngineIcon.jsx';
import React, { useEffect, useState } from 'react';
import {
  ChatCircleDots,
  ChatsCircle,
  CircleDashed,
  CircleNotch,
  DotsThree,
  Folder,
  GitPullRequest,
  Link,
  Plus,
  ShieldCheck,
  Tray,
  WarningCircle,
} from '@phosphor-icons/react';
import { errorText, request } from '../bridge.js';
import { relativeTime, useStored, useMenuFocus } from '../ui.jsx';
import { StatusPill } from './WorkChat.jsx';
import { confirmAction } from './confirm.jsx';
import { needsAttention, newId, shortId, statusOf } from './useWorks.js';
import dancingClawd from '../../assets/clawd-official/dancing.webp';

/// 第一栏分类（docs/ui-refactor-v003.md §6.1）：all 为截图中的完整看板，其它只显示对应的列。
const CATEGORY_LABELS = {
  queued: '待执行',
  running: '执行中',
  waiting_user: '待回答',
  waiting_review: '待审阅',
  trouble: '异常',
  ended: '已结束',
};
const CATEGORY_STATUSES = {
  queued: ['queued'],
  running: ['running'],
  waiting_user: ['waiting_user'],
  waiting_review: ['waiting_review'],
  trouble: ['failed', 'interrupted'],
  ended: ['completed', 'cancelled'],
};

const COLUMNS = [
  ['queued', '排队中', CircleDashed, 'neutral'],
  ['running', '执行中', CircleNotch, 'blue'],
  ['waiting_user', '待回答', ChatCircleDots, 'orange'],
  ['waiting_review', '待审阅', GitPullRequest, 'purple'],
];
const TROUBLE = ['failed', 'interrupted'];
const ENDED = ['completed', 'cancelled'];

function sourceChip(work) {
  const ref = work.tapdRefs?.[0];
  if (ref)
    return (
      <span className="source-id" title={`TAPD ${ref.entityType} ${ref.entityId}`}>
        <Link size={11} /> #{shortId(ref.entityId)}
      </span>
    );
  if (work.origin === 'wecom')
    return (
      <span className="source-id">
        <ChatsCircle size={11} /> 企业微信
      </span>
    );
  return <span className="source-id">本地</span>;
}

function CardMenu({ work, notify, onExport, onClose }) {
  const focus = useMenuFocus(onClose);
  const { ref } = focus;
  useEffect(() => {
    const dismiss = (event) => {
      if (!ref.current?.parentElement.contains(event.target)) onClose();
    };
    window.addEventListener('pointerdown', dismiss);
    return () => window.removeEventListener('pointerdown', dismiss);
  }, [onClose]);

  async function run(method, extra = {}, confirm = null) {
    onClose();
    if (confirm && !(await confirmAction(confirm))) return;
    try {
      const result = await request(method, { workId: work.id, revision: work.revision, requestId: newId(), ...extra });
      if (result?.accepted === false && result.message) notify(result.message, true);
    } catch (cause) {
      notify(errorText(cause), true);
    }
  }
  const live = work.status === 'running' || work.status === 'waiting_user';
  const ended = ENDED.includes(work.status);
  const idle = ended || TROUBLE.includes(work.status);
  return (
    <div className="dropdown card-menu" role="menu" aria-label="Work 操作" {...focus} data-blocking onClick={(event) => event.stopPropagation()}>
      {work.status === 'queued' && !work.startRequested && (
        <button role="menuitem" onClick={() => run('work.start')}>
          启动
        </button>
      )}
      {live && (
        <button role="menuitem" onClick={() => run('work.interrupt')}>
          停止本轮
        </button>
      )}
      {TROUBLE.includes(work.status) && (
        <button role="menuitem" onClick={() => run('work.retry')}>
          重试
        </button>
      )}
      <button
        role="menuitem"
        onClick={() => {
          onClose();
          onExport(work);
        }}
      >
        导出任务卡 / 执行记录
      </button>
      {idle && (
        <button role="menuitem" onClick={() => run('work.archive', { archived: !work.archived })}>
          {work.archived ? '取消归档' : '归档（不删除任何内容）'}
        </button>
      )}
      {!ended && (
        <button
          role="menuitem"
          className="danger"
          onClick={() =>
            run(
              'work.cancel',
              {},
              {
                title: `取消 ${work.displayId}？`,
                text: '执行会被停止，Work 标记为已取消。工作树和分支保留，不会自动删除。',
                confirmLabel: '取消 Work',
                cancelLabel: '保留',
                danger: true,
              },
            )
          }
        >
          取消 Work
        </button>
      )}
    </div>
  );
}

function WorkCard({ work, onOpen, notify, onExport, focused = false }) {
  const [menu, setMenu] = useState(false);
  return (
    <article
      data-work-id={work.id}
      className={`task-card ${needsAttention(work) ? 'attention' : ''} ${focused ? 'focused' : ''}`}
    >
      <div className="task-card-top">
        {sourceChip(work)}
        <span className="work-number">{work.displayId}</span>
        <button
          className="icon-button"
          aria-label={`${work.displayId} 的操作`}
          title="更多操作"
          aria-haspopup="menu"
          aria-expanded={menu}
          onClick={(event) => {
            event.stopPropagation();
            setMenu(!menu);
          }}
        >
          <DotsThree size={16} />
        </button>
        {menu && <CardMenu work={work} notify={notify} onExport={onExport} onClose={() => setMenu(false)} />}
      </div>
      <h3><button type="button" className="task-card-open" onClick={() => onOpen(work)}>{work.title}</button></h3>
      <p>{work.objective}</p>
      <div className="task-card-env">
        <EngineIcon id={work.executor ?? 'claude'} />
        <Folder size={12} /> {work.project?.name ?? '项目不可用'}
      </div>
      {work.statusReason && <div className="task-card-reason">{work.statusReason}</div>}
      <div className="task-card-bottom">
        <StatusPill work={work} />
        <small>{relativeTime(work.updatedAt)}</small>
      </div>
    </article>
  );
}

export default function BoardPage({ snapshot, notify, onOpenWork, onNewWork, onOpenTapd, onExport, category = 'all', focusId = null, query = '' }) {
  // 刚从 TAPD 创建的 Work：滚动到它并短暂高亮。
  useEffect(() => {
    if (!focusId) return;
    const timer = window.setTimeout(() => {
      document.querySelector(`[data-work-id="${focusId}"]`)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }, 120);
    return () => window.clearTimeout(timer);
  }, [focusId, snapshot.works.length]);
  const [view, setView] = useStored('boardView', 'board');
  const [projectId, setProjectId] = useStored('boardProject', '');
  const [showEnded, setShowEnded] = useStored('boardEnded', false);
  const [statusFilter, setStatusFilter] = useState('');

  // 第一栏搜索框：按名称、编号、目标、TAPD 编号筛选。
  const needle = query.trim().toLowerCase();
  const matches = (work) =>
    !needle ||
    [work.title, work.displayId, work.objective, ...(work.tapdRefs ?? []).flatMap((ref) => [ref.entityId, shortId(ref.entityId)])]
      .filter(Boolean)
      .some((text) => String(text).toLowerCase().includes(needle));
  const all = snapshot.works.filter(matches);
  const scoped = all.filter((work) => (!projectId || work.projectId === projectId) && (showEnded || !work.archived));
  const active = scoped.filter((work) => !ENDED.includes(work.status) && !work.archived);
  const attention = scoped.filter(needsAttention);
  const trouble = scoped.filter((work) => TROUBLE.includes(work.status) && !work.archived);
  const capacity = snapshot.capacity;
  const projects = snapshot.projects.filter((project) => all.some((work) => work.projectId === project.id));

  // 「已结束」分类总是包含已归档的，不受「显示已结束与已归档」开关影响。
  const endedAll = all.filter(
    (work) => (!projectId || work.projectId === projectId) && (ENDED.includes(work.status) || work.archived),
  );
  const inCategory = (work) =>
    category === 'all' ||
    (category === 'ended'
      ? ENDED.includes(work.status) || work.archived
      : !work.archived && CATEGORY_STATUSES[category]?.includes(work.status));
  const listed = scoped.filter(
    (work) =>
      inCategory(work) &&
      (category === 'ended' || showEnded || !ENDED.includes(work.status)) &&
      (!statusFilter || work.status === statusFilter),
  );
  const columns = category === 'all' ? COLUMNS : COLUMNS.filter(([value]) => value === category);
  const showTrouble = category === 'trouble' || (category === 'all' && trouble.length > 0);
  const showEndedSection = category === 'ended' || (category === 'all' && showEnded);
  // 有 Work 且全部已结束：空态换成跳舞的 Clawd（§9.9）。
  const allDone = all.length > 0 && all.every((work) => ENDED.includes(work.status) || work.archived);
  const boardEmpty =
    category !== 'ended' &&
    columns.every(([value]) => !active.some((work) => work.status === value)) &&
    !(showTrouble && trouble.length);

  return (
    <section className="page board-page">
      <div className="page-heading">
        <div>
          <div className="eyebrow">AGENT WORKSPACE</div>
          <h1>{category === 'all' ? 'Work 中心' : CATEGORY_LABELS[category]}</h1>
          <p>从需求到交付持续推进，在需要你时找到你。</p>
        </div>
        <div>
          <button className="secondary" onClick={onOpenTapd}>
            <Tray size={14} /> 从 TAPD 导入
          </button>
          <button className="primary" onClick={() => onNewWork()}>
            <Plus size={14} />
            新建 Work
          </button>
        </div>
      </div>

      {!snapshot.available && (
        <div className="pane-note error" role="alert">
          <WarningCircle size={14} />
          Work 数据不可用：{snapshot.error ?? '数据库无法打开'}
        </div>
      )}
      {snapshot.available && !snapshot.owner && (
        <div className="pane-note warn" role="status">
          <WarningCircle size={14} />
          另一个 Claude Picker 实例正在管理这份 Work 数据。本窗口只能查看，不能启动或修改。
        </div>
      )}

      <div className="overview-strip">
        <div>
          <span>进行中的 Work</span>
          <strong>
            {active.length}
            <small>个</small>
          </strong>
        </div>
        <div>
          <span>需要你的关注</span>
          <strong className={attention.length ? 'orange' : ''}>
            {attention.length}
            <small>个</small>
          </strong>
        </div>
        <div>
          <span>执行位置</span>
          <strong>
            {capacity.running}
            <small>/ {capacity.slots}</small>
          </strong>
          <em>
            {capacity.queued} 个排队
            {capacity.waitingStart ? ` · ${capacity.waitingStart} 个待启动` : ''}
          </em>
        </div>
        <div className="strip-note">
          <ShieldCheck size={22} />
          <span>
            每个 Work 在独立工作树里执行
            <br />
            <small>结果由你审阅确认后才算完成</small>
          </span>
        </div>
      </div>

      <div className="board-toolbar">
        <div className="segmented" role="group" aria-label="视图">
          <button aria-pressed={view === 'board'} className={view === 'board' ? 'chosen' : ''} onClick={() => setView('board')}>
            看板
          </button>
          <button aria-pressed={view === 'list'} className={view === 'list' ? 'chosen' : ''} onClick={() => setView('list')}>
            列表
          </button>
        </div>
        <label className="inline-select">
          <Folder size={13} />
          <select aria-label="按项目筛选" value={projectId} onChange={(event) => setProjectId(event.target.value)}>
            <option value="">所有项目</option>
            {projects.map((project) => (
              <option key={project.id} value={project.id}>
                {project.name}
              </option>
            ))}
          </select>
        </label>
        {view === 'list' && (
          <label className="inline-select">
            <select aria-label="按状态筛选" value={statusFilter} onChange={(event) => setStatusFilter(event.target.value)}>
              <option value="">全部状态</option>
              {['queued', 'running', 'waiting_user', 'waiting_review', 'failed', 'interrupted', 'completed', 'cancelled'].map(
                (value) => (
                  <option key={value} value={value}>
                    {statusOf({ status: value, startRequested: true }).label}
                  </option>
                ),
              )}
            </select>
          </label>
        )}
        <label className="inline-check">
          <input type="checkbox" checked={showEnded} onChange={(event) => setShowEnded(event.target.checked)} />
          显示已结束与已归档（{all.filter((work) => ENDED.includes(work.status) || work.archived).length}）
        </label>
      </div>

      {view === 'board' ? (
        <>
          {allDone && boardEmpty && (
            <div className="work-all-done">
              <img src={dancingClawd} alt="" />
              <p>所有 Work 都已结束。</p>
            </div>
          )}
          {category !== 'ended' && (
          <div className="kanban" style={{ '--columns': Math.max(1, columns.length + (showTrouble ? 1 : 0)) }}>
            {columns.map(([value, label, Icon, tone]) => {
              const cards = active.filter((work) => work.status === value);
              return (
                <section className="kanban-column" key={value} aria-label={label}>
                  <div className="column-title">
                    <span className={tone}>
                      <Icon size={15} />
                    </span>
                    <h2>{label}</h2>
                    <span className="tiny-count">{cards.length}</span>
                    {value === 'queued' && (
                      <button className="icon-button" aria-label="新建 Work" title="新建 Work" onClick={() => onNewWork()}>
                        <Plus size={14} />
                      </button>
                    )}
                  </div>
                  {cards.map((work) => (
                    <WorkCard key={work.id} work={work} onOpen={onOpenWork} notify={notify} onExport={onExport} focused={work.id === focusId} />
                  ))}
                  {!cards.length && <div className="empty-column">暂无{label}的 Work</div>}
                </section>
              );
            })}
            {showTrouble && (
              <section className="kanban-column" aria-label="失败与中断">
                <div className="column-title">
                  <span className="red">
                    <WarningCircle size={15} />
                  </span>
                  <h2>失败 / 中断</h2>
                  <span className="tiny-count">{trouble.length}</span>
                </div>
                {trouble.map((work) => (
                  <WorkCard key={work.id} work={work} onOpen={onOpenWork} notify={notify} onExport={onExport} focused={work.id === focusId} />
                ))}
                {!trouble.length && <div className="empty-column">暂无异常的 Work</div>}
              </section>
            )}
          </div>
          )}
          {showEndedSection && (
            <div className="ended-works">
              <h2>已结束与已归档</h2>
              {endedAll.length === 0 && <p className="context-empty">没有已结束的 Work。</p>}
              <div className="ended-grid">
                {endedAll.map((work) => (
                  <WorkCard key={work.id} work={work} onOpen={onOpenWork} notify={notify} onExport={onExport} focused={work.id === focusId} />
                ))}
              </div>
            </div>
          )}
        </>
      ) : (
        <div className="work-table" role="group" aria-label="Work 列表">
          <div className="work-table-head" aria-hidden="true">
            <span>编号</span>
            <span>名称</span>
            <span>项目</span>
            <span>来源</span>
            <span>状态</span>
            <span>更新</span>
          </div>
          {listed.length === 0 &&
            (allDone ? (
              <div className="work-all-done">
                <img src={dancingClawd} alt="" />
                <p>所有 Work 都已结束。</p>
              </div>
            ) : (
              <p className="context-empty padded">没有符合条件的 Work。</p>
            ))}
          {listed.map((work) => (
            <button className="work-table-row" key={work.id} onClick={() => onOpenWork(work)}>
              <span>{work.displayId}</span>
              <span title={work.title}>
                <b>{work.title}</b>
                {work.statusReason && <small>{work.statusReason}</small>}
              </span>
              <span>{work.project?.name ?? '—'}</span>
              <span>{sourceChip(work)}</span>
              <span>
                <StatusPill work={work} />
              </span>
              <span>{relativeTime(work.updatedAt)}</span>
            </button>
          ))}
        </div>
      )}
    </section>
  );
}
