const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { MainUpdater, validateManifest } = require("../../Desktop/updater.cjs");
const {
  git,
  gitRequest,
  fileRequest,
  inside,
} = require("../../Desktop/git.cjs");

async function run() {
  const root = await fs.mkdtemp(
    path.join(os.tmpdir(), "claude-picker-desktop-"),
  );
  try {
    await git(root, ["init"]);
    await git(root, ["config", "user.name", "Desktop Regression"]);
    await git(root, ["config", "user.email", "desktop@example.invalid"]);
    const filename = "file with spaces.txt";
    await fs.writeFile(path.join(root, filename), "original\n");
    let status = await gitRequest("git.status", { projectPath: root });
    assert.equal(status.files[0].untracked, true);
    await gitRequest("git.stage", { projectPath: root, paths: [filename] });
    await gitRequest("git.commit", { projectPath: root, message: "initial" });
    const initial = await fileRequest("file.read", {
      projectPath: root,
      filePath: filename,
    });
    await fileRequest("file.write", {
      projectPath: root,
      filePath: filename,
      content: "changed\n",
      expectedModifiedAt: initial.modifiedAt,
    });
    await assert.rejects(
      fileRequest("file.write", {
        projectPath: root,
        filePath: filename,
        content: "lost",
        expectedModifiedAt: "2000-01-01T00:00:00Z",
      }),
    );
    const diff = await gitRequest("git.diff", {
      projectPath: root,
      filePath: filename,
    });
    assert.equal(diff.additions, 1);
    assert.equal(diff.deletions, 1);
    assert.equal(
      (await gitRequest("git.log", { projectPath: root }))[0].message,
      "initial",
    );
    await assert.rejects(inside(root, "../escape"));
    await assert.rejects(
      gitRequest("git.switchBranch", { projectPath: root, branch: "--help" }),
    );

    const commit = "a".repeat(40);
    const bytes = Buffer.from("fake installer");
    const platform = process.platform + "-" + process.arch;
    const asset = {
      url: "https://github.com/zeng-66/claude-picker/releases/download/main-latest/test.exe",
      sha256: createHash("sha256").update(bytes).digest("hex"),
      size: bytes.length,
    };
    const manifest = {
      schema: 1,
      branch: "main",
      commit,
      version: "1.0.1",
      assets: { [platform]: asset, "win32-x64": asset },
    };
    assert.equal(validateManifest(manifest, commit, platform), asset);
    assert.throws(() =>
      validateManifest({ ...manifest, branch: "master" }, commit, platform),
    );
    assert.throws(() => validateManifest(manifest, "b".repeat(40), platform));
    assert.throws(() =>
      validateManifest(
        {
          ...manifest,
          assets: {
            [platform]: { ...asset, url: "https://example.invalid/test.exe" },
          },
        },
        commit,
        platform,
      ),
    );
    let payload = bytes;
    const fetchImpl = async (url) => {
      if (url.includes("/commits/main"))
        return new Response(JSON.stringify({ sha: commit }));
      if (url.endsWith("manifest.json"))
        return new Response(JSON.stringify(manifest));
      return new Response(payload);
    };
    const updater = new MainUpdater({
      dataPath: root,
      app: { getVersion: () => "1.0.0" },
      beforeInstall: () => {},
      fetchImpl,
    });
    updater.build = { version: "1.0.0", commit: "b".repeat(40), dirty: false };
    assert.equal((await updater.request("update.check")).state, "available");
    assert.equal((await updater.request("update.download")).state, "ready");
    assert.equal(
      (await fs.readFile(updater.installer)).toString(),
      bytes.toString(),
    );
    payload = Buffer.from("tampered");
    await assert.rejects(updater.request("update.download"), /校验|大小/);
    assert.equal(
      (await fs.readdir(path.join(root, "updates"))).filter((file) =>
        file.endsWith(".part"),
      ).length,
      0,
    );
    updater.build.commit = commit;
    assert.equal((await updater.request("update.check")).state, "current");
    updater.build.dirty = true;
    updater.fetch = async (url) =>
      url.endsWith("/commits/main")
        ? new Response(JSON.stringify({ sha: commit }))
        : new Response("", { status: 404 });
    assert.equal((await updater.request("update.check")).state, "unpublished");
    console.log(
      "Desktop regression passed · Git, file concurrency, main-only updates, download integrity",
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}
run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
