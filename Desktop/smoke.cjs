const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

async function smokeTest() {
  const pty = require("node-pty");
  const marker =
    process.env.CLAUDE_PICKER_SMOKE_FILE ||
    path.join(os.tmpdir(), "claude-picker-windows-smoke.txt");
  await new Promise((resolve, reject) => {
    const terminal = pty.spawn(
      "powershell.exe",
      [
        "-NoLogo",
        "-NoProfile",
        "-Command",
        "[Console]::WriteLine('CLAUDE_PICKER_PTY_OK')",
      ],
      { cols: 80, rows: 24, cwd: os.homedir(), env: process.env },
    );
    let output = "";
    const timer = setTimeout(() => {
      terminal.kill();
      reject(new Error("ConPTY smoke test timed out"));
    }, 15000);
    terminal.onData((data) => {
      output += data;
    });
    terminal.onExit(({ exitCode }) => {
      clearTimeout(timer);
      if (exitCode !== 0 || !output.includes("CLAUDE_PICKER_PTY_OK")) {
        reject(new Error("ConPTY output missing"));
        return;
      }
      fs.writeFileSync(marker, "CLAUDE_PICKER_PTY_OK\n");
      resolve();
    });
  });
}
module.exports = { smokeTest };
