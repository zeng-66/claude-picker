const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const root = path.resolve(__dirname, "..");
const git = (args) =>
  execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
const build = {
  version: process.env.VERSION || require("../Desktop/package.json").version,
  commit: git(["rev-parse", "HEAD"]),
  branch: git(["branch", "--show-current"]),
  dirty: Boolean(git(["status", "--porcelain", "--untracked-files=normal"])),
};
build.channel =
  { main: "release", master: "prerelease", test: "test" }[build.branch] ||
  "dev";
fs.writeFileSync(
  path.join(root, "Desktop/build-info.json"),
  JSON.stringify(build, null, 2) + "\n",
);
console.log(
  `Desktop ${build.version} ${build.commit.slice(0, 12)} ${build.dirty ? "working-tree" : "clean"}`,
);
