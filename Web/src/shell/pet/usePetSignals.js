// 桌宠状态汇总（docs/ui-refactor-v003.md §9.3、§9.5）：会话 + Work → 一个语义状态，外加一次性事件。
import { useEffect, useRef, useState } from 'react';

const COMPLETE_MS = 10000;

/// 其它模块发出的一次性事件（TAPD 流转成功、Git 冲突……）：petEvent('lgtm')。
export function petEvent(name) {
  window.dispatchEvent(new CustomEvent('claude-picker:pet', { detail: name }));
}

function runningSessions(state) {
  let count = 0;
  for (const project of state?.projects ?? []) for (const session of project.sessions ?? []) if (session.running) count++;
  return count;
}

export function usePetSignals(state, workSnap, settings) {
  const [completeUntil, setCompleteUntil] = useState(0);
  const [events, setEvents] = useState([]);
  const previous = useRef(null);
  const works = (workSnap?.works ?? []).filter((work) => !work.archived);
  const active = state?.active ?? null;
  const sessions = runningSessions(state);
  const runningWorks = works.filter((work) => work.status === 'running').length;
  const running = sessions + runningWorks + (active?.busy && !sessions ? 1 : 0);

  function push(name) {
    setEvents((current) => [...current.slice(-4), { id: `${Date.now()}-${Math.random()}`, name }]);
  }

  // 完成：会话从忙变闲、Work 进入 completed、执行中的 Work 被中断。
  useEffect(() => {
    const snapshot = {
      busy: running,
      statuses: Object.fromEntries((workSnap?.works ?? []).map((work) => [work.id, work.status])),
      limit: (state?.usage?.session?.percent ?? 0) >= 100,
    };
    const before = previous.current;
    previous.current = snapshot;
    if (!before) return;
    let completed = before.busy > snapshot.busy;
    for (const [id, status] of Object.entries(snapshot.statuses)) {
      const was = before.statuses[id];
      if (!was || was === status) continue;
      if (status === 'completed') completed = true;
      if (status === 'interrupted') push('esc');
    }
    if (completed) setCompleteUntil(Date.now() + COMPLETE_MS);
    if (snapshot.limit && !before.limit) push('limit');
  }, [running, workSnap, state?.usage?.session?.percent]);

  useEffect(() => {
    if (!completeUntil) return undefined;
    const timer = window.setTimeout(() => setCompleteUntil(0), Math.max(0, completeUntil - Date.now()));
    return () => window.clearTimeout(timer);
  }, [completeUntil]);

  useEffect(() => {
    push('hello');
    const listener = (event) => push(event.detail);
    window.addEventListener('claude-picker:pet', listener);
    return () => window.removeEventListener('claude-picker:pet', listener);
  }, []);

  let current = 'idle';
  if (works.some((work) => work.status === 'waiting_user')) current = 'notification';
  else if (works.some((work) => (work.status === 'failed' || work.status === 'interrupted') && work.unread)) current = 'error';
  else if (works.some((work) => work.status === 'waiting_review')) current = 'review';
  else if (completeUntil && running === 0) current = 'complete';
  else if (running > 0) {
    const mode = state?.runtime?.mode;
    const effort = state?.runtime?.effort;
    if (active?.busy && mode === 'plan') current = 'plan';
    else if (active?.busy && effort === 'max') current = 'ultrathink';
    else current = 'working';
  }

  return { state: current, running, events };
}
