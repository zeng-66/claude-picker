// 悬浮终端：第二栏终端不可见时，从桌宠（或桌宠关闭时的圆形浮标）打开。
// 可移动、可从左上 / 右下角连续缩放；尺寸够大时把原生终端的「洞」搬进浮窗，显示真实终端（docs §8）。
import React, { useEffect, useRef } from 'react';
import { ArrowsInSimple, ArrowsOutSimple, Minus, Terminal } from '@phosphor-icons/react';
import appIcon from './clawd-mark.png';
import { IconButton, useStored } from './ui.jsx';

const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
const MIN = { width: 280, height: 180 };
const SMALL = { width: 360, height: 214 };
const LARGE = { width: 620, height: 420 };
// 上方让出标题栏，下方留一点边距。
const TOP = 52;
const BOTTOM = 16;

export function outputThreshold() {
  return {
    width: Math.min(520, window.innerWidth - 24),
    height: Math.min(330, window.innerHeight - TOP - BOTTOM - 48),
  };
}

export default function FloatingConsole({ open, onClose, title, status, composer, terminal, footer, onRestore }) {
  const [size, setSize] = useStored('consoleSize', SMALL);
  const [position, setPosition] = useStored('consolePosition', {
    x: Math.round(window.innerWidth * 0.3),
    y: Math.max(TOP + 20, window.innerHeight - SMALL.height - 80),
  });
  const moved = useRef(false);
  const threshold = outputThreshold();
  const showOutput = size.width >= threshold.width && size.height >= threshold.height;

  function contain(nextSize, nextPosition) {
    const width = clamp(nextSize.width, MIN.width, Math.max(MIN.width, window.innerWidth - 24));
    const height = clamp(nextSize.height, MIN.height, Math.max(MIN.height, window.innerHeight - TOP - BOTTOM));
    setSize((current) => (current.width === width && current.height === height ? current : { width, height }));
    const x = clamp(nextPosition.x, 12, Math.max(12, window.innerWidth - width - 12));
    const y = clamp(nextPosition.y, TOP, Math.max(TOP, window.innerHeight - height - BOTTOM));
    setPosition((current) => (current.x === x && current.y === y ? current : { x, y }));
  }

  useEffect(() => {
    if (!open) return undefined;
    const fit = () => contain(size, position);
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, [open, size.width, size.height, position.x, position.y]);

  function beginDrag(event) {
    if (event.button !== 0 || event.target.closest('[data-console-action]')) return;
    const handle = event.currentTarget;
    const start = { x: event.clientX, y: event.clientY, position };
    moved.current = false;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (pointer) => {
      const dx = pointer.clientX - start.x;
      const dy = pointer.clientY - start.y;
      if (!moved.current && Math.hypot(dx, dy) <= 4) return;
      moved.current = true;
      setPosition({
        x: clamp(start.position.x + dx, 12, window.innerWidth - size.width - 12),
        y: clamp(start.position.y + dy, TOP, window.innerHeight - size.height - BOTTOM),
      });
    };
    handle.onpointerup = handle.onpointercancel = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
      window.setTimeout(() => {
        moved.current = false;
      }, 0);
    };
  }

  function beginResize(event, corner) {
    if (event.button !== 0) return;
    event.preventDefault();
    const handle = event.currentTarget;
    const start = { x: event.clientX, y: event.clientY, size, position };
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (pointer) => {
      const direction = corner === 'top-left' ? -1 : 1;
      const width = clamp(
        start.size.width + direction * (pointer.clientX - start.x),
        MIN.width,
        corner === 'top-left' ? start.position.x + start.size.width - 12 : window.innerWidth - start.position.x - 12,
      );
      const height = clamp(
        start.size.height + direction * (pointer.clientY - start.y),
        MIN.height,
        corner === 'top-left'
          ? start.position.y + start.size.height - TOP
          : window.innerHeight - start.position.y - BOTTOM,
      );
      setSize({ width, height });
      // 左上角拖柄：右下角保持不动。
      if (corner === 'top-left')
        setPosition({
          x: start.position.x + start.size.width - width,
          y: start.position.y + start.size.height - height,
        });
    };
    handle.onpointerup = handle.onpointercancel = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
    };
  }

  function resizeWithKey(event) {
    const delta = { ArrowRight: [20, 0], ArrowLeft: [-20, 0], ArrowDown: [0, 20], ArrowUp: [0, -20] }[event.key];
    if (!delta) return;
    event.preventDefault();
    event.stopPropagation();
    contain({ width: size.width + delta[0], height: size.height + delta[1] }, position);
  }

  // 浮窗的位置、尺寸是本组件自己的状态：变化时让外壳重新回报布局，原生终端跟着浮窗走。
  useEffect(() => {
    window.dispatchEvent(new Event('claude-picker:layout'));
  }, [open, showOutput, size.width, size.height, position.x, position.y]);

  if (!open) return null;
  return (
    <section
      className={`floating-composer floating-console ${showOutput ? 'show-output' : ''} ${position.y < 220 ? 'near-top' : ''}`}
      style={{ left: position.x, top: position.y, width: size.width, height: size.height }}
      aria-label="悬浮终端"
    >
      <div className="floating-composer-header" onPointerDown={beginDrag}>
        <img src={appIcon} alt="" />
        <span>{title}</span>
        {status && <small role="status">{status}</small>}
        <div data-console-action>
          <IconButton
            icon={showOutput ? ArrowsInSimple : ArrowsOutSimple}
            label={showOutput ? '收起终端内容' : '展开终端内容'}
            onClick={() => contain(showOutput ? SMALL : LARGE, position)}
          />
        </div>
        <div data-console-action>
          <IconButton icon={Minus} label="收起到桌宠" onClick={onClose} />
        </div>
        <div data-console-action>
          <IconButton icon={Terminal} label="在工作空间展开终端 ⌘J" onClick={onRestore} />
        </div>
      </div>
      {showOutput ? (
        <>
          <div className="console-output">{terminal}</div>
          {footer}
        </>
      ) : (
        composer
      )}
      <button
        className="console-resize top-left"
        data-terminal-overlay
        aria-label="从左上角调整悬浮窗大小"
        title="拖动缩放"
        onPointerDown={(event) => beginResize(event, 'top-left')}
        onKeyDown={resizeWithKey}
      />
      <button
        className="console-resize bottom-right"
        data-terminal-overlay
        aria-label="调整悬浮窗大小"
        title="拖动缩放，方向键微调"
        onPointerDown={(event) => beginResize(event, 'bottom-right')}
        onKeyDown={resizeWithKey}
      />
    </section>
  );
}

