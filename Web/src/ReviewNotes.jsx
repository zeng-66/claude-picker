import React, { useRef, useState } from 'react';
import './review-notes.css';

const storageKey = 'cp.h5-review.notes';

function readNotes() {
  try {
    const notes = JSON.parse(localStorage.getItem(storageKey) ?? '[]');
    return Array.isArray(notes) ? notes : [];
  } catch {
    return [];
  }
}

export default function ReviewNotes() {
  const [notes, setNotes] = useState(readNotes);
  const [target, setTarget] = useState('');
  const [comment, setComment] = useState('');
  const [error, setError] = useState('');
  const dialog = useRef(null);

  function storeNotes(next) {
    setNotes(next);
    try {
      localStorage.setItem(storageKey, JSON.stringify(next));
      setError('');
    } catch {
      setError('浏览器保存失败，可导出本次批注。');
    }
  }

  function save(event) {
    event.preventDefault();
    if (!target.trim() || !comment.trim()) return;
    storeNotes([...notes, {
      id: crypto.randomUUID(),
      target: target.trim(),
      text: comment.trim(),
      createdAt: new Date().toISOString(),
    }]);
    setComment('');
  }

  function download() {
    const file = new Blob([JSON.stringify({ prototype: 'claude-picker-h5-review', notes }, null, 2)], {
      type: 'application/json',
    });
    const url = URL.createObjectURL(file);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'claude-picker-h5-review.json';
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  return (
    <div className="h5-review-notes" onKeyDown={(event) => event.stopPropagation()}>
      <button type="button" className="h5-review-trigger" aria-haspopup="dialog" onClick={() => dialog.current.showModal()}>
        批注{notes.length ? ` (${notes.length})` : ''}
      </button>
      <dialog ref={dialog} aria-labelledby="h5-review-title"
        onClose={() => document.querySelector('[role="dialog"][aria-modal="true"]')?.focus()}>
        <header>
          <h2 id="h5-review-title">界面批注</h2>
          <button type="button" onClick={() => dialog.current.close()}>关闭</button>
        </header>
        <form onSubmit={save}>
          <label>页面或控件<input autoFocus value={target} onChange={(event) => setTarget(event.target.value)} /></label>
          <label>修改意见<textarea rows={4} value={comment} onChange={(event) => setComment(event.target.value)} /></label>
          <div className="h5-review-actions">
            <button type="submit" disabled={!comment.trim() || !target.trim()}>保存批注</button>
            <button type="button" disabled={!notes.length} onClick={download}>导出 JSON</button>
          </div>
        </form>
        {error && <p role="alert">{error}</p>}
        {notes.length > 0 && (
          <ol aria-label="已保存批注">
            {notes.map((note, index) => (
              <li key={note.id ?? index}>
                <b>{note.target}</b>
                <p>{note.text}</p>
                <button type="button" aria-label={`删除批注：${note.target}`}
                  onClick={() => storeNotes(notes.filter((item) => item !== note))}>删除</button>
              </li>
            ))}
          </ol>
        )}
      </dialog>
    </div>
  );
}
