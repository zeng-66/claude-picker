import React, { useEffect, useRef } from "react";
import {
  ArrowsInSimple,
  ArrowsOutSimple,
  Minus,
  Terminal,
} from "@phosphor-icons/react";
import appIcon from "./clawd-mark.png";
import { IconButton, useStored } from "./ui.jsx";

const clamp = (value, minimum, maximum) =>
  Math.max(minimum, Math.min(maximum, value));

export function TerminalTranscript({ active, messages = [] }) {
  return (
    <div
      className="prototype-terminal-output"
      role="log"
      aria-label="终端内容演示"
      aria-live="polite"
    >
      <p className="console-caption">Claude Code · 演示终端</p>
      <p className="console-muted">
        {active?.cwd || "~/project/claude-picker"}
      </p>
      <p>
        <span className="console-prompt">❯</span>{" "}
        {active?.label || "等待输入新的任务"}
      </p>
      <details className="terminal-command-record">
        <summary>会话上下文 · 查看输出</summary>
        <pre>{`工作目录：${active?.cwd || "~/project/claude-picker"}\n已读取项目上下文，可以继续当前会话。`}</pre>
      </details>
      {messages.map((message, index) => (
        <React.Fragment key={index}>
          <p>
            <span className="console-prompt">❯</span> {message}
          </p>
          <details className="terminal-command-record">
            <summary>处理记录 · 查看输出</summary>
            <pre>已收到这条输入。此处演示对应的终端输出。</pre>
          </details>
        </React.Fragment>
      ))}
    </div>
  );
}

export default function FloatingConsole({
  composer,
  active,
  messages,
  onRestore,
  forceOpen,
  onOpened,
}) {
  const [minimized, setMinimized] = useStored("consoleMinimized", true);
  const [size, setSize] = useStored("consoleSize", { width: 360, height: 214 });
  const [position, setPosition] = useStored("consolePosition", {
    x: Math.round(window.innerWidth * 0.3),
    y: Math.max(70, window.innerHeight - 292),
  });
  const moved = useRef(false);
  useEffect(() => {
    if (forceOpen) {
      setMinimized(false);
      onOpened?.();
    }
  }, [forceOpen]);
  const showOutput =
    size.width >= Math.min(520, window.innerWidth - 24) &&
    size.height >= Math.min(330, window.innerHeight - 116);

  function contain(nextSize, nextPosition) {
    const width = clamp(
      nextSize.width,
      280,
      Math.max(280, window.innerWidth - 24),
    );
    const height = clamp(
      nextSize.height,
      180,
      Math.max(180, window.innerHeight - 116),
    );
    const displayWidth = width;
    const displayHeight = height;
    setSize((current) =>
      current.width === width && current.height === height
        ? current
        : { width, height },
    );
    const x = clamp(nextPosition.x, 12, window.innerWidth - displayWidth - 12);
    const y = clamp(
      nextPosition.y,
      52,
      window.innerHeight - displayHeight - 64,
    );
    setPosition((current) =>
      current.x === x && current.y === y ? current : { x, y },
    );
  }

  useEffect(() => {
    const fit = () => contain(size, position);
    fit();
    window.addEventListener("resize", fit);
    return () => window.removeEventListener("resize", fit);
  }, [minimized, size.width, size.height, position.x, position.y]);

  function beginDrag(event) {
    if (event.button !== 0 || event.target.closest("[data-console-action]"))
      return;
    const handle = event.currentTarget;
    const start = { x: event.clientX, y: event.clientY, position };
    moved.current = false;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (pointer) => {
      const dx = pointer.clientX - start.x,
        dy = pointer.clientY - start.y;
      if (Math.hypot(dx, dy) <= 4 && !moved.current) return;
      moved.current = true;
      setPosition({
        x: clamp(
          start.position.x + dx,
          12,
          window.innerWidth - size.width - 12,
        ),
        y: clamp(
          start.position.y + dy,
          52,
          window.innerHeight - size.height - 64,
        ),
      });
    };
    const finish = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
      setTimeout(() => {
        moved.current = false;
      }, 0);
    };
    handle.onpointerup = finish;
    handle.onpointercancel = finish;
  }

  function beginResize(event, corner) {
    if (event.button !== 0) return;
    event.preventDefault();
    const handle = event.currentTarget;
    const start = { x: event.clientX, y: event.clientY, size, position };
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (pointer) => {
      const direction = corner === "top-left" ? -1 : 1;
      const width = clamp(
        start.size.width + direction * (pointer.clientX - start.x),
        280,
        corner === "top-left"
          ? start.position.x + start.size.width - 12
          : window.innerWidth - start.position.x - 12,
      );
      const height = clamp(
        start.size.height + direction * (pointer.clientY - start.y),
        180,
        corner === "top-left"
          ? start.position.y + start.size.height - 52
          : window.innerHeight - start.position.y - 64,
      );
      setSize({ width, height });
      if (corner === "top-left")
        setPosition({
          x: start.position.x + start.size.width - width,
          y: start.position.y + start.size.height - height,
        });
    };
    const finish = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
    };
    handle.onpointerup = finish;
    handle.onpointercancel = finish;
  }

  function resizeWithKey(event) {
    const delta = {
      ArrowRight: [20, 0],
      ArrowLeft: [-20, 0],
      ArrowDown: [0, 20],
      ArrowUp: [0, -20],
    }[event.key];
    if (!delta) return;
    event.preventDefault();
    event.stopPropagation();
    contain(
      { width: size.width + delta[0], height: size.height + delta[1] },
      position,
    );
  }

  if (minimized) return null;
  return (
    <section
      className={`floating-composer floating-console ${showOutput ? "show-output" : ""} ${position.y < 220 ? "near-top" : ""}`}
      style={{
        left: position.x,
        top: position.y,
        width: size.width,
        height: size.height,
      }}
      aria-label="悬浮终端"
    >
      <div className="floating-composer-header" onPointerDown={beginDrag}>
        <img src={appIcon} alt="" />
        <span>{active?.label || "新对话"}</span>
        <div data-console-action>
          <IconButton
            icon={showOutput ? ArrowsInSimple : ArrowsOutSimple}
            label={showOutput ? "收起终端内容" : "展开终端内容"}
            onClick={() =>
              contain(
                showOutput
                  ? { width: 360, height: 214 }
                  : { width: 620, height: 420 },
                position,
              )
            }
          />
        </div>
        <div data-console-action>
          <IconButton
            icon={Minus}
            label="收起到桌宠"
            onClick={() => setMinimized(true)}
          />
        </div>
        <div data-console-action>
          <IconButton
            icon={Terminal}
            label="在工作空间展开终端"
            onClick={onRestore}
          />
        </div>
      </div>
      {showOutput && <TerminalTranscript active={active} messages={messages} />}
      {composer}
      <button
        className="console-resize top-left"
        aria-label="从左上角调整悬浮窗大小"
        title="拖动缩放"
        onPointerDown={(event) => beginResize(event, "top-left")}
        onKeyDown={resizeWithKey}
      />
      <button
        className="console-resize bottom-right"
        aria-label="调整悬浮窗大小"
        title="拖动缩放，方向键微调"
        onPointerDown={(event) => beginResize(event, "bottom-right")}
        onKeyDown={resizeWithKey}
      />
    </section>
  );
}
