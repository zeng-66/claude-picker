const {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  protocol,
  net,
  shell,
} = require("electron");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { DesktopRuntime } = require("./runtime.cjs");
const { MainUpdater } = require("./updater.cjs");

let channel = "dev";
try {
  channel = require("./build-info.json").channel;
} catch {}
if (channel !== "release")
  app.setPath(
    "userData",
    path.join(app.getPath("appData"), "ClaudePicker-" + channel),
  );

protocol.registerSchemesAsPrivileged([
  {
    scheme: "claude-picker",
    privileges: { standard: true, secure: true, supportFetchAPI: true },
  },
]);
if (!app.requestSingleInstanceLock()) app.quit();
let window;
let runtime;
app.on("second-instance", () => {
  window?.show();
  window?.focus();
});

app.whenReady().then(async () => {
  if (process.argv.includes("--smoke-test")) {
    try {
      await require("./smoke.cjs").smokeTest();
      app.exit(0);
    } catch (error) {
      console.error(error);
      app.exit(1);
    }
    return;
  }
  const webRoot = app.isPackaged
    ? path.join(process.resourcesPath, "web")
    : path.resolve(__dirname, "../Web/dist");
  protocol.handle("claude-picker", (request) => {
    const url = new URL(request.url);
    const target = path.resolve(
      webRoot,
      "." + decodeURIComponent(url.pathname),
    );
    if (url.hostname !== "app" || !target.startsWith(webRoot + path.sep))
      return new Response("Forbidden", { status: 403 });
    return net.fetch(pathToFileURL(target).href);
  });
  window = new BrowserWindow({
    width: 1440,
    height: 940,
    minWidth: 900,
    minHeight: 640,
    backgroundColor: "#111214",
    title: "ClaudePicker",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  window.removeMenu();
  const emit = (name, value) => {
    if (!window.isDestroyed()) window.webContents.send(name, value);
  };
  runtime = new DesktopRuntime({
    dataPath: app.getPath("userData"),
    emit,
    dialog,
    shell,
    window,
  });
  const updater = new MainUpdater({
    dataPath: app.getPath("userData"),
    app,
    beforeInstall: () => runtime.assertIdle(),
  });
  ipcMain.handle("bridge", async (event, method, params = {}) => {
    if (
      event.sender !== window.webContents ||
      event.senderFrame !== window.webContents.mainFrame ||
      !event.senderFrame.url.startsWith("claude-picker://app/")
    ) {
      return {
        ok: false,
        error: { code: "FORBIDDEN", message: "无效的调用来源" },
      };
    }
    try {
      const result = method.startsWith("update.")
        ? await updater.request(method)
        : await runtime.request(method, params);
      return { ok: true, result: result ?? null };
    } catch (error) {
      return {
        ok: false,
        error: {
          code: error.code || "COMMAND_FAILED",
          message: error.message,
          detail: error.detail || null,
        },
      };
    }
  });
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https:\/\//.test(url)) shell.openExternal(url);
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.webContents.on("before-input-event", (event, input) => {
    if (input.type !== "keyDown" || !input.control || input.alt || input.shift)
      return;
    const name = {
      n: "newSession",
      j: "toggleTerminal",
      b: "toggleSidebar",
      k: "search",
      ",": "openSettings",
    }[input.key.toLowerCase()];
    if (name) {
      event.preventDefault();
      emit("claude-picker:command", { name });
    }
  });
  window.webContents.session.setPermissionRequestHandler(
    (_contents, _permission, callback) => callback(false),
  );
  window.on("close", (event) => {
    if (!runtime.hasSessions()) return;
    const result = dialog.showMessageBoxSync(window, {
      type: "question",
      message: "退出将关闭正在运行的终端会话。",
      buttons: ["继续使用", "退出"],
      defaultId: 0,
      cancelId: 0,
    });
    if (result === 0) event.preventDefault();
  });
  window.loadURL("claude-picker://app/index.html");
});
app.on("before-quit", () => runtime?.dispose());
app.on("window-all-closed", () => app.quit());
