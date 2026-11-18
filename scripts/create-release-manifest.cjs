const fs = require("node:fs");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { execFileSync } = require("node:child_process");
const directory = path.resolve(process.argv[2] || "release-assets");
const commit = execFileSync("git", ["rev-parse", "HEAD"], {
  encoding: "utf8",
}).trim();
const files = fs.readdirSync(directory);
const assets = {};
for (const [platform, suffix] of [
  ["win32-x64", "-windows-x64.exe"],
  ["darwin-arm64", "-macos-arm64.zip"],
]) {
  const filename = files.find((file) => file.endsWith(suffix));
  if (!filename) throw new Error(`缺少 ${platform} 安装包`);
  const bytes = fs.readFileSync(path.join(directory, filename));
  assets[platform] = {
    url: `https://github.com/zeng-66/claude-picker/releases/download/main-latest/${filename}`,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    size: bytes.length,
  };
}
const manifest = {
  schema: 1,
  branch: "main",
  commit,
  version: process.env.VERSION || require("../Desktop/package.json").version,
  assets,
};
fs.writeFileSync(
  path.join(directory, "manifest.json"),
  JSON.stringify(manifest, null, 2) + "\n",
);
console.log(`main ${commit.slice(0, 12)} manifest generated`);
