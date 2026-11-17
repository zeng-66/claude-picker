import React, { useState } from "react";

// PROTOTYPE. Update states and versions are illustrative, with no network or installer side effects.
export default function VersionUpdates() {
  const [platform, setPlatform] = useState("Windows x64");
  const [scenario, setScenario] = useState("available");
  const [phase, setPhase] = useState("idle");
  const [progress, setProgress] = useState(0);
  function check() {
    setPhase("checking");
    setTimeout(() => setPhase(scenario), 650);
  }
  function download() {
    setPhase("downloading");
    setProgress(0);
    let value = 0;
    const timer = setInterval(() => {
      value += 20;
      setProgress(value);
      if (value === 100) {
        clearInterval(timer);
        setPhase("ready");
      }
    }, 250);
  }
  return (
    <>
      <h3>版本更新</h3>
      <p>获取 main 分支最新构建的正式版，下载完成后安装。</p>
      <div className="field">
        当前版本 <strong>演示版本 · {platform}</strong>
      </div>
      <div className="field">
        更新来源 <code>zeng-66/claude-picker · main</code>
      </div>
      <div className="settings-inline">
        <button
          className="primary"
          disabled={["checking", "downloading"].includes(phase)}
          onClick={check}
        >
          {phase === "checking" ? "检查中…" : "检查更新"}
        </button>
        <button onClick={() => setPhase("packages")}>下载安装包</button>
      </div>
      <div aria-live="polite" style={{ marginTop: 20 }}>
        {phase === "available" && (
          <>
            <h4>发现 main 最新构建</h4>
            <p>提交示例 · 改进设置与跨平台支持</p>
            <button className="primary" onClick={download}>
              下载更新
            </button>
          </>
        )}
        {phase === "current" && <p>已是 main 最新构建。</p>}
        {phase === "unpublished" && (
          <p>main 有新提交，安装包尚未发布。稍后重新检查。</p>
        )}
        {phase === "error" && (
          <>
            <p role="alert">连接失败，请检查网络后重试。</p>
            <button onClick={check}>重试</button>
          </>
        )}
        {phase === "downloading" && (
          <>
            <p>下载中 {progress}%</p>
            <progress max="100" value={progress} />
          </>
        )}
        {phase === "ready" && (
          <>
            <p>下载与校验完成。</p>
            <button className="primary" onClick={() => setPhase("installed")}>
              退出并安装
            </button>
            <button onClick={() => setPhase("idle")}>稍后</button>
          </>
        )}
        {phase === "installed" && (
          <p>已演示退出与安装流程。正式版安装完成后重新启动应用。</p>
        )}
        {phase === "packages" && (
          <>
            <h4>选择安装包</h4>
            {["Windows x64", "macOS Apple Silicon"].map((value) => (
              <p key={value}>
                <button
                  onClick={() => {
                    setPlatform(value);
                    download();
                  }}
                >
                  {value} · 下载
                </button>
              </p>
            ))}
          </>
        )}
      </div>
      <details style={{ marginTop: 28 }}>
        <summary>原型场景</summary>
        <p>此处用于批注时复现不同更新状态。</p>
        <label>
          系统{" "}
          <select
            value={platform}
            onChange={(e) => {
              setPlatform(e.target.value);
              setPhase("idle");
            }}
          >
            <option>Windows x64</option>
            <option>macOS Apple Silicon</option>
          </select>
        </label>
        <label>
          {" "}
          检查结果{" "}
          <select
            value={scenario}
            onChange={(e) => {
              setScenario(e.target.value);
              setPhase("idle");
            }}
          >
            <option value="available">有新版本</option>
            <option value="current">已是最新</option>
            <option value="unpublished">等待 main 构建</option>
            <option value="error">网络失败</option>
          </select>
        </label>
      </details>
    </>
  );
}
