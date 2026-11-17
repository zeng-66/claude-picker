import React, { useEffect, useRef, useState } from "react";
import {
  ArrowsOut,
  ChatCircleDots,
  Gear,
  Monitor,
  X,
} from "@phosphor-icons/react";
import { useStored } from "./ui.jsx";
import idle from "../assets/clawd/clawd-idle.gif";
import running from "../assets/clawd/clawd-running.gif";
import runningLeft from "../assets/clawd/clawd-running-left.gif";
import runningRight from "../assets/clawd/clawd-running-right.gif";
import waving from "../assets/clawd/clawd-waving.gif";
import jumping from "../assets/clawd/clawd-jumping.gif";
import waiting from "../assets/clawd/clawd-waiting.gif";
import review from "../assets/clawd/clawd-review.gif";
import failed from "../assets/clawd/clawd-failed.gif";
import "./desktop-pet.css";

export const DEFAULT_PET_SETTINGS = {
  enabled: true,
  size: 128,
  state: "auto",
  wander: false,
};
export const PET_STATES = [
  ["auto", "跟随当前会话"],
  ["idle", "空闲"],
  ["running", "执行中"],
  ["waiting", "等待回答"],
  ["review", "待审阅"],
  ["failed", "执行失败"],
  ["complete", "已完成"],
];
const animations = {
  idle,
  running,
  "running-left": runningLeft,
  "running-right": runningRight,
  waving,
  jumping,
  waiting,
  review,
  failed,
  complete: jumping,
};
const stateLabels = {
  idle: "准备就绪",
  running: "正在执行",
  waiting: "需要你的回答",
  review: "有结果待审阅",
  failed: "执行遇到问题",
  complete: "任务已完成",
};
const clamp = (value, low, high) => Math.max(low, Math.min(high, value));

export function PetSettings({ settings, onChange, onPreviewDesktop }) {
  return (
    <>
      <h3>Clawd 桌宠</h3>
      <p>用动画显示会话状态，点击查看当前会话，拖动可调整位置。</p>
      <label className="pet-setting-switch">
        <span>显示桌宠</span>
        <input
          type="checkbox"
          role="switch"
          aria-label="显示桌宠"
          checked={settings.enabled}
          onChange={(event) =>
            onChange({ ...settings, enabled: event.target.checked })
          }
        />
      </label>
      <label className="field">
        桌宠大小
        <select
          aria-label="桌宠大小"
          value={settings.size}
          onChange={(event) =>
            onChange({ ...settings, size: Number(event.target.value) })
          }
        >
          <option value="96">小</option>
          <option value="128">标准</option>
          <option value="160">大</option>
        </select>
      </label>
      <label className="pet-setting-switch">
        <span>空闲时散步</span>
        <input
          type="checkbox"
          role="switch"
          aria-label="空闲时散步"
          checked={settings.wander}
          onChange={(event) =>
            onChange({ ...settings, wander: event.target.checked })
          }
        />
      </label>
      <label className="field">
        演示状态
        <select
          aria-label="桌宠演示状态"
          value={settings.state}
          onChange={(event) =>
            onChange({ ...settings, state: event.target.value })
          }
        >
          {PET_STATES.map(([value, label]) => (
            <option key={value} value={value}>
              {label}
            </option>
          ))}
        </select>
      </label>
      <button onClick={onPreviewDesktop}>
        <Monitor size={15} />
        预览桌面模式
      </button>
      <p className="setting-hint">
        桌面模式在浏览器中演示窗口最小化后的桌宠与悬浮输入交互。
      </p>
    </>
  );
}

export function DesktopScene({ onRestore }) {
  return (
    <section className="desktop-scene" aria-label="桌面模式演示">
      <span className="desktop-scene-label">桌面模式 · 原型</span>
      <button className="return-to-app" onClick={onRestore}>
        <Monitor size={19} />
        返回 ClaudePicker
      </button>
    </section>
  );
}

