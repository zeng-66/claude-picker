// CLI 引擎目录（Windows Electron 版）：发现可执行文件、拼装启动 / 恢复参数、校验原始 ID、扫描历史。
// 与 macOS 的 AgentProviders.swift / *SessionScanner.swift 保持同一口径。纯函数优先，便于在任意平台回归。
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const UUID_ID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

const ENGINES = {
  claude: {
    id: "claude",
    label: "Claude Code",
    shortLabel: "Claude",
    command: "claude",
    override: "CLAUDE_PICKER_CLAUDE_BIN",
    // Claude 可以预先指定会话 ID；其它引擎由 CLI 分配，启动后再从历史里回绑。
    presetId: true,
    idPattern: UUID_ID,
    args: ({ id, resume, runtime }) => [
      resume ? "--resume" : "--session-id",
      id,
      ...(runtime?.model ? ["--model", runtime.model] : []),
      ...(runtime?.mode ? ["--permission-mode", runtime.mode] : []),
    ],
    resumeCommand: (id) => `claude --resume ${id}`,
  },
  codex: {
    id: "codex",
    label: "Codex CLI",
    shortLabel: "Codex",
    command: "codex",
    override: "CLAUDE_PICKER_CODEX_BIN",
    presetId: false,
    idPattern: UUID_ID,
    args: ({ id, resume }) => (resume ? ["resume", id] : []),
    resumeCommand: (id) => `codex resume ${id}`,
  },
  antigravity: {
    id: "antigravity",
    label: "Antigravity",
    shortLabel: "Antigravity",
    command: "agy",
    override: "CLAUDE_PICKER_AGY_BIN",
    presetId: false,
    idPattern: SAFE_ID,
    args: ({ id, resume }) => (resume ? ["--conversation", id] : []),
    resumeCommand: (id) => `agy --conversation ${id}`,
  },
  dsh: {
    id: "dsh",
    label: "DeepSeek Harness",
    shortLabel: "DeepSeek",
    command: "dsh-tui",
    override: "CLAUDE_PICKER_DSH_TUI_BIN",
    presetId: false,
    idPattern: SAFE_ID,
    // 显式使用 dsh 后端；恢复时带原始会话 ID。
    args: ({ id, resume }) => ["--backend", "dsh", ...(resume ? ["--resume", id] : [])],
    resumeCommand: (id) => `dsh-tui --backend dsh --resume ${id}`,
    requires: ["dsh"],
  },
};

function engine(id) {
  const found = ENGINES[id || "claude"];
  if (!found) throw new Error(`未知的 CLI 引擎：${id}`);
  return found;
}

function validateId(engineId, id) {
  const spec = engine(engineId);
  return typeof id === "string" && !id.startsWith("-") && spec.idPattern.test(id);
}

/// 可执行文件查找：环境变量覆盖 → PATH（Windows 按 PATHEXT 补扩展名）→ 常见安装目录。
/// GUI 启动时 PATH 可能不完整，所以额外查 npm 全局目录与用户本地 bin。
function findExecutable(command, { env = process.env, platform = process.platform, override, exists = fs.existsSync } = {}) {
  if (override && env[override]) return exists(env[override]) ? env[override] : null;
  const windows = platform === "win32";
  const join = windows ? path.win32.join : path.posix.join;
  const delimiter = windows ? ";" : ":";
  const home = env.USERPROFILE || env.HOME || os.homedir();
  const dirs = (env.PATH || env.Path || "").split(delimiter).filter(Boolean);
  if (windows) {
    if (env.APPDATA) dirs.push(join(env.APPDATA, "npm"));
    if (env.LOCALAPPDATA) dirs.push(join(env.LOCALAPPDATA, "Programs", command), join(env.LOCALAPPDATA, "Microsoft", "WinGet", "Links"));
    dirs.push(join(home, ".local", "bin"));
  } else {
    dirs.push(join(home, ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin");
  }
  const extensions = windows
    ? (env.PATHEXT || ".COM;.EXE;.BAT;.CMD").split(";").filter(Boolean).map((ext) => ext.toLowerCase()).concat([".ps1"])
    : [""];
  for (const dir of dirs) {
    for (const ext of extensions) {
      const candidate = join(dir, command + ext);
      if (exists(candidate)) return candidate;
    }
  }
  return null;
}

function diagnose(id, options = {}) {
  const spec = engine(id);
  const found = findExecutable(spec.command, { ...options, override: spec.override });
  let status = found ? "可启动" : `未检测到 ${spec.command}`;
  if (found && spec.requires) {
    const missing = spec.requires.filter((dep) => !findExecutable(dep, options));
    if (missing.length) status = `缺少依赖 ${missing.join("、")}`;
  }
  return {
    id: spec.id,
    label: spec.label,
    shortLabel: spec.shortLabel,
    command: spec.command,
    path: found,
    available: status === "可启动",
    status,
    supportsChat: false,
  };
}

/// PowerShell 单引号字面量：内部单引号写两遍，路径里的空格与特殊字符原样保留。
function psQuote(value) {
  return "'" + String(value).replaceAll("'", "''") + "'";
}

/// 生成 PTY 启动参数。Windows 经 PowerShell 的调用运算符启动（兼容 npm 的 .cmd 垫片与带空格路径）；
/// 其它平台直接执行。工作目录只通过 spawn 的 cwd 传递，不拼进命令行。
function launchSpec(engineId, { executable, id, resume, runtime, platform = process.platform }) {
  const spec = engine(engineId);
  if (resume && !validateId(engineId, id)) throw new Error("无效的会话 ID");
  if (!resume && spec.presetId && !validateId(engineId, id)) throw new Error("无效的会话 ID");
  const args = spec.args({ id, resume, runtime });
  if (platform === "win32") {
    const command = `& ${psQuote(executable)} ${args.map(psQuote).join(" ")}`.trim();
    return { file: "powershell.exe", args: ["-NoLogo", "-NoProfile", "-Command", command] };
  }
  return { file: executable, args };
}

// MARK: 历史扫描

function readLines(file, limit = 64 * 1024) {
  const descriptor = fs.openSync(file, "r");
  try {
    const buffer = Buffer.alloc(Math.min(fs.fstatSync(descriptor).size, limit));
    fs.readSync(descriptor, buffer, 0, buffer.length, 0);
    return buffer.toString("utf8").split("\n");
  } finally {
    fs.closeSync(descriptor);
  }
}

function walk(dir, visit, depth = 0) {
  let entries = [];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory() && depth < 4) walk(full, visit, depth + 1);
    else if (entry.isFile()) visit(full);
  }
}

