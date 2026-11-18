import React, { useEffect, useRef, useState } from "react";
import {
  ChatCircleDots,
  CheckCircle,
  ClockCounterClockwise,
  DotsSixVertical,
  DotsThree,
  Folder,
  Gear,
  GitBranch,
  GitDiff,
  ListChecks,
  SidebarSimple,
  Terminal,
  TreeStructure,
} from "@phosphor-icons/react";
import appIcon from "./clawd-mark.png";
import { IconButton } from "./ui.jsx";

export const DEFAULT_NAVIGATION = ["workspace", "tapd", "works", "git"].map(
  (id) => ({ id, visible: true }),
);
const labels = {
  workspace: "工作空间",
  tapd: "TAPD 待办",
  works: "Work 中心",
  git: "变更",
};
export const TAPD_PROJECTS = [
  { id: "all", label: "全部项目" },
  { id: "67103358", label: "lm-global" },
  { id: "33349361", label: "蓝马" },
];
const workItems = [
  ["all", "全部 Work", ListChecks],
  ["pending", "待执行", ClockCounterClockwise],
  ["running", "执行中", Terminal],
  ["waiting_user", "待回答", ChatCircleDots],
  ["waiting_review", "待审阅", GitDiff],
  ["completed", "已结束", CheckCircle],
];
const gitItems = [
  ["工作区", "工作区", GitDiff],
  ["提交历史", "提交历史", ClockCounterClockwise],
  ["分支", "分支", GitBranch],
  ["工作树", "工作树", TreeStructure],
  ["更多", "更多", DotsThree],
];

export function moveNavigation(current, from, to) {
  const next = [...current];
  const source = next.findIndex((item) => item.id === from);
  const target = next.findIndex((item) => item.id === to);
  if (source < 0 || target < 0 || source === target) return current;
  next.splice(target, 0, next.splice(source, 1)[0]);
  return next;
}

export function useNavigationDrag(onChange) {
  const dragged = useRef(false);
  function beginDrag(event) {
    const handle = event.currentTarget;
    if (
      event.button !== 0 ||
      (event.target.closest("button, input") &&
        event.target.closest("button, input") !== handle)
    )
      return;
    const start = { x: event.clientX, y: event.clientY };
    const source = handle.dataset.navigationId;
    const group = handle.dataset.navigationGroup;
    let target = source;
    dragged.current = false;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (pointer) => {
      if (
        Math.hypot(pointer.clientX - start.x, pointer.clientY - start.y) < 6 &&
        !dragged.current
      )
        return;
      dragged.current = true;
      handle.dataset.dragging = "true";
      const candidate = document
        .elementFromPoint(pointer.clientX, pointer.clientY)
        ?.closest("[data-navigation-id]");
      target =
        candidate?.dataset.navigationGroup === group
          ? candidate.dataset.navigationId
          : source;
    };
    const finish = (pointer) => {
      if (
        pointer.type !== "pointercancel" &&
        dragged.current &&
        target !== source
      )
        onChange((current) => moveNavigation(current, source, target));
      delete handle.dataset.dragging;
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
      setTimeout(() => {
        dragged.current = false;
      }, 0);
    };
    handle.onpointerup = finish;
    handle.onpointercancel = finish;
  }
  return { beginDrag, wasDragged: () => dragged.current };
}

