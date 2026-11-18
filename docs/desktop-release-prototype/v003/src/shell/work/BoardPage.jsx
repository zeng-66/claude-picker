// Work 中心：看板 / 列表。列、数量、执行容量都来自领域状态；卡片不能靠拖动改变状态。
import React, { useEffect, useRef, useState } from 'react';
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
import { relativeTime, useStored } from '../ui.jsx';
import { StatusPill } from './WorkChat.jsx';
import { confirmAction } from './confirm.jsx';
import { needsAttention, newId, shortId, statusOf } from './useWorks.js';

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
  const ref = useRef(null);
  useEffect(() => {
    const dismiss = (event) => {
      if (!ref.current?.contains(event.target)) onClose();
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
    <div className="dropdown card-menu" role="menu" ref={ref} data-blocking onClick={(event) => event.stopPropagation()}>
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

function WorkCard({ work, onOpen, notify, onExport }) {
  const [menu, setMenu] = useState(false);
  return (
    <div
      className={`task-card ${needsAttention(work) ? 'attention' : ''}`}
      role="button"
      tabIndex={0}
      onClick={() => onOpen(work)}
      onKeyDown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          onOpen(work);
        }
      }}
    >
      <div className="task-card-top">
        {sourceChip(work)}
        <span className="work-number">{work.displayId}</span>
        <button
          className="icon-button"
          aria-label={`${work.displayId} 的操作`}
          title="更多操作"
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
      <h3>{work.title}</h3>
      <p>{work.objective}</p>
      <div className="task-card-env">
        <Folder size={12} /> {work.project?.name ?? '项目不可用'}
      </div>
      {work.statusReason && <div className="task-card-reason">{work.statusReason}</div>}
      <div className="task-card-bottom">
        <StatusPill work={work} />
        <small>{relativeTime(work.updatedAt)}</small>
      </div>
    </div>
  );
}

export default function BoardPage({ snapshot, notify, onOpenWork, onNewWork, onOpenTapd, onExport }) {
  const [view, setView] = useStored('boardView', 'board');
  const [projectId, setProjectId] = useStored('boardProject', '');
  const [showEnded, setShowEnded] = useStored('boardEnded', false);
  const [statusFilter, setStatusFilter] = useState('');

  const all = snapshot.works;
  const scoped = all.filter((work) => (!projectId || work.projectId === projectId) && (showEnded || !work.archived));
  const active = scoped.filter((work) => !ENDED.includes(work.status) && !work.archived);
  const attention = scoped.filter(needsAttention);
  const trouble = scoped.filter((work) => TROUBLE.includes(work.status) && !work.archived);
  const ended = scoped.filter((work) => ENDED.includes(work.status) || work.archived);
  const capacity = snapshot.capacity;
  const projects = snapshot.projects.filter((project) => all.some((work) => work.projectId === project.id));

  const listed = scoped.filter(
    (work) => (showEnded || !ENDED.includes(work.status)) && (!statusFilter || work.status === statusFilter),
  );

  return (
    <section className="page board-page">
      <div className="page-heading">
        <div>
          <div className="eyebrow">AGENT WORKSPACE</div>
          <h1>Work 中心</h1>
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
          <button className={view === 'board' ? 'chosen' : ''} onClick={() => setView('board')}>
            看板
          </button>
          <button className={view === 'list' ? 'chosen' : ''} onClick={() => setView('list')}>
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
          <div className="kanban" style={{ '--columns': COLUMNS.length + (trouble.length ? 1 : 0) }}>
            {COLUMNS.map(([value, label, Icon, tone]) => {
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
                    <WorkCard key={work.id} work={work} onOpen={onOpenWork} notify={notify} onExport={onExport} />
                  ))}
                  {!cards.length && <div className="empty-column">暂无{label}的 Work</div>}
                </section>
              );
            })}
            {trouble.length > 0 && (
              <section className="kanban-column" aria-label="失败与中断">
                <div className="column-title">
                  <span className="red">
                    <WarningCircle size={15} />
                  </span>
                  <h2>失败 / 中断</h2>
                  <span className="tiny-count">{trouble.length}</span>
                </div>
                {trouble.map((work) => (
                  <WorkCard key={work.id} work={work} onOpen={onOpenWork} notify={notify} onExport={onExport} />
                ))}
              </section>
            )}
          </div>
          {showEnded && (
            <div className="ended-works">
              <h2>已结束与已归档</h2>
              {ended.length === 0 && <p className="context-empty">没有已结束的 Work。</p>}
              <div className="ended-grid">
                {ended.map((work) => (
                  <WorkCard key={work.id} work={work} onOpen={onOpenWork} notify={notify} onExport={onExport} />
                ))}
              </div>
            </div>
          )}
        </>
      ) : (
        <div className="work-table" role="table" aria-label="Work 列表">
          <div className="work-table-head" role="row">
            <span>编号</span>
            <span>名称</span>
            <span>项目</span>
            <span>来源</span>
            <span>状态</span>
            <span>更新</span>
          </div>
          {listed.length === 0 && <p className="context-empty padded">没有符合条件的 Work。</p>}
          {listed.map((work) => (
            <button className="work-table-row" role="row" key={work.id} onClick={() => onOpenWork(work)}>
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