/// Codex：`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`，首行 `session_meta` 带原始线程 ID、cwd 与分支。
function scanCodex({ home = process.env.CODEX_HOME || path.join(os.homedir(), ".codex") } = {}) {
  const sessions = [];
  walk(path.join(home, "sessions"), (file) => {
    if (!file.endsWith(".jsonl")) return;
    try {
      const first = JSON.parse(readLines(file, 32 * 1024)[0]);
      if (first.type !== "session_meta") return;
      const meta = first.payload || {};
      if (!UUID_ID.test(meta.id || "") || !meta.cwd) return;
      const stat = fs.statSync(file);
      sessions.push({
        id: meta.id,
        provider: "codex",
        cwd: meta.cwd,
        title: `Codex · ${meta.id.slice(0, 8)}`,
        branch: meta.git?.branch ?? null,
        createdAt: Date.parse(meta.timestamp) || stat.birthtimeMs,
        modifiedAt: stat.mtimeMs,
        time: new Date(stat.mtimeMs).toISOString(),
        running: false,
        unread: false,
      });
    } catch {
      // 半写入或格式不对的文件跳过
    }
  });
  return sessions;
}

/// DeepSeek：dsh-TUI 索引与 DSH 元数据缓存的交集，只给出 TUI profile 能恢复的会话。
function scanDeepSeek({ userHome = os.homedir(), dshHome = process.env.DSH_HOME || path.join(os.homedir(), ".dsh") } = {}) {
  let index;
  try {
    index = JSON.parse(fs.readFileSync(path.join(userHome, ".dsh-tui", "session-index.json"), "utf8"));
  } catch {
    return [];
  }
  const sessions = [];
  for (const [id, entry] of Object.entries(index.entries || {})) {
    const uuid = id.startsWith("session-") ? id.slice(8) : id;
    if (!UUID_ID.test(uuid) || !entry?.derived) continue;
    try {
      const cached = JSON.parse(fs.readFileSync(path.join(dshHome, "storages", "session_projcache", "sessions", id + ".json"), "utf8"));
      const identity = cached.record?.identity;
      if (!identity?.cwd || !path.isAbsolute(identity.cwd) && !path.win32.isAbsolute(identity.cwd)) continue;
      const title = (entry.derived.title || "").trim();
      sessions.push({
        id,
        provider: "dsh",
        cwd: identity.cwd,
        title: title || `DeepSeek · ${uuid.slice(0, 8)}`,
        branch: entry.branch ?? null,
        createdAt: identity.createdAt,
        modifiedAt: entry.derived.modifiedAt,
        time: new Date(entry.derived.modifiedAt).toISOString(),
        running: false,
        unread: false,
      });
    } catch {
      // 缓存缺失：不提供无法恢复的会话
    }
  }
  return sessions;
}

function samePath(a, b) {
  if (!a || !b) return false;
  const normalize = (value) => path.resolve(value).replace(/[\\/]+$/, "");
  return process.platform === "win32" ? normalize(a).toLowerCase() === normalize(b).toLowerCase() : normalize(a) === normalize(b);
}

/// 引擎自行分配 ID 的新会话：在同一目录、启动之后出现且只有一个候选时才回绑，避免认错。
function findNewConversation(sessions, { cwd, since, ignoring = new Set() }) {
  const matches = sessions.filter(
    (session) => !ignoring.has(session.id) && samePath(session.cwd, cwd) && (session.createdAt ?? session.modifiedAt) >= since,
  );
  return matches.length === 1 ? matches[0] : null;
}

module.exports = {
  ENGINES,
  engine,
  validateId,
  findExecutable,
  diagnose,
  psQuote,
  launchSpec,
  scanCodex,
  scanDeepSeek,
  findNewConversation,
  samePath,
};
