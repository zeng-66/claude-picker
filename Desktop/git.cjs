const { execFile } = require("node:child_process");
const { promisify } = require("node:util");
const fs = require("node:fs/promises");
const path = require("node:path");
const execute = promisify(execFile);

async function git(cwd, args, allowFailure = false) {
  try {
    const { stdout } = await execute(
      "git",
      ["--literal-pathspecs", "-c", "core.quotepath=false", ...args],
      {
        cwd,
        windowsHide: true,
        maxBuffer: 16 * 1024 * 1024,
        timeout: 120000,
        encoding: "utf8",
      },
    );
    return stdout;
  } catch (error) {
    if (allowFailure) return "";
    const failure = new Error(
      error.code === "ENOENT" ? "请先安装 Git 并加入 PATH。" : "Git 操作失败",
    );
    failure.detail = error.stderr || error.message;
    failure.code = "GIT_FAILED";
    throw failure;
  }
}
function ref(value) {
  if (
    typeof value !== "string" ||
    !value ||
    value.startsWith("-") ||
    /[\x00-\x20]/.test(value)
  )
    throw new Error("无效的 Git 引用");
  return value;
}
function kind(file) {
  if (/\.(md|markdown)$/i.test(file)) return "markdown";
  if (/\.(png|jpe?g|gif|webp|ico)$/i.test(file)) return "image";
  return "code";
}
async function inside(root, relative = ".") {
  if (
    typeof relative !== "string" ||
    path.isAbsolute(relative) ||
    relative.includes("\0")
  )
    throw new Error("需要项目内相对路径");
  const base = await fs.realpath(root);
  const candidate = path.resolve(base, relative);
  let resolved;
  try {
    resolved = await fs.realpath(candidate);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    resolved = path.join(
      await fs.realpath(path.dirname(candidate)),
      path.basename(candidate),
    );
  }
  const difference = path.relative(base, resolved);
  if (
    difference === ".." ||
    difference.startsWith(".." + path.sep) ||
    path.isAbsolute(difference)
  )
    throw new Error("文件路径超出项目目录");
  return resolved;
}
async function status(cwd) {
  const raw = await git(cwd, [
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
  ]);
  const records = raw.split("\0");
  const files = [];
  for (let index = 0; index < records.length; index++) {
    const record = records[index];
    if (!record) continue;
    const x = record[0],
      y = record[1],
      file = record.slice(3);
    const oldPath = /[RC]/.test(x + y) ? records[++index] : null;
    const untracked = x === "?";
    const conflicted = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].includes(
      x + y,
    );
    files.push({
      path: file,
      oldPath,
      kind: kind(file),
      state: conflicted ? "conflicted" : untracked ? "untracked" : "modified",
      label: conflicted ? "U" : untracked ? "?" : (x + y).trim()[0],
      staged: x !== " " && !untracked,
      unstaged: y !== " " || untracked,
      untracked,
      indexStatus: x,
      workTreeStatus: y,
      binary: null,
    });
  }
  const branch =
    (
      await git(cwd, ["symbolic-ref", "--quiet", "--short", "HEAD"], true)
    ).trim() || null;
  const upstream =
    (
      await git(cwd, ["rev-parse", "--abbrev-ref", "@{upstream}"], true)
    ).trim() || null;
  const counts = upstream
    ? (
        await git(cwd, [
          "rev-list",
          "--left-right",
          "--count",
          "HEAD...@{upstream}",
        ])
      )
        .trim()
        .split(/\s+/)
        .map(Number)
    : [0, 0];
  return {
    projectPath: cwd,
    branch,
    detachedHead: !branch,
    upstream,
    ahead: counts[0],
    behind: counts[1],
    files,
  };
}
async function log(cwd, params = {}) {
  const args = [
    "log",
    "--format=%H%x00%h%x00%s%x00%an%x00%ae%x00%aI%x00%P%x1e",
    `-n${Math.max(1, Math.min(500, Number(params.limit) || 50))}`,
    `--skip=${Math.max(0, Number(params.skip) || 0)}`,
  ];
  if (params.branch) args.push(ref(params.branch));
  const output = await git(cwd, args, true);
  return output
    .split("\x1e")
    .map((value) => value.trim())
    .filter(Boolean)
    .map((value) => {
      const [
        hash,
        shortHash,
        message,
        author,
        authorEmail,
        date,
        parents = "",
      ] = value.split("\0");
      return {
        hash,
        shortHash,
        message,
        author,
        authorEmail,
        date,
        parents: parents.split(" ").filter(Boolean),
      };
    });
}
async function fileRequest(method, params) {
  const target = await inside(params.projectPath, params.filePath || ".");
  if (method === "file.list") {
    const entries = await fs.readdir(target, { withFileTypes: true });
    return entries
      .filter(
        (entry) => ![".git", "node_modules", ".build"].includes(entry.name),
      )
      .map((entry) => ({
        name: entry.name,
        path: path
          .relative(params.projectPath, path.join(target, entry.name))
          .replaceAll("\\", "/"),
        isDirectory: entry.isDirectory(),
        kind: kind(entry.name),
      }));
  }
  const stat = await fs.stat(target);
  const modifiedAt = stat.mtime.toISOString();
  if (method === "file.stat")
    return {
      path: params.filePath,
      size: stat.size,
      modifiedAt,
      isDirectory: stat.isDirectory(),
    };
  if (method === "file.write") {
    if (params.expectedModifiedAt && params.expectedModifiedAt !== modifiedAt)
      throw new Error("文件已被其它程序修改，请重新载入后保存。");
    if (typeof params.content !== "string") throw new Error("缺少文件内容");
    const temporary =
      target + ".claude-picker-" + require("node:crypto").randomUUID();
    try {
      await fs.writeFile(temporary, params.content, { mode: stat.mode });
      const latest = await fs.stat(target);
      if (latest.mtimeMs !== stat.mtimeMs || latest.size !== stat.size)
        throw new Error("文件已被其它程序修改，请重新载入。");
      await fs.rename(temporary, target);
    } finally {
      await fs.rm(temporary, { force: true });
    }
    return { modifiedAt: (await fs.stat(target)).mtime.toISOString() };
  }
  const limit = Math.min(
    16 * 1024 * 1024,
    Number(params.maxBytes) || 1024 * 1024,
  );
  const handle = await fs.open(target, "r");
  const buffer = Buffer.alloc(Math.min(stat.size, limit));
  try {
    await handle.read(buffer);
  } finally {
    await handle.close();
  }
  const isBinary = buffer.includes(0);
  return {
    path: params.filePath,
    size: stat.size,
    modifiedAt,
    isBinary,
    content: isBinary ? null : buffer.toString("utf8"),
    truncated: stat.size > limit,
    kind: kind(target),
  };
}
// ---------- 工作树：统一命令与归属 ----------

