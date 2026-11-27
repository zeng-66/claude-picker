// Windows 版（Electron）工作树回归：统一命令（ai-worktree）的入参、失败与格式校验、Git 复核，
// 项目内 `.worktrees` 模式的范围与忽略校验，以及按 common dir 归属。只在临时仓库上操作；
// 真实 ai-worktree 经包装脚本把统一根固定在临时目录，不写 ~/project/worktrees。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { gitRequest, validateWorktreeCommand, worktreeOwner, parseWorktreeReply } = require("../../Desktop/git.cjs");
const { DesktopRuntime } = require("../../Desktop/runtime.cjs");

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "claude-picker-worktree-")));
const sh = (cwd, ...args) => execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
const script = (name, body) => {
  const file = path.join(root, "bin", name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return file;
};
const create = (input) => gitRequest("git.createWorktree", { projectPath: input.projectPath, input });

async function run() {
  const repo = path.join(root, "repo");
  fs.mkdirSync(repo);
  sh(repo, "init", "-q", "-b", "main");
  sh(repo, "config", "user.email", "t@t");
  sh(repo, "config", "user.name", "t");
  fs.writeFileSync(path.join(repo, "a.txt"), "a\n");
  sh(repo, "add", ".");
  sh(repo, "commit", "-qm", "init");

  // 1. 设置与解析
  assert.equal(await validateWorktreeCommand(""), "");
  await assert.rejects(validateWorktreeCommand("bin/ai-worktree"), /绝对路径/);
  await assert.rejects(validateWorktreeCommand(path.join(root, "missing")), /不存在/);
  assert.equal(parseWorktreeReply('noise\n{"action":"reused","repo_root":"/r","path":"/p","branch":null}\n').action, "reused");
  assert.equal(parseWorktreeReply("not json"), null);
  assert.equal(parseWorktreeReply('{"action":"weird","repo_root":"/r","path":"/p"}'), null);

  // 2. 假命令：失败去前缀、格式无效、未登记目录、缺任务标识
  const failing = script("fake-worktree", "echo 'fake-worktree: The branch already exists: x' >&2; exit 1");
  await assert.rejects(create({ projectPath: repo, task: "T1", command: failing }), { message: "The branch already exists: x" });
  await assert.rejects(create({ projectPath: repo, task: "T1", command: script("garbage", "echo nope") }), /格式无效/);
  const stray = script("stray", `echo '{"action":"created","repo_root":"${repo}","path":"${root}/nowhere","branch":"b"}'`);
  await assert.rejects(create({ projectPath: repo, task: "T1", command: stray }), /不在该仓库的 Git 工作树登记中/);
  await assert.rejects(create({ projectPath: repo, command: failing }), /任务标识/);
  await assert.rejects(create({ projectPath: repo, task: "坏", command: failing }), /任务标识只能/);

  // 3. 项目模式：建在 .worktrees 下且被 Git 忽略；越界路径被拒绝
  const local = await create({ projectPath: repo, branch: "feature/local" });
  assert.equal(local.path, path.join(repo, ".worktrees", "feature-local"));
  assert.equal(local.mode, "project");
  assert.equal(sh(repo, "status", "--porcelain"), "");
  await assert.rejects(create({ projectPath: repo, branch: "escape", path: "../outside" }), /\.worktrees/);
  assert.equal(worktreeOwner(local.path), repo);

  // 4. 运行时：命令只认设置；前端传来的 command 被覆盖；删除时拦截运行中的会话
  const data = path.join(root, "data");
  fs.mkdirSync(data);
  fs.writeFileSync(path.join(data, "desktop-state.json"), JSON.stringify({ directories: [repo] }));
  const runtime = new DesktopRuntime({ dataPath: data, emit() {}, dialog: null, shell: null, window: null,
    env: process.env, platform: process.platform, homes: { codex: path.join(root, "codex"), user: root, dsh: path.join(root, "dsh") } });
  await assert.rejects(runtime.request("app.setWorktreeCommand", { path: "relative" }), /绝对路径/);
  await runtime.request("app.settings", { worktreeCommand: failing });
  assert.equal(runtime.settings.worktreeCommand ?? "", "", "app.settings 不应绕过校验写入命令");
  runtime.sessions.set("live", { cwd: path.join(local.path, "sub") });
  await assert.rejects(runtime.request("git.removeWorktree", { input: { projectPath: repo, path: local.path } }), /会话在运行/);
  runtime.sessions.delete("live");

  // 5. 真实 ai-worktree
  const real = path.join(os.homedir(), ".local/bin/ai-worktree");
  if (fs.existsSync(real)) {
    const shared = path.join(root, "shared-root");
    const wrapper = script("ai-worktree", `AI_WORKTREE_ROOT='${shared}' exec '${real}' "$@"`);
    await runtime.request("app.setWorktreeCommand", { path: wrapper });
    const input = { projectPath: repo, baseBranch: "main", task: "1131010001030864", name: "listing", command: "/bin/false" };
    const [a, b] = await Promise.all([
      runtime.request("git.createWorktree", { input }),
      runtime.request("git.createWorktree", { input }),
    ]);
    assert.deepEqual(new Set([a.action, b.action]), new Set(["created", "reused"]));
    assert.equal(a.path, b.path);
    assert.ok(a.path.startsWith(shared + path.sep), a.path);
    assert.equal(a.branch, "worktree/1131010001030864-listing");
    assert.equal(a.baseCommit, b.baseCommit);
    assert.equal(worktreeOwner(a.path), repo);
    // 未传基线、仓库没有远端：从当前分支起步
    const noBase = await runtime.request("git.createWorktree", { input: { projectPath: repo, task: "T4" } });
    assert.equal(noBase.action, "created");
    assert.equal(noBase.baseRef, "main");
    const checked = await runtime.request("git.checkWorktreeCommand", { projectPath: repo });
    assert.equal(fs.realpathSync(checked.repoRoot), repo);
    await runtime.request("app.setWorktreeCommand", { path: "" });
    assert.equal(runtime.settings.worktreeCommand, "");
  } else {
    console.log("SKIP 未找到 ~/.local/bin/ai-worktree，跳过真实命令用例");
  }

  // 6. 归属：主仓库、普通目录、已删除路径
  assert.equal(worktreeOwner(repo), repo);
  assert.equal(worktreeOwner(root), root);
  assert.equal(worktreeOwner(path.join(root, "deleted")), path.join(root, "deleted"));

  console.log("Desktop worktree regression passed · unified command, verification, project mode, ownership");
}

run()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => fs.rmSync(root, { recursive: true, force: true }));
