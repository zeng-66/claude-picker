// 设置 → 桌宠（docs/ui-refactor-v003.md §10）。
import React from 'react';
import { PET_THEMES } from './themes.js';

export const DEFAULT_PET = { enabled: true, size: 128, theme: 'dev-life', idleShows: true, wander: false, x: null, y: null };

export function PetSettings({ settings, onChange }) {
  const pet = { ...DEFAULT_PET, ...settings };
  return (
    <>
      <h3>Clawd 桌宠</h3>
      <p>用动画显示会话与 Work 的状态。单击打开悬浮终端，拖动调整位置，右键查看更多操作。</p>
      <label className="pet-setting-switch">
        <span>显示桌宠</span>
        <input
          type="checkbox"
          role="switch"
          aria-label="显示桌宠"
          checked={pet.enabled}
          onChange={(event) => onChange({ enabled: event.target.checked })}
        />
      </label>
      <label className="field">
        主题
        <select aria-label="桌宠主题" value={pet.theme} onChange={(event) => onChange({ theme: event.target.value })}>
          {Object.values(PET_THEMES).map((theme) => (
            <option key={theme.id} value={theme.id}>
              {theme.label}
            </option>
          ))}
        </select>
      </label>
      <label className="field">
        大小
        <select aria-label="桌宠大小" value={pet.size} onChange={(event) => onChange({ size: Number(event.target.value) })}>
          <option value="96">小</option>
          <option value="128">标准</option>
          <option value="160">大</option>
        </select>
      </label>
      <label className="pet-setting-switch">
        <span>
          空闲小剧场
          <small>空闲时随机表演摸鱼、咖啡、小黄鸭等；下班和深夜也有对应动画。</small>
        </span>
        <input
          type="checkbox"
          role="switch"
          aria-label="空闲小剧场"
          checked={pet.idleShows}
          onChange={(event) => onChange({ idleShows: event.target.checked })}
        />
      </label>
      <label className="pet-setting-switch">
        <span>
          空闲时散步
          <small>每 10 秒朝窗口中间走一小段。</small>
        </span>
        <input
          type="checkbox"
          role="switch"
          aria-label="空闲时散步"
          checked={pet.wander}
          onChange={(event) => onChange({ wander: event.target.checked })}
        />
      </label>
      <h4 className="pet-credit-title">素材署名</h4>
      <ul className="pet-credits">
        {Object.values(PET_THEMES).map((theme) => (
          <li key={theme.id}>
            <strong>{theme.label}</strong>
            <span>
              作者 {theme.credit.author} · {theme.credit.license}
            </span>
            <a href={theme.credit.source} target="_blank" rel="noreferrer">
              {theme.credit.source}
            </a>
            <small>{theme.credit.note}</small>
          </li>
        ))}
      </ul>
    </>
  );
}
