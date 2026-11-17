// 应用内的确认框。WKWebView 里 window.confirm 不会弹出（宿主没有接管 JS 对话框），所以统一走这里。
import React, { useEffect, useRef, useState } from 'react';

let ask = null;

/// 弹出确认框，返回用户是否确认。没有宿主组件时按「未确认」处理。
export function confirmAction(options) {
  return ask ? ask(options) : Promise.resolve(false);
}

export function ConfirmHost() {
  const [pending, setPending] = useState(null);
  const confirmButton = useRef(null);
  const previousFocus = useRef(null);

  useEffect(() => {
    ask = (options) =>
      new Promise((resolve) => {
        previousFocus.current = document.activeElement;
        setPending({ options, resolve });
      });
    return () => {
      ask = null;
    };
  }, []);

  useEffect(() => {
    if (pending) confirmButton.current?.focus();
  }, [pending]);

  if (!pending) return null;
  const { options, resolve } = pending;
  const finish = (value) => {
    setPending(null);
    resolve(value);
    previousFocus.current?.focus?.(); // 焦点回到触发入口
  };
  return (
    <div className="modal-backdrop confirm-backdrop" data-blocking onClick={() => finish(false)}>
      <section
        className="modal confirm-modal"
        role="alertdialog"
        aria-modal="true"
        aria-label={options.title}
        onClick={(event) => event.stopPropagation()}
        onKeyDown={(event) => {
          if (event.key === 'Escape') {
            event.stopPropagation();
            finish(false);
          }
        }}
      >
        <h2>{options.title}</h2>
        {options.text && <p className="modal-description">{options.text}</p>}
        <div className="modal-footer">
          <button onClick={() => finish(false)}>{options.cancelLabel ?? '取消'}</button>
          <button
            ref={confirmButton}
            className={options.danger ? 'danger solid' : 'primary'}
            onClick={() => finish(true)}
          >
            {options.confirmLabel ?? '确认'}
          </button>
        </div>
      </section>
    </div>
  );
}
