// 可拖动分割条 + 记忆尺寸。
// 尺寸存 localStorage（只是本机的界面偏好，读写失败就用默认值）；双击分割条恢复默认。
import React, { useState } from 'react';

export function useStoredSize(key, initial, min, max) {
  const [size, setSize] = useState(() => {
    try {
      const value = Number(window.localStorage.getItem(key));
      return Number.isFinite(value) && value >= min && value <= max ? value : initial;
    } catch {
      return initial;
    }
  });
  const commit = (value) => {
    try {
      window.localStorage.setItem(key, String(Math.round(value)));
    } catch {
      /* 存不了就只在本次会话生效 */
    }
  };
  return { size, setSize, commit, initial, min, max };
}

/**
 * @param axis    'x' 左右拖（改宽度） / 'y' 上下拖（改高度）
 * @param invert  分割条在被调整区域的左/上边时为 true（往左/上拖变大）
 * @param reserve 另一侧至少保留的像素；按父容器实时尺寸再夹一次上限
 */
export function Splitter({
  state,
  axis = 'x',
  invert = false,
  reserve = 0,
  className = '',
  style,
}) {
  const { size, setSize, commit, initial, min, max } = state;

  const onPointerDown = (event) => {
    if (event.button !== 0) return;
    event.preventDefault();
    const handle = event.currentTarget;
    const container = handle.parentElement;
    const start = axis === 'x' ? event.clientX : event.clientY;
    const base = size;
    const room = container
      ? (axis === 'x' ? container.clientWidth : container.clientHeight) - reserve
      : max;
    const upper = Math.max(min, Math.min(max, room));
    let last = base;

    const move = (ev) => {
      const delta = (axis === 'x' ? ev.clientX : ev.clientY) - start;
      last = Math.min(upper, Math.max(min, base + (invert ? -delta : delta)));
      setSize(last);
    };
    const up = () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      document.body.classList.remove('is-resizing-x', 'is-resizing-y');
      commit(last);
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
    document.body.classList.add(axis === 'x' ? 'is-resizing-x' : 'is-resizing-y');
  };

  return (
    <div
      role="separator"
      aria-orientation={axis === 'x' ? 'vertical' : 'horizontal'}
      title="拖动调整大小，双击恢复默认"
      className={`splitter splitter-${axis} ${className}`}
      style={style}
      onPointerDown={onPointerDown}
      onDoubleClick={() => {
        setSize(initial);
        commit(initial);
      }}
    />
  );
}
