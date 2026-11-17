// 顶部页签（显示、排序、拖拽）与 TAPD / Work / 变更 共用的模块侧栏。
// 交互约定见 docs/ui-refactor-v003.md §1.4、§2、§4、§10。
import React, { useRef } from 'react';
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
  WarningCircle,
} from '@phosphor-icons/react';
import appIcon from './clawd-mark.png';
import { IconButton } from './ui.jsx';

export const PAGE_IDS = ['workspace', 'tapd', 'works', 'git'];
export const DEFAULT_NAVIGATION = PAGE_IDS.map((id) => ({ id, visible: true }));
export const PAGE_LABELS = {
  workspace: '工作空间',
  tapd: 'TAPD 待办',
  works: 'Work 中心',
  git: '变更',
};

/// 原生给的列表可能缺项或带未知项：只留四个已知页签，缺的按默认顺序补在后面。
export function normalizeNavigation(value) {
  const seen = new Set();
  const list = (Array.isArray(value) ? value : []).filter(
    (item) => item && PAGE_IDS.includes(item.id) && !seen.has(item.id) && seen.add(item.id),
  );
  for (const id of PAGE_IDS) if (!seen.has(id)) list.push({ id, visible: true });
  return list.map((item) => ({ id: item.id, visible: item.visible !== false }));
}

export function moveNavigation(current, from, to) {
  const next = [...current];
  const source = next.findIndex((item) => item.id === from);
  const target = next.findIndex((item) => item.id === to);
  if (source < 0 || target < 0 || source === target) return current;
  next.splice(target, 0, next.splice(source, 1)[0]);
  return next;
}

/// 按住页签（顶部图标或设置行）移动 6px 以上即为拖拽排序；松开时落在同组另一项上则交换位置。
/// 拖拽过的那次点击不切换页面（wasDragged）。
export function useNavigationDrag(onMove) {
  const dragged = useRef(false);
  function beginDrag(event) {
    const handle = event.currentTarget;
    const inner = event.target.closest('button, input');
    if (event.button !== 0 || (inner && inner !== handle)) return;
    const start = { x: event.clientX, y: event.clientY };
    const source = handle.dataset.navigationId;
    const group = handle.dataset.navigationGroup;
    let target = source;
    dragged.current = false;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (pointer) => {
      if (!dragged.current && Math.hypot(pointer.clientX - start.x, pointer.clientY - start.y) < 6) return;
      dragged.current = true;
      handle.dataset.dragging = 'true';
      const candidate = document
        .elementFromPoint(pointer.clientX, pointer.clientY)
        ?.closest('[data-navigation-id]');
      target = candidate?.dataset.navigationGroup === group ? candidate.dataset.navigationId : source;
    };
    const finish = (pointer) => {
      if (pointer.type !== 'pointercancel' && dragged.current && target !== source) onMove(source, target);
      delete handle.dataset.dragging;
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
      window.setTimeout(() => {
        dragged.current = false;
      }, 0);
    };
    handle.onpointerup = finish;
    handle.onpointercancel = finish;
  }
  return { beginDrag, wasDragged: () => dragged.current };
}

