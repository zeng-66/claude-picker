// Windows 版 CLI 引擎回归：可执行文件发现（PATHEXT、npm 垫片、带空格目录）、启动 / 恢复参数、
// 原始 ID 校验、Codex / DeepSeek 历史扫描、新会话 ID 回绑。PTY 启动被替换为记录参数的替身，不启动任何 CLI。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const engines = require("../../Desktop/engines.cjs");
const { DesktopRuntime } = require("../../Desktop/runtime.cjs");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "claude-picker-engines-"));
const touch = (file, content = "") => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
  return file;
};

async function run() {
  // 1. 发现：Windows 按 PATHEXT 补扩展名，并查 %APPDATA%\npm；路径带空格。
  const winBin = path.join(root, "Program Files", "nodejs");
  const npmDir = path.join(root, "App Data", "npm");
  touch(path.join(winBin, "claude.exe"));
  touch(path.join(npmDir, "codex.cmd"));
  const winEnv = { PATH: [winBin, path.join(root, "missing")].join(";"), PATHEXT: ".COM;.EXE;.BAT;.CMD", APPDATA: path.join(root, "App Data"),
    USERPROFILE: path.join(root, "User Home") };
  const exists = (file) => fs.existsSync(file.replaceAll("\\", "/"));
  const toPosix = (value) => value && value.replaceAll("\\", "/");
  assert.equal(toPosix(engines.findExecutable("claude", { env: winEnv, platform: "win32", exists })), path.join(winBin, "claude.exe"));
  assert.equal(toPosix(engines.findExecutable("codex", { env: winEnv, platform: "win32", exists })), path.join(npmDir, "codex.cmd"));
  assert.equal(engines.findExecutable("agy", { env: winEnv, platform: "win32", exists }), null);
  const override = touch(path.join(root, "custom dir", "agy.exe"));
  assert.equal(engines.findExecutable("agy", { env: { ...winEnv, CLAUDE_PICKER_AGY_BIN: override }, platform: "win32",
    override: "CLAUDE_PICKER_AGY_BIN" }), override);

  // DeepSeek 需要 dsh-tui 与 dsh 两个命令：缺 dsh 时报依赖缺失而不是可启动。
  const posixBin = path.join(root, "bin");
  touch(path.join(posixBin, "dsh-tui"));
  const posixEnv = { PATH: posixBin, HOME: path.join(root, "home") };
  assert.equal(engines.diagnose("dsh", { env: posixEnv, platform: "linux" }).status, "缺少依赖 dsh");
  touch(path.join(posixBin, "dsh"));
  assert.equal(engines.diagnose("dsh", { env: posixEnv, platform: "linux" }).available, true);

  // 2. 参数：Windows 走 PowerShell 调用运算符，路径与 ID 单引号转义；恢复使用原始 ID。
  const uuid = "019a6b2c-1111-7222-8333-444455556666";
  const exe = "C:\\Users\\O'Brien Li\\AppData\\Roaming\\npm\\codex.cmd";
  const codexResume = engines.launchSpec("codex", { executable: exe, id: uuid, resume: true, platform: "win32" });
  assert.equal(codexResume.file, "powershell.exe");
  assert.equal(codexResume.args.at(-1), `& 'C:\\Users\\O''Brien Li\\AppData\\Roaming\\npm\\codex.cmd' 'resume' '${uuid}'`);
  const claudeNew = engines.launchSpec("claude", { executable: "/usr/bin/claude", id: uuid, resume: false,
    runtime: { model: "sonnet", mode: "default" }, platform: "linux" });
  assert.deepEqual(claudeNew.args, ["--session-id", uuid, "--model", "sonnet", "--permission-mode", "default"]);
  assert.deepEqual(engines.launchSpec("dsh", { executable: "/x/dsh-tui", id: "session-" + uuid, resume: true, platform: "linux" }).args,
    ["--backend", "dsh", "--resume", "session-" + uuid]);
  assert.deepEqual(engines.launchSpec("antigravity", { executable: "/x/agy", id: "conv_01", resume: true, platform: "linux" }).args,
    ["--conversation", "conv_01"]);
  assert.deepEqual(engines.launchSpec("codex", { executable: "/x/codex", id: null, resume: false, platform: "linux" }).args, []);
  assert.throws(() => engines.launchSpec("codex", { executable: "/x/codex", id: "--yolo", resume: true, platform: "linux" }), /无效/);
  assert.throws(() => engines.launchSpec("claude", { executable: "/x/claude", id: "not-a-uuid", resume: true, platform: "linux" }), /无效/);

  // 3. 历史：Codex rollout 首行元数据，DeepSeek 索引与缓存的交集；cwd 带空格。
  const project = path.join(root, "My Project");
  const worktree = path.join(project, ".worktrees", "feature x");
  fs.mkdirSync(worktree, { recursive: true });
  const codexHome = path.join(root, "codex-home");
  touch(path.join(codexHome, "sessions", "2026", "11", "19", `rollout-2026-11-19T10-00-00-${uuid}.jsonl`),
    JSON.stringify({ type: "session_meta", payload: { id: uuid, cwd: worktree, timestamp: "2026-11-19T10:00:00Z", git: { branch: "feature/x" } } }) + "\n");
  touch(path.join(codexHome, "sessions", "2026", "11", "19", "rollout-broken.jsonl"), "{not json\n");
  const codex = engines.scanCodex({ home: codexHome });
  assert.equal(codex.length, 1);
  assert.equal(codex[0].cwd, worktree);
  assert.equal(codex[0].branch, "feature/x");

  const userHome = path.join(root, "home");
  const dshHome = path.join(root, "dsh-home");
  const dshId = "session-0f8fad5b-d9cb-469f-a165-70867728950e";
  const now = Date.now();
  touch(path.join(userHome, ".dsh-tui", "session-index.json"), JSON.stringify({ entries: {
    [dshId]: { derived: { modifiedAt: now, title: "整理报表" }, branch: "main" },
    "session-11111111-2222-4333-8444-555555555555": { derived: { modifiedAt: now } },
  } }));
  touch(path.join(dshHome, "storages", "session_projcache", "sessions", dshId + ".json"),
    JSON.stringify({ record: { identity: { cwd: project, createdAt: now - 5000 } } }));
  const dsh = engines.scanDeepSeek({ userHome, dshHome });
  assert.deepEqual(dsh.map((item) => [item.id, item.title, item.cwd]), [[dshId, "整理报表", project]]);

  // 4. 运行时：替身 PTY 记录启动参数；恢复工作树里的 Codex 会话、拒绝伪造 ID、新会话回绑原始 ID。
  const spawned = [];
  const fakePty = () => ({ onData() {}, onExit() {}, write() {}, kill() {}, resize() {} });
  touch(path.join(posixBin, "claude"));
  touch(path.join(posixBin, "codex"));
  const runtime = new DesktopRuntime({
    dataPath: path.join(root, "data"),
    emit() {},
    dialog: null,
    shell: null,
    window: null,
    env: posixEnv,
    platform: "linux",
    homes: { codex: codexHome, user: userHome, dsh: dshHome },
    spawn: (file, args, options) => {
      spawned.push({ file, args, cwd: options.cwd });
      return fakePty();
    },
  });
  await runtime.request("app.addDirectory", { path: project });
  const state = runtime.snapshot();
  const rows = state.projects.flatMap((item) => item.sessions);
  assert.ok(rows.some((row) => row.id === uuid && row.provider === "codex" && row.originalSessionId === uuid), "Codex 历史进入项目树");
  assert.ok(rows.some((row) => row.id === dshId && row.provider === "dsh"), "DeepSeek 历史进入项目树");
  assert.equal(state.providers.find((item) => item.id === "codex").available, true);

  await runtime.request("session.open", { sessionId: uuid, projectPath: project });
  assert.deepEqual(spawned.at(-1), { file: path.join(posixBin, "codex"), args: ["resume", uuid], cwd: worktree });
  await runtime.request("session.open", { sessionId: dshId, projectPath: project });
  assert.deepEqual(spawned.at(-1).args, ["--backend", "dsh", "--resume", dshId]);
  assert.equal(spawned.at(-1).cwd, project);
  await assert.rejects(runtime.request("session.open", { sessionId: "-rf", provider: "codex", projectPath: project }), /无效/);
  await assert.rejects(runtime.request("session.open", { sessionId: "pending-codex-x", provider: "codex", projectPath: project }), /原始 ID/);

  const created = await runtime.request("session.create", { projectPath: project, cwd: worktree, provider: "codex", mode: "current", title: "并行任务" });
  assert.match(created.sessionId, /^pending-codex-/);
  assert.deepEqual(spawned.at(-1).args, []);
  const live = runtime.sessions.get(created.sessionId);
  const fresh = "019a6b2c-9999-7222-8333-444455556666";
  touch(path.join(codexHome, "sessions", "2026", "11", "19", `rollout-new-${fresh}.jsonl`),
    JSON.stringify({ type: "session_meta", payload: { id: fresh, cwd: worktree, timestamp: new Date(live.startedAt + 500).toISOString() } }) + "\n");
  assert.equal(runtime.tryBind(live, new Set([uuid])), true, "唯一候选时回绑原始 ID");
  assert.equal(runtime.active.sessionId, fresh);
  assert.equal(runtime.config.providers[fresh], "codex");
  assert.equal(runtime.config.titles[fresh], "并行任务");

  const claude = await runtime.request("session.create", { projectPath: project, provider: "claude", mode: "current" });
  assert.match(claude.sessionId, /^[a-f0-9-]{36}$/);
  assert.equal(spawned.at(-1).args[0], "--session-id");
  runtime.settings.cliPreferences = { codex: { enabled: false } };
  await assert.rejects(runtime.request("session.open", { sessionId: uuid, provider: "codex", projectPath: project }), /已停用/);
  runtime.dispose();
  console.log("Desktop engine regression passed · discovery, launch args, history scan, resume and ID binding");
}

run()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => fs.rmSync(root, { recursive: true, force: true }));