/// 桌宠关闭时浮窗的入口：可拖动的小圆形浮标（docs §8.1）。
export function ConsoleBubble({ busy, onOpen }) {
  const [position, setPosition] = useStored('consoleBubble', {
    x: Math.max(12, window.innerWidth - 84),
    y: Math.max(TOP + 20, window.innerHeight - 96),
  });
  const moved = useRef(false);
  useEffect(() => {
    const fit = () =>
      setPosition((current) => {
        const x = clamp(current.x, 12, window.innerWidth - 60);
        const y = clamp(current.y, TOP, window.innerHeight - 60);
        return x === current.x && y === current.y ? current : { x, y };
      });
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, []);
  function beginDrag(event) {
    if (event.button !== 0) return;
    const handle = event.currentTarget;
    const start = { x: event.clientX, y: event.clientY, position };
    moved.current = false;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (pointer) => {
      const dx = pointer.clientX - start.x;
      const dy = pointer.clientY - start.y;
      if (!moved.current && Math.hypot(dx, dy) <= 4) return;
      moved.current = true;
      setPosition({
        x: clamp(start.position.x + dx, 12, window.innerWidth - 60),
        y: clamp(start.position.y + dy, TOP, window.innerHeight - 60),
      });
    };
    handle.onpointerup = handle.onpointercancel = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
      window.setTimeout(() => {
        moved.current = false;
      }, 0);
    };
  }
  return (
    <button
      className={`composer-bubble ${busy ? 'busy' : ''}`}
      style={{ left: position.x, top: position.y }}
      aria-label="打开悬浮终端"
      title="打开悬浮终端 · 拖动可移动"
      onPointerDown={beginDrag}
      onClick={() => {
        if (!moved.current) onOpen();
      }}
    >
      <img src={appIcon} alt="" />
    </button>
  );
}
