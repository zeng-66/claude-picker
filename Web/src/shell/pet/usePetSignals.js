// 桌宠状态汇总（docs/ui-refactor-v003.md §9.3、§9.5）：会话 + Work → 一个语义状态、一条提示，外加一次性事件。
import { useEffect, useRef, useState } from 'react';

const COMPLETE_MS = 10000;

/// 其它模块发出的一次性事件（TAPD 流转成功、Git 冲突……）：petEvent('lgtm')。
export function petEvent(name) {
  window.dispatchEvent(new CustomEvent('claude-picker:pet', { detail: { name } }));
}

function runningSessions(state) {
  const list = [];
  for (const project of state?.projects ?? [])
    for (const session of project.sessions ?? []) if (session.running) list.push({ id: session.id, title: session.title });
  return list;
}

const workLabel = (work) => `${work.displayId} ${work.title}`;

export function usePetSignals(state, workSnap) {
  const [completed, setCompleted] = useState(null); // { text, detail, target, until }
  const [events, setEvents] = useState([]);
  const previous = useRef(null);
  const works = (workSnap?.works ?? []).filter((work) => !work.archived);
  const active = state?.active ?? null;
  const sessions = runningSessions(state);
  const runningWorks = works.filter((work) => work.status === 'running');
  const running = sessions.length + runningWorks.length + (active?.busy && !sessions.length ? 1 : 0);

  function push(name) {
    setEvents((current) => [...current.slice(-4), { id: `${Date.now()}-${Math.random()}`, name }]);
  }

  // 完成：会话从忙变闲、Work 进入 completed；执行中的 Work 被中断时挥一下 Esc。
  useEffect(() => {
    const snapshot = {
      sessions: Object.fromEntries(sessions.map((item) => [item.id, item.title])),
      works: Object.fromEntries((workSnap?.works ?? []).map((work) => [work.id, work])),
      limit: (state?.usage?.session?.percent ?? 0) >= 100,
    };
    const before = previous.current;
    previous.current = snapshot;
    if (!before) return;
    let done = null;
    for (const [id, title] of Object.entries(before.sessions)) {
      if (!(id in snapshot.sessions)) done = { text: `「${title}」这一轮已完成`, detail: '点击查看会话', target: null };
    }
    for (const [id, work] of Object.entries(snapshot.works)) {
      const was = before.works[id]?.status;
      if (!was || was === work.status) continue;
      if (work.status === 'completed')
        done = { text: `${work.displayId} 已完成`, detail: work.title, target: { displayId: work.displayId } };
      if (work.status === 'interrupted') push('esc');
    }
    if (done) setCompleted({ ...done, until: Date.now() + COMPLETE_MS, key: `done-${Date.now()}` });
    if (snapshot.limit && !before.limit) push('limit');
  }, [sessions.map((item) => item.id).join(','), workSnap, state?.usage?.session?.percent]);

  useEffect(() => {
    if (!completed) return undefined;
    const timer = window.setTimeout(() => setCompleted(null), Math.max(0, completed.until - Date.now()));
    return () => window.clearTimeout(timer);
  }, [completed]);

  useEffect(() => {
    push('hello');
    const listener = (event) => {
      const name = typeof event.detail === 'string' ? event.detail : event.detail?.name;
      if (name) push(name);
    };
    window.addEventListener('claude-picker:pet', listener);
    return () => window.removeEventListener('claude-picker:pet', listener);
  }, []);

  // 状态与提示：需要用户处理的排前面，提示一直显示到用户关掉；进行中的只在变化时显示一会儿。
  const waiting = works.find((work) => work.status === 'waiting_user');
  const failed = works.find((work) => (work.status === 'failed' || work.status === 'interrupted') && work.unread);
  const review = works.find((work) => work.status === 'waiting_review');
  let current = 'idle';
  let tip = null;
  if (waiting) {
    current = 'notification';
    tip = { text: `${waiting.displayId} 需要你的回答`, detail: waiting.statusReason || waiting.title, target: { displayId: waiting.displayId }, persistent: true };
  } else if (failed) {
    current = 'error';
    tip = {
      text: `${failed.displayId} ${failed.status === 'failed' ? '执行失败' : '已中断'}`,
      detail: failed.statusReason || failed.title,
      target: { displayId: failed.displayId },
      persistent: true,
    };
  } else if (review) {
    current = 'review';
    tip = { text: `${review.displayId} 有结果待审阅`, detail: review.title, target: { displayId: review.displayId }, persistent: true };
  } else if (completed && running === 0) {
    current = 'complete';
    tip = { ...completed, persistent: false };
  } else if (running > 0) {
    const mode = state?.runtime?.mode;
    const effort = state?.runtime?.effort;
    const labels = [...sessions.map((item) => item.title), ...runningWorks.map(workLabel)];
    const label = active?.busy ? active.label : labels[0];
    if (active?.busy && mode === 'plan') {
      current = 'plan';
      tip = { text: `正在规划：${label ?? '当前会话'}`, persistent: false };
    } else if (active?.busy && effort === 'max') {
      current = 'ultrathink';
      tip = { text: `深度思考中：${label ?? '当前会话'}`, persistent: false };
    } else {
      current = 'working';
      tip = {
        text: running > 1 ? `正在执行 ${running} 个任务` : `正在执行：${label ?? '当前会话'}`,
        detail: running > 1 ? labels.slice(0, 3).join('、') : runningWorks[0]?.statusReason ?? null,
        target: runningWorks.length === 1 && running === 1 ? { displayId: runningWorks[0].displayId } : null,
        persistent: false,
      };
    }
  }
  if (tip) tip.key = tip.key ?? `${current}:${tip.text}`;

  return { state: current, running, events, tip };
}