export function NavigationSettings({ navigation, onChange }) {
  const drag = useNavigationDrag(onChange);
  return (
    <>
      <h3>顶部页签</h3>
      <p>开关控制显示，拖动行左侧的手柄调整顺序。顶部图标也可直接拖动排序。</p>
      <ul className="navigation-settings">
        {navigation.map((item, index) => (
          <li
            key={item.id}
            data-navigation-id={item.id}
            data-navigation-group="settings"
            aria-label={`${labels[item.id]}页签排序项`}
            onPointerDown={drag.beginDrag}
          >
            <DotsSixVertical
              size={18}
              aria-label={`拖动${labels[item.id]}排序`}
            />
            <span>{labels[item.id]}</span>
            <button
              aria-label={`上移${labels[item.id]}`}
              disabled={index === 0}
              onClick={() =>
                onChange(
                  moveNavigation(navigation, item.id, navigation[index - 1].id),
                )
              }
            >
              ↑
            </button>
            <button
              aria-label={`下移${labels[item.id]}`}
              disabled={index === navigation.length - 1}
              onClick={() =>
                onChange(
                  moveNavigation(navigation, item.id, navigation[index + 1].id),
                )
              }
            >
              ↓
            </button>
            <input
              type="checkbox"
              role="switch"
              aria-label={`显示${labels[item.id]}页签`}
              checked={item.visible}
              onChange={(event) =>
                onChange(
                  navigation.map((value) =>
                    value.id === item.id
                      ? { ...value, visible: event.target.checked }
                      : value,
                  ),
                )
              }
            />
          </li>
        ))}
      </ul>
      {!navigation.some((item) => item.visible) && (
        <p role="status">全部页签已隐藏，可随时在此重新开启。</p>
      )}
    </>
  );
}

export function ModuleSidebar({
  branchControls,
  page,
  section,
  onSection,
  collapsed,
  onToggle,
  onSettings,
  terminalVisible,
  onTerminal,
}) {
  const items =
    page === "tapd"
      ? TAPD_PROJECTS.map((item) => [item.id, item.label, Folder])
      : page === "works"
        ? workItems
        : page === "git"
          ? gitItems
          : [];
  return (
    <aside
      className={`module-sidebar ${collapsed ? "collapsed" : ""}`}
      aria-label={`${labels[page] || "模块"}操作栏`}
    >
      <div className="module-brand">
        <img src={appIcon} alt="ClaudePicker" />
        {!collapsed && <strong>{labels[page] || "ClaudePicker"}</strong>}
        <div className="sidebar-header-actions">
          <IconButton
            icon={SidebarSimple}
            label={collapsed ? "展开模块操作栏" : "收起模块操作栏"}
            onClick={onToggle}
          />
          {!terminalVisible && (
            <IconButton
              icon={Terminal}
              label="展开终端 ⌘J"
              onClick={onTerminal}
            />
          )}
        </div>
      </div>
      {!collapsed && branchControls && (
        <div className="module-branch-controls">{branchControls}</div>
      )}
      <nav aria-label={`${labels[page] || "模块"}分类`}>
        {items.map(([id, label, Icon]) => (
          <button
            key={id}
            className={section === id ? "active" : ""}
            title={label}
            aria-label={label}
            aria-current={section === id ? "page" : undefined}
            onClick={() => onSection(id)}
          >
            <Icon size={18} />
            {!collapsed && <span>{label}</span>}
          </button>
        ))}
      </nav>
      <div className="module-sidebar-bottom">
        <button onClick={onSettings} title="设置" aria-label="模块设置">
          <Gear size={18} />
          {!collapsed && <span>设置</span>}
        </button>
      </div>
    </aside>
  );
}

export function EmptyModules({ onSettings }) {
  return (
    <main className="module-page empty-modules">
      <h2>选择要显示的模块</h2>
      <p>在设置中开启顶部页签。</p>
      <button onClick={onSettings}>打开页签设置</button>
    </main>
  );
}

const tapdTasks = [
  {
    id: "1001001",
    project: "67103358",
    title: "订单解码接口联调",
    status: "开发中",
    owner: "曾长亮",
    type: "需求",
    description: "核对订单解码请求、状态变化与回调结果，补齐联调记录。",
  },
  {
    id: "1001002",
    project: "67103358",
    title: "设计模板绑定校验",
    status: "待处理",
    owner: "曾长亮",
    type: "任务",
    description: "模板上下架时检查关联商品状态，并在界面展示校验结果。",
  },
  {
    id: "1001003",
    project: "33349361",
    title: "订单列表统计条件调整",
    status: "待测试",
    owner: "曾长亮",
    type: "缺陷",
    description: "统一列表筛选与头部统计的条件，核对商家维度的数据。",
  },
  {
    id: "1001004",
    project: "33349361",
    title: "物流渠道映射检查",
    status: "待处理",
    owner: "曾长亮",
    type: "任务",
    description: "补充渠道映射缺失时的提示与处理入口。",
  },
];

