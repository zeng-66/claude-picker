import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// WebView 内以相对路径加载资源，base 必须是 "./"，不能是 "/"。
export default defineConfig({
  base: "./",
  build: {
    outDir: "dist"
  },
  optimizeDeps: {
    include: ["react", "react-dom/client"]
  },
  server: {
    host: "0.0.0.0",
    port: 5173,
    allowedHosts: ["terminal.local"],
    warmup: {
      clientFiles: ["./src/main.jsx"]
    }
  },
  plugins: [react()]
});
