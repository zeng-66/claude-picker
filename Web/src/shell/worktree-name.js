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

