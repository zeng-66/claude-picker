const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { randomUUID } = require("node:crypto");
const { git, gitRequest, fileRequest } = require("./git.cjs");
const engines = require("./engines.cjs");

const defaults = {
  appFontSize: 12,
  termFontSize: 12.5,
  followSessionBranch: false,
  density: "comfortable",
  sidebar: true,
  terminal: true,
  workbench: true,
  terminalWidth: 42,
};
function readJSON(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return fallback;
    throw new Error(`配置文件读取失败 ${file}，${error.message}`);
  }
}
function sampleSession(file) {
  const descriptor = fs.openSync(file, "r");
  try {
    const stat = fs.fstatSync(descriptor);
    const first = Buffer.alloc(Math.min(stat.size, 64 * 1024));
    fs.readSync(descriptor, first, 0, first.length, 0);
    const tail = Buffer.alloc(Math.min(stat.size, 128 * 1024));
    fs.readSync(
      descriptor,
      tail,
      0,
      tail.length,
      Math.max(0, stat.size - tail.length),
    );
    const messages = (first.toString("utf8") + "\n" + tail.toString("utf8"))
      .split("\n")
      .flatMap((line) => {
        try {
          return [JSON.parse(line)];
        } catch {
          return [];
        }
      });
    const metadata = messages.find((message) => message.cwd);
    if (!metadata) return null;
    const user = messages.find(
      (message) =>
        message.type === "user" &&
        typeof message.message?.content === "string" &&
        !message.message.content.startsWith("<"),
    );
    const title =
      messages.findLast((message) => message.type === "custom-title")
        ?.customTitle ||
      user?.message.content.slice(0, 70) ||
      "Claude 会话";
    return {
      id: path.basename(file, ".jsonl"),
      provider: "claude",
      cwd: metadata.cwd,
      title,
      time: new Date(stat.mtimeMs).toISOString(),
      modifiedAt: stat.mtimeMs,
      running: false,
      unread: false,
    };
  } finally {
    fs.closeSync(descriptor);
  }
}

