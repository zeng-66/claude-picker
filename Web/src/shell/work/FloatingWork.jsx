// 收起对话后的悬浮输入卡片：与对话共用同一份草稿（按 Work 保存），抓手可拖动，恢复后草稿还在。
import React, { useEffect, useRef, useState } from 'react';
import { ArrowUp, ArrowsOut, CircleNotch, DotsSixVertical, Warning } from '@phosphor-icons/react';
import { errorText, request } from '../bridge.js';
import { IconButton, useStored } from '../ui.jsx';
import { newId, statusOf, useDraft } from './useWorks.js';

export default function FloatingWork({ work, onRestore }) {
  const [draft, setDraft, clearDraft] = useDraft('chat', work.id);
  const [position, setPosition] = useStored('floatingWork', { x: window.innerWidth - 460, y: window.innerHeight - 220 });
  const [sending, setSending] = useState(false);
  const [error, setError] = useState(null);
  const panel = useRef(null);
  const pending = useRef(null);

  // 窗口变小后把卡片拉回可见范围。
  useEffect(() => {
    const contain = () => {
      const box = panel.current?.getBoundingClientRect();
      if (!box) return;
      setPosition((current) => {
        const next = {
          x: Math.max(12, Math.min(window.innerWidth - box.width - 12, current.x)),
          y: Math.max(52, Math.min(window.innerHeight - box.height - 12, current.y)),
        };
        return next.x === current.x && next.y === current.y ? current : next;
      });
    };
    contain();
    window.addEventListener('resize', contain);
    return () => window.removeEventListener('resize', contain);
  }, []);

  function drag(event) {
    if (event.button !== 0 || event.target.closest('button')) return;
    const handle = event.currentTarget;
    const start = { ...position };
    const origin = { x: event.clientX, y: event.clientY };
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (move) => {
      const box = panel.current.getBoundingClientRect();
      setPosition({
        x: Math.max(12, Math.min(window.innerWidth - box.width - 12, start.x + move.clientX - origin.x)),
        y: Math.max(52, Math.min(window.innerHeight - box.height - 12, start.y + move.clientY - origin.y)),
      });
    };
    handle.onpointerup = handle.onpointercancel = () => {
      handle.onpointermove = null;
    };
  }

  const blocked =
    work.status === 'completed' || work.status === 'cancelled'
      ? `${statusOf(work).label}的 Work 不再接收消息`
      : work.status === 'waiting_user'
        ? '有待回答的问题，请恢复对话后作答'
        : work.status === 'queued' && !work.startRequested && !work.sessionId
          ? '启动后才能继续对话'
          : null;

  async function send() {
    const text = draft.trim();
    if (!text || sending || blocked) return;
    if (!pending.current || pending.current.text !== text) pending.current = { id: newId(), text };
    setSending(true);
    setError(null);
    try {
      await request('work.send', { workId: work.id, messageId: pending.current.id, text });
      pending.current = null;
      clearDraft();
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setSending(false);
    }
  }

  return (
    <section className="floating-work" ref={panel} style={{ left: position.x, top: position.y }} aria-label="悬浮输入框">
      <div className="floating-handle" onPointerDown={drag}>
        <DotsSixVertical size={14} />
        <span>
          {work.displayId} · {work.title}
        </span>
        <small>{statusOf(work).label}</small>
        <IconButton icon={ArrowsOut} label="恢复对话 ⌘J" onClick={onRestore} />
      </div>
      <form
        className="composer"
        onSubmit={(event) => {
          event.preventDefault();
          send();
        }}
      >
        <textarea
          aria-label="发送给 Claude 的消息"
          rows={2}
          value={draft}
          disabled={Boolean(blocked)}
          placeholder={blocked ?? '继续说明…'}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key !== 'Enter' || event.shiftKey || event.nativeEvent.isComposing || event.keyCode === 229) return;
            event.preventDefault();
            send();
          }}
        />
        <div className="composer-tools">
          <div />
          <button className="send" aria-label="发送消息" disabled={!draft.trim() || sending || Boolean(blocked)}>
            {sending ? <CircleNotch size={15} className="spin" /> : <ArrowUp size={16} />}
          </button>
        </div>
      </form>
      {error && (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {error}
        </div>
      )}
    </section>
  );
}
