// Clawd 桌宠（P1：主窗口内浮层）。docs/ui-refactor-v003.md §9。
// 显示优先级：一次性反应 > 拖动 / 散步 > 睡眠流程 > 空闲小剧场 > 状态动画。
import React, { useEffect, useMemo, useRef, useState } from 'react';
import { ArrowsOut, ChatCircleDots, Gear } from '@phosphor-icons/react';
import { themeOf } from './themes.js';
import { DEFAULT_PET } from './PetSettings.jsx';
import './pet.css';

const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
const MARGIN = 12;
const TOP = 48;
const STATE_LABELS = {
  idle: '准备就绪',
  working: '正在执行',
  plan: '正在规划',
  ultrathink: '深度思考中',
  thinking: '思考中',
  notification: '需要你的回答',
  review: '有结果待审阅',
  error: '执行遇到问题',
  complete: '任务已完成',
};
const BADGES = { notification: '•', review: '•', error: '!', complete: '✓' };

/// 让外壳重新回报布局：桌宠盖在终端「洞」上时，原生需要知道这块区域归网页。
export const reportLayoutSoon = () => window.dispatchEvent(new Event('claude-picker:layout'));

function todayKey() {
  const now = new Date();
  return `${now.getFullYear()}-${now.getMonth() + 1}-${now.getDate()}`;
}
function onceToday(name) {
  try {
    const key = `cp.pet.${name}`;
    if (localStorage.getItem(key) === todayKey()) return false;
    localStorage.setItem(key, todayKey());
  } catch {}
  return true;
}

