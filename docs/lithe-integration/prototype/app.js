const $ = (id) => document.getElementById(id);
const storageKey = 'lithe-claude-review-v1';
const initial = {
  active: 's1',
  projects: [
    { id: 'p1', name: 'lm-global-java', path: '~/project/lm-global-java', expanded: true },
    { id: 'p2', name: 'claude-picker', path: '~/project/claude-picker', expanded: true },
    { id: 'p3', name: 'lanma-bankend', path: '~/project/lanma-bankend', expanded: false }
  ],
  sessions: [
    { id: 's1', project: 'p1', title: '订单解码链路梳理', summary: '梳理异步回调与订单状态流转', time: '刚刚', status: 'idle', pinned: true, opened: true },
    { id: 's2', project: 'p1', title: '物流渠道优先级调整', summary: '检查渠道匹配规则与测试用例', time: '12 分钟前', status: 'running', opened: true },
    { id: 's3', project: 'p1', title: '设计模板下线校验', summary: '关联商品状态与解绑流程', time: '昨天', status: 'stopped' },
    { id: 's4', project: 'p2', title: 'Lithe 功能集成方案', summary: '会话管理与终端能力迁移', time: '35 分钟前', status: 'idle', opened: true, unread: true },
    { id: 's5', project: 'p2', title: '优化会话标题读取', summary: 'JSONL 增量扫描与尾部总结', time: '昨天', status: 'stopped' },
    { id: 's6', project: 'p3', title: '排查订单推送日志', summary: '定位任务触发与失败重试', time: '前天', status: 'stopped' }
  ],
  defaults: { model: 'Sonnet', mode: '默认权限', effort: 'Medium', fast: false },
  fontSize: 14,
  usage: 32,
  imported: false
};
let state;
try { state = JSON.parse(localStorage.getItem(storageKey)) || structuredClone(initial); }
catch { state = structuredClone(initial); }
let toastTimer;
let lastFocus;
let dragItem;
const timers = new Map();
const statusNames = { running: '运行中', idle: '空闲', stopped: '未启动', exited: '已退出', failed: '启动失败' };
const escapeHTML = (value) => String(value).replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]));
const activeSession = () => state.sessions.find((session) => session.id === state.active);
function persist() {
  try { localStorage.setItem(storageKey, JSON.stringify(state)); }
  catch { toast('浏览器存储不可用，本次操作保留在当前页面'); }
}
function toast(message) {
  $('toast').textContent = message;
  $('toast').hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { $('toast').hidden = true; }, 3300);
}
function dialog(title, content, setup) {
  lastFocus = document.activeElement;
  $('dialogTitle').textContent = title;
  $('dialogBody').innerHTML = content;
  $('overlay').hidden = false;
  if (setup) setup();
  $('dismiss').focus();
}
function closeDialog() {
  $('overlay').hidden = true;
  if (lastFocus?.isConnected) lastFocus.focus();
}
$('dismiss').onclick = closeDialog;
$('overlay').onclick = (event) => { if (event.target === $('overlay')) closeDialog(); };
function render() {
  document.documentElement.style.setProperty('--term-size', `${state.fontSize}px`);
  const query = $('search').value.toLowerCase().trim();
  const tree = $('tree');
  tree.innerHTML = '';
  for (const project of state.projects.filter((item) => !item.hidden)) {
    const sessions = state.sessions.filter((item) => item.project === project.id && !item.hidden && (!query || `${project.name} ${item.title} ${item.summary}`.toLowerCase().includes(query)));
    if (query && !sessions.length && !project.name.toLowerCase().includes(query)) continue;
    const group = document.createElement('section');
    const heading = document.createElement('div');
    heading.className = 'project-heading';
    heading.draggable = true;
    heading.innerHTML = `<button class="project-label">${project.expanded || query ? '⌄' : '›'} &nbsp;${project.pinned ? '◆ ' : '▱ '}${escapeHTML(project.name)}</button><small>${sessions.length}</small><div class="project-actions"><button title="置顶项目">↑</button><button title="隐藏项目">−</button></div>`;
    heading.querySelector('.project-label').onclick = () => { project.expanded = !project.expanded; persist(); render(); };
    const projectActions = heading.querySelectorAll('.project-actions button');
    projectActions[0].onclick = () => { project.pinned = true; state.projects = [project, ...state.projects.filter((item) => item.id !== project.id)]; persist(); render(); toast('项目已置顶'); };
    projectActions[1].onclick = () => { project.hidden = true; persist(); render(); toast('项目已隐藏，可在管理隐藏项中恢复'); };
    attachDrag(heading, 'project', project.id);
    group.append(heading);
    if (project.expanded || query) {
      for (const session of sessions) {
        const row = document.createElement('div');
        row.className = `session-row ${session.id === state.active ? 'selected' : ''}`;
        row.tabIndex = 0;
        row.setAttribute('role', 'button');
        row.setAttribute('aria-label', `打开会话 ${session.title}`);
        row.draggable = true;
        const icon = session.status === 'running' ? '<span class="busy">◌</span>' : session.unread ? '<span class="unread">●</span>' : '✳';
        row.innerHTML = `<span class="session-icon">${icon}</span><div class="session-copy"><div class="session-name">${session.pinned ? '⌁ ' : ''}${escapeHTML(session.title)}</div><div class="session-meta">${escapeHTML(session.time)} · ${statusNames[session.status]}${session.unread ? ' · 新消息' : ''}</div></div><div class="session-tools"><button title="置顶会话">↑</button><button title="隐藏会话">−</button></div>`;
        row.onclick = () => openSession(session.id);
        row.onkeydown = (event) => { if (event.key === 'Enter') openSession(session.id); };
        const actions = row.querySelectorAll('button');
        actions[0].onclick = (event) => { event.stopPropagation(); session.pinned = true; state.sessions = [session, ...state.sessions.filter((item) => item.id !== session.id)]; persist(); render(); toast('会话已置顶'); };
        actions[1].onclick = (event) => { event.stopPropagation(); session.hidden = true; persist(); render(); toast('已隐藏，后台进程继续运行'); };
        attachDrag(row, 'session', session.id);
        group.append(row);
      }
      if (!sessions.length) group.insertAdjacentHTML('beforeend', '<div class="empty">暂无会话，点击新建开始。</div>');
    }
    tree.append(group);
  }
  if (!tree.children.length) tree.innerHTML = '<div class="empty">没有匹配结果。<br>尝试其他关键词或添加项目。</div>';
  const session = activeSession();
  const project = state.projects.find((item) => item.id === session.project);
  $('workspace').textContent = project.name;
  $('projectPath').textContent = project.path;
  $('sessionTitle').textContent = session.title;
  $('tabTitle').textContent = session.title;
  $('sessionSummary').textContent = session.summary;
  $('runtimeStatus').textContent = statusNames[session.status];
  $('sessionCount').textContent = `${state.projects.filter((item) => !item.hidden).length} 个项目 · ${state.sessions.filter((item) => !item.hidden).length} 个会话`;
  const options = session.options || state.defaults;
  $('modeLabel').textContent = options.mode;
  $('modelLabel').textContent = options.model;
  $('effortLabel').textContent = options.effort;
  $('fastLabel').textContent = options.fast ? '开启' : '关闭';
  $('appliedState').textContent = session.opened ? '当前会话已应用 · 模拟' : '下次启动时应用';
  $('quotaLabel').textContent = `${state.usage}%`;
  $('prompt').disabled = !session.opened;
  $('closeButton').disabled = !session.opened;
  renderOutput();
  $('runningTabs').innerHTML = '';
  for (const item of state.sessions.filter((item) => item.opened)) {
    const button = document.createElement('button');
    button.className = item.id === state.active ? 'current' : '';
    button.textContent = `${item.status === 'running' ? '◌' : item.unread ? '●' : '✳'} ${item.title}`;
    button.onclick = () => openSession(item.id);
    $('runningTabs').append(button);
  }
}
function attachDrag(element, type, id) {
  element.ondragstart = (event) => { dragItem = { type, id }; event.dataTransfer.setData('text/plain', id); };
  element.ondragover = (event) => event.preventDefault();
  element.ondrop = (event) => {
    event.preventDefault();
    if (!dragItem || dragItem.type !== type || dragItem.id === id) return;
    const key = type === 'project' ? 'projects' : 'sessions';
    const source = state[key].find((item) => item.id === dragItem.id);
    const target = state[key].find((item) => item.id === id);
    if (type === 'session' && source.project !== target.project) return toast('会话排序限定在原项目内');
    const items = state[key].filter((item) => item.id !== source.id);
    items.splice(items.indexOf(target), 0, source);
    state[key] = items;
    persist(); render(); toast('排序已保存');
  };
}
function renderOutput() {
  const session = activeSession();
  if (!session.messages) session.messages = [
    { kind: 'assistant', text: '✳ Claude Code' },
    { kind: 'muted', text: `${session.options?.model || state.defaults.model} · ${state.projects.find((item) => item.id === session.project).path}\n会话 ${session.id} · 本地审核原型` },
    { kind: 'user', text: `❯ ${session.summary}` },
    { kind: 'text', text: '已定位相关模块，并整理了当前处理进度。\n\n  ✓ 阅读入口与服务调用关系\n  ✓ 核对关键状态与异常分支\n  ✓ 整理需要进一步验证的场景' },
    { kind: 'success', text: session.status === 'running' ? '◌ 正在检查相关实现…' : '● 已完成分析，等待你的下一条指令。' }
  ];
  $('output').innerHTML = session.messages.map((message) => `<p class="${escapeHTML(message.kind)}">${escapeHTML(message.text)}</p>`).join('');
  if (!session.opened) $('output').insertAdjacentHTML('beforeend', '<p class="muted">会话已停止。重新选择此会话可模拟恢复。</p>');
  $('output').scrollTop = $('output').scrollHeight;
}
function openSession(id) {
  const session = state.sessions.find((item) => item.id === id);
  if (!session.opened && state.sessions.filter((item) => item.opened).length >= 8) return terminalManager();
  const previousProject = activeSession().project;
  session.opened = true;
  if (['stopped', 'exited', 'failed'].includes(session.status)) session.status = 'idle';
  session.options ||= structuredClone(state.defaults);
  state.active = id;
  session.unread = false;
  persist(); render(); showEditor(false);
  document.querySelector('.sidebar').classList.remove('mobile-open');
  if (previousProject !== session.project) toast('模拟路由到目标工作区，原工作区会话继续运行');
}
function showEditor(show) {
  $('terminalView').hidden = show;
  $('editorView').hidden = !show;
  $('editorButton').classList.toggle('active', show);
  $('terminalButton').classList.toggle('active', !show);
}
function settings() {
  const options = activeSession().options || state.defaults;
  const select = (id, label, values, current, note) => `<div class="field"><label for="${id}">${label}</label><select id="${id}">${values.map((value) => `<option ${value === current ? 'selected' : ''}>${value}</option>`).join('')}</select><small>${note}</small></div>`;
  dialog('Claude 配置', `<div class="notice">默认配置供新会话使用。应用到当前会话会模拟发送运行时命令，原型中的结果均为演示。</div>${select('configModel', '模型', ['Sonnet', 'Opus', 'Haiku'], options.model, '正式版根据已安装 Claude CLI 的能力提供可选值。')}${select('configMode', '权限模式', ['默认权限', '接受编辑', '计划模式', '跳过权限确认'], options.mode, '权限模式影响 CLI 对操作的确认行为。')}${select('configEffort', '推理强度', ['Low', 'Medium', 'High'], options.effort, '实际可选强度取决于 CLI 与模型。')}<div class="field"><label><input type="checkbox" id="configFast" ${options.fast ? 'checked' : ''}> 开启 Fast 模式</label><small>正式版通过 CLI 支持的命令切换，并显示真实生效状态。</small></div><div class="dialog-actions"><button id="saveDefaults">保存为默认配置</button><button id="applyCurrent" class="primary">应用到当前会话</button></div>`, () => {
    const values = () => ({ model: $('configModel').value, mode: $('configMode').value, effort: $('configEffort').value, fast: $('configFast').checked });
    $('saveDefaults').onclick = () => { state.defaults = values(); persist(); render(); closeDialog(); toast('默认配置已保存，供后续新会话使用'); };
    $('applyCurrent').onclick = () => { activeSession().options = values(); persist(); render(); closeDialog(); toast('已模拟应用到当前会话'); };
  });
}
function quota(error = false) {
  dialog('使用额度', `<p>Claude 订阅额度 · 演示账号<br>最近更新 ${new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}</p>${error ? '<div class="notice">模拟网络请求失败，以下保留上次数据。你可以重新刷新。</div>' : ''}<div class="metric"><div class="metric-head"><span>5 小时窗口</span><b>${state.usage}%</b></div><div class="progress"><i style="width:${state.usage}%"></i></div><small>演示重置时间 · 2 小时 18 分钟后</small></div><div class="metric"><div class="metric-head"><span>7 天窗口</span><b>18%</b></div><div class="progress"><i style="width:18%"></i></div><small>演示重置时间 · 周五 16:00</small></div><div class="dialog-actions"><button id="quotaFail">模拟请求失败</button><button id="quotaRefresh" class="primary">刷新额度</button></div>`, () => {
    $('quotaFail').onclick = () => quota(true);
    $('quotaRefresh').onclick = () => { state.usage = Math.min(95, state.usage + 1); persist(); render(); quota(); toast('模拟额度已刷新'); };
  });
}
function terminalManager() {
  dialog('终端管理', `<p>正式宿主每插件最多保留 8 个终端句柄。结束并释放后可以启动其他会话。</p>${state.sessions.filter((item) => item.opened).map((item) => `<div class="list-item"><span>${escapeHTML(item.title)}<small>${statusNames[item.status]}</small></span><button data-stop="${item.id}">结束并释放</button></div>`).join('')}`, () => {
    document.querySelectorAll('[data-stop]').forEach((button) => { button.onclick = () => { stopSession(button.dataset.stop); terminalManager(); }; });
  });
}
function stopSession(id) {
  const session = state.sessions.find((item) => item.id === id);
  clearTimeout(timers.get(id)); timers.delete(id);
  session.opened = false; session.status = 'exited';
  persist(); render();
}
$('newSession').onclick = () => {
  dialog('新建 Claude 会话', `<p>会话将在当前项目启动。正式版首次启动沿用宿主的进程授权流程。</p><div class="field"><label for="newTitle">会话名称</label><input id="newTitle" placeholder="例如，检查订单状态流转" maxlength="80"></div><div class="notice">${escapeHTML(state.projects.find((item) => item.id === activeSession().project).path)}<br>使用默认配置 ${escapeHTML(state.defaults.model)} · ${escapeHTML(state.defaults.mode)}</div><div class="dialog-actions"><button id="createSession" class="primary">创建并启动</button></div>`, () => {
    $('createSession').onclick = () => {
      if (state.sessions.filter((item) => item.opened).length >= 8) return terminalManager();
      const session = { id: crypto.randomUUID(), project: activeSession().project, title: $('newTitle').value.trim() || '新建会话', summary: '新的 Claude Code 会话', time: '刚刚', status: 'idle', opened: true, options: structuredClone(state.defaults) };
      state.sessions.unshift(session);
      state.projects.find((item) => item.id === session.project).expanded = true;
      closeDialog(); openSession(session.id); toast('模拟会话已创建');
    };
  });
};
$('addProject').onclick = () => dialog('添加项目', '<p>在正式应用中通过系统目录选择器授权目录。</p><div class="field"><label for="projectInput">演示目录路径</label><input id="projectInput" value="~/project/new-project"></div><div class="dialog-actions"><button id="confirmProject" class="primary">添加目录</button></div>', () => {
  $('confirmProject').onclick = () => {
    const path = $('projectInput').value.trim().replace(/\/+$/, '');
    if (!path) return toast('请输入目录路径');
    if (state.projects.some((item) => item.path === path)) return toast('该目录已存在');
    const project = { id: crypto.randomUUID(), name: path.split('/').pop(), path, expanded: true };
    state.projects.push(project);
    state.sessions.push({ id: crypto.randomUUID(), project: project.id, title: '开始新的项目会话', summary: '目录已添加，点击恢复以体验工作区切换', time: '刚刚', status: 'stopped' });
    persist(); render(); closeDialog(); toast('演示目录已添加');
  };
});
$('hiddenButton').onclick = hiddenItems;
function hiddenItems() {
  const items = [...state.projects.filter((item) => item.hidden).map((item) => ({ ...item, type: 'projects' })), ...state.sessions.filter((item) => item.hidden).map((item) => ({ ...item, type: 'sessions' }))];
  dialog('管理隐藏项', `<p>恢复后重新出现在列表中，原历史数据保留。</p>${items.length ? items.map((item) => `<div class="list-item"><span>${escapeHTML(item.name || item.title)}<small>${item.type === 'projects' ? '项目' : '会话'}</small></span><button data-restore="${item.id}" data-type="${item.type}">恢复</button></div>`).join('') : '<div class="empty">当前没有隐藏项。</div>'}`, () => {
    document.querySelectorAll('[data-restore]').forEach((button) => { button.onclick = () => { state[button.dataset.type].find((item) => item.id === button.dataset.restore).hidden = false; persist(); render(); hiddenItems(); }; });
  });
}
$('importButton').onclick = () => dialog('导入 ClaudePicker 数据', `<p>以下为内置演示文件预览。正式版由你选择本地 tree.json 并解析。</p><div class="notice">来源 ~/.local/share/claude-picker/tree.json<br>2 个项目 · 4 个会话排序 · 1 个隐藏项<br>导入保留当前会话内容，重复导入使用来源指纹去重。</div><div class="list-item"><span>lm-global-java<small>合并项目排序与会话偏好</small></span><span>可导入</span></div><div class="list-item"><span>claude-picker<small>恢复原项目展开状态</small></span><span>可导入</span></div><div class="dialog-actions">${state.imported ? '<button id="undoImport">撤销本次导入</button>' : ''}<button id="confirmImport" class="primary" ${state.imported ? 'disabled' : ''}>${state.imported ? '该来源已导入' : '确认导入模拟数据'}</button></div>`, () => {
  $('confirmImport').onclick = () => {
    state.importSnapshot = { order: state.sessions.map((item) => item.id), hidden: state.sessions.find((item) => item.id === 's5')?.hidden || false };
    const hidden = state.sessions.find((item) => item.id === 's5');
    if (hidden) hidden.hidden = true;
    state.imported = true; persist(); render(); closeDialog(); toast('模拟导入完成，已应用演示隐藏偏好');
  };
  if ($('undoImport')) $('undoImport').onclick = () => {
    const session = state.sessions.find((item) => item.id === 's5');
    if (session) session.hidden = state.importSnapshot?.hidden || false;
    state.imported = false; persist(); render(); closeDialog(); toast('本次导入已撤销');
  };
});
$('promptForm').onsubmit = (event) => {
  event.preventDefault();
  const input = $('prompt').value.trim();
  if (!input) return;
  const session = activeSession();
  if (session.status === 'running') return toast('模拟任务进行中，请先等待完成');
  $('prompt').value = '';
  if (input === '/clear') { session.messages = []; persist(); renderOutput(); return; }
  session.messages.push({ kind: 'user', text: `❯ ${input}` });
  if (input === '/help') { session.messages.push({ kind: 'muted', text: '支持 /clear 清屏。输入消息可模拟运行，切换到其他会话后会出现后台完成未读点。' }); persist(); renderOutput(); return; }
  session.status = 'running'; persist(); render();
  timers.set(session.id, setTimeout(() => {
    session.messages.push({ kind: 'text', text: '已收到你的消息。这是审核原型的模拟回复。\n真实版本将在这里呈现 Claude CLI 的终端输出。' });
    session.status = 'idle'; session.unread = state.active !== session.id; session.time = '刚刚';
    timers.delete(session.id); persist(); render();
  }, 2200));
};
$('finishButton').onclick = () => {
  const session = state.sessions.find((item) => item.id !== state.active && item.opened);
  if (!session) return toast('请先打开另一个会话');
  clearTimeout(timers.get(session.id)); timers.delete(session.id);
  session.status = 'idle'; session.unread = true; session.time = '刚刚';
  if (session.messages) session.messages.push({ kind: 'success', text: '● 后台分析已完成，可以继续对话。' });
  persist(); render(); toast(`「${session.title}」后台完成，已标记未读`);
};
$('closeButton').onclick = () => dialog('终止当前会话？', `<p>将停止「${escapeHTML(activeSession().title)}」的进程并释放终端句柄。历史会话仍可再次恢复。</p><div class="dialog-actions"><button id="cancelClose">继续运行</button><button id="confirmClose" class="primary">终止并释放</button></div>`, () => {
  $('cancelClose').onclick = closeDialog;
  $('confirmClose').onclick = () => { stopSession(state.active); closeDialog(); toast('模拟进程已终止，历史已保留'); };
});
$('preferencesButton').onclick = () => dialog('界面偏好', `<div class="field"><label for="fontSize">终端字号</label><input id="fontSize" type="range" min="11" max="19" value="${state.fontSize}"><small id="fontValue">${state.fontSize}px</small></div><div class="dialog-actions"><button id="manageTerminals">管理终端</button><button id="resetDemo">重置演示数据</button><button id="savePreference" class="primary">保存偏好</button></div>`, () => {
  $('fontSize').oninput = () => { $('fontValue').textContent = `${$('fontSize').value}px`; };
  $('manageTerminals').onclick = terminalManager;
  $('resetDemo').onclick = () => { timers.forEach(clearTimeout); timers.clear(); state = structuredClone(initial); $('search').value = ''; persist(); render(); closeDialog(); toast('演示数据已重置'); };
  $('savePreference').onclick = () => { state.fontSize = Number($('fontSize').value); persist(); render(); closeDialog(); };
});
$('guide').onclick = () => dialog('建议审核路径', '<p>1. 在左侧选择其他项目，检查工作区切换与会话保留。<br>2. 新建会话，输入消息后切到其他会话，观察后台未读点。<br>3. 点击底栏配置，分别保存默认值和应用到当前会话。<br>4. 置顶、拖动、隐藏会话，再从管理入口恢复。<br>5. 查看额度并模拟请求失败，体验旧数据导入与撤销。<br>6. 终止并重新恢复会话，或从偏好进入终端管理。</p><div class="notice">原型用于审核布局和操作。原生控件、实际 CLI 状态与协议实现按开发文档执行。</div><div class="dialog-actions"><button id="startReview" class="primary">开始审核</button></div>', () => { $('startReview').onclick = closeDialog; });
$('refresh').onclick = () => { toast('模拟刷新完成，已同步当前历史会话'); render(); };
$('search').oninput = render;
$('settingsButton').onclick = settings;
['modeButton', 'modelButton', 'effortButton', 'fastButton'].forEach((id) => { $(id).onclick = settings; });
$('quotaButton').onclick = () => quota();
$('sessionsButton').onclick = () => {
  const sidebar = document.querySelector('.sidebar');
  sidebar.classList.toggle(window.matchMedia('(max-width: 620px)').matches ? 'mobile-open' : 'collapsed');
};
$('filesButton').onclick = () => showEditor(true);
$('editorButton').onclick = () => showEditor(true);
$('terminalButton').onclick = () => showEditor(false);
$('returnTerminal').onclick = () => showEditor(false);
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') closeDialog();
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault();
    const sidebar = document.querySelector('.sidebar');
    sidebar.classList.remove('collapsed');
    if (window.matchMedia('(max-width: 620px)').matches) sidebar.classList.add('mobile-open');
    $('search').focus();
  }
  if (event.key === 'Tab' && !$('overlay').hidden) {
    const focusable = [...$('overlay').querySelectorAll('button:not(:disabled), input, select')];
    const first = focusable[0]; const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  }
});
render();