class DesktopRuntime {
  constructor({ dataPath, emit, dialog, shell, window, spawn, env, platform, homes }) {
    this.dataPath = dataPath;
    // PTY 启动、环境与历史目录可注入：回归在任意平台验证参数，而不真的启动 CLI。
    this.spawnPty = spawn || ((file, args, options) => require("node-pty").spawn(file, args, options));
    this.env = env || process.env;
    this.platform = platform || process.platform;
    this.homes = homes || {};
    this.emit = emit;
    this.dialog = dialog;
    this.shell = shell;
    this.window = window;
    this.sessions = new Map();
    fs.mkdirSync(dataPath, { recursive: true });
    this.configFile = path.join(dataPath, "desktop-state.json");
    this.config = {
      directories: [],
      settings: {},
      titles: {},
      pinned: [],
      hidden: [],
      collapsed: [],
      hiddenProjects: [],
      projectOrder: [],
      sessionOrders: {},
      providers: {},
      ...readJSON(this.configFile, {}),
    };
    this.config.providers = this.config.providers || {};
    this.settings = { ...defaults, ...this.config.settings };
    this.runtime = {
      mode: "default",
      model: "sonnet",
      effort: "medium",
      fast: false,
    };
    this.projects = [];
    this.active = null;
    this.scan();
  }
  persist() {
    this.config.settings = this.settings;
    const temporary = this.configFile + ".tmp";
    fs.writeFileSync(temporary, JSON.stringify(this.config, null, 2));
    fs.renameSync(temporary, this.configFile);
  }
  scan() {
    const projects = new Map();
    const add = (raw) => {
      // `<项目>/.worktrees/<名字>` 里的会话归到 `<项目>` 名下，与 macOS 一致。
      const marker = raw.search(/[\\/]\.worktrees[\\/]/);
      const cwd = marker > 0 ? raw.slice(0, marker) : raw;
      if (!projects.has(cwd))
        projects.set(cwd, {
          path: cwd,
          title: cwd === os.homedir() ? "~" : path.basename(cwd),
          isHome: cwd === os.homedir(),
          expanded: !this.config.collapsed.includes(cwd),
          showAll: false,
          sessions: [],
        });
      return projects.get(cwd);
    };
    for (const directory of this.config.directories)
      if (!this.config.hiddenProjects.includes(directory)) add(directory);
    const source = path.join(os.homedir(), ".claude", "projects");
    if (fs.existsSync(source)) {
      for (const directory of fs
        .readdirSync(source, { withFileTypes: true })
        .filter((item) => item.isDirectory())) {
        for (const file of fs
          .readdirSync(path.join(source, directory.name))
          .filter((name) => name.endsWith(".jsonl"))) {
          let session;
          try {
            session = sampleSession(path.join(source, directory.name, file));
          } catch {
            continue;
          }
          if (!session || this.config.hidden.includes(session.id)) continue;
          if (this.config.hiddenProjects.includes(session.cwd)) continue;
          session.title = this.config.titles[session.id] || session.title;
          session.pinned = this.config.pinned.includes(session.id);
          add(session.cwd).sessions.push(session);
        }
      }
    }
    const others = [
      ...(this.settings.cliPreferences?.codex?.enabled === false ? [] : engines.scanCodex({ home: this.homes.codex })),
      ...(this.settings.cliPreferences?.dsh?.enabled === false ? [] : engines.scanDeepSeek({ userHome: this.homes.user, dshHome: this.homes.dsh })),
    ];
    for (const session of others) {
      if (this.config.hidden.includes(session.id) || this.config.hiddenProjects.includes(session.cwd)) continue;
      session.title = this.config.titles[session.id] || session.title;
      session.pinned = this.config.pinned.includes(session.id);
      add(session.cwd).sessions.push(session);
    }
    // 本次运行中新建、尚未回绑原始 ID 的会话保留在列表里。
    for (const live of this.sessions.values()) {
      if (!live.pending) continue;
      const project = add(live.projectPath || live.cwd);
      if (!project.sessions.some((item) => item.id === live.id))
        project.sessions.unshift({ id: live.id, provider: live.provider, cwd: live.cwd, title: this.config.titles[live.id] || "新建会话",
          running: true, unread: false, time: "刚刚", modifiedAt: Date.now() });
    }
    for (const project of projects.values())
      project.sessions.sort(
        (a, b) =>
          Number(b.pinned) - Number(a.pinned) || b.modifiedAt - a.modifiedAt,
      );
    this.projects = [...projects.values()];
    if (this.config.projectOrder.length)
      this.projects.sort(
        (a, b) =>
          this.orderIndex(this.config.projectOrder, a.path) -
          this.orderIndex(this.config.projectOrder, b.path),
      );
    for (const project of this.projects) {
      const order = this.config.sessionOrders[project.path];
      if (order)
        project.sessions.sort(
          (a, b) => this.orderIndex(order, a.id) - this.orderIndex(order, b.id),
        );
    }
  }
  orderIndex(order, value) {
    const index = order.indexOf(value);
    return index < 0 ? order.length : index;
  }
  snapshot() {
    return {
      home: os.homedir(),
      projects: this.projects.map((project) => ({
        ...project,
        sessions: project.sessions.map((session) => ({
          ...session,
          provider: session.provider || this.config.providers[session.id] || "claude",
          originalSessionId: session.id.startsWith("pending-") ? null : session.id,
          openMode: "terminal",
        })),
      })),
      providers: this.diagnostics(),

      active: this.active,
      settings: this.settings,
      runtime: {
        ...this.runtime,
        modes: [
          { id: "default", label: "默认" },
          { id: "plan", label: "规划" },
          { id: "acceptEdits", label: "接受编辑" },
        ],
        models: [
          { id: "sonnet", label: "Sonnet" },
          { id: "opus", label: "Opus" },
          { id: "haiku", label: "Haiku" },
        ],
        efforts: [
          { id: "low", label: "低" },
          { id: "medium", label: "中" },
          { id: "high", label: "高" },
        ],
      },
      usage: {
        session: null,
        weekly: null,
        note: "Windows 用量可在 Claude 终端执行 /usage 查看",
      },
    };
  }
  diagnostics() {
    return Object.keys(engines.ENGINES).map((id) => engines.diagnose(id, { env: this.env, platform: this.platform }));
  }
  sessionRow(sessionId) {
    for (const project of this.projects)
      for (const session of project.sessions) if (session.id === sessionId) return session;
    return null;
  }
  providerOf(sessionId) {
    for (const project of this.projects)
      for (const session of project.sessions) if (session.id === sessionId) return session.provider || "claude";
    return this.config.providers[sessionId] || null;
  }
  changed() {
    this.emit("claude-picker:state", this.snapshot());
  }
  hasSessions() {
    return this.sessions.size > 0;
  }
  assertIdle() {
    if (this.hasSessions()) throw new Error("请先关闭所有终端会话后安装更新。");
  }
  dispose() {
    for (const session of this.sessions.values()) session.pty.kill();
    this.sessions.clear();
  }
  async open(p, create) {
    const provider = p.provider || (create ? this.settings.defaultProvider : this.providerOf(p.sessionId)) || "claude";
    const spec = engines.engine(provider);
    if (this.settings.cliPreferences?.[provider]?.enabled === false) throw new Error(`${spec.label} 已停用`);
    // 恢复时以会话记录的执行目录为准（工作树会话不在项目根目录）。
    const cwd = p.cwd || (!create ? this.sessionRow(p.sessionId)?.cwd : null) || p.projectPath;
    if (!cwd || !fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) throw new Error("工作目录不存在");
    const generated = randomUUID();
    const id = create ? (spec.presetId ? generated : `pending-${provider}-${generated}`) : p.sessionId;
    if (!create && !this.sessions.has(id)) {
      if (typeof id === "string" && id.startsWith("pending-")) throw new Error("会话尚未取得原始 ID，无法恢复");
      if (!engines.validateId(provider, id)) throw new Error("无效的会话 ID");
    }
    if (!this.sessions.has(id)) {
      const diagnosis = engines.diagnose(provider, { env: this.env, platform: this.platform });
      if (!diagnosis.available) throw new Error(`${spec.label}：${diagnosis.status}`);
      const launch = engines.launchSpec(provider, {
        executable: diagnosis.path,
        id: create && !spec.presetId ? null : id,
        resume: !create,
        runtime: provider === "claude" ? this.runtime : null,
        platform: this.platform,
      });
      const terminal = this.spawnPty(launch.file, launch.args, {
        name: "xterm-256color",
        cols: 100,
        rows: 32,
        cwd,
        env: { ...this.env, TERM: "xterm-256color" },
      });
      const session = { pty: terminal, buffer: "", sequence: 0, cwd, id, provider, projectPath: p.projectPath || cwd,
        pending: create && !spec.presetId, startedAt: Date.now() };
      this.sessions.set(id, session);
      terminal.onData((data) => {
        session.buffer = (session.buffer + data).slice(-2 * 1024 * 1024);
        session.sequence += 1;
        this.emit("terminal:data", {
          sessionId: session.id,
          data,
          sequence: session.sequence,
        });
      });
      terminal.onExit(() => {
        this.sessions.delete(session.id);
        if (this.active?.sessionId === session.id) this.active = null;
        this.changed();
      });
      if (session.pending) this.scheduleBind(session);
    }
    this.active = {
      sessionId: id,
      cwd,
      projectPath: p.projectPath || cwd,
      label: p.title || `${spec.shortLabel} 会话`,
      busy: false,
      provider,
      surface: "terminal",
    };
    if (create) {
      let project = this.projects.find((item) => item.path === (p.projectPath || cwd));
      if (!project) {
        project = {
          path: cwd,
          title: path.basename(cwd),
          expanded: true,
          sessions: [],
        };
        this.projects.push(project);
      }
      project.sessions.unshift({
        id,
        provider,
        title: p.title || "新建会话",
        cwd,
        branch: p.workspace?.branch ?? null,
        running: true,
        time: "刚刚",
        modifiedAt: Date.now(),
      });
      if (!this.config.directories.includes(p.projectPath || cwd))
        this.config.directories.push(p.projectPath || cwd);
      if (p.title) this.config.titles[id] = p.title;
      this.config.providers[id] = provider;
      this.persist();
    }
    this.changed();
    return { sessionId: id, cwd, provider };
  }
  /// CLI 自行分配 ID 的会话：等它写入本地历史后，把占位 ID 换成原始 ID（只认唯一候选）。
  scheduleBind(session, delays = [2000, 5000, 12000, 25000]) {
    const known = new Set(this.projects.flatMap((project) => project.sessions.map((item) => item.id)));
    for (const delay of delays) {
      setTimeout(() => this.tryBind(session, known), delay).unref?.();
    }
  }
  tryBind(session, known = new Set()) {
    if (!session.pending || !this.sessions.has(session.id)) return false;
    const history = session.provider === "codex" ? engines.scanCodex({ home: this.homes.codex })
      : session.provider === "dsh" ? engines.scanDeepSeek({ userHome: this.homes.user, dshHome: this.homes.dsh })
      : [];
    const found = engines.findNewConversation(history, { cwd: session.cwd, since: session.startedAt - 1000, ignoring: known });
    if (!found) return false;
    const placeholder = session.id;
    this.sessions.delete(placeholder);
    session.id = found.id;
    session.pending = false;
    this.sessions.set(found.id, session);
    if (this.config.titles[placeholder]) {
      this.config.titles[found.id] = this.config.titles[placeholder];
      delete this.config.titles[placeholder];
    }
    delete this.config.providers[placeholder];
    this.config.providers[found.id] = session.provider;
    for (const project of this.projects)
      for (const item of project.sessions)
        if (item.id === placeholder) Object.assign(item, { id: found.id, branch: item.branch ?? found.branch });
    if (this.active?.sessionId === placeholder) this.active = { ...this.active, sessionId: found.id };
    this.persist();
    this.emit("terminal:rebind", { from: placeholder, to: found.id });
    this.changed();
    return true;
  }
  async request(method, p = {}) {
    if (method.startsWith("git.") || method.startsWith("file.")) {
      if (p.input?.projectPath) p = { ...p, projectPath: p.input.projectPath };
      if (
        !this.projects.some(
          (project) =>
            path.resolve(project.path) === path.resolve(p.projectPath || ""),
        )
      )
        throw new Error("请先添加项目目录");
      return method.startsWith("git.")
        ? gitRequest(method, p)
        : fileRequest(method, p);
    }
    switch (method) {
      case "app.state":
        return this.snapshot();
      case "app.refreshUsage":
        throw new Error("Windows 暂未提供额度接口");
      case "app.layout":
        return null;
      case "app.settings":
        if (p.interactionMode && p.interactionMode !== "terminal")
          throw new Error("Windows 的聊天方式尚未适配，请使用原生终端。");
        Object.assign(this.settings, p);
        this.persist();
        this.changed();
        return this.settings;
      case "app.runtime":
        this.runtime[p.key] = p.value;
        this.changed();
        return this.runtime;
      case "app.pickDirectory": {
        const result = await this.dialog.showOpenDialog(this.window, {
          properties: ["openDirectory"],
        });
        return { path: result.canceled ? null : result.filePaths[0] };
      }
      case "app.addDirectory": {
        const directory = path.resolve(p.path);
        if (!fs.statSync(directory).isDirectory())
          throw new Error("请选择目录");
        if (!this.config.directories.includes(directory))
          this.config.directories.push(directory);
        this.config.hiddenProjects = this.config.hiddenProjects.filter(
          (value) => value !== directory,
        );
        this.persist();
        this.scan();
        this.changed();
        return { path: directory };
      }
      case "app.toggleProject": {
        const project = this.projects.find((item) => item.path === p.path);
        if (project) {
          project.expanded = !project.expanded;
          this.config.collapsed = this.projects
            .filter((item) => !item.expanded)
            .map((item) => item.path);
          this.persist();
          this.changed();
        }
        return null;
      }
      case "app.toggleShowAll": {
        const project = this.projects.find((item) => item.path === p.path);
        if (project) project.showAll = !project.showAll;
        this.changed();
        return null;
      }
      case "app.renameSession":
        this.config.titles[p.sessionId] = p.title;
        for (const project of this.projects)
          for (const session of project.sessions)
            if (session.id === p.sessionId) session.title = p.title;
        this.persist();
        this.changed();
        return { ok: true };
      case "app.pin": {
        const index = this.config.pinned.indexOf(p.sessionId);
        if (index === -1) this.config.pinned.push(p.sessionId);
        else this.config.pinned.splice(index, 1);
        this.persist();
        this.scan();
        this.changed();
        return null;
      }
      case "app.remove": {
        if (p.sessionId) {
          this.config.hidden.push(p.sessionId);
          this.sessions.get(p.sessionId)?.pty.kill();
        } else {
          this.config.directories = this.config.directories.filter(
            (item) => item !== p.projectPath,
          );
          this.config.hiddenProjects.push(p.projectPath);
        }
        this.persist();
        this.scan();
        this.changed();
        return null;
      }
      case "app.moveProject":
      case "app.moveSession": {
        const project = this.projects.find(
          (item) => item.path === p.projectPath,
        );
        const items =
          method === "app.moveProject" ? this.projects : project?.sessions;
        if (!items) throw new Error("找不到项目");
        const key = method === "app.moveProject" ? "path" : "id";
        const from = items.findIndex((item) => item[key] === p.from);
        const to = items.findIndex((item) => item[key] === p.to);
        if (from < 0 || to < 0) throw new Error("找不到排序目标");
        const [moved] = items.splice(from, 1);
        items.splice(to, 0, moved);
        if (method === "app.moveProject")
          this.config.projectOrder = items.map((item) => item.path);
        else
          this.config.sessionOrders[p.projectPath] = items.map(
            (item) => item.id,
          );
        this.persist();
        this.changed();
        return null;
      }
      case "app.revealInFinder":
        await this.shell.openPath(p.path || p.projectPath);
        return null;
      case "app.revealBranchSessions":
        return { enabled: false, matched: 0 };
      case "app.context":
        return { files: [], skills: [], rules: [], mcp: [] };
      case "app.command": {
        if (p.name === "closeTerminal") {
          const session = this.sessions.get(this.active?.sessionId);
          session?.pty.kill();
          this.active = null;
          this.changed();
        }
        if (p.name === "refresh") {
          this.scan();
          this.changed();
        }
        return null;
      }
      case "session.open":
        return this.open(p, false);
      case "session.create": {
        if (p.mode === "current" && p.workspace?.worktreePath) {
          const trees = await gitRequest("git.worktrees", { projectPath: p.projectPath });
          const tree = trees.find((item) => !item.isPrunable && !item.isBare &&
            path.resolve(item.path) === path.resolve(p.workspace.worktreePath));
          if (!tree) throw new Error("工作树不存在或已不可用");
          p = { ...p, cwd: tree.path };
        } else if (p.mode === "current" && p.workspace?.branch) {
          await gitRequest("git.switchWorkspaceBranch", { projectPath: p.projectPath, branch: p.workspace.branch });
        }
        if (p.mode === "branch") {
          if (!p.branch || p.branch.startsWith("-"))
            throw new Error("无效的分支名称");
          await git(p.projectPath, ["switch", "-c", p.branch]);
        }
        if (p.mode === "worktree") {
          const tree = await gitRequest("git.createWorktree", {
            projectPath: p.projectPath,
            input: { projectPath: p.projectPath, branch: p.branch },
          });
          p = { ...p, cwd: tree.path };
        }
        return this.open(p, true);
      }
      case "app.prompt": {
        if (!this.active)
          await this.open(
            {
              projectPath:
                p.projectPath || this.projects[0]?.path || os.homedir(),
              title: (p.text || "").slice(0, 50),
            },
            true,
          );
        const terminal = this.sessions.get(this.active.sessionId)?.pty;
        if (!terminal) throw new Error("终端会话已结束");
        terminal.write(p.text + "\r");
        return { ok: true };
      }
      case "terminal.attach":
        return {
          buffer: this.sessions.get(p.sessionId)?.buffer || "",
          sequence: this.sessions.get(p.sessionId)?.sequence || 0,
        };
      case "terminal.write": {
        if (typeof p.data !== "string") throw new Error("无效的终端输入");
        this.sessions.get(p.sessionId)?.pty.write(p.data);
        return null;
      }
      case "terminal.resize": {
        this.sessions
          .get(p.sessionId)
          ?.pty.resize(
            Math.max(2, Math.min(500, Number(p.cols) || 80)),
            Math.max(2, Math.min(200, Number(p.rows) || 24)),
          );
        return null;
      }
      case "work.snapshot":
        return {
          available: false,
          owner: true,
          error:
            "Windows Work、TAPD、企微服务适配尚未完成。当前可使用 Claude 终端、项目与 Git 工作台。",
          works: [],
          projects: [],
          workSessionIds: [],
          capacity: { slots: 0, running: 0, queued: 0, waitingStart: 0 },
        };
      case "mcp.list": {
        const config = readJSON(path.join(os.homedir(), ".claude.json"), {});
        return Object.entries(config.mcpServers || {}).map(([id, server]) => ({
          id,
          name: id,
          transport: server.type || "stdio",
          endpoint: server.url || server.command,
          scope: "user",
        }));
      }
      case "mcp.status":
        return [];
      default: {
        const error = new Error(`Windows 尚未适配 ${method}`);
        error.code = "UNAVAILABLE";
        throw error;
      }
    }
  }
}
module.exports = { DesktopRuntime, sampleSession };
