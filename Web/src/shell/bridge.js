// JS ⇄ Swift 桥。全仓库唯一出现 `window.webkit` 的地方。
//
// 请求 `{id, method, params}` → 应答 `{id, ok, result}` 或 `{id, ok:false, error}`，
// 原生侧用 `window.__claudeBridge.receive(envelope)` 回包（Sources/ClaudeDeck/ThirdPane/Bridge.swift）。
// 原生 → 网页的单向事件走 `window.dispatchEvent(new CustomEvent('claude-picker:<name>'))`。
// 浏览器里直接 `npm run dev` 时没有原生桥，落到 mock.js 的内存演示数据。
import { mockRequest } from './mock.js';

const pending = new Map();
let nextId = 1;

export class BridgeError extends Error {
  constructor(error = {}) {
    super(error.message ?? '未知错误');
    this.name = 'BridgeError';
    this.code = error.code ?? 'COMMAND_FAILED';
    this.detail = error.detail ?? null;
    this.recoverable = error.recoverable !== false;
  }
}

function nativeHandler() {
  const handler = window.webkit?.messageHandlers?.claudeBridge;
  return handler && typeof handler.postMessage === 'function' ? handler : null;
}

export function isNative() {
  return nativeHandler() !== null || Boolean(window.claudeDesktop);
}

window.__claudeBridge = {
  receive(payload) {
    const envelope = typeof payload === 'string' ? JSON.parse(payload) : payload;
    const entry = pending.get(envelope?.id);
    if (!entry) return false;
    pending.delete(envelope.id);
    clearTimeout(entry.timer);
    if (envelope.ok) entry.resolve(envelope.result ?? null);
    else entry.reject(new BridgeError(envelope.error));
    return true;
  },
};

/// 发一条请求，返回解包后的 result；失败抛 BridgeError。
export function request(method, params = {}, { timeoutMs = 30000 } = {}) {
  if (window.claudeDesktop) {
    return window.claudeDesktop.request(method, params).then(envelope => {
      if (!envelope.ok) throw new BridgeError(envelope.error);
      return envelope.result;
    });
  }
  const handler = nativeHandler();
  if (!handler) {
    return mockRequest(method, params).catch((error) => {
      throw error instanceof BridgeError ? error : new BridgeError(error);
    });
  }
  return new Promise((resolve, reject) => {
    const id = nextId++;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new BridgeError({ code: 'TIMEOUT', message: `请求超时：${method}` }));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    try {
      handler.postMessage({ id, method, params });
    } catch (error) {
      pending.delete(id);
      clearTimeout(timer);
      reject(new BridgeError({ code: 'BRIDGE_UNAVAILABLE', message: String(error) }));
    }
  });
}

/// 订阅原生事件，返回取消订阅函数。
export function on(name, listener) {
  if (window.claudeDesktop) return window.claudeDesktop.on('claude-picker:' + name, listener);
  const handler = (event) => listener(event.detail ?? {});
  window.addEventListener('claude-picker:' + name, handler);
  return () => window.removeEventListener('claude-picker:' + name, handler);
}

/// 错误 → 一行给人看的中文（git 的 stderr 在 detail 里，优先展示）。
export function errorText(error) {
  const detail = typeof error?.detail === 'string' ? error.detail.trim() : '';
  const message = error?.message ?? '操作失败';
  if (!detail) return message;
  const firstLine = detail.split('\n').find((line) => line.trim()) ?? detail;
  return `${message}：${firstLine.trim()}`.slice(0, 220);
}
