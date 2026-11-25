// 各 CLI 引擎的官方图标：项目树、引擎切换、新建会话与 Work 卡片共用。
import React from 'react';
import claudeIcon from './engine-icons/claude.ico';
import codexIcon from './engine-icons/codex.png';
import antigravityIcon from './engine-icons/antigravity.ico';
import deepseekIcon from './engine-icons/deepseek.png';

export const engineIcons = { claude: claudeIcon, codex: codexIcon, antigravity: antigravityIcon, dsh: deepseekIcon };
export const engineNames = { claude: 'Claude Code', codex: 'Codex', antigravity: 'Antigravity', dsh: 'DeepSeek' };

export default function EngineIcon({ id, size = 14, className = '' }) {
  const key = engineIcons[id] ? id : 'claude';
  return (
    <img className={`engine-icon ${className}`.trim()} src={engineIcons[key]} alt={engineNames[key]}
      width={size} height={size} draggable={false} />
  );
}