export default function DesktopPet({ settings, onChange, signals, onClick, onOpenConsole, onOpenSession, onSettings }) {
  const pet = { ...DEFAULT_PET, ...settings };
  const theme = themeOf(pet.theme);
  const dark = true; // 外壳是深色界面，Dev Life 用深色素材
  const width = pet.size;
  const height = Math.round(pet.size / theme.aspect);
  const defaultPosition = () => ({
    x: Math.max(MARGIN, window.innerWidth - width - 40),
    y: Math.max(TOP, window.innerHeight - height - 30),
  });
  const [position, setPosition] = useState(() =>
    pet.x != null && pet.y != null ? { x: pet.x, y: pet.y } : defaultPosition(),
  );
  const [menu, setMenu] = useState(false);
  const [overlay, setOverlay] = useState(null); // { clip, key } 一次性反应 / 小剧场 / 作息
  const [motion, setMotion] = useState(null); // 拖动或散步时的动画
  const [sleep, setSleep] = useState(null); // null | 'yawning' | 'sleeping' | 'waking'
  const overlayTimer = useRef(0);
  const moved = useRef(false);
  const clicks = useRef([]);
  const lastActivity = useRef(Date.now());
  const handled = useRef(new Set());

  const state = signals.state;
  const tier = signals.running >= 3 ? 3 : signals.running >= 2 ? 2 : 1;
  // 状态动画：状态（或工作中的人数档位）变化时才重新随机选一个文件。
  const stateClip = useMemo(
    () => theme.clip(state, { dark, running: signals.running }),
    [theme.id, state, state === 'working' ? tier : 0],
  );

  function play(clip, fallbackMs = 1600) {
    if (!clip?.url) return;
    window.clearTimeout(overlayTimer.current);
    setOverlay({ clip, key: `${clip.file}-${Date.now()}` });
    overlayTimer.current = window.setTimeout(() => setOverlay(null), clip.duration || fallbackMs);
  }
  useEffect(() => () => window.clearTimeout(overlayTimer.current), []);

  // 设置里改了位置或尺寸：同步并限制在窗口内。
  useEffect(() => {
    const fit = () =>
      setPosition((current) => {
        const x = clamp(current.x, MARGIN, window.innerWidth - width - MARGIN);
        const y = clamp(current.y, TOP, window.innerHeight - height - MARGIN);
        return x === current.x && y === current.y ? current : { x, y };
      });
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, [width, height]);

  useEffect(() => {
    reportLayoutSoon();
  }, [position.x, position.y, width, height, menu]);

  // 一次性事件（启动问好、Git 冲突、TAPD 流转成功……）。
  useEffect(() => {
    for (const event of signals.events) {
      if (handled.current.has(event.id)) continue;
      handled.current.add(event.id);
      play(theme.reaction(event.name, { dark }));
    }
  }, [signals.events]);

  // 状态变化算一次活动：叫醒睡着的桌宠。
  useEffect(() => {
    lastActivity.current = Date.now();
    if (sleep === 'sleeping' || sleep === 'yawning') wake();
  }, [state]);

  useEffect(() => {
    const touch = () => {
      lastActivity.current = Date.now();
      if (sleep === 'sleeping' || sleep === 'yawning') wake();
    };
    window.addEventListener('pointermove', touch, { passive: true });
    window.addEventListener('keydown', touch);
    return () => {
      window.removeEventListener('pointermove', touch);
      window.removeEventListener('keydown', touch);
    };
  }, [sleep]);

  function wake() {
    setSleep('waking');
    window.setTimeout(() => setSleep((current) => (current === 'waking' ? null : current)), theme.timings.wakeDuration ?? 1500);
  }

  // 空闲计时：小剧场、作息、入睡。
  useEffect(() => {
    if (!pet.enabled) return undefined;
    const timer = window.setInterval(() => {
      if (state !== 'idle' || overlay || motion || menu || sleep) return;
      const idleFor = Date.now() - lastActivity.current;
      const sleepAfter = theme.timings.mouseSleepTimeout;
      if (sleepAfter && idleFor > sleepAfter) {
        setSleep('yawning');
        window.setTimeout(() => setSleep((current) => (current === 'yawning' ? 'sleeping' : current)), theme.timings.yawnDuration ?? 5000);
        return;
      }
      if (!pet.idleShows || idleFor < (theme.timings.mouseIdleTimeout ?? 20000)) return;
      const hour = new Date().getHours();
      if (hour >= 18 && onceToday('offwork')) return play(theme.routine('offwork', dark));
      if (hour >= 22 && signals.running > 0 && onceToday('overtime')) return play(theme.routine('overtime', dark));
      if (Math.random() < 0.35) play(theme.idleShow(dark));
    }, 9000);
    return () => window.clearInterval(timer);
  }, [pet.enabled, pet.idleShows, state, overlay, motion, menu, sleep, theme.id, signals.running]);

  // 空闲散步。
  useEffect(() => {
    if (!pet.enabled || !pet.wander || state !== 'idle' || menu || sleep) return undefined;
    const timer = window.setInterval(() => {
      if (overlay || moved.current) return;
      const direction = position.x + width / 2 > window.innerWidth / 2 ? -1 : 1;
      setMotion(theme.walk(direction, dark));
      setPosition((current) => ({
        ...current,
        x: clamp(current.x + direction * 100, MARGIN, window.innerWidth - width - MARGIN),
      }));
      window.setTimeout(() => setMotion(null), 1800);
    }, 10000);
    return () => window.clearInterval(timer);
  }, [pet.enabled, pet.wander, state, menu, sleep, overlay, position.x, width, theme.id]);

  // 右键菜单：点外面或按 Esc 关闭。
  useEffect(() => {
    if (!menu) return undefined;
    const close = (event) => {
      if (!event.target.closest('.desktop-pet-layer')) setMenu(false);
    };
    window.addEventListener('pointerdown', close);
    return () => window.removeEventListener('pointerdown', close);
  }, [menu]);

  function beginDrag(event) {
    if (event.button !== 0) return;
    const handle = event.currentTarget;
    const start = { x: event.clientX, y: event.clientY, position };
    moved.current = false;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (pointer) => {
      const dx = pointer.clientX - start.x;
      const dy = pointer.clientY - start.y;
      if (!moved.current && Math.hypot(dx, dy) < 5) return;
      if (!moved.current) {
        setMenu(false);
        setSleep(null);
        setMotion(theme.reaction('drag', { dark }));
      }
      moved.current = true;
      setPosition({
        x: clamp(start.position.x + dx, MARGIN, window.innerWidth - width - MARGIN),
        y: clamp(start.position.y + dy, TOP, window.innerHeight - height - MARGIN),
      });
    };
    handle.onpointerup = handle.onpointercancel = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
      if (moved.current) {
        setMotion(null);
        setPosition((current) => {
          onChange({ x: Math.round(current.x), y: Math.round(current.y) });
          return current;
        });
      }
      window.setTimeout(() => {
        moved.current = false;
      }, 0);
    };
  }

  function handleClick() {
    if (moved.current) return;
    setMenu(false);
    const now = Date.now();
    clicks.current = [...clicks.current.filter((time) => now - time < 2000), now];
    if (clicks.current.length >= 5) {
      clicks.current = [];
      play(theme.reaction('annoyed', { dark }));
    } else {
      play(theme.reaction('click', { dark }));
    }
    onClick();
  }

  function run(action) {
    setMenu(false);
    action();
  }

  if (!pet.enabled) return null;

  const sleepClip = sleep ? theme.clip(sleep, { dark }) : null;
  const shown = overlay?.clip ?? motion ?? sleepClip ?? stateClip;
  const imageKey = overlay?.key ?? shown?.file ?? 'idle';
  const popupWidth = Math.min(220, window.innerWidth - 24);
  const popupLeft = clamp(position.x + width / 2 - popupWidth / 2, MARGIN, window.innerWidth - popupWidth - MARGIN);
  const popupTop = Math.max(TOP, position.y - 268);

  return (
    <div className="desktop-pet-layer">
      {menu && (
        <div
          className="pet-context-menu"
          role="menu"
          aria-label="桌宠菜单"
          data-terminal-overlay
          style={{ left: popupLeft, top: popupTop, width: popupWidth }}
        >
          <div className="pet-menu-status">{STATE_LABELS[state] ?? state}</div>
          <button role="menuitem" onClick={() => run(onOpenSession)}>
            <ArrowsOut size={15} />
            打开当前会话
          </button>
          <button role="menuitem" onClick={() => run(onOpenConsole)}>
            <ChatCircleDots size={15} />
            打开悬浮输入
          </button>
          <button role="menuitem" onClick={() => run(() => play(theme.reaction('hello', { dark })))}>
            挥手
          </button>
          <button role="menuitem" onClick={() => run(() => play(theme.reaction('jump', { dark })))}>
            跳一下
          </button>
          <button role="menuitem" onClick={() => run(onSettings)}>
            <Gear size={15} />
            桌宠设置
          </button>
          <button
            role="menuitem"
            onClick={() =>
              run(() => {
                const clip = theme.reaction('bye', { dark });
                play(clip);
                window.setTimeout(() => onChange({ enabled: false }), Math.min(clip?.duration || 1400, 2600));
              })
            }
          >
            隐藏桌宠
          </button>
        </div>
      )}
      <button
        className={`desktop-pet ${moved.current ? 'dragging' : ''} ${motion && !moved.current ? 'walking' : ''}`}
        data-terminal-overlay
        data-theme={theme.id}
        style={{ left: position.x, top: position.y, width, height }}
        aria-label={`Clawd 桌宠，${STATE_LABELS[state] ?? state}`}
        title="点击打开悬浮终端 · 拖动移动 · 右键更多操作"
        onPointerDown={beginDrag}
        onClick={handleClick}
        onDoubleClick={() => play(theme.reaction('double', { dark }))}
        onContextMenu={(event) => {
          event.preventDefault();
          setMenu(true);
          play(theme.reaction('right', { dark }));
        }}
        onKeyDown={(event) => {
          if (event.key === 'Escape') {
            setMenu(false);
            event.stopPropagation();
          }
        }}
      >
        {shown?.url && <img key={imageKey} src={shown.url} alt="" draggable="false" />}
        {BADGES[state] && <span className={`pet-attention ${state}`}>{BADGES[state]}</span>}
      </button>
    </div>
  );
}
