import React, { useCallback, useState } from 'react';
import { request } from './bridge.js';

export function IconButton({ icon: Icon, label, onClick, active = false, className, ...props }) {
  return (
    <button
      className={className ?? `icon-button ${active ? 'active' : ''}`}
      title={label}
      aria-label={label}
      onClick={onClick}
      {...props}
    >
      <Icon size={17} />
    </button>
  );
}

/// 记在本机的界面偏好（变更栏宽度、差异视图模式…）。存不了就只在本次生效。
export function useStored(key, initial) {
  const [value, setValue] = useState(() => {
    try {
      const raw = window.localStorage.getItem('cp.' + key);
      return raw === null ? initial : JSON.parse(raw);
    } catch {
      return initial;
    }
  });
  const update = useCallback(
    (next) =>
      setValue((current) => {
        const resolved = typeof next === 'function' ? next(current) : next;
        try {
          window.localStorage.setItem('cp.' + key, JSON.stringify(resolved));
        } catch {
          /* 忽略 */
        }
        return resolved;
      }),
    [key],
  );
  return [value, update];
}

/// 分隔条拖动：按下后独占指针，松开或取消时收尾。
export function trackPaneDrag(event, onMove, onEnd) {
  if (event.button !== 0) return;
  event.preventDefault();
  const handle = event.currentTarget;
  handle.setPointerCapture(event.pointerId);
  handle.onpointermove = onMove;
  const finish = () => {
    handle.onpointermove = null;
    handle.onpointerup = null;
    handle.onpointercancel = null;
    onEnd?.();
  };
  handle.onpointerup = finish;
  handle.onpointercancel = finish;
}

/// `/Users/me/project/x` → `~/project/x`
export function tildePath(path, home) {
  if (!path) return '';
  if (home && (path === home || path.startsWith(home + '/'))) return '~' + path.slice(home.length);
  return path;
}

export function baseName(path = '') {
  const clean = String(path).replace(/\/+$/, '');
  return clean.slice(clean.lastIndexOf('/') + 1);
}

export function dirName(path = '') {
  const clean = String(path).replace(/\/+$/, '');
  const index = clean.lastIndexOf('/');
  return index === -1 ? '' : clean.slice(0, index);
}

/// ISO 时间 → 「12 分钟前 / 昨天 / 2026-11-13」
export function relativeTime(iso) {
  const date = new Date(iso);
  if (!iso || Number.isNaN(date.getTime())) return '';
  const seconds = (Date.now() - date.getTime()) / 1000;
  if (seconds < 60) return '刚刚';
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`;
  if (seconds < 172800) return '昨天';
  if (seconds < 86400 * 30) return `${Math.floor(seconds / 86400)} 天前`;
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

/// 外部链接一律交给系统浏览器（外壳 WebView 不跳转）。
export function openExternal(url) {
  return request('app.openURL', { url }).catch(() => {});
}
