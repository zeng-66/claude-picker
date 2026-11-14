// 工作区页：变更文件列表 + 差异预览 + 提交框。
//
// T4：`transportKind() === 'mock'`（浏览器直开 / 真桥回退）时继续用 App.jsx 的演示 props；
// 原生桥下改成读 `git.status` / `git.diff`。写操作（暂存、提交）本卡不接，
// 按钮保留但只提示「暂不支持」，绝不发请求假装成功。
import React, { useCallback, useEffect, useState } from 'react';
import { Splitter, useStoredSize } from '../ui/Splitter.jsx';
import { transportKind } from '../bridge/client.js';
import { projectRequest } from '../bridge/project-request.js';
import {
  currentProjectId,
  describeError,
  onProjectChange,
  projectPathFor,
  toDiff,
  toStatus,
} from '../bridge/dto.js';
import { codeLines as demoCodeLines } from '../mock/data.js';
import {
  ArrowCounterClockwise,
  CaretDown,
  CaretLeft,
  CaretRight,
  Check,
  Clock,
  Copy,
  DotsThree,
  FileCode,
  GitCommit,
  MagnifyingGlass,
  Plus,
} from '@phosphor-icons/react';

const WRITE_LOCKED = '暂不支持：写操作（T4 只接了只读链路）';

const noticeStyle = { color: '#d78e8c', lineHeight: 1.6, whiteSpace: 'normal' };
const detailStyle = {
  margin: '6px 0 0',
  padding: '6px 8px',
  maxHeight: 140,
  overflow: 'auto',
  background: '#1b1c20',
  border: '1px solid #34353a',
  borderRadius: 6,
  color: '#858890',
  fontSize: 11,
  whiteSpace: 'pre-wrap',
};
const retryStyle = {
  marginTop: 6,
  padding: '3px 10px',
  fontSize: 12,
  background: 'transparent',
  border: '1px solid #34353a',
  borderRadius: 6,
  color: '#dadbdd',
  cursor: 'pointer',
};

