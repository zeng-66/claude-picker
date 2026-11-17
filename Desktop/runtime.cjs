const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { randomUUID } = require("node:crypto");
const { git, gitRequest, fileRequest } = require("./git.cjs");

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
  constructor({ dataPath, emit, dialog, shell, window }) {
    this.dataPath = dataPath;
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
      ...readJSON(this.configFile, {}),
    };
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
    const add = (cwd) => {
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
      projects: this.projects,
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
    const cwd = p.cwd || p.projectPath;
    if (!cwd || !fs.statSync(cwd).isDirectory())
      throw new Error("工作目录不存在");
    const id = create ? randomUUID() : p.sessionId;
    if (!/^[a-f0-9-]{36}$/i.test(id)) throw new Error("无效的会话 ID");
    if (!this.sessions.has(id)) {
      const pty = require("node-pty");
      const quote = (value) => "'" + value.replaceAll("'", "''") + "'";
      const flags = create
        ? `--session-id ${quote(id)}`
        : `--resume ${quote(id)}`;
      const command = `& claude ${flags} --model ${quote(this.runtime.model)} --permission-mode ${quote(this.runtime.mode)}`;
      const terminal = pty.spawn(
        "powershell.exe",
        ["-NoLogo", "-NoProfile", "-NoExit", "-Command", command],
        {
          name: "xterm-256color",
          cols: 100,
          rows: 32,
          cwd,
          env: { ...process.env, TERM: "xterm-256color" },
        },
      );
      const session = { pty: terminal, buffer: "", sequence: 0, cwd, id };
      this.sessions.set(id, session);
      terminal.onData((data) => {
        session.buffer = (session.buffer + data).slice(-2 * 1024 * 1024);
        session.sequence += 1;
        this.emit("terminal:data", {
          sessionId: id,
          data,
          sequence: session.sequence,
        });
      });
      terminal.onExit(() => {
        this.sessions.delete(id);
        if (this.active?.sessionId === id) this.active = null;
        this.changed();
      });
    }
    this.active = {
      sessionId: id,
      cwd,
      projectPath: p.projectPath || cwd,
      label: p.title || "Claude 会话",
      busy: false,
    };
    if (create) {
      let project = this.projects.find((item) => item.path === cwd);
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
        title: p.title || "新建会话",
        cwd,
        running: true,
        time: "刚刚",
        modifiedAt: Date.now(),
      });
      if (!this.config.directories.includes(cwd))
        this.config.directories.push(cwd);
      if (p.title) this.config.titles[id] = p.title;
      this.persist();
    }
    this.changed();
    return { sessionId: id, cwd };
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
      case "app.layout":
        return null;
      case "app.settings":
        if (p.interactionMode === "chat")
          throw new Error("Windows 图形聊天服务尚未适配，请使用原生终端。");
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
        if (p.mode === "branch") {
          if (!p.branch || p.branch.startsWith("-"))
            throw new Error("无效的分支名称");
          await git(p.projectPath, ["switch", "-c", p.branch]);
        }
        if (p.mode === "worktree") {
          const tree = await gitRequest("git.createWorktree", {
            projectPath: p.projectPath,
            input: { branch: p.branch },
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
