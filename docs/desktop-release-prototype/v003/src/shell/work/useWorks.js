// Work 领域状态在原生侧（SQLite）。这里只做三件事：取快照、订阅变化、按 Work 维护事件流。
// 页面重新挂载不会制造任何领域事件；事件按每个 Work 自己的连续序号衔接，发现缺口就重新拉取。
import { useCallback, useEffect, useRef, useState } from 'react';
import { on, request } from '../bridge.js';

export const STATUS = {
  queued: { label: '排队中', tone: 'neutral' },
  running: { label: '执行中', tone: 'blue' },
  waiting_user: { label: '待回答', tone: 'orange' },
  waiting_review: { label: '待审阅', tone: 'purple' },
  failed: { label: '失败', tone: 'red' },
  interrupted: { label: '已中断', tone: 'amber' },
  completed: { label: '已完成', tone: 'green' },
  cancelled: { label: '已取消', tone: 'neutral' },
};

export const ACTIVE_STATUSES = ['queued', 'running', 'waiting_user', 'waiting_review'];

export function statusOf(work) {
  if (work?.cancelling) return { label: '正在取消', tone: 'neutral' };
  if (work?.status === 'queued' && !work.startRequested) return { label: '待启动', tone: 'neutral' };
  return STATUS[work?.status] ?? { label: work?.status ?? '—', tone: 'neutral' };
}

/// 需要用户处理：待回答、待审阅，以及还没看过的失败 / 中断。
export function needsAttention(work) {
  if (work.archived) return false;
  return (
    work.status === 'waiting_user' ||
    work.status === 'waiting_review' ||
    ((work.status === 'failed' || work.status === 'interrupted') && work.unread)
  );
}

export function sourceLabel(work) {
  const ref = work.tapdRefs?.[0];
  if (ref) return `TAPD #${shortId(ref.entityId)}`;
  if (work.origin === 'wecom') return '企业微信';
  return '本地';
}

/// TAPD 的完整 ID 很长，界面上显示末 7 位的短号；关联与写入始终用完整 ID。
export function shortId(id = '') {
  const text = String(id);
  return text.length > 7 ? String(Number(text.slice(-7))) : text;
}

export function newId() {
  return crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

const EMPTY = {
  available: true,
  owner: true,
  works: [],
  projects: [],
  capacity: { slots: 2, running: 0, queued: 0, waitingStart: 0 },
  workSessionIds: [],
};

export function useWorks() {
  const [snapshot, setSnapshot] = useState(null);
  const loading = useRef(false);
  const again = useRef(false);

  const reload = useCallback(() => {
    if (loading.current) {
      again.current = true;
      return;
    }
    loading.current = true;
    request('work.snapshot')
      .then((next) => setSnapshot(next ?? EMPTY))
      .catch((error) => setSnapshot({ ...EMPTY, available: false, error: error.message }))
      .finally(() => {
        loading.current = false;
        if (again.current) {
          again.current = false;
          reload();
        }
      });
  }, []);

  useEffect(() => {
    reload();
    return on('work', (detail) => {
      if (detail.type === 'changed') reload();
    });
  }, [reload]);

  return { snapshot: snapshot ?? EMPTY, loaded: snapshot !== null, reload };
}

/// 一个 Work 的事件流、Attention、Run、活动与证据。切换 Work 时各自保留，不会串到别的 Work 上。
export function useTranscript(workId, revision) {
  const [data, setData] = useState(null);
  const [live, setLive] = useState('');
  const [error, setError] = useState(null);
  const target = useRef(workId);
  const lastSeq = useRef(0);
  const loading = useRef(false);
  const pending = useRef(false);
  target.current = workId;

  const load = useCallback(() => {
    const id = target.current;
    if (!id) return;
    if (loading.current) {
      pending.current = true;
      return;
    }
    loading.current = true;
    request('work.transcript', { workId: id, after: 0 })
      .then((result) => {
        if (target.current !== id) return; // 已经切到别的 Work：迟到的结果不覆盖当前页面
        lastSeq.current = result.lastSeq ?? 0;
        setData(result);
        setError(null);
      })
      .catch((cause) => {
        if (target.current === id) setError(cause.message);
      })
      .finally(() => {
        loading.current = false;
        if (pending.current) {
          pending.current = false;
          load();
        }
      });
  }, []);

  useEffect(() => {
    setData(null);
    setLive('');
    setError(null);
    lastSeq.current = 0;
    load();
  }, [workId, load]);

  // Work 的状态版本变了（状态、Attention、证据）：重取一次，保持 Attention / 证据是最新的。
  useEffect(() => {
    if (workId && revision !== undefined) load();
  }, [revision, workId, load]);

  useEffect(() => {
    if (!workId) return undefined;
    return on('work', (detail) => {
      if (detail.type === 'delta' && detail.workId === workId) {
        setLive((text) => text + detail.text);
        return;
      }
      if (detail.type !== 'event' || detail.event?.workId !== workId) return;
      const event = detail.event;
      if (event.seq <= lastSeq.current) return; // 重复事件
      if (event.seq !== lastSeq.current + 1) {
        load(); // 序号有缺口：重新拉取快照
        return;
      }
      lastSeq.current = event.seq;
      if (event.kind === 'assistant' || event.kind === 'turn_result' || event.kind === 'tool_use') setLive('');
      setData((current) => (current ? { ...current, events: [...current.events, event] } : current));
      if (event.kind === 'attention' || event.kind === 'attention_resolved') load();
    });
  }, [workId, load]);

  return { data, live, error, reload: load };
}

/// 按所属上下文保存的草稿（会话输入、提交信息、交付正文）：落在原生数据库里，切换与重启都不丢。
export function useDraft(scope, key) {
  const [value, setValue] = useState('');
  const [loaded, setLoaded] = useState(false);
  const current = useRef(`${scope}:${key}`);
  const timer = useRef(0);
  current.current = `${scope}:${key}`;

  useEffect(() => {
    const tag = `${scope}:${key}`;
    setLoaded(false);
    setValue('');
    if (!key) return undefined;
    request('draft.get', { scope, key })
      .then((result) => {
        if (current.current !== tag) return;
        setValue(result?.value ?? '');
        setLoaded(true);
      })
      .catch(() => setLoaded(true));
    return () => window.clearTimeout(timer.current);
  }, [scope, key]);

  const update = useCallback(
    (next) => {
      setValue(next);
      if (!key) return;
      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => {
        request('draft.set', { scope, key, value: next }).catch(() => {});
      }, 350);
    },
    [scope, key],
  );

  const clear = useCallback(() => {
    window.clearTimeout(timer.current);
    setValue('');
    if (key) request('draft.set', { scope, key, value: '' }).catch(() => {});
  }, [scope, key]);

  return [value, update, clear, loaded];
}

export function formatTime(iso) {
  const date = new Date(iso);
  if (!iso || Number.isNaN(date.getTime())) return '';
  const pad = (n) => String(n).padStart(2, '0');
  const today = new Date();
  const sameDay = date.toDateString() === today.toDateString();
  const time = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  return sameDay ? time : `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${time}`;
}
