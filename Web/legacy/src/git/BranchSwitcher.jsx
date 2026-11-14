// 「Git 工作台」标签与分支下拉合一：
// - 点标签切到 Git 工作台；已在 Git 工作台时再点（或点箭头）展开分支下拉；
// - 下拉顶部是 获取 / 更新 / 推送，下面是本地与远程分支，单击选中、双击签出；
// - 右键任意分支（或右键标签本身 = 当前分支）弹出分支操作菜单。
// WKWebView 没有实现 window.prompt / confirm，新建分支名与删除确认都在弹层里内联完成。
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowDown,
  ArrowUp,
  ArrowsClockwise,
  CaretDown,
  GitBranch,
  GitMerge,
  Plus,
  Copy,
  Trash,
  CloudArrowDown,
  SignIn,
  MagnifyingGlass,
  Folder,
} from '@phosphor-icons/react';
import { request } from '../bridge/client.js';
import { describeError } from '../bridge/dto.js';

export default function BranchSwitcher({
  headless = false,
  active,
  projectPath,
  branch,
  ahead = 0,
  behind = 0,
  onActivate,
  onChanged,
  onNotify,
  // 传了 projects 就在弹层左侧多一列项目：切项目时右侧分支跟着换（标题栏「项目 / 分支」合一控件用）
  projects = null,
  onSelectProject,
}) {
  const [open, setOpen] = useState(false);
  const [branches, setBranches] = useState(null);
  const [filter, setFilter] = useState('');
  const [menu, setMenu] = useState(null); // { item, x, y }
  const [dialog, setDialog] = useState(null); // { kind: 'create'|'delete', item }
  const [busy, setBusy] = useState('');
  const [error, setError] = useState(null);
  const rootRef = useRef(null);

  // 切项目时旧请求可能晚回来：只接受当前项目的结果。
  const pathRef = useRef(projectPath);
  pathRef.current = projectPath;
  const load = useCallback(() => {
    if (!projectPath) return;
    request('git.branches', { projectPath })
      .then((list) => {
        if (pathRef.current === projectPath) setBranches(Array.isArray(list) ? list : []);
      })
      .catch((err) => {
        if (pathRef.current === projectPath) setError(describeError(err));
      });
  }, [projectPath]);

  useEffect(() => {
    setBranches(null);
    // 带项目列的弹层里切项目，是在弹层内操作的，保持打开、右侧重新读分支
    if (!projects) setOpen(false);
    setMenu(null);
    setDialog(null);
    setError(null);
    setFilter('');
    setRevealNote('');
  }, [projectPath]);

  useEffect(() => {
    if (open || menu) load();
  }, [open, menu, load]);

  // 点外面 / Esc 关闭
  useEffect(() => {
    if (!open && !menu) return undefined;
    const onDown = (event) => {
      if (rootRef.current && !rootRef.current.contains(event.target)) close();
    };
    const onKey = (event) => {
      if (event.key === 'Escape') close();
    };
    window.addEventListener('mousedown', onDown);
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('mousedown', onDown);
      window.removeEventListener('keydown', onKey);
    };
  }, [open, menu]);

  // 无标签模式：按钮在原生标题栏，点击 / 右键菜单通过事件驱动这里的弹层与分支操作。
  const actionsRef = useRef(null);
  useEffect(() => {
    if (!headless) return undefined;
    const onToggle = () => {
      setMenu(null);
      setOpen((value) => !value);
    };
    const onAction = (event) => {
      const kind = event.detail?.action;
      const fns = actionsRef.current;
      if (!fns) return;
      if (kind === 'create') {
        setOpen(true);
        setDialog({ kind: 'create', item: fns.current });
      } else if (kind === 'fetch') fns.fetch();
      else if (fns[kind]) fns[kind](fns.current);
    };
    window.addEventListener('claude-picker:branch-popover', onToggle);
    window.addEventListener('claude-picker:branch-action', onAction);
    return () => {
      window.removeEventListener('claude-picker:branch-popover', onToggle);
      window.removeEventListener('claude-picker:branch-action', onAction);
    };
  }, [headless]);

  const close = () => {
    setOpen(false);
    setMenu(null);
    setDialog(null);
    setFilter('');
    setError(null);
  };

  const current = useMemo(
    () =>
      branches?.find((item) => item.isCurrent) ?? {
        name: branch,
        isCurrent: true,
        isRemote: false,
      },
    [branches, branch],
  );

  // 统一执行：忙碌态、成功提示、失败留在弹层里显示 stderr，成功后通知外层刷新。
  // 刚做完一次分支操作的短时间内不接受签出：防误触 / 重复触发时沿着列表一路连续签出。
  const lastOpAt = useRef(0);
  // 分支 → 会话：选中 / 签出分支后，让第一栏定位到该分支对应的会话（设置里开了绑定才生效）
  const [revealNote, setRevealNote] = useState('');
  const localName = (item) => (item.isRemote ? item.name.replace(/^[^/]+\//, '') : item.name);
  const reveal = (name) => {
    if (!headless || !projectPath || !name) return;
    request('app.revealBranchSessions', { projectPath, branch: name })
      .then((result) => {
        if (!result?.enabled) return setRevealNote('');
        setRevealNote(
          result.matched
            ? `已在左侧定位 ${name} 的会话` +
                (result.matched > 1 ? `（共 ${result.matched} 个，选中最近的）` : '')
            : `${name} 没有对应的会话`,
        );
      })
      .catch(() => {});
  };
  const [picked, setPicked] = useState('');
  const run = async (label, method, params, success) => {
    if (busy) return;
    if (method === 'git.switchBranch' && Date.now() - lastOpAt.current < 1500) return false;
    let ok = false;
    setBusy(label);
    setError(null);
    setMenu(null);
    try {
      await request(method, { projectPath, ...params }, { timeoutMs: 150000 });
      ok = true;
      onNotify?.(success);
      setDialog(null);
      load();
      onChanged?.();
    } catch (err) {
      setError(describeError(err));
      setOpen(true);
    } finally {
      lastOpAt.current = Date.now();
      setBusy('');
    }
    return ok;
  };

  const actions = {
    checkout: async (item) => {
      const ok = await run(
        '正在签出 ' + item.name,
        'git.switchBranch',
        { branch: item.name },
        '已签出 ' + item.name,
      );
      if (ok) reveal(localName(item));
    },
    update: (item) =>
      run(
        '正在更新 ' + item.name,
        'git.pull',
        item.isCurrent ? {} : { branch: item.name },
        '已更新 ' + item.name,
      ),
    push: (item) =>
      run('正在推送 ' + item.name, 'git.push', { branch: item.name }, '已推送 ' + item.name),
    merge: (item) =>
      run(
        '正在合并 ' + item.name,
        'git.merge',
        { branch: item.name },
        '已将 ' + item.name + ' 合并到 ' + current.name,
      ),
    fetch: () => run('正在获取远程', 'git.fetch', {}, '已获取所有远程的最新引用'),
    create: (from, name) =>
      run(
        '正在新建 ' + name,
        'git.createBranch',
        { name, from },
        '已从 ' + from + ' 新建分支 ' + name,
      ),
    remove: (item) =>
      run(
        '正在删除 ' + item.name,
        'git.deleteBranch',
        { branch: item.name },
        '已删除分支 ' + item.name,
      ),
    copy: (item) => {
      copyText(item.name);
      onNotify?.('已复制 ' + item.name);
      setMenu(null);
    },
  };

  actionsRef.current = { ...actions, current };

  const openMenu = (event, item) => {
    event.preventDefault();
    event.stopPropagation();
    const box = rootRef.current?.getBoundingClientRect();
    setMenu({
      item,
      x: event.clientX - (box?.left ?? 0),
      y: event.clientY - (box?.top ?? 0),
    });
  };

  const onTabClick = () => {
    if (!active) {
      onActivate?.();
      return;
    }
    setOpen((value) => !value);
    setMenu(null);
  };

  const q = filter.trim().toLowerCase();
  const matches = (item) => !q || item.name.toLowerCase().includes(q);
  const local = (branches ?? []).filter((item) => !item.isRemote && matches(item));
  const remote = (branches ?? []).filter((item) => item.isRemote && matches(item));

  return (
    <div className={'branch-switcher' + (headless ? ' headless' : '')} ref={rootRef}>
      {!headless && (
        <div
          className={'branch-tab' + (active ? ' active' : '') + (open ? ' open' : '')}
          onContextMenu={(event) => projectPath && openMenu(event, current)}
        >
          <button
            role="tab"
            aria-selected={active}
            className="branch-tab-main"
            onClick={onTabClick}
            title={active ? '切换分支（右键：分支操作）' : 'Git 工作台'}
          >
            <GitBranch size={15} />
            <span className="branch-tab-label">Git 工作台</span>
            {branch && <span className="branch-chip">{branch}</span>}
            {busy && <span className="branch-busy" aria-label={busy} />}
          </button>
          <button
            className="branch-tab-caret"
            aria-label="分支列表"
            onClick={() => {
              if (!active) onActivate?.();
              setOpen((value) => !value);
              setMenu(null);
            }}
          >
            <CaretDown size={11} />
          </button>
        </div>
      )}

      {open && (
        <div
          className={'branch-popover' + (projects ? ' with-projects' : '')}
          role="dialog"
          aria-label="项目与分支"
        >
          {projects && (
            <div className="branch-projects" aria-label="项目">
              <div className="branch-group">项目</div>
              {projects.map((project) => (
                <button
                  key={project.path}
                  className={'branch-project' + (project.path === projectPath ? ' current' : '')}
                  title={project.path}
                  onClick={() => project.path !== projectPath && onSelectProject?.(project.path)}
                >
                  <Folder size={13} weight={project.path === projectPath ? 'fill' : 'regular'} />
                  <span>{project.title}</span>
                </button>
              ))}
            </div>
          )}
          <div className="branch-main">
            <div className="branch-popover-actions">
              <button disabled={!!busy} onClick={actions.fetch} title="git fetch --all --prune">
                <ArrowsClockwise size={14} />
                获取
              </button>
              <button
                disabled={!!busy}
                onClick={() => actions.update(current)}
                title="git pull --ff-only"
              >
                <ArrowDown size={14} />
                更新 <small>{behind}</small>
              </button>
              <button
                disabled={!!busy}
                className="push"
                onClick={() => actions.push(current)}
                title="git push"
              >
                <ArrowUp size={14} />
                推送 <small>{ahead}</small>
              </button>
              <button
                disabled={!!busy}
                onClick={() => setDialog({ kind: 'create', item: current })}
                title="从当前分支新建分支"
              >
                <Plus size={14} />
                新建
              </button>
            </div>

            {busy && <div className="branch-status">{busy}…</div>}
            {error && (
              <div className="branch-error" role="alert">
                <b>{error.title}</b>
                <span>{error.message}</span>
                {error.detail && <pre>{error.detail}</pre>}
              </div>
            )}
            {dialog && (
              <BranchDialog
                dialog={dialog}
                busy={!!busy}
                onCancel={() => setDialog(null)}
                onCreate={(name) => actions.create(dialog.item.name, name)}
                onDelete={() => actions.remove(dialog.item)}
              />
            )}

            <label className="branch-search">
              <MagnifyingGlass size={13} />
              <input
                autoFocus
                value={filter}
                placeholder="筛选分支…"
                onChange={(event) => setFilter(event.target.value)}
              />
            </label>

            <div className="branch-list">
              {!branches && <div className="branch-empty">正在读取分支…</div>}
              {branches && (
                <>
                  <div className="branch-group">本地分支</div>
                  {local.length === 0 && <div className="branch-empty">没有匹配的本地分支</div>}
                  {local.map((item) => (
                    <BranchRow
                      key={'l:' + item.name}
                      item={item}
                      selected={picked === 'l:' + item.name}
                      onClick={() => {
                        setPicked('l:' + item.name);
                        reveal(localName(item));
                      }}
                      onDoubleClick={() => !item.isCurrent && actions.checkout(item)}
                      onContextMenu={(event) => openMenu(event, item)}
                    />
                  ))}
                  <div className="branch-group">远程分支</div>
                  {remote.length === 0 && <div className="branch-empty">没有远程分支</div>}
                  {remote.map((item) => (
                    <BranchRow
                      key={'r:' + item.name}
                      item={item}
                      selected={picked === 'r:' + item.name}
                      onClick={() => {
                        setPicked('r:' + item.name);
                        reveal(localName(item));
                      }}
                      onDoubleClick={() => actions.checkout(item)}
                      onContextMenu={(event) => openMenu(event, item)}
                    />
                  ))}
                </>
              )}
            </div>
            <div className="branch-hint">{revealNote || '双击签出 · 右键更多操作'}</div>
          </div>
        </div>
      )}

      {menu && (
        <BranchMenu
          // 右键时分支列表可能还没读回来：一旦读到，用带 upstream/ahead 的完整记录替换占位对象
          menu={{
            ...menu,
            item:
              branches?.find(
                (b) => b.name === menu.item.name && b.isRemote === Boolean(menu.item.isRemote),
              ) ?? menu.item,
          }}
          current={current}
          busy={!!busy}
          actions={actions}
          onCreate={(item) => {
            setMenu(null);
            setOpen(true);
            setDialog({ kind: 'create', item });
          }}
          onDelete={(item) => {
            setMenu(null);
            setOpen(true);
            setDialog({ kind: 'delete', item });
          }}
        />
      )}
    </div>
  );
}

function BranchRow({ item, selected, onClick, onDoubleClick, onContextMenu }) {
  const track = [];
  if (item.ahead) track.push('↑' + item.ahead);
  if (item.behind) track.push('↓' + item.behind);
  return (
    <button
      className={'branch-row' + (item.isCurrent ? ' current' : '') + (selected ? ' picked' : '')}
      onClick={onClick}
      onDoubleClick={onDoubleClick}
      onContextMenu={onContextMenu}
      title={item.upstream ? item.name + ' → ' + item.upstream : item.name}
    >
      <GitBranch size={13} />
      <span className="branch-row-name">{item.name}</span>
      {item.upstreamGone && <em className="gone">上游已删除</em>}
      {track.length > 0 && <em>{track.join(' ')}</em>}
      {item.isCurrent && <em className="cur">当前</em>}
    </button>
  );
}

function BranchMenu({ menu, current, busy, actions, onCreate, onDelete }) {
  const { item } = menu;
  const isCurrent = item.isCurrent || (!item.isRemote && item.name === current.name);
  const entries = item.isRemote
    ? [
        [SignIn, '签出为本地分支', () => actions.checkout(item)],
        [GitMerge, `合并到 ${current.name}`, () => actions.merge(item)],
        [Plus, '从此分支新建…', () => onCreate(item)],
        null,
        [Copy, '复制分支名', () => actions.copy(item)],
      ]
    : [
        !isCurrent && [SignIn, '签出', () => actions.checkout(item)],
        [
          CloudArrowDown,
          isCurrent ? '更新（拉取）' : '更新（快进到上游）',
          () => actions.update(item),
          !isCurrent && !item.upstream,
        ],
        [ArrowUp, item.upstream ? '推送' : '推送并建立上游', () => actions.push(item)],
        !isCurrent && [GitMerge, `合并到 ${current.name}`, () => actions.merge(item)],
        [Plus, '从此分支新建…', () => onCreate(item)],
        null,
        [Copy, '复制分支名', () => actions.copy(item)],
        !isCurrent && [Trash, '删除…', () => onDelete(item), false, 'danger'],
      ];
  return (
    <div
      className="branch-menu"
      role="menu"
      style={{ left: menu.x, top: menu.y }}
      onContextMenu={(event) => event.preventDefault()}
    >
      <div className="branch-menu-title">{item.name}</div>
      {entries
        .filter((entry) => entry !== false)
        .map((entry, index) =>
          entry === null ? (
            <div key={'sep' + index} className="branch-menu-sep" />
          ) : (
            <button
              key={entry[1]}
              role="menuitem"
              className={entry[4] ?? ''}
              disabled={busy || entry[3] === true}
              onClick={entry[2]}
            >
              {React.createElement(entry[0], { size: 14 })}
              {entry[1]}
            </button>
          ),
        )}
    </div>
  );
}

function BranchDialog({ dialog, busy, onCancel, onCreate, onDelete }) {
  const [name, setName] = useState('');
  if (dialog.kind === 'delete') {
    return (
      <div className="branch-dialog danger">
        <span>
          删除本地分支 <b>{dialog.item.name}</b>？未合并的分支 git 会拒绝删除。
        </span>
        <div>
          <button onClick={onCancel}>取消</button>
          <button className="danger" disabled={busy} onClick={onDelete}>
            删除
          </button>
        </div>
      </div>
    );
  }
  return (
    <form
      className="branch-dialog"
      onSubmit={(event) => {
        event.preventDefault();
        if (name.trim()) onCreate(name.trim());
      }}
    >
      <span>
        从 <b>{dialog.item.name}</b> 新建分支
      </span>
      <input
        autoFocus
        value={name}
        placeholder="feature/xxx"
        onChange={(event) => setName(event.target.value)}
      />
      <div>
        <button type="button" onClick={onCancel}>
          取消
        </button>
        <button type="submit" className="primary" disabled={busy || !name.trim()}>
          新建
        </button>
      </div>
    </form>
  );
}

// WKWebView 的自定义 scheme 不一定是安全上下文，navigator.clipboard 可能不可用。
function copyText(text) {
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).catch(() => legacyCopy(text));
  } else legacyCopy(text);
}
function legacyCopy(text) {
  const el = document.createElement('textarea');
  el.value = text;
  el.style.position = 'fixed';
  el.style.opacity = '0';
  document.body.appendChild(el);
  el.select();
  document.execCommand('copy');
  el.remove();
}
