import React, { useState } from "react";
import "./prototype.css";

const storageKey = "claude-picker-prototype-v002-notes";
function readNotes() {
  try {
    return JSON.parse(localStorage.getItem(storageKey) || "[]");
  } catch {
    return [];
  }
}

export default function PrototypeNotes() {
  const [open, setOpen] = useState(false);
  const [notes, setNotes] = useState(readNotes);
  const [text, setText] = useState("");
  const [target, setTarget] = useState("设置 / 版本更新");
  const [error, setError] = useState("");
  function save() {
    const next = [
      ...notes,
      {
        id: crypto.randomUUID(),
        target,
        text: text.trim(),
        createdAt: new Date().toISOString(),
      },
    ];
    setNotes(next);
    setText("");
    try {
      localStorage.setItem(storageKey, JSON.stringify(next));
      setError("");
    } catch {
      setError("浏览器保存失败，请立即导出批注。");
    }
  }
  function download() {
    const url = URL.createObjectURL(
      new Blob([JSON.stringify({ prototype: "v002", notes }, null, 2)], {
        type: "application/json",
      }),
    );
    const link = document.createElement("a");
    link.href = url;
    link.download = "claude-picker-v002-comments.json";
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  function remove(id) {
    const next = notes.filter((note) => note.id !== id);
    setNotes(next);
    try {
      localStorage.setItem(storageKey, JSON.stringify(next));
    } catch {
      setError("浏览器保存失败，请导出批注。");
    }
  }
  return (
    <aside
      className="prototype-notes"
      onKeyDown={(event) => event.stopPropagation()}
    >
      <button onClick={() => setOpen(!open)}>
        H5 v002 · 批注 ({notes.length})
      </button>
      {open && (
        <section>
          <h3>界面批注</h3>
          <p>
            当前 App
            界面快照与演示数据。批注保存在当前浏览器，导出后可纳入项目。
          </p>
          <label>
            页面或控件
            <input value={target} onChange={(e) => setTarget(e.target.value)} />
          </label>
          <label>
            修改意见
            <textarea
              rows="4"
              value={text}
              onChange={(e) => setText(e.target.value)}
            />
          </label>
          <button disabled={!text.trim() || !target.trim()} onClick={save}>
            保存批注
          </button>
          <button onClick={download}>导出批注 JSON</button>
          {error && <p role="alert">{error}</p>}
          <ol>
            {notes.map((note) => (
              <li key={note.id}>
                <strong>{note.target}</strong>
                <p>{note.text}</p>
                <button onClick={() => remove(note.id)}>删除这条批注</button>
              </li>
            ))}
          </ol>
        </section>
      )}
    </aside>
  );
}
