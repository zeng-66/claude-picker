import { pinyin } from 'pinyin-pro';

const TAPD_BRANCH = /^v\d+(?:\.\d+)+\/[^/]+-(\d{5,})-[^/]+-\d{8}$/;

export function worktreeTitleSlug(title) {
  return pinyin(title, { toneType: 'none', nonZh: 'consecutive' })
    .normalize('NFKD')
    .replace(/\p{Mark}/gu, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
}

export function untitledWorktreeBranch(branches) {
  const names = new Set(branches.map(({ name }) => name));
  const stem = 'session/worktree';
  let candidate = stem;
  for (let suffix = 2; names.has(candidate); suffix += 1) candidate = `${stem}-${suffix}`;
  return candidate;
}

export function nameFromFirstSession(title, branch) {
  const task = /\btapd[^\d]{0,12}(\d{5,})/i.exec(title);
  const rawId = task?.[1] ?? '';
  const id = /^11\d{17}$/.test(rawId) ? String(Number(rawId.slice(-9))) : rawId;
  const canonical = TAPD_BRANCH.exec(branch ?? '');
  if (canonical && (!id || canonical[1] === id))
    return branch.replace(/\p{Script=Han}+/gu, worktreeTitleSlug);
  if (!task) return worktreeTitleSlug(title);
  const subject = worktreeTitleSlug(title.replace(task[0], ''));
  return [`tapd-${id}`, subject].filter(Boolean).join('-');
}

// ---------- 统一工作树命令（ai-worktree）的入参 ----------

// 与 ai-worktree `component()` 同一规则：字母数字开头，最多 100 个字母、数字、点、横线或下划线，不以点结尾。
const WORKTREE_COMPONENT = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const TAPD_IN_TITLE = /\btapd[^\d]{0,12}(\d{5,})/i;

export function validWorktreeComponent(value) {
  return WORKTREE_COMPONENT.test(value) && !value.endsWith('.');
}

// 标题里的 TAPD 编号作为任务标识，取完整 ID，不截短。
export function tapdTaskId(text) {
  return TAPD_IN_TITLE.exec(text ?? '')?.[1] ?? '';
}

// `--name`：标题去掉 TAPD 编号后转 ASCII，并截到与任务标识、子任务拼接后不超过 100 个字符。
export function unifiedWorktreeName(title, task, subtask) {
  const slug = worktreeTitleSlug(String(title ?? '').replace(TAPD_IN_TITLE, ' '));
  const room = 100 - task.length - 1 - (subtask ? subtask.length + 1 : 0);
  return room > 0 ? slug.slice(0, room).replace(/[-.]+$/, '') : '';
}
