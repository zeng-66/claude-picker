// 工作区：变更文件（未暂存 / 已暂存）+ 提交表单 + 差异 / 预览 / 编辑。
import React, { Suspense, lazy, useEffect, useRef, useState } from 'react';
import {
  CaretDoubleLeft,
  CaretDown,
  CaretRight,
  Check,
  Checks,
  DotsThree,
  FileCode,
  FileText,
  GitCommit,
  MagnifyingGlass,
  Minus,
  Plus,
  Warning,
} from '@phosphor-icons/react';
import { errorText, request } from './bridge.js';
import { addedHunk, parsePatch } from './diff.js';
import DiffView from './DiffView.jsx';
import { IconButton, baseName, dirName, trackPaneDrag, useStored } from './ui.jsx';

const MarkdownRenderer = lazy(() => import('../MarkdownRenderer.jsx'));

const DEFAULT_ROWS = [46, 24, 30];
const DEFAULT_WIDTH = 228;
const EDIT_LIMIT = 1024 * 1024;

function isConflict(file) {
  const x = file.indexStatus ?? '';
  const y = file.workTreeStatus ?? '';
  return x === 'U' || y === 'U' || (x === 'A' && y === 'A') || (x === 'D' && y === 'D');
}

export function changeGroups(files) {
  const unstaged = [];
  const staged = [];
  for (const file of files ?? []) {
    const conflict = isConflict(file);
    if (file.untracked || file.unstaged || conflict)
      unstaged.push({
        ...file,
        group: false,
        letter: conflict ? 'U' : file.untracked ? '?' : file.workTreeStatus?.trim() || file.label,
        conflict,
      });
    if (file.staged && !conflict)
      staged.push({ ...file, group: true, letter: file.indexStatus?.trim() || file.label });
  }
  return { unstaged, staged };
}

function letterClass(entry) {
  if (entry.letter === 'U' || entry.letter === 'D') return 'red';
  if (entry.group) return 'green';
  return entry.letter === '?' ? 'blue' : 'amber';
}

