/**
 * 桥客户端。UI 只认这个文件，**全仓库唯一允许出现 `window.webkit` 的地方**。
 *
 * - 有原生桥（WKWebView 注入 `window.webkit.messageHandlers.claudeBridge`）→ 真实请求
 * - 没有（浏览器直开、`npm run dev`、单测）→ 回落 `mock.js`
 * - 每个请求自带自增 id、默认 30s 超时；超时/取消都会 reject 一个可辨识的 `BridgeError`
 */
import {
  BridgeError,
  CLIENT_ERROR_CODES,
  DEFAULT_TIMEOUT_MS,
  ERROR_CODES,
  validateParams,
} from './protocol.js';
import { createMockTransport } from './mock.js';

/** 原生侧回包入口的全局名：`window.__claudeBridge.receive({id, ok, result|error})`。 */
export const REPLY_CHANNEL = '__claudeBridge';

/** id → { resolve, reject }，只在原生模式下使用。 */
const pending = new Map();
let nextId = 1;
let transport = null;

// ---------- 传输层 ----------

function nativeHandler() {
  if (typeof window === 'undefined') return null;
  const handlers = window.webkit?.messageHandlers;
  const handler = handlers?.claudeBridge;
  return handler && typeof handler.postMessage === 'function' ? handler : null;
}

export function hasNativeBridge() {
  return nativeHandler() !== null;
}

function nativeTransport(handler) {
  return {
    kind: 'native',
    send(message) {
      return new Promise((resolve, reject) => {
        pending.set(message.id, { resolve, reject });
        try {
          handler.postMessage(message);
        } catch (error) {
          pending.delete(message.id);
          reject(
            new BridgeError(CLIENT_ERROR_CODES.BRIDGE_UNAVAILABLE, `桥发送失败：${error.message}`, {
              source: 'client',
              detail: String(error),
              recoverable: false,
            }),
          );
        }
      });
    },
  };
}

function resolveTransport() {
  if (transport) return transport;
  const handler = nativeHandler();
  transport = handler ? nativeTransport(handler) : createMockTransport();
  return transport;
}

/** 供测试/热更新重置；正常代码不需要调用。 */
export function resetBridge() {
  pending.clear();
  transport = null;
  nextId = 1;
}

/**
 * 注册原生回包入口。T3 在 `main.swift` 里用 `evaluateJavaScript` 调
 * `window.__claudeBridge.receive(<json>)` 即可，不需要知道待处理请求表。
 */
export function installReceiver(target = typeof window === 'undefined' ? null : window) {
  if (!target) return false;
  if (!target[REPLY_CHANNEL] || typeof target[REPLY_CHANNEL].receive !== 'function') {
    target[REPLY_CHANNEL] = { receive: receiveResponse };
  }
  return true;
}

/** 原生侧回包：接受 JSON 字符串或已解析对象。 */
export function receiveResponse(payload) {
  let envelope = payload;
  if (typeof payload === 'string') {
    try {
      envelope = JSON.parse(payload);
    } catch {
      return false;
    }
  }
  if (!envelope || typeof envelope !== 'object') return false;
  const entry = pending.get(envelope.id);
  if (!entry) return false;
  pending.delete(envelope.id);
  if (envelope.ok) {
    entry.resolve(envelope);
  } else {
    entry.reject(toBridgeError(envelope.error));
  }
  return true;
}

function toBridgeError(error) {
  const code = error?.code ?? ERROR_CODES.COMMAND_FAILED;
  return new BridgeError(code, error?.message ?? '未知桥错误', {
    detail: error?.detail ?? null,
    recoverable: Boolean(error?.recoverable),
    source: 'bridge',
  });
}

// ---------- 超时 / 取消 ----------

function withDeadline(promise, { method, timeoutMs, signal }) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (signal) signal.removeEventListener('abort', onAbort);
      fn(value);
    };
    const timer = setTimeout(() => {
      finish(
        reject,
        new BridgeError(CLIENT_ERROR_CODES.TIMEOUT, `请求超时（${timeoutMs}ms）：${method}`, {
          source: 'client',
          recoverable: true,
        }),
      );
    }, timeoutMs);
    const onAbort = () =>
      finish(
        reject,
        new BridgeError(CLIENT_ERROR_CODES.ABORTED, `请求已取消：${method}`, {
          source: 'client',
          recoverable: true,
        }),
      );
    if (signal) {
      if (signal.aborted) return onAbort();
      signal.addEventListener('abort', onAbort, { once: true });
    }
    promise.then(
      (value) => finish(resolve, value),
      (error) => finish(reject, error),
    );
  });
}

// ---------- 对外 API ----------

/**
 * 发一条请求，返回 `result`（已解包）。失败时抛 `BridgeError`。
 *
 * @param {string} method `protocol.js` METHODS 里的方法名，如 `git.status`
 * @param {object} [params]
 * @param {{timeoutMs?: number, signal?: AbortSignal}} [options]
 */
export async function request(method, params = {}, options = {}) {
  installReceiver();
  const validated = validateParams(method, params);
  const { timeoutMs = DEFAULT_TIMEOUT_MS, signal } = options;
  if (signal?.aborted) {
    throw new BridgeError(CLIENT_ERROR_CODES.ABORTED, `请求已取消：${method}`, {
      source: 'client',
      recoverable: true,
    });
  }

  const id = nextId;
  nextId += 1;
  const active = resolveTransport();
  const message = { id, method, params: validated };

  let envelope;
  try {
    envelope = await withDeadline(active.send(message), { method, timeoutMs, signal });
  } finally {
    pending.delete(id);
  }

  if (!envelope || typeof envelope !== 'object') {
    throw new BridgeError(
      CLIENT_ERROR_CODES.BRIDGE_UNAVAILABLE,
      `桥返回了非法响应：${method}`,
      { source: 'client', recoverable: false },
    );
  }
  if (envelope.ok) return envelope.result;

  const error = toBridgeError(envelope.error);
  // 第三栏刚接上原生侧时，Swift 对所有方法都回 NOT_IMPLEMENTED。这里自动回落 mock，
  // 让界面保持完整可用；每接入一批方法，对应的请求自然走真桥，前端不用逐方法改。
  if (active.kind === 'native' && error.code === CLIENT_ERROR_CODES.NOT_IMPLEMENTED) {
    const retryId = nextId;
    nextId += 1;
    let retryEnvelope;
    try {
      retryEnvelope = await withDeadline(createMockTransport().send({ id: retryId, method, params: validated }), {
        method,
        timeoutMs,
        signal,
      });
    } finally {
      pending.delete(retryId);
    }
    if (retryEnvelope && retryEnvelope.ok) return retryEnvelope.result;
    throw toBridgeError(retryEnvelope?.error ?? envelope.error);
  }
  throw error;
}

/**
 * `file.watch` 的占位实现。本卡不做事件推送；T4 接真实文件监听时
 * 按 SPEC 用 1s 轮询 `file.stat`，返回 `unsubscribe`。
 */
export async function watch() {
  throw new BridgeError(
    CLIENT_ERROR_CODES.NOT_IMPLEMENTED,
    'bridge.watch 尚未实现（计划：1s 轮询 file.stat）',
    { source: 'client', recoverable: false },
  );
}

/** 当前走的是真桥还是 mock，UI 状态栏可用它显示数据来源。 */
export function transportKind() {
  return resolveTransport().kind;
}

export const bridge = {
  request,
  watch,
  hasNativeBridge,
  transportKind,
  installReceiver,
  reset: resetBridge,
};