export function NavigationSettings({ navigation, onChange }) {
  const drag = useNavigationDrag((from, to) => onChange(moveNavigation(navigation, from, to)));
  return (
    <>
      <h3>顶部页签</h3>
      <p>开关控制显示，拖动行调整顺序；顶部的页签图标也可以直接拖动排序。</p>
      <ul className="navigation-settings">
        {navigation.map((item, index) => (
          <li
            key={item.id}
            data-navigation-id={item.id}
            data-navigation-group="settings"
            aria-label={`${PAGE_LABELS[item.id]}页签排序项`}
            onPointerDown={drag.beginDrag}
          >
            <DotsSixVertical size={18} aria-hidden="true" />
            <span>{PAGE_LABELS[item.id]}</span>
            <button
              aria-label={`上移${PAGE_LABELS[item.id]}`}
              disabled={index === 0}
              onClick={() => onChange(moveNavigation(navigation, item.id, navigation[index - 1].id))}
            >
              ↑
            </button>
            <button
              aria-label={`下移${PAGE_LABELS[item.id]}`}
              disabled={index === navigation.length - 1}
              onClick={() => onChange(moveNavigation(navigation, item.id, navigation[index + 1].id))}
            >
              ↓
            </button>
            <input
              type="checkbox"
              role="switch"
              aria-label={`显示${PAGE_LABELS[item.id]}页签`}
              checked={item.visible}
              onChange={(event) =>
                onChange(
                  navigation.map((value) =>
                    value.id === item.id ? { ...value, visible: event.target.checked } : value,
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

/// Work 第一栏分类（docs §6.1）。
export const WORK_SECTIONS = [
  ['all', '全部 Work', ListChecks],
  ['queued', '待执行', ClockCounterClockwise],
  ['running', '执行中', Terminal],
  ['waiting_user', '待回答', ChatCircleDots],
  ['waiting_review', '待审阅', GitDiff],
  ['trouble', '异常', WarningCircle],
  ['ended', '已结束', CheckCircle],
];

export const GIT_SECTIONS = [
  ['工作区', '工作区', GitDiff],
  ['提交历史', '提交历史', ClockCounterClockwise],
  ['分支', '分支', GitBranch],
  ['工作树', '工作树', TreeStructure],
  ['更多', '更多', DotsThree],
];

export function tapdSections(workspaces) {
  return [['all', '全部项目', Folder], ...workspaces.map((item) => [item.id, item.name || item.id, Folder])];
}

export function ModuleSidebar({
  page,
  items,
  section,
  onSection,
  counts = {},
  collapsed,
  onToggle,
  onSettings,
  terminalVisible,
  onTerminal,
  branchControls,
}) {
  const label = PAGE_LABELS[page] ?? 'ClaudePicker';
  return (
    <aside className={`module-sidebar ${collapsed ? 'collapsed' : ''}`} aria-label={`${label}操作栏`}>
      <div className="module-brand">
        <img src={appIcon} alt="ClaudePicker" />
        {!collapsed && <strong>{label}</strong>}
        <div className="sidebar-header-actions">
          <IconButton
            icon={SidebarSimple}
            label={collapsed ? '展开侧栏 ⌘B' : '收起侧栏 ⌘B'}
            onClick={onToggle}
          />
          {!terminalVisible && <IconButton icon={Terminal} label="展开终端 ⌘J" onClick={onTerminal} />}
        </div>
      </div>
      {!collapsed && branchControls && <div className="module-branch-controls">{branchControls}</div>}
      <nav aria-label={`${label}分类`}>
        {items.map(([id, text, Icon]) => (
          <button
            key={id}
            className={section === id ? 'active' : ''}
            title={text}
            aria-label={text}
            aria-current={section === id ? 'page' : undefined}
            onClick={() => onSection(id)}
          >
            <Icon size={18} />
            {!collapsed && <span>{text}</span>}
            {!collapsed && counts[id] > 0 && <small className="module-count">{counts[id]}</small>}
          </button>
        ))}
      </nav>
      <div className="module-sidebar-bottom">
        <button onClick={onSettings} title="设置" aria-label="设置">
          <Gear size={18} />
          {!collapsed && <span>设置</span>}
        </button>
      </div>
    </aside>
  );
}

/// 第一栏右边界：拖动 / 双击复位 / 方向键与 Home、End 调整，范围 180–360。
export const SIDEBAR_MIN = 180;
export const SIDEBAR_MAX = 360;
export const SIDEBAR_DEFAULT = 248;
export const clampSidebarWidth = (value) => Math.max(SIDEBAR_MIN, Math.min(SIDEBAR_MAX, Math.round(value)));

export function SidebarResizer({ width, onChange }) {
  function begin(event) {
    if (event.button !== 0) return;
    event.preventDefault();
    const handle = event.currentTarget;
    const startX = event.clientX;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (move) => onChange(clampSidebarWidth(width + move.clientX - startX));
    handle.onpointerup = handle.onpointercancel = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
    };
  }
  return (
    <div
      className="first-sidebar-resize"
      role="separator"
      aria-label="调整第一栏宽度"
      aria-orientation="vertical"
      aria-valuemin={SIDEBAR_MIN}
      aria-valuemax={SIDEBAR_MAX}
      aria-valuenow={width}
      tabIndex={0}
      title="拖动调整宽度，双击恢复默认"
      onPointerDown={begin}
      onDoubleClick={() => onChange(SIDEBAR_DEFAULT)}
      onKeyDown={(event) => {
        const next = {
          ArrowLeft: width - 12,
          ArrowRight: width + 12,
          Home: SIDEBAR_MIN,
          End: SIDEBAR_MAX,
        }[event.key];
        if (next === undefined) return;
        event.preventDefault();
        onChange(clampSidebarWidth(next));
      }}
    />
  );
}