const taskMeta = {
  1001001: {
    priority: "Middle",
    iteration: "V1.0 订单",
    created: "2026-11-17 09:59",
    scope: "待办",
  },
  1001002: {
    priority: "High",
    iteration: "V1.0 设计",
    created: "2026-11-16 16:32",
    scope: "已创建",
  },
  1001003: {
    priority: "High",
    iteration: "—",
    created: "2026-11-16 14:55",
    scope: "已办",
  },
  1001004: {
    priority: "Middle",
    iteration: "—",
    created: "2026-11-13 10:04",
    scope: "已关注",
  },
};

export function TapdModule({ workspace, onCreateWork }) {
  const [creating, setCreating] = useState(false);
  const pageRef = useRef(null);
  const [visited, setVisited] = useState([]);
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("全部状态");
  const [scope, setScope] = useState("待办");
  const [selectedId, setSelectedId] = useState(null);
  const [collapsed, setCollapsed] = useState({});
  const [checked, setChecked] = useState([]);
  const [detailTab, setDetailTab] = useState("详细信息");
  const [comments, setComments] = useState({});
  const [draft, setDraft] = useState("");
  const [starred, setStarred] = useState([]);
  const [showFilters, setShowFilters] = useState(false);
  const [showFields, setShowFields] = useState(false);
  const [fields, setFields] = useState([
    "优先级",
    "迭代",
    "预计结束",
    "处理人",
    "创建时间",
  ]);
  const [priority, setPriority] = useState("全部优先级");
  const selected = tapdTasks.find((task) => task.id === selectedId);
  const projectName = (id) =>
    TAPD_PROJECTS.find((project) => project.id === id)?.label;
  const tasks = tapdTasks.filter(
    (task) =>
      (workspace === "all" || task.project === workspace) &&
      (status === "全部状态" || task.status === status) &&
      (priority === "全部优先级" || taskMeta[task.id].priority === priority) &&
      (scope === "待办"
        ? task.status !== "待测试"
        : scope === "最近访问"
          ? visited.includes(task.id)
          : scope === "已关注"
            ? taskMeta[task.id].scope === scope || starred.includes(task.id)
            : taskMeta[task.id].scope === scope) &&
      `${task.title} ${task.id}`
        .toLowerCase()
        .includes(query.toLowerCase().trim()),
  );
  function openTask(task) {
    pageRef.current?.scrollTo({ top: 0 });
    setVisited((current) => [...new Set([...current, task.id])]);
    setSelectedId(task.id);
    setDetailTab("详细信息");
    setDraft("");
  }
  function toggleCheck(id) {
    setChecked((current) =>
      current.includes(id)
        ? current.filter((item) => item !== id)
        : [...current, id],
    );
  }
  function submitComment(event) {
    event.preventDefault();
    if (!draft.trim()) return;
    setComments((current) => ({
      ...current,
      [selected.id]: [...(current[selected.id] || []), draft.trim()],
    }));
    setDraft("");
  }
  return (
    <main ref={pageRef} className="module-page tapd-page">
      {creating && selected && (
        <TapdCreateWork
          task={selected}
          project={projectName(selected.project)}
          onClose={() => setCreating(false)}
          onCreate={onCreateWork}
        />
      )}
      <header className="tapd-heading">
        <h2>{selected ? "工作项详情" : "我的工作"}</h2>
      </header>
      {selected ? (
        <section className="tapd-detail" aria-label="TAPD 工作项详情">
          <header className="tapd-detail-bar">
            <span className="tapd-status">{selected.status}</span>
            <strong>ID: {selected.id}</strong>
            <button
              onClick={() => setSelectedId(null)}
              aria-label="关闭任务详情"
            >
              返回列表 →
            </button>
          </header>
          <div className="tapd-detail-grid">
            <article className="tapd-detail-main">
              <h3>
                <span
                  className={`tapd-type ${selected.type === "缺陷" ? "bug" : ""}`}
                >
                  {selected.type === "缺陷" ? "BUG" : "DD"}
                </span>
                {selected.title}
                <button
                  aria-label={
                    starred.includes(selected.id) ? "取消关注任务" : "关注任务"
                  }
                  onClick={() =>
                    setStarred((current) =>
                      current.includes(selected.id)
                        ? current.filter((id) => id !== selected.id)
                        : [...current, selected.id],
                    )
                  }
                >
                  {starred.includes(selected.id) ? "★" : "☆"}
                </button>
              </h3>
              <nav className="tapd-detail-tabs" aria-label="任务详情页签">
                {["详细信息", "子需求", "缺陷", "测试用例", "变更历史"].map(
                  (tab) => (
                    <button
                      key={tab}
                      className={detailTab === tab ? "active" : ""}
                      onClick={() => setDetailTab(tab)}
                    >
                      {tab}
                      {["子需求", "缺陷", "测试用例"].includes(tab)
                        ? " (0)"
                        : ""}
                    </button>
                  ),
                )}
              </nav>
              {detailTab === "详细信息" ? (
                <>
                  <div className="tapd-description">
                    <p className="tapd-demo-note">
                      当前为演示工作项，字段和评论仅用于原型体验。
                    </p>
                    <p>使用场景：</p>
                    <p>{selected.description}</p>
                    <p>要解决的问题：</p>
                    <p>
                      核对 {projectName(selected.project)} 中「{selected.title}
                      」的处理流程。
                    </p>
                    <p>期待的结果：</p>
                    <p>完成实现与验证，补充处理记录。</p>
                    <p>相关截图或者照片：—</p>
                  </div>
                  <details className="tapd-section">
                    <summary>标签</summary>
                    <p>暂无标签</p>
                  </details>
                  <details className="tapd-section">
                    <summary>附件</summary>
                    <p>暂无附件</p>
                  </details>
                  <details className="tapd-section" open>
                    <summary>
                      评论 ({(comments[selected.id] || []).length})
                    </summary>
                    {(comments[selected.id] || []).map((comment, index) => (
                      <p className="tapd-comment" key={index}>
                        <small>曾长亮 · 本地演示</small>
                        {comment}
                      </p>
                    ))}
                  </details>
                  <details className="tapd-section">
                    <summary>检查清单 (0/0)</summary>
                    <p>暂无检查项</p>
                  </details>
                  <section className="tapd-workflow">
                    <h4>工作流</h4>
                    <div>
                      {["待处理", "开发中", "待测试"].map((step) => (
                        <span
                          key={step}
                          className={selected.status === step ? "current" : ""}
                        >
                          {step}
                          {selected.status === step ? "（当前）" : ""}
                        </span>
                      ))}
                    </div>
                    <p>
                      处理人 <strong>{selected.owner}</strong>
                    </p>
                    <small>状态流转将在接入 TAPD 后开放。</small>
                  </section>
                </>
              ) : (
                <div className="tapd-tab-empty">
                  {detailTab === "变更历史"
                    ? "暂无变更记录，当前为只读演示工作项。"
                    : `暂无关联${detailTab}。`}
                </div>
              )}
            </article>
            <aside className="tapd-basic" aria-label="基础信息">
              <h4>基础信息</h4>
              <dl>
                {[
                  ["状态", selected.status],
                  ["迭代", taskMeta[selected.id].iteration],
                  ["优先级", taskMeta[selected.id].priority],
                  ["标签", "—"],
                  ["处理人", selected.owner],
                  ["项目", projectName(selected.project)],
                  ["开发人员", "—"],
                  ["测试人员", "—"],
                  ["创建人", selected.owner],
                  ["创建时间", taskMeta[selected.id].created],
                  ["设计完成时间", "—"],
                  ["实际提测时间", "—"],
                  ["上线时间", "—"],
                  ["上线方案", "—"],
                  ["发布服务", "—"],
                  ["预计结束", "—"],
                  ["备注", "—"],
                  ["跟进人", selected.owner],
                ].map(([label, value]) => (
                  <React.Fragment key={label}>
                    <dt>{label}</dt>
                    <dd>{value}</dd>
                  </React.Fragment>
                ))}
              </dl>
            </aside>
          </div>
          <form className="tapd-comment-form" onSubmit={submitComment}>
            <span className="tapd-avatar">曾</span>
            <input
              aria-label="任务评论"
              placeholder="输入评论（仅本地演示）"
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
            />
            <button disabled={!draft.trim()}>发表评论</button>
            <button
              type="button"
              className="tapd-create-work"
              onClick={() => setCreating(true)}
            >
              创建任务
            </button>
          </form>
        </section>
      ) : (
        <>
          <div className="tapd-toolbar">
            <nav aria-label="我的工作分类">
              {["待办", "已办", "已创建", "已关注", "最近访问", "草稿"].map(
                (item) => (
                  <button
                    key={item}
                    className={scope === item ? "active" : ""}
                    onClick={() => {
                      setScope(item);
                      setChecked([]);
                    }}
                  >
                    {item}
                  </button>
                ),
              )}
            </nav>
            <div>
              <span>共 {tasks.length} 个</span>
              <button
                aria-expanded={showFilters}
                onClick={() => setShowFilters(!showFilters)}
              >
                筛选
              </button>
              <button
                aria-expanded={showFields}
                onClick={() => setShowFields(!showFields)}
              >
                字段
              </button>
            </div>
          </div>
          <div className="tapd-search">
            <input
              aria-label="搜索 TAPD 任务"
              placeholder="搜索任务名称或 ID"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
            {checked.length > 0 && (
              <span>
                已选择 {checked.length} 项{" "}
                <button onClick={() => setChecked([])}>取消选择</button>
              </span>
            )}
          </div>
          {showFilters && (
            <div className="module-filters">
              <select
                aria-label="TAPD 任务状态"
                value={status}
                onChange={(event) => setStatus(event.target.value)}
              >
                {["全部状态", "待处理", "开发中", "待测试"].map((value) => (
                  <option key={value}>{value}</option>
                ))}
              </select>
              <select
                aria-label="任务优先级"
                value={priority}
                onChange={(event) => setPriority(event.target.value)}
              >
                {["全部优先级", "High", "Middle"].map((value) => (
                  <option key={value}>{value}</option>
                ))}
              </select>
              <button
                onClick={() => {
                  setStatus("全部状态");
                  setPriority("全部优先级");
                }}
              >
                重置筛选
              </button>
            </div>
          )}
          {showFields && (
            <div className="tapd-field-picker">
              {["优先级", "迭代", "预计结束", "处理人", "创建时间"].map(
                (field) => (
                  <label key={field}>
                    <input
                      type="checkbox"
                      checked={fields.includes(field)}
                      onChange={() =>
                        setFields((current) =>
                          current.includes(field)
                            ? current.filter((item) => item !== field)
                            : [...current, field],
                        )
                      }
                    />
                    {field}
                  </label>
                ),
              )}
            </div>
          )}
          {TAPD_PROJECTS.filter(
            (project) =>
              project.id !== "all" &&
              (workspace === "all" || workspace === project.id),
          ).map((project) => {
            const rows = tasks.filter((task) => task.project === project.id);
            if (!rows.length) return null;
            return (
              <section className="tapd-group" key={project.id}>
                <button
                  className="tapd-group-heading"
                  aria-expanded={!collapsed[project.id]}
                  onClick={() =>
                    setCollapsed((current) => ({
                      ...current,
                      [project.id]: !current[project.id],
                    }))
                  }
                >
                  <span>{collapsed[project.id] ? "▸" : "▾"}</span>
                  {project.label}
                  <small>({rows.length})</small>
                </button>
                {!collapsed[project.id] && (
                  <div className="tapd-table-scroll">
                    <table className="tapd-table">
                      <thead>
                        <tr>
                          <th>
                            <input
                              type="checkbox"
                              aria-label={`选择 ${project.label} 全部任务`}
                              checked={rows.every((task) =>
                                checked.includes(task.id),
                              )}
                              onChange={(event) =>
                                setChecked((current) =>
                                  event.target.checked
                                    ? [
                                        ...new Set([
                                          ...current,
                                          ...rows.map((task) => task.id),
                                        ]),
                                      ]
                                    : current.filter(
                                        (id) =>
                                          !rows.some((task) => task.id === id),
                                      ),
                                )
                              }
                            />
                          </th>
                          <th>标题</th>
                          <th>状态</th>
                          {fields.map((field) => (
                            <th key={field}>{field}</th>
                          ))}
                        </tr>
                      </thead>
                      <tbody>
                        {rows.map((task) => (
                          <tr key={task.id}>
                            <td>
                              <input
                                type="checkbox"
                                aria-label={`选择任务 ${task.id}`}
                                checked={checked.includes(task.id)}
                                onChange={() => toggleCheck(task.id)}
                              />
                            </td>
                            <td>
                              <button
                                className="tapd-task-title"
                                onClick={() => openTask(task)}
                              >
                                <span
                                  className={`tapd-type ${task.type === "缺陷" ? "bug" : ""}`}
                                >
                                  {task.type === "缺陷" ? "BUG" : "DD"}
                                </span>
                                <span>
                                  {task.title}
                                  <small>#{task.id}</small>
                                </span>
                              </button>
                            </td>
                            <td>
                              <span className="tapd-status">{task.status}</span>
                            </td>
                            {fields.map((field) => (
                              <td key={field}>
                                {field === "优先级" ? (
                                  <span
                                    className={`tapd-priority ${taskMeta[task.id].priority.toLowerCase()}`}
                                  >
                                    {taskMeta[task.id].priority}
                                  </span>
                                ) : field === "迭代" ? (
                                  taskMeta[task.id].iteration
                                ) : field === "预计结束" ? (
                                  "—"
                                ) : field === "处理人" ? (
                                  <span className="tapd-owner">
                                    <span className="tapd-avatar">曾</span>
                                    {task.owner}
                                  </span>
                                ) : (
                                  taskMeta[task.id].created
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
            );
          })}
          {!tasks.length && (
            <p className="module-empty">
              {scope === "草稿" ? "暂无草稿。" : "当前筛选下没有任务项。"}
            </p>
          )}
        </>
      )}
    </main>
  );
}

function TapdCreateWork({ task, project, onClose, onCreate }) {
  const dialogRef = useRef(null);
  const [title, setTitle] = useState(task.title);
  const [supplement, setSupplement] = useState("");
  useEffect(() => {
    const dialog = dialogRef.current;
    const opener = document.activeElement;
    dialog.showModal();
    return () => {
      dialog.close();
      opener?.focus();
    };
  }, []);
  function submit(event) {
    event.preventDefault();
    if (!title.trim()) return;
    onCreate({
      title: title.trim(),
      supplement: supplement.trim(),
      task,
      project,
    });
  }
  return (
    <dialog
      ref={dialogRef}
      className="tapd-create-dialog"
      aria-labelledby="tapd-create-title"
      onCancel={onClose}
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <form onSubmit={submit} onClick={(event) => event.stopPropagation()}>
        <header>
          <h2 id="tapd-create-title">创建任务</h2>
          <button type="button" aria-label="关闭创建任务" onClick={onClose}>
            ×
          </button>
        </header>
        <div className="tapd-create-source">
          <small>
            来源 · {project} · TAPD #{task.id}
          </small>
          <strong>{task.title}</strong>
          <p>{task.description}</p>
        </div>
        <label>
          任务名称
          <input
            autoFocus
            required
            maxLength={160}
            aria-label="任务名称"
            value={title}
            onChange={(event) => setTitle(event.target.value)}
          />
        </label>
        <label>
          补充内容
          <textarea
            aria-label="补充内容"
            rows={6}
            placeholder="补充实现要求、注意事项或验收标准…"
            value={supplement}
            onChange={(event) => setSupplement(event.target.value)}
          />
        </label>
        <p className="tapd-create-hint">
          创建后进入 Work 中心，保留 TAPD
          来源与补充内容。当前原型保存在本机浏览器，不会启动执行或修改 TAPD。
        </p>
        <footer>
          <button type="button" onClick={onClose}>
            取消
          </button>
          <button className="primary" disabled={!title.trim()}>
            创建并进入 Work
          </button>
        </footer>
      </form>
    </dialog>
  );
}

const workSeed = [
  {
    id: "WORK-DEMO-1",
    title: "Windows 桌面运行层适配",
    status: "running",
    project: "claude-picker",
    summary: "核对本地终端与项目目录的交互。",
  },
  {
    id: "WORK-DEMO-2",
    title: "订单解码需求确认",
    status: "waiting_user",
    project: "lm-global-java",
    summary: "等待确认解码失败后的重试行为。",
  },
  {
    id: "WORK-DEMO-3",
    title: "版本更新入口审阅",
    status: "waiting_review",
    project: "claude-picker",
    summary: "检查更新状态与安装前确认已准备好审阅。",
  },
  {
    id: "WORK-DEMO-4",
    title: "Git 工作台界面整理",
    status: "completed",
    project: "claude-picker",
    summary: "界面整理的演示任务已结束。",
  },
];
const workStatus = {
  pending: "待执行",
  running: "执行中",
  waiting_user: "待回答",
  waiting_review: "待审阅",
  completed: "已结束",
};

export function WorkModule({ filter, createdWorks = [], focusId }) {
  const [view, setView] = useState("board");
  const allWorks = [...createdWorks, ...workSeed];
  const [selected, setSelected] = useState(
    () =>
      allWorks.find(
        (work) =>
          work.id === focusId && (filter === "all" || work.status === filter),
      ) || null,
  );
  const visible = allWorks.filter(
    (work) => filter === "all" || work.status === filter,
  );
  return (
    <main className="module-page">
      <header className="module-page-header">
        <h2>{filter === "all" ? "Work 中心" : workStatus[filter]}</h2>
      </header>
      <div className="segmented work-view-control">
        <button
          className={view === "board" ? "chosen" : ""}
          onClick={() => setView("board")}
        >
          看板
        </button>
        <button
          className={view === "list" ? "chosen" : ""}
          onClick={() => setView("list")}
        >
          列表
        </button>
      </div>
      {view === "board" ? (
        <div className="module-work-board">
          {Object.entries(workStatus)
            .filter(([id]) => filter === "all" || filter === id)
            .map(([id, label]) => (
              <section key={id}>
                <h3>
                  {label}
                  <small>
                    {visible.filter((work) => work.status === id).length}
                  </small>
                </h3>
                {visible
                  .filter((work) => work.status === id)
                  .map((work) => (
                    <button key={work.id} onClick={() => setSelected(work)}>
                      <small>{work.id}</small>
                      <strong>{work.title}</strong>
                      <span>{work.project}</span>
                    </button>
                  ))}
              </section>
            ))}
        </div>
      ) : (
        <div className="module-task-list">
          {visible.map((work) => (
            <button key={work.id} onClick={() => setSelected(work)}>
              <span>
                <small>
                  {work.id} · {work.project}
                </small>
                <strong>{work.title}</strong>
              </span>
              <span className="module-status">{workStatus[work.status]}</span>
            </button>
          ))}
        </div>
      )}
      {selected && (
        <section className="work-detail-summary" aria-label="Work 详情">
          <button className="detail-close" onClick={() => setSelected(null)}>
            关闭详情
          </button>
          <small>
            {selected.id} · {workStatus[selected.status]}
          </small>
          <h3>{selected.title}</h3>
          <p>{selected.summary}</p>
          {selected.source && (
            <div className="work-source-info">
              <h4>TAPD 来源</h4>
              <p>
                {selected.source.project} · #{selected.source.id} ·{" "}
                {selected.source.type}
              </p>
              <p>{selected.source.description}</p>
              <h4>补充内容</h4>
              <p className="work-supplement">
                {selected.supplement || "未填写补充内容"}
              </p>
            </div>
          )}
        </section>
      )}
    </main>
  );
}
