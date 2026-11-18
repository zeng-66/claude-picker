const base = require("./package.json").build;
const build = require("./build-info.json");
const suffix =
  { release: "", prerelease: "Preview", test: "Test", dev: "Dev" }[
    build.channel
  ] || "Dev";
module.exports = {
  ...base,
  appId: base.appId + (suffix ? "." + build.channel : ""),
  productName: "ClaudePicker" + suffix,
  win: {
    ...base.win,
    artifactName:
      "ClaudePicker" + suffix + "-${version}-windows-${arch}.${ext}",
  },
  extraMetadata: { version: build.version },
};
