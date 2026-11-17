const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("claudeDesktop", {
  platform: process.platform,
  request: (method, params) => ipcRenderer.invoke("bridge", method, params),
  on: (name, listener) => {
    const receive = (_event, detail) => listener(detail);
    ipcRenderer.on(name, receive);
    return () => ipcRenderer.removeListener(name, receive);
  },
});
