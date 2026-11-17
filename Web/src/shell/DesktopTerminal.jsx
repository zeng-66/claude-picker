import React, { useEffect, useRef } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { request } from './bridge.js';

export default function DesktopTerminal({ sessionId, fontSize }) {
  const element = useRef(null);
  useEffect(() => {
    const terminal = new Terminal({
      fontSize,
      fontFamily: 'Consolas, monospace',
      cursorBlink: true,
      theme: { background: '#111214', foreground: '#e0e0e4' },
    });
    const fit = new FitAddon();
    terminal.loadAddon(fit);
    terminal.open(element.current);
    let attached = false;
    let disposed = false;
    const queued = [];
    const unsubscribe = window.claudeDesktop.on('terminal:data', (event) => {
      if (event.sessionId !== sessionId) return;
      if (attached) terminal.write(event.data);
      else queued.push(event);
    });
    const data = terminal.onData((value) =>
      request('terminal.write', { sessionId, data: value }).catch(() => {}),
    );
    const resize = () => {
      if (!element.current?.clientWidth || !element.current?.clientHeight) return;
      fit.fit();
      request('terminal.resize', { sessionId, cols: terminal.cols, rows: terminal.rows }).catch(
        () => {},
      );
    };
    const observer = new ResizeObserver(resize);
    observer.observe(element.current);
    request('terminal.attach', { sessionId })
      .then(({ buffer, sequence }) => {
        if (disposed) return;
        terminal.write(buffer);
        for (const event of queued) if (event.sequence > sequence) terminal.write(event.data);
        attached = true;
        resize();
      })
      .catch((error) => terminal.writeln(error.message));
    terminal.focus();
    return () => {
      disposed = true;
      unsubscribe();
      data.dispose();
      observer.disconnect();
      terminal.dispose();
    };
  }, [sessionId, fontSize]);
  return (
    <div
      ref={element}
      style={{ flex: 1, minHeight: 0, padding: '38px 12px 8px', overflow: 'hidden' }}
    />
  );
}
