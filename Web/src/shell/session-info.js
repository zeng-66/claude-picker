const resumeCommands = {
  claude: 'claude --resume',
  codex: 'codex resume',
  antigravity: 'agy --conversation',
  dsh: 'dsh-tui --backend dsh --resume',
};

export function resumeCommand(provider, id) {
  const command = resumeCommands[provider];
  if (!command || !id || id.startsWith('-')) return null;
  const safeId = /^[\w.-]+$/.test(id) ? id : "'" + id.replaceAll("'", "'\"'\"'") + "'";
  return `${command} ${safeId}`;
}