// 与 ai-worktree `component()` 同一规则；见 docs/worktree-unified-entry-plan.md §3。
const WORKTREE_COMPONENT = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const WORKTREE_COMMAND_TIMEOUT = 120000;
const worktreeComponent = (value) => WORKTREE_COMPONENT.test(value) && !value.endsWith(".");

function worktreeError(message, detail) {
  const failure = new Error(message);
  failure.code = "COMMAND_FAILED";
  failure.recoverable = true;
  if (detail) failure.detail = detail;
  return failure;
}

async function canonical(target) {
  try {
    return await fs.realpath(target);
  } catch {
    return path.resolve(target);
  }
}

// 设置里的命令路径：空 = 项目内 `.worktrees` 模式；否则必须是可执行的绝对路径。
async function validateWorktreeCommand(raw) {
  const command = String(raw ?? "").trim();
  if (!command) return "";
  if (!path.isAbsolute(command)) throw worktreeError(`工作树命令必须是绝对路径：${command}`);
  let stat;
  try {
    stat = await fs.stat(command);
  } catch {
    throw worktreeError(`工作树命令不存在：${command}`);
  }
  if (!stat.isFile()) throw worktreeError(`工作树命令不存在：${command}`);
  if (process.platform !== "win32") {
    try {
      await fs.access(command, require("node:fs").constants.X_OK);
    } catch {
      throw worktreeError(`工作树命令没有执行权限：${command}`);
    }
  }
  return command;
}