export default function DesktopPet({
  settings,
  onChange,
  active,
  onOpenSession,
  onOpenConsole,
  onSettings,
  onDesktop,
}) {
  const [position, setPosition] = useStored("petPosition", {
    x: Math.max(12, window.innerWidth - 178),
    y: Math.max(52, window.innerHeight - 240),
  });
  const [bubble, setBubble] = useState(false);
  const [menu, setMenu] = useState(false);
  const [action, setAction] = useState(null);
  const [dragging, setDragging] = useState(false);
  const moved = useRef(false);
  const actionTimer = useRef(null);
  const height = Math.round((settings.size * 208) / 192);
  const state =
    settings.state === "auto"
      ? active?.busy
        ? "running"
        : "idle"
      : settings.state;
  const animation = action || state;

  function play(name, duration = 1400) {
    clearTimeout(actionTimer.current);
    setAction(name);
    actionTimer.current = setTimeout(() => setAction(null), duration);
  }
  useEffect(() => () => clearTimeout(actionTimer.current), []);

  useEffect(() => {
    const fit = () =>
      setPosition((current) => {
        const x = clamp(current.x, 12, window.innerWidth - settings.size - 12);
        const y = clamp(current.y, 52, window.innerHeight - height - 64);
        return x === current.x && y === current.y ? current : { x, y };
      });
    fit();
    window.addEventListener("resize", fit);
    return () => window.removeEventListener("resize", fit);
  }, [settings.size, height]);

  useEffect(() => {
    if (!bubble && !menu) return;
    const closeOutside = (event) => {
      if (!event.target.closest(".desktop-pet-layer")) {
        setBubble(false);
        setMenu(false);
      }
    };
    window.addEventListener("pointerdown", closeOutside);
    return () => window.removeEventListener("pointerdown", closeOutside);
  }, [bubble, menu]);

  useEffect(() => {
    if (
      !settings.enabled ||
      !settings.wander ||
      state !== "idle" ||
      dragging ||
      bubble ||
      menu
    )
      return;
    const timer = setInterval(() => {
      const direction = position.x > window.innerWidth / 2 ? -1 : 1;
      play(direction < 0 ? "running-left" : "running-right", 1800);
      setPosition((current) => ({
        ...current,
        x: clamp(
          current.x + direction * 100,
          12,
          window.innerWidth - settings.size - 12,
        ),
      }));
    }, 10000);
    return () => clearInterval(timer);
  }, [
    settings.enabled,
    settings.wander,
    settings.size,
    state,
    dragging,
    bubble,
    menu,
    position.x,
  ]);

  function beginDrag(event) {
    if (event.button !== 0) return;
    const handle = event.currentTarget;
    const start = { x: event.clientX, y: event.clientY, position };
    moved.current = false;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (pointer) => {
      const dx = pointer.clientX - start.x,
        dy = pointer.clientY - start.y;
      if (Math.hypot(dx, dy) < 5 && !moved.current) return;
      if (!moved.current) {
        clearTimeout(actionTimer.current);
        setBubble(false);
        setMenu(false);
        setDragging(true);
      }
      moved.current = true;
      setAction(dx < 0 ? "running-left" : "running-right");
      setPosition({
        x: clamp(
          start.position.x + dx,
          12,
          window.innerWidth - settings.size - 12,
        ),
        y: clamp(start.position.y + dy, 52, window.innerHeight - height - 64),
      });
    };
    const finish = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
      setDragging(false);
      if (moved.current) play("jumping", 800);
      setTimeout(() => {
        moved.current = false;
      }, 0);
    };
    handle.onpointerup = finish;
    handle.onpointercancel = finish;
  }

  function closeAndRun(operation) {
    setBubble(false);
    setMenu(false);
    operation();
  }
  if (!settings.enabled) return null;
  const popupWidth = Math.min(280, window.innerWidth - 24);
  const popupLeft = clamp(
    position.x + settings.size / 2 - popupWidth / 2,
    12,
    window.innerWidth - popupWidth - 12,
  );
  const popupTop = Math.max(52, position.y - (menu ? 290 : 128));
  return (
    <div className="desktop-pet-layer">
      {bubble && (
        <section
          className={`pet-speech ${state}`}
          style={{ left: popupLeft, top: popupTop, width: popupWidth }}
          aria-label="桌宠会话状态"
        >
          <header>
            <span className="pet-status-dot" />
            <strong>{stateLabels[state]}</strong>
            <button aria-label="关闭桌宠状态" onClick={() => setBubble(false)}>
              <X size={12} />
            </button>
          </header>
          <p>{active?.label || "选择会话后开始新的任务"}</p>
          <div>
            <button onClick={() => closeAndRun(onOpenSession)}>打开会话</button>
            <button onClick={() => closeAndRun(onOpenConsole)}>悬浮输入</button>
          </div>
        </section>
      )}
      {menu && (
        <div
          className="pet-context-menu"
          role="menu"
          aria-label="桌宠菜单"
          style={{ left: popupLeft, top: popupTop, width: popupWidth }}
        >
          <button role="menuitem" onClick={() => closeAndRun(onOpenSession)}>
            <ArrowsOut size={15} />
            打开当前会话
          </button>
          <button role="menuitem" onClick={() => closeAndRun(onOpenConsole)}>
            <ChatCircleDots size={15} />
            打开悬浮输入
          </button>
          <button
            role="menuitem"
            onClick={() => closeAndRun(() => play("waving"))}
          >
            挥手
          </button>
          <button
            role="menuitem"
            onClick={() => closeAndRun(() => play("jumping", 1000))}
          >
            跳一下
          </button>
          <button role="menuitem" onClick={() => closeAndRun(onDesktop)}>
            <Monitor size={15} />
            桌面模式
          </button>
          <button role="menuitem" onClick={() => closeAndRun(onSettings)}>
            <Gear size={15} />
            桌宠设置
          </button>
          <button
            role="menuitem"
            onClick={() =>
              closeAndRun(() => onChange({ ...settings, enabled: false }))
            }
          >
            隐藏桌宠
          </button>
        </div>
      )}
      <button
        className={`desktop-pet ${dragging ? "dragging" : ""} ${action?.startsWith("running-") && !dragging ? "walking" : ""}`}
        style={{
          left: position.x,
          top: position.y,
          width: settings.size,
          height,
        }}
        aria-label={`Clawd 桌宠，${stateLabels[state]}`}
        title="点击查看会话 · 拖动移动 · 右键更多操作"
        onPointerDown={beginDrag}
        onClick={() => {
          if (!moved.current) {
            setMenu(false);
            setBubble(!bubble);
          }
        }}
        onDoubleClick={() => {
          setBubble(false);
          play("jumping", 1000);
        }}
        onContextMenu={(event) => {
          event.preventDefault();
          setBubble(false);
          setMenu(true);
        }}
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            setBubble(false);
            setMenu(false);
            event.stopPropagation();
          }
        }}
      >
        <img
          src={animations[animation]}
          alt={`Clawd ${animation}`}
          draggable="false"
        />
        {["waiting", "review", "failed", "complete"].includes(state) && (
          <span className={`pet-attention ${state}`}>
            {state === "complete" ? "✓" : state === "failed" ? "!" : "•"}
          </span>
        )}
      </button>
    </div>
  );
}
