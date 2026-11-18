// 桌宠主题。两套素材共用一个引擎：语义状态 → 动画文件，外加空闲小剧场与一次性反应。
// Clawd Dev Life 直接读取素材包自带的 theme.json（clawd-on-desk 主题格式）；Codex 像素版只有 9 个动作，按同样的语义映射。
// 设计见 docs/ui-refactor-v003.md §9。
import devLife from '../../assets/pet/dev-life/theme.json';
import devLifeDurations from '../../assets/pet/dev-life/durations.json';

const basename = (path) => path.split('/').pop();
const byName = (map) => Object.fromEntries(Object.entries(map).map(([path, url]) => [basename(path), url]));

const devLight = byName(
  import.meta.glob('../../assets/pet/dev-life/light/*.{apng,svg}', { eager: true, query: '?url', import: 'default' }),
);
const devDark = byName(
  import.meta.glob('../../assets/pet/dev-life/dark/*.{apng,svg}', { eager: true, query: '?url', import: 'default' }),
);
const codexFiles = byName(
  import.meta.glob('../../assets/pet/codex/*.gif', { eager: true, query: '?url', import: 'default' }),
);

const pick = (list) => list[Math.floor(Math.random() * list.length)];

/// 一个动画：{ url, file, duration }。duration 为一次完整播放的毫秒数（循环动画为 0）。
function devClip(file, dark, duration) {
  const url = (dark ? devDark[file] : devLight[file]) ?? devLight[file];
  return url ? { url, file, duration: duration ?? devLifeDurations[file] ?? 0 } : null;
}

const DEV_STATE_FILES = {
  idle: ['idle.svg'],
  thinking: devLife.states.thinking.filter((file) => file === 'thinking.apng'),
  plan: ['plan.apng'],
  ultrathink: ['ultrathink.apng'],
  juggling: devLife.states.juggling,
  sweeping: devLife.states.sweeping,
  carrying: devLife.states.carrying,
  notification: devLife.states.notification,
  review: ['lgtm.apng'],
  complete: ['passed_long.apng'],
  error: devLife.states.error,
  sleeping: devLife.states.sleeping,
  yawning: devLife.states.yawning,
  waking: devLife.states.waking,
  roam: devLife.states.roam,
};

const devLifeTheme = {
  id: 'dev-life',
  label: 'Clawd Dev Life',
  aspect: 1, // 288 × 288
  credit: {
    author: devLife.author,
    license: devLife.license,
    source: 'https://github.com/alwinecor/clawd-stickers',
    note: '非官方同人作品，Clawd 角色归 Anthropic 所有。',
  },
  timings: devLife.timings,
  /// 语义状态 → 动画。working 按同时运行的数量分档。
  clip(state, { dark, running = 1 } = {}) {
    if (state === 'working') {
      const tier = devLife.workingTiers.find((item) => running >= item.minSessions) ?? devLife.workingTiers.at(-1);
      return devClip(pick(tier.files ?? [tier.file]), dark, 0);
    }
    const files = DEV_STATE_FILES[state] ?? DEV_STATE_FILES.idle;
    return devClip(pick(files), dark, 0);
  },
  /// 一次性反应：播完回到当前状态。
  reaction(name, { dark } = {}) {
    const reactions = devLife.reactions;
    switch (name) {
      case 'click':
        return devClip(reactions.clickLeft.file, dark, reactions.clickLeft.duration);
      case 'right':
        return devClip(reactions.clickRight.file, dark, reactions.clickRight.duration);
      case 'double':
        return devClip(pick(reactions.double.files), dark, reactions.double.duration);
      case 'annoyed':
        return devClip(reactions.annoyed.file, dark, reactions.annoyed.duration);
      case 'drag':
        return devClip(reactions.drag.file, dark, 0);
      case 'jump':
        return devClip('passed_long.apng', dark);
      case 'hello':
        return devClip('hello.apng', dark);
      case 'bye':
        return devClip('bye_long.apng', dark);
      default:
        // 事件反应直接用同名动画：conflict / forcepush / stash / cherry / detached_long / limit / esc / lgtm / deadline …
        return devClip(`${name}.apng`, dark);
    }
  },
  idleShow(dark) {
    const item = pick(devLife.idleAnimations);
    return devClip(item.file, dark, item.duration);
  },
  /// 作息：下班 / 深夜加班。
  routine(name, dark) {
    return devClip(name === 'offwork' ? 'offwork.apng' : 'overtime.apng', dark);
  },
  walk(direction, dark) {
    return devClip('roam.svg', dark, 0);
  },
};

const codexClip = (name, duration = 0) => ({ url: codexFiles[`clawd-${name}.gif`], file: `clawd-${name}.gif`, duration });
const CODEX_STATES = {
  idle: 'idle',
  thinking: 'running',
  plan: 'running',
  ultrathink: 'running',
  working: 'running',
  juggling: 'running',
  sweeping: 'running',
  carrying: 'running',
  notification: 'waiting',
  review: 'review',
  complete: 'jumping',
  error: 'failed',
  sleeping: 'idle',
  yawning: 'idle',
  waking: 'idle',
  roam: 'running-right',
};

const codexTheme = {
  id: 'codex',
  label: 'Codex 像素版',
  aspect: 192 / 208,
  credit: {
    author: 'Han1',
    license: '社区桌宠包（从官方 Claude Code Clawd 帧提取）',
    source: 'https://codex-pets.net/#/pets/clawd',
    note: 'Clawd 美术归 Anthropic 所有。',
  },
  timings: { minDisplay: {}, autoReturn: { complete: 10000 }, mouseIdleTimeout: 20000, mouseSleepTimeout: 0 },
  clip(state) {
    return codexClip(CODEX_STATES[state] ?? 'idle');
  },
  reaction(name) {
    if (name === 'drag') return codexClip('running-right');
    if (name === 'click' || name === 'hello' || name === 'bye' || name === 'right') return codexClip('waving', 1400);
    return codexClip('jumping', 1000);
  },
  idleShow() {
    return null;
  },
  routine() {
    return null;
  },
  walk(direction) {
    return codexClip(direction < 0 ? 'running-left' : 'running-right');
  },
};

export const PET_THEMES = { 'dev-life': devLifeTheme, codex: codexTheme };
export const themeOf = (id) => PET_THEMES[id] ?? devLifeTheme;