export default function WorkspacePage({
  files,
  staged,
  selected,
  query,
  message,
  amend,
  tab,
  onStagedChange,
  onNotify,
  onQueryChange,
  onMessageChange,
  onAmendChange,
  onToggleStage,
  onSelect,
  onCommit,
  onOpen,
  onTabChange,
}) {
  const demo = transportKind() === 'mock';
  const [snapshot, setSnapshot] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [picked, setPicked] = useState(null);
  const [diff, setDiff] = useState(null);
  const [diffLoading, setDiffLoading] = useState(false);
  const [diffError, setDiffError] = useState(null);

  const loadStatus = useCallback(async () => {
    if (demo) return;
    setLoading(true);
    setError(null);
    setPicked(null);
    try {
      const result = await projectRequest(
        'git.status',
        { projectPath: projectPathFor(currentProjectId()) },
        { timeoutMs: 60000 },
      );
      setSnapshot(toStatus(result));
    } catch (cause) {
      setError(describeError(cause));
    } finally {
      setLoading(false);
    }
  }, [demo]);

  useEffect(() => {
    loadStatus();
  }, [loadStatus]);

  useEffect(() => onProjectChange(loadStatus), [loadStatus]);

  const realFiles = snapshot?.files ?? [];
  const list = demo ? files : realFiles;
  const isStaged = (file) => (demo ? staged.includes(file.name) : Boolean(file.staged));
  const active = demo ? selected : (picked ?? realFiles[0] ?? null);
  const activeKey = active ? (demo ? active.name : active.path) : null;

  // 选中的文件变化（或状态刷新后）重新取 diff。已暂存且没有工作区改动时看 index。
  useEffect(() => {
    if (demo || !active) {
      setDiff(null);
      setDiffError(null);
      return undefined;
    }
    let alive = true;
    const stagedView = Boolean(active.staged) && !active.untracked && !active.unstaged;
    setDiffLoading(true);
    setDiffError(null);
    projectRequest(
      'git.diff',
      {
        projectPath: projectPathFor(currentProjectId()),
        filePath: active.path,
        staged: stagedView,
      },
      { timeoutMs: 60000 },
    )
      .then((result) => {
        if (alive) setDiff(toDiff(result));
      })
      .catch((cause) => {
        if (alive) {
          setDiff(null);
          setDiffError(describeError(cause));
        }
      })
      .finally(() => {
        if (alive) setDiffLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [demo, active?.path, active?.staged, active?.unstaged, active?.untracked]);

  const visible = list.filter((file) => file.name.toLowerCase().includes(query.toLowerCase()));
  const unstagedRows = visible.filter((file) => !isStaged(file));
  const stagedRows = visible.filter((file) => isStaged(file));
  const stagedCount = realFiles.filter((file) => file.staged).length;
  const stagedTotal = demo ? staged.length : stagedCount;

  const pick = (file) => {
    if (demo) onSelect(file);
    else setPicked(file);
  };

  const stageAction = (file) => {
    if (demo) {
      onToggleStage(file);
      return;
    }
    onNotify(WRITE_LOCKED);
  };

  const patchLines = diff?.lines?.filter((line) => line.kind !== 'meta') ?? [];
  const hunkTitle = patchLines.find((line) => line.kind === 'hunk')?.text ?? '@@ 无差异 @@';

  const renderLines = (column) => {
    if (demo) {
      return demoCodeLines(active?.name, column === 1 || tab === '统一').map(([kind, line], i) => (
        <div key={i} className={'code-line ' + kind}>
          <span className="ln">{24 + i}</span>
          <span className="mark">{kind === 'added' ? '+' : kind === 'removed' ? '−' : ''}</span>
          <code>{line}</code>
        </div>
      ));
    }
    const rows =
      tab === '统一'
        ? patchLines
        : patchLines.filter(
            (line) =>
              line.kind !== 'hunk' &&
              (column === 0 ? line.kind !== 'added' : line.kind !== 'removed'),
          );
    return rows.map((line, i) => {
      if (line.kind === 'hunk') {
        return (
          <div key={i} className="code-line hunk-line">
            <span className="ln" />
            <span className="mark" />
            <code style={{ color: '#858890' }}>{line.text}</code>
          </div>
        );
      }
      return (
        <div
          key={i}
          className={
            'code-line ' +
            (line.kind === 'added' ? 'added' : line.kind === 'removed' ? 'removed' : '')
          }
        >
          <span className="ln">
            {tab === '统一' ? (line.newLine ?? line.oldLine) : (line.oldLine ?? line.newLine)}
          </span>
          <span className="mark">{line.mark}</span>
          <code>{line.text}</code>
        </div>
      );
    });
  };

  // 变更列表宽度 / 提交框高度可拖动，记在本机。
  const changesW = useStoredSize('cp.workspace.changesW', 250, 180, 640);
  const commitH = useStoredSize('cp.workspace.commitH', 230, 140, 560);
  // 变更文件栏可收成窄条（记在本机），未暂存 / 已暂存分组可各自折叠
  const [panelCollapsed, setPanelCollapsed] = useState(() => {
    try {
      return window.localStorage.getItem('cp.workspace.changesCollapsed') === '1';
    } catch {
      return false;
    }
  });
  const togglePanel = () =>
    setPanelCollapsed((value) => {
      try {
        window.localStorage.setItem('cp.workspace.changesCollapsed', value ? '0' : '1');
      } catch {
        /* 存不了就只在本次生效 */
      }
      return !value;
    });
  const [groupCollapsed, setGroupCollapsed] = useState({ unstaged: false, staged: false });
  const toggleGroup = (key) => setGroupCollapsed((value) => ({ ...value, [key]: !value[key] }));

  const renderDiffPanel = () => (
    <section className="diff-panel">
      <div className="panel-head">
        <div className="diff-title">
          <FileCode />
          <b>{active?.name || '文件预览'}</b>
          <span className="green">+{demo ? active?.add || 0 : (diff?.additions ?? 0)}</span>
          <span className="red">−{demo ? active?.del || 0 : (diff?.deletions ?? 0)}</span>
        </div>
        <div className="segmented">
          {['并排', '统一'].map((x) => (
            <button key={x} className={tab === x ? 'chosen' : ''} onClick={() => onTabChange(x)}>
              {x}
            </button>
          ))}
        </div>
      </div>
      <div className="diff-path">
        {demo ? active?.path + '/' + active?.name : active?.path}
        <div>
          <button onClick={() => onOpen('查看文件历史')}>
            <Clock />
            文件历史
          </button>
          <button onClick={() => onOpen('放弃文件修改（暂不支持）', 'danger')} title="放弃文件修改">
            <ArrowCounterClockwise />
          </button>
        </div>
      </div>
      <div className="diff-scroll">
        {diffLoading && <div className="empty-small">正在读取差异…</div>}
        {diffError && (
          <div className="empty-small" role="alert" style={noticeStyle}>
            <b>{diffError.title}</b>
            <div>{diffError.message}</div>
            {diffError.detail && <pre style={detailStyle}>{diffError.detail}</pre>}
          </div>
        )}
        {!demo && !diffLoading && !diffError && active && patchLines.length === 0 && (
          <div className="empty-small">
            {active.untracked
              ? '未跟踪文件：git diff 没有内容，可在文件预览里查看'
              : '没有可显示的差异'}
          </div>
        )}
        {!demo && !active && <div className="empty-small">工作区没有可显示的变更</div>}
        <div className="hunk">
          {hunkTitle} <span>{active?.name || ''}</span>
          <button
            onClick={() => {
              if (demo && active && !staged.includes(active.name)) onToggleStage(active);
              onNotify(demo ? '演示：已暂存此文件' : WRITE_LOCKED);
            }}
          >
            暂存此文件
          </button>
        </div>
        <div className={'code-columns ' + (tab === '统一' ? 'unified' : '')}>
          {(tab === '统一' ? ['修改预览'] : ['修改前 · HEAD', '修改后 · Working Tree']).map(
            (label, col) => (
              <div className="code-side" key={label}>
                <div className="code-label">{label}</div>
                {renderLines(col)}
              </div>
            ),
          )}
        </div>
        <div className="diff-end">
          <Check size={16} /> 已显示全部文件差异
        </div>
      </div>
      <div className="diff-footer">
        <span>Swift</span>
        <span>UTF-8</span>
        <span>LF</span>
        <span>空格: 4</span>
        <button onClick={() => onOpen('复制文件路径')}>
          <Copy />
          复制路径
        </button>
      </div>
    </section>
  );

  if (panelCollapsed) {
    return (
      <div className="workarea changes-collapsed">
        <button
          className="changes-rail"
          onClick={togglePanel}
          title="展开变更文件"
          aria-label="展开变更文件"
        >
          <CaretRight size={13} />
          <span>变更文件</span>
          <small>{list.length}</small>
        </button>
        {renderDiffPanel()}
      </div>
    );
  }

  return (
    <div className="workarea" style={{ '--changes-w': changesW.size + 'px' }}>
      <Splitter
        state={changesW}
        axis="x"
        reserve={260}
        className="workarea-split"
        style={{ left: changesW.size - 3 }}
      />
      <section className="changes">
        <div className="panel-head">
          <b>
            <button
              className="panel-collapse"
              onClick={togglePanel}
              title="收起变更文件"
              aria-label="收起变更文件"
            >
              <CaretLeft size={12} />
            </button>
            变更文件 <small>{list.length}</small>
          </b>
          <button
            title="暂存全部"
            onClick={() => {
              if (demo) {
                onStagedChange(files.map((f) => f.name));
                onNotify('已暂存全部文件');
                return;
              }
              onNotify(WRITE_LOCKED);
            }}
          >
            <Plus />
            全部暂存
          </button>
        </div>
        <div className="file-list">
          <div className="file-filter">
            <MagnifyingGlass />
            <input
              placeholder="筛选文件…"
              value={query}
              onChange={(e) => onQueryChange(e.target.value)}
            />
          </div>

          {loading && !snapshot && <div className="empty-small">正在读取仓库状态…</div>}
          {error && (
            <div className="empty-small" role="alert" style={noticeStyle}>
              <b>{error.title}</b>
              <div>{error.message}</div>
              {error.detail && <pre style={detailStyle}>{error.detail}</pre>}
              <button type="button" style={retryStyle} onClick={loadStatus}>
                重试
              </button>
            </div>
          )}
          {!demo && !loading && !error && list.length === 0 && (
            <div className="empty-small">工作区干净</div>
          )}
          {list.length > 0 && visible.length === 0 && (
            <div className="empty-small">没有匹配的变更文件</div>
          )}

          <div
            className="group-title"
            role="button"
            tabIndex={0}
            aria-expanded={!groupCollapsed.unstaged}
            onClick={() => toggleGroup('unstaged')}
            onKeyDown={(event) => event.key === 'Enter' && toggleGroup('unstaged')}
          >
            {groupCollapsed.unstaged ? <CaretRight /> : <CaretDown />}
            未暂存 <span>{unstagedRows.length}</span>
          </div>
          {!groupCollapsed.unstaged &&
            unstagedRows.map((file) => (
              <div
                key={demo ? file.name : file.path}
                className={
                  'file-row ' + (activeKey === (demo ? file.name : file.path) ? 'selected' : '')
                }
              >
                <button className="file-main" onClick={() => pick(file)}>
                  <FileCode size={18} />
                  <span>
                    <b>{file.name}</b>
                    <small>{demo ? file.path : file.dir || ''}</small>
                  </span>
                  <em className={file.type}>{file.type}</em>
                </button>
                <button title={'暂存 ' + file.name} onClick={() => stageAction(file)}>
                  <Plus size={16} />
                </button>
              </div>
            ))}

          <div
            className="group-title staged"
            role="button"
            tabIndex={0}
            aria-expanded={!groupCollapsed.staged}
            onClick={() => toggleGroup('staged')}
            onKeyDown={(event) => event.key === 'Enter' && toggleGroup('staged')}
          >
            {groupCollapsed.staged ? <CaretRight /> : <CaretDown />}
            已暂存 <span>{stagedRows.length}</span>
            <button
              onClick={(event) => {
                event.stopPropagation();
                if (demo) {
                  onStagedChange([]);
                  return;
                }
                onNotify(WRITE_LOCKED);
              }}
              title="取消全部暂存"
            >
              <ArrowCounterClockwise />
            </button>
          </div>
          {!groupCollapsed.staged &&
            stagedRows.map((file) => (
              <div className="file-row" key={demo ? file.name : file.path}>
                <button className="file-main" onClick={() => pick(file)}>
                  <FileCode size={18} />
                  <span>
                    <b>{file.name}</b>
                    <small>{demo ? file.path : file.dir || ''}</small>
                  </span>
                  <em className={file.type}>{file.type}</em>
                </button>
                <button onClick={() => stageAction(file)} title={'取消暂存 ' + file.name}>
                  <ArrowCounterClockwise />
                </button>
              </div>
            ))}
          {!stagedTotal && <div className="empty-small">暂存文件，准备下一次提交</div>}
        </div>

        <Splitter state={commitH} axis="y" invert reserve={120} className="commit-split" />
        <div className="commit-box" style={{ height: commitH.size }}>
          <div className="commit-title">
            <GitCommit />
            创建提交 <span>{stagedTotal} 个文件</span>
          </div>
          <textarea
            value={message}
            onChange={(e) => onMessageChange(e.target.value)}
            placeholder="这次修改做了什么？"
          />
          <div className="commit-options">
            <label>
              <input
                type="checkbox"
                checked={amend}
                onChange={(e) => onAmendChange(e.target.checked)}
              />{' '}
              Amend 最近提交
            </label>
            <button
              title="更多提交方式"
              onClick={() => onOpen('更多提交方式：签名 / 跳过钩子 / 空提交（暂不支持）')}
            >
              <DotsThree />
            </button>
          </div>
          <button
            className="primary commit-btn"
            disabled={demo ? !stagedTotal || !message.trim() : !message.trim()}
            onClick={() => {
              if (demo) {
                onCommit();
                return;
              }
              onNotify(WRITE_LOCKED);
            }}
          >
            <Check />
            提交到当前分支
          </button>
          <small className="commit-hint">
            {stagedTotal ? '已暂存 ' + stagedTotal + ' 个文件' : '先选择要提交的文件'}
          </small>
        </div>
      </section>

      {renderDiffPanel()}
    </div>
  );
}
