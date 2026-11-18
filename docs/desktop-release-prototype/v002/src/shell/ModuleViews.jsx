import React, { useRef, useState } from "react";
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
        <button
          aria-label={collapsed ? "展开模块操作栏" : "收起模块操作栏"}
          onClick={onToggle}
        >
          <SidebarSimple size={17} />
        </button>
      </div>
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
        <button
          onClick={onTerminal}
          title={terminalVisible ? "收起第二栏终端" : "在工作空间展开终端"}
          aria-label={terminalVisible ? "收起第二栏终端" : "在工作空间展开终端"}
        >
          <Terminal size={18} />
          {!collapsed && (
            <span>{terminalVisible ? "收起终端" : "展开终端"}</span>
          )}
        </button>
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

export function TapdModule({ workspace }) {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("全部状态");
  const [selectedId, setSelectedId] = useState(null);
  const tasks = tapdTasks.filter(
    (task) =>
      (workspace === "all" || task.project === workspace) &&
      (status === "全部状态" || task.status === status) &&
      `${task.title} ${task.id}`.includes(query),
  );
  const selected = tasks.find((task) => task.id === selectedId);
  const projectName = (id) =>
    TAPD_PROJECTS.find((project) => project.id === id)?.label;
  return (
    <main className="module-page">
      <header className="module-page-header">
        <div>
          <small>TAPD · {projectName(workspace)}</small>
          <h2>任务项</h2>
        </div>
        <small>演示数据</small>
      </header>
      <div className="module-filters">
        <input
          aria-label="搜索 TAPD 任务"
          placeholder="搜索任务名称或 ID"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <select
          aria-label="TAPD 任务状态"
          value={status}
          onChange={(event) => setStatus(event.target.value)}
        >
          {["全部状态", "待处理", "开发中", "待测试"].map((value) => (
            <option key={value}>{value}</option>
          ))}
        </select>
      </div>
      <div className={`module-content-split ${selected ? "has-detail" : ""}`}>
        <div className="module-task-list">
          {tasks.map((task) => (
            <button
              className={selectedId === task.id ? "selected" : ""}
              key={task.id}
              onClick={() => setSelectedId(task.id)}
            >
              <span>
                <small>
                  {projectName(task.project)} · #{task.id} · {task.type}
                </small>
                <strong>{task.title}</strong>
              </span>
              <span className="module-status">{task.status}</span>
            </button>
          ))}
          {!tasks.length && (
            <p className="module-empty">当前筛选下没有任务项。</p>
          )}
        </div>
        {selected && (
          <aside className="module-task-detail">
            <button
              className="detail-close"
              onClick={() => setSelectedId(null)}
            >
              关闭详情
            </button>
            <small>
              #{selected.id} · {selected.type}
            </small>
            <h3>{selected.title}</h3>
            <dl>
              <dt>项目</dt>
              <dd>{projectName(selected.project)}</dd>
              <dt>负责人</dt>
              <dd>{selected.owner}</dd>
              <dt>状态</dt>
              <dd>{selected.status}</dd>
            </dl>
            <p>{selected.description}</p>
          </aside>
        )}
      </div>
    </main>
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
  running: "执行中",
  waiting_user: "待回答",
  waiting_review: "待审阅",
  completed: "已结束",
};

export function WorkModule({ filter }) {
  const [view, setView] = useState("board");
  const [selected, setSelected] = useState(null);
  const visible = workSeed.filter(
    (work) => filter === "all" || work.status === filter,
  );
  return (
    <main className="module-page">
      <header className="module-page-header">
        <h2>{filter === "all" ? "Work 中心" : workStatus[filter]}</h2>
        <small>演示数据</small>
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
        </section>
      )}
    </main>
  );
}