async function runWorktreeCommand(command, args, timeout) {
  try {
    const { stdout } = await execute(command, args, {
      windowsHide: true,
      maxBuffer: 4 * 1024 * 1024,
      timeout,
      encoding: "utf8",
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    });
    return stdout;
  } catch (error) {
    if (error.killed || error.signal === "SIGTERM")
      throw worktreeError(`工作树命令超时（${Math.round(timeout / 1000)}s）`);
    if (typeof error.code === "string") throw worktreeError(`工作树命令不可用：${command}`, error.message);
    const stderr = String(error.stderr || "").trim();
    const prefix = `${path.basename(command)}: `;
    const lines = stderr.split("\n");
    const last = lines.findLast((line) => line.startsWith(prefix)) ?? lines.at(-1) ?? "";
    const message = last.startsWith(prefix) ? last.slice(prefix.length) : last;
    throw worktreeError(message || `工作树命令失败（退出码 ${error.code}）`);
  }
}

function parseWorktreeReply(stdout) {
  const line = String(stdout).split("\n").filter((item) => item.trim()).at(-1);
  let reply;
  try {
    reply = JSON.parse(line);
  } catch {
    return null;
  }
  if (!reply || !["created", "reused"].includes(reply.action)) return null;
  if (typeof reply.path !== "string" || !path.isAbsolute(reply.path)) return null;
  if (typeof reply.repo_root !== "string" || !path.isAbsolute(reply.repo_root)) return null;
  return reply;
}