export default function WorkspaceTab({ projectPath, status, statusError, stamp, refresh, notify }) {
  const [query, setQuery] = useState('');
  const [message, setMessage] = useState('');
  const [amend, setAmend] = useState(false);
  const [commitOptions, setCommitOptions] = useState({
    signOff: false,
    noVerify: false,
    allowEmpty: false,
  });
  const [optionsOpen, setOptionsOpen] = useState(false);
  const [committing, setCommitting] = useState(false);
  const [picked, setPicked] = useState(null);
  const [fileView, setFileView] = useState('差异');
  const [diffMode, setDiffMode] = useStored('diffMode', '统一');
  const [collapsed, setCollapsed] = useStored('changesCollapsed', false);
  const [changesWidth, setChangesWidth] = useStored('changesWidth', DEFAULT_WIDTH);
  const [changeRows, setChangeRows] = useStored('changeRows', DEFAULT_ROWS);
  const [diff, setDiff] = useState(null);
  const [content, setContent] = useState(null);
  const [drafts, setDrafts] = useState({});
  const [stale, setStale] = useState(false);
  const [saving, setSaving] = useState(false);
  const changesPaneRef = useRef(null);
  const changeSectionsRef = useRef(null);

  const files = status?.files ?? [];
  const { unstaged, staged } = changeGroups(files);
  const all = [...unstaged, ...staged];
  const selected =
    (picked && all.find((entry) => entry.path === picked.path && entry.group === picked.group)) ||
    (picked && all.find((entry) => entry.path === picked.path)) ||
    all[0] ||
    null;
  const selectedKey = selected ? `${selected.path}|${selected.group}` : '';
  const isDirectory = Boolean(selected?.path.endsWith('/'));
  const isDeleted = Boolean(selected && !selected.group && selected.letter === 'D');
  const matches = (entry) => entry.path.toLowerCase().includes(query.toLowerCase());

  // ---- 差异 ----
  useEffect(() => {
    if (!selected) {
      setDiff(null);
      return undefined;
    }
    let alive = true;
    const key = selectedKey;
    (async () => {
      try {
        let parsed;
        if (isDirectory) {
          parsed = { hunks: [], note: '未跟踪的目录：暂存后可查看其中的文件' };
        } else if (selected.untracked) {
          const file = await request('file.read', {
            projectPath,
            filePath: selected.path,
            maxBytes: EDIT_LIMIT,
          });
          parsed =
            file.isBinary || file.content == null
              ? {
                  hunks: [],
                  note: file.isBinary ? '二进制文件，无法显示差异' : '文件过大，无法显示差异',
                }
              : { ...addedHunk(file.content), deletions: 0 };
        } else {
          const result = await request(
            'git.diff',
            { projectPath, filePath: selected.path, staged: selected.group },
            { timeoutMs: 60000 },
          );
          parsed = {
            ...parsePatch(result.patch),
            additions: result.additions,
            deletions: result.deletions,
            note: result.binary ? '二进制文件，无法显示差异' : null,
          };
        }
        if (alive) setDiff({ key, error: null, ...parsed });
      } catch (error) {
        if (alive) setDiff({ key, hunks: [], error: errorText(error) });
      }
    })();
    return () => {
      alive = false;
    };
  }, [projectPath, selectedKey, selected?.untracked, stamp]);

  // ---- 文件内容（预览 / 编辑）----
  const contentStamp = fileView === '预览' ? stamp : 0;
  useEffect(() => {
    if (!selected || fileView === '差异' || isDirectory || isDeleted) return undefined;
    let alive = true;
    const path = selected.path;
    request('file.read', { projectPath, filePath: path, maxBytes: EDIT_LIMIT })
      .then((file) => {
        if (!alive) return;
        setContent({
          path,
          text: file.isBinary ? null : file.content,
          dataUrl: file.kind === 'image' ? file.content : null,
          kind: file.kind,
          size: file.size,
          modifiedAt: file.modifiedAt,
          isBinary: file.isBinary,
          error: null,
        });
      })
      .catch((error) => {
        if (alive) setContent({ path, text: null, error: errorText(error) });
      });
    return () => {
      alive = false;
    };
  }, [projectPath, selected?.path, fileView === '差异', contentStamp]);

  useEffect(() => setStale(false), [selected?.path]);

  // 「更多提交方式」弹层：点到外面就收起
  useEffect(() => {
    if (!optionsOpen) return undefined;
    const dismiss = (event) => {
      if (!event.target.closest('.commit-more')) setOptionsOpen(false);
    };
    window.addEventListener('pointerdown', dismiss);
    return () => window.removeEventListener('pointerdown', dismiss);
  }, [optionsOpen]);

  const loaded = content && selected && content.path === selected.path ? content : null;
  const savedText = loaded?.text ?? '';
  const draft = selected && drafts[selected.path] !== undefined ? drafts[selected.path] : savedText;
  const hasEdits = Boolean(loaded) && loaded.text != null && draft !== savedText;

  async function saveFile(force = false) {
    if (!selected || !loaded || saving) return;
    setSaving(true);
    try {
      const result = await request('file.write', {
        projectPath,
        filePath: selected.path,
        content: draft,
        ...(force ? {} : { expectedModifiedAt: loaded.modifiedAt }),
      });
      setContent({ ...loaded, text: draft, modifiedAt: result?.modifiedAt ?? loaded.modifiedAt });
      setDrafts(({ [selected.path]: _saved, ...rest }) => rest);
      setStale(false);
      notify(`已保存 ${baseName(selected.path)}`);
      refresh();
    } catch (error) {
      if (error.detail === 'STALE_FILE') setStale(true);
      else notify(errorText(error));
    } finally {
      setSaving(false);
    }
  }

  async function reloadFile() {
    if (!selected) return;
    setDrafts(({ [selected.path]: _dropped, ...rest }) => rest);
    setStale(false);
    setContent(null);
    try {
      const file = await request('file.read', {
        projectPath,
        filePath: selected.path,
        maxBytes: EDIT_LIMIT,
      });
      setContent({
        path: selected.path,
        text: file.isBinary ? null : file.content,
        dataUrl: file.kind === 'image' ? file.content : null,
        kind: file.kind,
        size: file.size,
        modifiedAt: file.modifiedAt,
        isBinary: file.isBinary,
        error: null,
      });
    } catch (error) {
      setContent({ path: selected.path, text: null, error: errorText(error) });
    }
  }

  // ---- 暂存 / 提交 ----
  async function gitWrite(method, params, done) {
    try {
      await request(method, { projectPath, ...params }, { timeoutMs: 60000 });
      if (done) notify(done);
    } catch (error) {
      notify(errorText(error));
    } finally {
      refresh();
    }
  }

  const pathsOf = (entry) => (entry.oldPath ? [entry.path, entry.oldPath] : [entry.path]);

  function toggleStage(entry) {
    if (picked?.path === entry.path || selected?.path === entry.path)
      setPicked({ path: entry.path, group: !entry.group });
    gitWrite(entry.group ? 'git.unstage' : 'git.stage', { paths: pathsOf(entry) });
  }

  const canCommit =
    !committing &&
    Boolean(message.trim()) &&
    (staged.length > 0 || amend || commitOptions.allowEmpty);

  async function commit() {
    if (!canCommit) return;
    setCommitting(true);
    try {
      const result = await request(
        'git.commit',
        { projectPath, message: message.trim(), options: { amend, ...commitOptions } },
        { timeoutMs: 120000 },
      );
      setMessage('');
      setAmend(false);
      setCommitOptions({ signOff: false, noVerify: false, allowEmpty: false });
      notify(`${result.amended ? '已改写提交' : '提交已创建'} ${result.shortHash}`);
    } catch (error) {
      // 失败保留输入内容：多半是 hooks 没过，改完还要再提
      notify(errorText(error));
    } finally {
      setCommitting(false);
      refresh();
    }
  }

  async function toggleAmend(checked) {
    setAmend(checked);
    if (!checked || message.trim()) return;
    try {
      const [last] = await request('git.log', { projectPath, limit: 1 });
      if (last?.message) setMessage((current) => current || last.message);
    } catch {
      /* 没有提交可改写时由 git 自己报错 */
    }
  }

  // ---- 变更栏尺寸 ----
  function resizeChangesWidth(event) {
    const pane = changesPaneRef.current;
    const startWidth = pane.getBoundingClientRect().width;
    const startX = event.clientX;
    const maximum = Math.max(170, pane.parentElement.getBoundingClientRect().width - 185);
    trackPaneDrag(event, (move) =>
      setChangesWidth(Math.max(170, Math.min(maximum, startWidth + move.clientX - startX))),
    );
  }

  function changeSectionHeights() {
    return [...changeSectionsRef.current.querySelectorAll('[data-change-section]')].map(
      (element) => element.getBoundingClientRect().height,
    );
  }

  function adjustedChangeRows(heights, divider, delta) {
    const next = [...heights];
    const pairHeight = heights[divider] + heights[divider + 1];
    const minimumBefore = Math.min(64, pairHeight * 0.3);
    const minimumAfter = Math.min(divider === 1 ? 160 : 64, pairHeight * 0.6);
    next[divider] = Math.max(
      minimumBefore,
      Math.min(pairHeight - minimumAfter, heights[divider] + delta),
    );
    next[divider + 1] = pairHeight - next[divider];
    return next;
  }

  function resizeChangeSections(event, divider) {
    const heights = changeSectionHeights();
    const startY = event.clientY;
    trackPaneDrag(event, (move) =>
      setChangeRows(adjustedChangeRows(heights, divider, move.clientY - startY)),
    );
  }

  function renderChangeDivider(divider) {
    return (
      <div
        className="change-row-divider"
        role="separator"
        aria-orientation="horizontal"
        aria-label={divider === 0 ? '调整未暂存与已暂存区域高度' : '调整文件列表与提交区域高度'}
        tabIndex={0}
        title="上下拖动调整高度，双击恢复默认"
        onPointerDown={(event) => resizeChangeSections(event, divider)}
        onDoubleClick={() => setChangeRows(DEFAULT_ROWS)}
        onKeyDown={(event) => {
          if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return;
          event.preventDefault();
          setChangeRows(
            adjustedChangeRows(changeSectionHeights(), divider, event.key === 'ArrowUp' ? -16 : 16),
          );
        }}
      >
        <span />
      </div>
    );
  }

  // ---- 右侧：差异 / 预览 / 编辑 ----
  function renderDiff() {
    const ready = diff && diff.key === selectedKey;
    return (
      <>
        <div className="diff-heading">
          <span>
            <FileCode size={16} />
            {selected ? baseName(selected.path.replace(/\/$/, '')) : '选择文件查看差异'}
          </span>
          <div className="segmented">
            {['并排', '统一'].map((mode) => (
              <button
                className={diffMode === mode ? 'chosen' : ''}
                onClick={() => setDiffMode(mode)}
                key={mode}
              >
                {mode}
              </button>
            ))}
          </div>
        </div>
        <div className="file-path">
          {selected.oldPath ? `${selected.oldPath} → ${selected.path}` : selected.path}
          <span>
            <b className="green">+{ready ? (diff.additions ?? 0) : 0}</b>
            <b className="red">−{ready ? (diff.deletions ?? 0) : 0}</b>
          </span>
        </div>
        {!ready ? (
          <div className="pane-note">正在读取差异…</div>
        ) : diff.error ? (
          <div className="pane-note error" role="alert">
            <Warning size={14} />
            {diff.error}
          </div>
        ) : diff.hunks.length === 0 ? (
          <>
            <div className="hunk">
              <code>@@ 无文本差异 @@</code>
              <button onClick={() => toggleStage(selected)}>
                {selected.group ? '取消暂存' : '暂存文件'}
                {selected.group ? <Minus size={13} /> : <Plus size={13} />}
              </button>
            </div>
            <div className="pane-note">
              {diff.note ?? '没有可显示的差异（可能只有权限或换行符变化）'}
            </div>
          </>
        ) : (
          <>
            <DiffView
              hunks={diff.hunks}
              mode={diffMode}
              action={
                <button onClick={() => toggleStage(selected)}>
                  {selected.group ? '取消暂存' : '暂存文件'}
                  {selected.group ? <Minus size={13} /> : <Plus size={13} />}
                </button>
              }
            />
            <div className="diff-end">
              <Checks size={16} />
              {diff.truncated ? '差异过大，仅显示前一部分' : '已显示全部文件差异'}
            </div>
          </>
        )}
      </>
    );
  }

  function renderContent() {
    if (isDirectory) return <div className="pane-note">目录没有可预览的内容</div>;
    if (isDeleted) return <div className="pane-note">文件已删除，没有可预览的内容</div>;
    if (!loaded) return <div className="pane-note">正在读取文件…</div>;
    if (loaded.error)
      return (
        <div className="pane-note error" role="alert">
          <Warning size={14} />
          {loaded.error}
        </div>
      );
    if (loaded.dataUrl && fileView === '预览')
      return (
        <div className="image-preview">
          <img src={loaded.dataUrl} alt={baseName(loaded.path)} />
        </div>
      );
    if (loaded.text == null)
      return (
        <div className="pane-note">
          {loaded.isBinary
            ? '二进制文件无法在这里预览或编辑'
            : '文件超过 1 MB，无法在这里预览或编辑'}
        </div>
      );
    if (fileView === '编辑')
      return (
        <>
          {stale && (
            <div className="stale-bar" role="alert">
              <Warning size={14} />
              <span>文件已在外部被修改</span>
              <button onClick={() => saveFile(true)}>覆盖保存</button>
              <button onClick={reloadFile}>放弃并重新载入</button>
            </div>
          )}
          <textarea
            className="file-editor"
            aria-label="编辑文件内容"
            spellCheck={false}
            value={draft}
            onChange={(event) =>
              setDrafts((current) => ({ ...current, [selected.path]: event.target.value }))
            }
            onKeyDown={(event) => {
              if ((event.metaKey || event.ctrlKey) && event.key === 's') {
                event.preventDefault();
                if (hasEdits) saveFile();
              }
            }}
          />
        </>
      );
    if (loaded.kind === 'markdown')
      return (
        <article className="document">
          <Suspense fallback={<p>正在渲染…</p>}>
            <MarkdownRenderer content={savedText} />
          </Suspense>
        </article>
      );
    return (
      <div className="source-preview">
        {savedText
          .replace(/\n$/, '')
          .split('\n')
          .map((line, index) => (
            <div key={index}>
              <span>{index + 1}</span>
              <code>{line || ' '}</code>
            </div>
          ))}
      </div>
    );
  }

  function renderFile() {
    if (!selected)
      return (
        <div className="empty">
          <Check size={30} />
          <h3>{statusError ? '无法读取仓库状态' : '工作区已清理'}</h3>
          <p>{statusError ?? '下一次修改会显示在这里'}</p>
        </div>
      );
    return (
      <>
        <div className="file-view-tabs" role="tablist" aria-label="文件查看方式">
          {['差异', '预览', '编辑'].map((view) => (
            <button
              key={view}
              role="tab"
              aria-selected={fileView === view}
              className={fileView === view ? 'selected' : ''}
              onClick={() => setFileView(view)}
            >
              {view}
            </button>
          ))}
          {fileView === '编辑' && (
            <button className="save-file" disabled={!hasEdits || saving} onClick={() => saveFile()}>
              <Check size={13} />
              {saving ? '正在保存…' : hasEdits ? '保存修改' : '已保存'}
            </button>
          )}
        </div>
        {fileView === '差异' ? (
          renderDiff()
        ) : (
          <>
            <div className="diff-heading">
              <span>
                <FileText size={16} />
                {baseName(selected.path)}
              </span>
              <small>{fileView === '编辑' ? '编辑 · ⌘S 保存' : '文件预览'}</small>
            </div>
            <div className="file-path">{selected.path}</div>
            {renderContent()}
          </>
        )}
      </>
    );
  }

  const renderGroup = (list, isStaged, divider) => (
    <React.Fragment key={String(isStaged)}>
      <div className="file-group" data-change-section={isStaged ? 'staged' : 'unstaged'}>
        <div className="group-label">
          <CaretDown size={11} />
          {isStaged ? '已暂存' : '未暂存'}
          <span>{list.length}</span>
          {isStaged && (
            <button
              title="取消全部暂存"
              aria-label="取消全部暂存"
              disabled={!list.length}
              onClick={() => gitWrite('git.unstage', { paths: list.flatMap(pathsOf) })}
            >
              <Minus size={13} />
            </button>
          )}
        </div>
        <div className="file-group-scroll">
          {list.filter(matches).map((entry) => (
            <div
              key={entry.path}
              className={`file-row ${selected?.path === entry.path && selected.group === entry.group ? 'selected' : ''}`}
            >
              <button
                className="file-select"
                title={entry.path}
                onClick={() => {
                  setPicked({ path: entry.path, group: entry.group });
                  setFileView('差异');
                }}
              >
                <FileCode size={15} />
                <span>
                  <b>{baseName(entry.path.replace(/\/$/, ''))}</b>
                  <small>{dirName(entry.path.replace(/\/$/, ''))}</small>
                </span>
                <em className={letterClass(entry)}>{entry.letter}</em>
              </button>
              <IconButton
                icon={entry.group ? Minus : Plus}
                label={(entry.group ? '取消暂存 ' : '暂存 ') + entry.path}
                onClick={() => toggleStage(entry)}
              />
            </div>
          ))}
          {!list.length && (
            <div className="group-empty">
              {isStaged ? '暂存文件，准备下一次提交' : statusError ? '' : '没有未暂存的变更'}
            </div>
          )}
        </div>
      </div>
      {renderChangeDivider(divider)}
    </React.Fragment>
  );

  return (
    <div className="workspace">
      {collapsed ? (
        <aside className="changes-rail">
          <IconButton icon={CaretRight} label="展开变更文件" onClick={() => setCollapsed(false)} />
          <span>变更 {files.length}</span>
        </aside>
      ) : (
        <>
          <section className="changes-pane" ref={changesPaneRef} style={{ width: changesWidth }}>
            <div className="section-heading">
              <IconButton
                icon={CaretDoubleLeft}
                label="收起变更文件"
                onClick={() => setCollapsed(true)}
              />
              <strong>
                变更文件 <span>{files.length}</span>
              </strong>
              <IconButton
                icon={Plus}
                label="全部暂存"
                disabled={!unstaged.length}
                onClick={() => gitWrite('git.stage', { paths: unstaged.flatMap(pathsOf) })}
              />
            </div>
            <label className="search">
              <MagnifyingGlass size={14} />
              <input
                placeholder="筛选文件…"
                aria-label="筛选变更文件"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
              />
            </label>
            <div
              className="file-groups"
              ref={changeSectionsRef}
              style={{
                gridTemplateRows: `minmax(0, ${changeRows[0]}fr) 6px minmax(0, ${changeRows[1]}fr) 6px minmax(0, ${changeRows[2]}fr)`,
              }}
            >
              {renderGroup(unstaged, false, 0)}
              {renderGroup(staged, true, 1)}
              <div className="commit-form" data-change-section="commit">
                <div className="section-heading">
                  <strong>
                    <GitCommit size={15} />
                    创建提交
                  </strong>
                  <small>{staged.length} 个文件</small>
                </div>
                <textarea
                  placeholder="这次修改做了什么？"
                  aria-label="提交信息"
                  value={message}
                  onChange={(event) => setMessage(event.target.value)}
                  onKeyDown={(event) => {
                    if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
                      event.preventDefault();
                      commit();
                    }
                  }}
                />
                <div className="commit-options">
                  <label>
                    <input
                      type="checkbox"
                      checked={amend}
                      onChange={(event) => toggleAmend(event.target.checked)}
                    />
                    Amend
                  </label>
                  <div className="commit-more">
                    <button
                      className={`commit-more-toggle ${Object.values(commitOptions).some(Boolean) ? 'on' : ''}`}
                      title="更多提交方式"
                      aria-label="更多提交方式"
                      aria-expanded={optionsOpen}
                      onClick={() => setOptionsOpen(!optionsOpen)}
                    >
                      <DotsThree size={16} />
                    </button>
                    {optionsOpen && (
                      <div className="commit-more-menu" role="menu" aria-label="更多提交方式">
                        {[
                          ['signOff', '签名 --signoff'],
                          ['noVerify', '跳过钩子 --no-verify'],
                          ['allowEmpty', '允许空提交 --allow-empty'],
                        ].map(([key, label]) => (
                          <label key={key}>
                            <input
                              type="checkbox"
                              checked={commitOptions[key]}
                              onChange={(event) =>
                                setCommitOptions((current) => ({
                                  ...current,
                                  [key]: event.target.checked,
                                }))
                              }
                            />
                            {label}
                          </label>
                        ))}
                      </div>
                    )}
                  </div>
                </div>
                <button className="primary commit-button" disabled={!canCommit} onClick={commit}>
                  <Check size={15} />
                  {committing ? '正在提交…' : '提交'}
                  {!committing && staged.length > 0 && ` ${staged.length} 个文件`}
                </button>
              </div>
            </div>
          </section>
          <div
            className="changes-width-divider"
            role="separator"
            aria-orientation="vertical"
            aria-label="调整变更文件栏宽度"
            tabIndex={0}
            title="左右拖动调整宽度，双击恢复默认"
            onPointerDown={resizeChangesWidth}
            onDoubleClick={() => setChangesWidth(DEFAULT_WIDTH)}
            onKeyDown={(event) => {
              if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
              event.preventDefault();
              const pane = changesPaneRef.current;
              const maximum = Math.max(170, pane.parentElement.getBoundingClientRect().width - 185);
              setChangesWidth(
                Math.max(
                  170,
                  Math.min(
                    maximum,
                    pane.getBoundingClientRect().width + (event.key === 'ArrowLeft' ? -16 : 16),
                  ),
                ),
              );
            }}
          />
        </>
      )}
      <section className="diff-pane">{renderFile()}</section>
    </div>
  );
}
