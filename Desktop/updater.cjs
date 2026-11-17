const fs = require("node:fs/promises");
const path = require("node:path");
const { createHash, randomUUID } = require("node:crypto");
const { spawn } = require("node:child_process");

const repository = "zeng-66/claude-picker";
const apiRoot = `https://api.github.com/repos/${repository}`;
const releaseRoot = `https://github.com/${repository}/releases/download/main-latest/`;
function validateManifest(manifest, head, platform) {
  if (
    manifest.schema !== 1 ||
    manifest.branch !== "main" ||
    manifest.commit !== head ||
    !/^[a-f0-9]{40}$/.test(manifest.commit) ||
    typeof manifest.version !== "string"
  )
    throw new Error("更新清单与 main 最新提交不匹配");
  const asset = manifest.assets?.[platform];
  if (!asset) return null;
  const url = new URL(asset.url);
  if (
    url.origin !== "https://github.com" ||
    !url.href.startsWith(releaseRoot) ||
    !/^[a-f0-9]{64}$/.test(asset.sha256) ||
    !Number.isSafeInteger(asset.size) ||
    asset.size <= 0 ||
    asset.size > 1024 * 1024 * 1024
  )
    throw new Error("安装包信息无效");
  if (platform === "win32-x64" && !url.pathname.endsWith(".exe"))
    throw new Error("Windows 安装包格式无效");
  return asset;
}
class MainUpdater {
  constructor({ dataPath, app, beforeInstall, fetchImpl = fetch }) {
    this.dataPath = dataPath;
    this.app = app;
    this.beforeInstall = beforeInstall;
    this.fetch = fetchImpl;
    try {
      this.build = require("./build-info.json");
    } catch {
      this.build = { commit: "", version: app.getVersion(), dirty: true };
    }
    this.platform = process.platform + "-" + process.arch;
    this.state = "idle";
    this.busy = false;
  }
  status() {
    return {
      version: this.build.version,
      commit: this.build.commit,
      platform: this.platform,
      state: this.state,
      latestVersion: this.manifest?.version,
      latestCommit: this.manifest?.commit,
    };
  }
  async json(url) {
    const response = await this.fetch(url, {
      signal: AbortSignal.timeout(30000),
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "ClaudePicker",
      },
    });
    if (response.status === 404) return null;
    if (!response.ok) throw new Error(`检查更新失败 HTTP ${response.status}`);
    const text = await response.text();
    if (text.length > 1024 * 1024) throw new Error("更新响应过大");
    return JSON.parse(text);
  }
  async check() {
    const head = await this.json(apiRoot + "/commits/main");
    if (!head?.sha) {
      this.state = "unpublished";
      return this.status();
    }
    if (head.sha === this.build.commit && !this.build.dirty) {
      this.state = "current";
      return this.status();
    }
    const manifest = await this.json(releaseRoot + "manifest.json");
    if (
      !manifest ||
      manifest.commit !== head.sha ||
      !manifest.assets?.[this.platform]
    ) {
      this.state = "unpublished";
      return this.status();
    }
    this.asset = validateManifest(manifest, head.sha, this.platform);
    this.manifest = manifest;
    this.state = "available";
    return this.status();
  }
  async download() {
    await this.check();
    if (this.state !== "available") return this.status();
    const directory = path.join(this.dataPath, "updates");
    await fs.mkdir(directory, { recursive: true });
    const temporary = path.join(directory, randomUUID() + ".part");
    const destination = path.join(
      directory,
      "ClaudePicker-" + this.manifest.commit + ".exe",
    );
    const response = await this.fetch(this.asset.url, {
      signal: AbortSignal.timeout(600000),
    });
    if (!response.ok || !response.body) throw new Error("下载更新失败");
    const handle = await fs.open(temporary, "wx");
    const hash = createHash("sha256");
    let size = 0;
    try {
      for await (const chunk of response.body) {
        size += chunk.length;
        if (size > this.asset.size) throw new Error("安装包大小与清单不一致");
        hash.update(chunk);
        await handle.writeFile(chunk);
      }
      if (size !== this.asset.size || hash.digest("hex") !== this.asset.sha256)
        throw new Error("安装包 SHA-256 校验失败，请重新下载");
      await handle.close();
      await fs.rename(temporary, destination);
    } catch (error) {
      await handle.close().catch(() => {});
      await fs.rm(temporary, { force: true });
      throw error;
    }
    this.installer = destination;
    this.state = "ready";
    return this.status();
  }
  async install() {
    if (this.state !== "ready" || !this.installer)
      throw new Error("请先下载更新");
    this.beforeInstall();
    const contents = await fs.readFile(this.installer);
    if (
      createHash("sha256").update(contents).digest("hex") !== this.asset.sha256
    ) {
      this.state = "available";
      throw new Error("安装包已变化，请重新下载");
    }
    const child = spawn(this.installer, [], {
      detached: true,
      stdio: "ignore",
      windowsHide: false,
    });
    await new Promise((resolve, reject) => {
      child.once("spawn", resolve);
      child.once("error", reject);
    });
    child.unref();
    this.state = "installing";
    setTimeout(() => this.app.quit(), 500);
    return this.status();
  }
  async request(method) {
    if (method === "update.status") return this.status();
    if (this.busy) throw new Error("更新正在处理中");
    this.busy = true;
    try {
      switch (method) {
        case "update.check":
          return await this.check();
        case "update.download":
          return await this.download();
        case "update.install":
          return await this.install();
        default:
          throw new Error("未知更新操作");
      }
    } finally {
      this.busy = false;
    }
  }
}
module.exports = { MainUpdater, validateManifest };