async function commonDirectory(directory) {
  const raw = await git(directory, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  return canonical(raw.trim());
}

async function ensureUnifiedWorktree(input, commandSetting) {
  const command = await validateWorktreeCommand(commandSetting);
  const cwd = input.projectPath;
  const text = (value) => (typeof value === "string" ? value.trim() : "");
  const task = text(input.task);
  const name = text(input.name);
  const subtask = text(input.subtask);
  if (!task) throw worktreeError("统一工作树需要填写任务标识");
  for (const [label, value] of [["任务标识", task], ["名称", name], ["子任务", subtask]]) {
    if (value && !worktreeComponent(value))
      throw worktreeError(`${label}只能包含字母、数字、点、横线和下划线，最多 100 个字符：${value}`);
  }
  if (!worktreeComponent([task, name, subtask].filter(Boolean).join("-")))
    throw worktreeError("任务标识、名称和子任务合起来不能超过 100 个字符");
  const branch = text(input.branch);
  // 未指定基线时与项目模式一致，从项目当前分支起步。
  const base = text(input.baseBranch) || (await git(cwd, ["symbolic-ref", "--quiet", "--short", "HEAD"], true)).trim();
  if (branch) ref(branch);
  if (base) ref(base);
  const repo = await canonical(cwd);
  const args = ["ensure", `--repo=${repo}`, `--task=${task}`];
  if (name) args.push(`--name=${name}`);
  if (subtask) args.push(`--subtask=${subtask}`);
  if (base) args.push(`--base=${base}`);
  if (branch) args.push(`--branch=${branch}`);
  args.push("--json");
  const stdout = await runWorktreeCommand(command, args, WORKTREE_COMMAND_TIMEOUT);
  const reply = parseWorktreeReply(stdout);
  if (!reply) throw worktreeError("工作树命令返回格式无效", String(stdout).slice(0, 200));

  // 用 Git 复核：主仓库、登记、分支、common dir 任一不符都不登记会话。
  const list = await gitRequest("git.worktrees", { projectPath: cwd });
  if (!list.length || (await canonical(list[0].path)) !== (await canonical(reply.repo_root)))
    throw worktreeError(`工作树命令返回的主仓库与所选项目不一致：${reply.repo_root}`);
  const target = await canonical(reply.path);
  let entry = null;
  for (const item of list) if ((await canonical(item.path)) === target) entry = item;
  if (!entry) throw worktreeError(`返回的目录不在该仓库的 Git 工作树登记中：${reply.path}`);
  if (entry.isPrunable || entry.isBare) throw worktreeError(`Git 登记的工作树已不可用：${reply.path}`);
  if ((entry.branch ?? null) !== (reply.branch ?? null))
    throw worktreeError(`工作树的检出分支与命令返回不一致：${entry.branch ?? "detached HEAD"}`);
  if ((await commonDirectory(cwd)) !== (await commonDirectory(target)))
    throw worktreeError(`返回的目录属于另一个仓库：${reply.path}`);
  return {
    path: target,
    branch: entry.branch,
    action: reply.action,
    mode: "unified",
    task: reply.task ?? null,
    baseRef: reply.base_ref ?? null,
    baseCommit: reply.base_commit ?? null,
    head: entry.head ?? reply.head ?? null,
  };
}

// 项目内模式：只能建在 `<项目>/.worktrees/<slug>`，并确认 Git 忽略该目录（与 macOS 一致）。
async function createProjectWorktree(cwd, input) {
  const branch = ref(input.branch);
  const root = await canonical(cwd);
  const container = path.join(root, ".worktrees");
  const target = input.path
    ? path.resolve(root, input.path)
    : path.join(container, branch.replace(/[^a-z0-9_.-]+/gi, "-").replace(/^-+|-+$/g, "") || "worktree");
  if (path.dirname(target) !== container)
    throw Object.assign(new Error(`工作树必须直接建在项目的 .worktrees 目录下：${target}`), { code: "PERMISSION_DENIED" });
  if (require("node:fs").existsSync(target))
    throw Object.assign(new Error(`Worktree 路径已存在：${target}`), { code: "WORKTREE_PATH_EXISTS" });
  await fs.mkdir(container, { recursive: true });
  if ((await canonical(container)) !== container)
    throw Object.assign(new Error(`工作树目录必须位于项目内：${container}`), { code: "PERMISSION_DENIED" });
  const common = await commonDirectory(cwd);
  const exclude = path.join(common, "info", "exclude");
  const existing = await fs.readFile(exclude, "utf8").catch(() => "");
  if (!existing.split(/\r?\n/).map((line) => line.trim()).some((line) => line === ".worktrees" || line === ".worktrees/")) {
    await fs.mkdir(path.dirname(exclude), { recursive: true });
    await fs.writeFile(exclude, (existing && !existing.endsWith("\n") ? existing + "\n" : existing) + ".worktrees/\n");
  }
  try {
    // check-ignore 不支持 git() 统一加的 --literal-pathspecs，单独调用。
    await execute("git", ["check-ignore", "--quiet", "--", target], { cwd, windowsHide: true, timeout: 30000 });
  } catch {
    throw Object.assign(new Error("工作树目录未被 Git 忽略，请检查本机的 info/exclude 与仓库忽略规则"), { code: "PERMISSION_DENIED" });
  }
  await git(cwd, [
    "worktree",
    "add",
    "-b",
    branch,
    target,
    ...(input.baseBranch ? [ref(input.baseBranch)] : []),
  ]);
  return { path: target, branch, action: "created", mode: "project" };
}

// 会话 cwd → 主仓库。认 `<项目>/.worktrees/<名字>` 与任意位置的 linked worktree（读 `.git` 文件 → commondir），
// 读不到时保持原路径。同步、只读小文件，扫描时逐个调用。
function worktreeOwner(raw) {
  const marker = raw.search(/[\\/]\.worktrees[\\/][^\\/]+[\\/]?$/);
  if (marker > 0) return raw.slice(0, marker);
  const sync = require("node:fs");
  try {
    const line = sync.readFileSync(path.join(raw, ".git"), "utf8").split(/\r?\n/)[0];
    if (!line.startsWith("gitdir:")) return raw;
    const gitDir = path.resolve(raw, line.slice("gitdir:".length).trim());
    const pointer = sync.readFileSync(path.join(gitDir, "commondir"), "utf8").trim();
    if (!pointer) return raw;
    let common = path.resolve(gitDir, pointer);
    try {
      common = sync.realpathSync(common);
    } catch {}
    if (path.basename(common) !== ".git") return raw;
    const owner = path.dirname(common);
    return path.resolve(owner) === path.resolve(raw) ? raw : owner;
  } catch {
    return raw;
  }
}

async function gitRequest(method, p) {
  const cwd = p.projectPath ?? p.input?.projectPath;
  switch (method) {
    case "git.status":
      return status(cwd);
    case "git.log":
      return log(cwd, p);
    case "git.diff": {
      await inside(cwd, p.filePath);
      const current = await status(cwd);
      const untracked = current.files.find(
        (file) => file.path === p.filePath,
      )?.untracked;
      const patch = untracked
        ? `+++ b/${p.filePath}\n` +
          (await fs.readFile(await inside(cwd, p.filePath), "utf8"))
            .split("\n")
            .map((line) => "+" + line)
            .join("\n")
        : await git(cwd, [
            "diff",
            ...(p.staged ? ["--cached"] : []),
            "--",
            p.filePath,
          ]);
      return {
        path: p.filePath,
        staged: Boolean(p.staged),
        binary: patch.includes("Binary files"),
        additions: patch
          .split("\n")
          .filter((line) => line.startsWith("+") && !line.startsWith("+++"))
          .length,
        deletions: patch
          .split("\n")
          .filter((line) => line.startsWith("-") && !line.startsWith("---"))
          .length,
        patch,
      };
    }
    case "git.branches": {
      const raw = await git(cwd, [
        "for-each-ref",
        "--format=%(refname:short)%00%(HEAD)%00%(refname)%00%(upstream:short)%00%(upstream:track)%00%(objectname:short)",
        "refs/heads",
        "refs/remotes",
      ]);
      return raw
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => {
          const [name, head, full, upstream, track, lastCommit] =
            line.split("\0");
          return {
            name,
            isCurrent: head === "*",
            isRemote: full.startsWith("refs/remotes/"),
            upstream: upstream || null,
            ahead: Number(/ahead (\d+)/.exec(track)?.[1] || 0),
            behind: Number(/behind (\d+)/.exec(track)?.[1] || 0),
            upstreamGone: track.includes("gone"),
            lastCommit,
          };
        });
    }
    case "git.worktrees": {
      const raw = await git(cwd, ["worktree", "list", "--porcelain"]);
      return raw
        .trim()
        .split("\n\n")
        .filter(Boolean)
        .map((block) => {
          const fields = Object.fromEntries(
            block.split("\n").map((line) => {
              const split = line.indexOf(" ");
              return split === -1
                ? [line, true]
                : [line.slice(0, split), line.slice(split + 1)];
            }),
          );
          return {
            path: fields.worktree,
            head: fields.HEAD,
            branch: fields.branch?.replace("refs/heads/", "") || null,
            isBare: Boolean(fields.bare),
            isLocked: Boolean(fields.locked),
            isPrunable: Boolean(fields.prunable),
          };
        });
    }
    case "git.show": {
      const hash = ref(p.hash);
      const commits = await log(cwd, { branch: hash, limit: 1 });
      const patch = await git(cwd, ["show", "--format=", hash, "--"]);
      const stats = (
        await git(cwd, ["show", "--format=", "--numstat", hash, "--"])
      )
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => {
          const [add, del, file] = line.split("\t");
          return {
            path: file,
            additions: Number(add) || 0,
            deletions: Number(del) || 0,
            binary: add === "-",
          };
        });
      return {
        commit: commits[0],
        files: stats,
        additions: stats.reduce((sum, file) => sum + file.additions, 0),
        deletions: stats.reduce((sum, file) => sum + file.deletions, 0),
        patch,
      };
    }
    case "git.stage":
    case "git.unstage": {
      if (!Array.isArray(p.paths) || !p.paths.length)
        throw new Error("请选择文件");
      for (const file of p.paths) await inside(cwd, file);
      await git(
        cwd,
        method === "git.stage"
          ? ["add", "--", ...p.paths]
          : ["reset", "--", ...p.paths],
      );
      break;
    }
    case "git.commit": {
      if (!p.message?.trim()) throw new Error("请输入提交说明");
      await git(cwd, ["commit", "-m", p.message]);
      break;
    }
    case "git.switchWorkspaceBranch": {
      const snapshot = await gitRequest("git.status", p);
      if (snapshot.branch === p.branch) return { ok: true };
      if (snapshot.files.length) throw new Error("当前工作区有未提交改动，请先处理后再切换分支");
      return gitRequest("git.switchBranch", p);
    }
    case "git.switchBranch":
      await git(cwd, ["switch", ref(p.branch)]);
      break;
    case "git.createBranch":
      await git(cwd, ["branch", ref(p.name), ...(p.from ? [ref(p.from)] : [])]);
      break;
    case "git.deleteBranch":
      await git(cwd, ["branch", "-d", ref(p.branch)]);
      break;
    case "git.merge":
      await git(cwd, ["merge", ref(p.branch)]);
      break;
    case "git.fetch":
      await git(cwd, ["fetch", ...(p.remote ? [ref(p.remote)] : [])]);
      break;
    case "git.pull":
      await git(cwd, [
        "pull",
        "--ff-only",
        ...(p.remote ? [ref(p.remote)] : []),
      ]);
      break;
    case "git.push":
      await git(cwd, [
        "push",
        ...(p.remote ? [ref(p.remote)] : []),
        ...(p.branch ? [ref(p.branch)] : []),
      ]);
      break;
    case "git.mergeAbort":
      await git(cwd, ["merge", "--abort"]);
      break;
    case "git.mergeContinue":
      await git(cwd, ["-c", "core.editor=true", "merge", "--continue"]);
      break;
    case "git.mergeState": {
      const conflicts = (
        await git(cwd, ["diff", "--name-only", "--diff-filter=U"])
      )
        .trim()
        .split("\n")
        .filter(Boolean);
      const merge = (
        await git(cwd, ["rev-parse", "--verify", "MERGE_HEAD"], true)
      ).trim();
      return {
        merging: Boolean(merge),
        inProgress: Boolean(merge),
        conflicts,
        canContinue: Boolean(merge) && conflicts.length === 0,
      };
    }
    case "git.stashes": {
      const raw = await git(cwd, [
        "stash",
        "list",
        "--format=%gd%x00%H%x00%s%x00%aI",
      ]);
      return raw
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line, index) => {
          const [ref, hash, message, date] = line.split("\0");
          return { index, ref, hash, message, date };
        });
    }
    case "git.stashSave":
      await git(cwd, [
        "stash",
        "push",
        ...(p.includeUntracked ? ["-u"] : []),
        "-m",
        p.message || "ClaudePicker stash",
      ]);
      break;
    case "git.stashApply":
    case "git.stashPop":
    case "git.stashDrop": {
      if (!Number.isInteger(p.index) || p.index < 0)
        throw new Error("无效的 stash 序号");
      await git(cwd, [
        "stash",
        method.slice(9).toLowerCase(),
        `stash@{${p.index}}`,
      ]);
      break;
    }
    case "git.tags": {
      const raw = await git(cwd, [
        "tag",
        "--format=%(refname:short)%00%(objectname)%00%(creatordate:iso-strict)%00%(subject)",
      ]);
      return raw
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => {
          const [name, hash, date, subject] = line.split("\0");
          return { name, hash, date, subject };
        });
    }
    case "git.remotes": {
      const names = (await git(cwd, ["remote"]))
        .trim()
        .split("\n")
        .filter(Boolean);
      return Promise.all(
        names.map(async (name) => ({
          name,
          fetchURL: (await git(cwd, ["remote", "get-url", name])).trim(),
          pushURL: (
            await git(cwd, ["remote", "get-url", "--push", name])
          ).trim(),
        })),
      );
    }
    case "git.resolveConflict": {
      await inside(cwd, p.filePath);
      if (["ours", "theirs"].includes(p.strategy))
        await git(cwd, ["checkout", "--" + p.strategy, "--", p.filePath]);
      else if (p.strategy !== "mark") throw new Error("未知的冲突解决方式");
      await git(cwd, ["add", "--", p.filePath]);
      break;
    }
    case "git.reflog": {
      const raw = await git(cwd, [
        "reflog",
        "--format=%H%x00%gd%x00%gs%x00%aI",
        "-n" + Math.max(1, Math.min(500, Number(p.limit) || 60)),
      ]);
      return raw
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => {
          const [hash, selector, message, date] = line.split("\0");
          return { hash, selector, message, date };
        });
    }
    case "git.createWorktree": {
      const input = { ...(p.input || p), projectPath: cwd };
      const command = typeof input.command === "string" ? input.command.trim() : "";
      return command ? ensureUnifiedWorktree(input, command) : createProjectWorktree(cwd, input);
    }
    case "git.checkWorktreeCommand": {
      const command = await validateWorktreeCommand(p.command);
      if (!command) throw worktreeError("尚未填写工作树命令");
      const root = (await runWorktreeCommand(command, ["repo-root", `--repo=${await canonical(cwd)}`], 30000)).trim();
      if (!path.isAbsolute(root)) throw worktreeError("工作树命令返回格式无效", root.slice(0, 200));
      return { repoRoot: root, command };
    }
    case "git.removeWorktree": {
      const input = p.input || p;
      if (!input.path || input.path.startsWith("-"))
        throw new Error("无效的工作树路径");
      await git(cwd, [
        "worktree",
        "remove",
        ...(input.force ? ["--force"] : []),
        input.path,
      ]);
      break;
    }
    default:
      throw new Error(`Windows 尚未适配此操作 ${method}`);
  }
  return { ok: true };
}
module.exports = { git, inside, gitRequest, fileRequest, validateWorktreeCommand, worktreeOwner, parseWorktreeReply };
