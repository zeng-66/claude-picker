import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  ArrowDown,
  ArrowUp,
  ArrowsClockwise,
  CaretDown,
  CaretDoubleLeft,
  CaretRight,
  CaretUp,
  Check,
  Checks,
  CircleNotch,
  Code,
  DotsThree,
  FileCode,
  FileText,
  Folder,
  Gear,
  GitBranch,
  GitCommit,
  GitDiff,
  GitMerge,
  ClockCounterClockwise,
  MagnifyingGlass,
  Minus,
  Plus,
  PlugsConnected,
  SidebarSimple,
  Stack,
  Terminal,
  TreeStructure,
  Lightning,
  X,
} from "@phosphor-icons/react";
import "./style.css";
import appIcon from "./clawd-mark.png";

const initialProjects = [
  {
    name: "claude-picker",
    branch: "codex/git-features",
    sessions: ["Git 工作台界面整理", "终端交互与会话状态", "项目侧栏优化"],
  },
  {
    name: "lm-global-java",
    branch: "feature/order-decode",
    sessions: [
      "订单解码流程梳理",
      "物流 webhook 对接",
      "运营端订单导出",
      "设计记录字段调整",
      "商品列表筛选",
      "接口响应检查",
    ],
  },
  {
    name: "lanma-bankend",
    branch: "beta",
    sessions: ["商品标题响应优化", "生产日志排查"],
  },
  {
    name: "fangguo-erp-java",
    branch: "feature/webhook",
    sessions: ["Webhook 事件处理"],
  },
];
const initialFiles = [
  {
    path: "Sources/ClaudeDeck/main.swift",
    status: "M",
    add: 24,
    del: 12,
    staged: false,
  },
  {
    path: "Sources/ClaudeDeck/Models.swift",
    status: "M",
    add: 8,
    del: 3,
    staged: false,
  },
  { path: "Web/src/App.jsx", status: "M", add: 18, del: 6, staged: false },
  { path: "Web/src/styles.css", status: "M", add: 12, del: 4, staged: true },
  {
    path: "docs/interface-notes.md",
    status: "?",
    add: 16,
    del: 0,
    staged: false,
  },
];
const tabs = [
  ["工作区", GitDiff],
  ["提交历史", ClockCounterClockwise],
  ["分支", GitBranch],
  ["工作树", TreeStructure],
  ["更多", DotsThree],
];
const initialHistory = [
  ["整理 Git 工作台布局与分支入口", "a84c2e1", "12 分钟前"],
  ["补充终端会话状态与恢复逻辑", "73f4b96", "1 小时前"],
  ["统一项目上下文与文件预览", "618de32", "3 小时前"],
  ["调整侧栏展开与收起交互", "49d13a0", "昨天"],
];
const changes = [
  ["context", 38, 38, "struct PickerView: View {"],
  ["context", 39, 39, "    @ObservedObject var store: Store"],
  ["context", 40, 40, ""],
  ["context", 41, 41, "    var body: some View {"],
  ["del", 42, "", "        HStack(spacing: 12) {"],
  ["add", "", 42, "        HStack(spacing: 0) {"],
  ["context", 43, 43, "            ProjectSidebar(store: store)"],
  ["context", 44, 44, ""],
  ["del", 45, "", "            TerminalPane(store: store)"],
  ["add", "", 45, "            if !store.settings.terminalCollapsed {"],
  ["add", "", 46, "                TerminalPane(store: store)"],
  ["add", "", 47, "                    .frame(minWidth: 320)"],
  ["add", "", 48, "            }"],
  ["context", 46, 49, ""],
  ["context", 47, 50, "            if store.thirdVisible {"],
  ["context", 48, 51, "                WebPane(store: store)"],
  ["context", 49, 52, "            }"],
  ["context", 50, 53, "        }"],
  ["context", 51, 54, "    }"],
  ["context", 52, 55, "}"],
];

function IconButton({ icon: Icon, label, onClick, active = false, ...props }) {
  return (
    <button
      className={`icon-button ${active ? "active" : ""}`}
      title={label}
      aria-label={label}
      onClick={onClick}
      {...props}
    >
      <Icon size={17} />
    </button>
  );
}

function App() {
  const [projects, setProjects] = useState(initialProjects);
  const [projectOrder, setProjectOrder] = useState(
    initialProjects.map((_, index) => index),
  );
  const [expandedProjects, setExpandedProjects] = useState([0]);
  const [showAllSessions, setShowAllSessions] = useState([]);
  const [treeCursor, setTreeCursor] = useState(null);
  const [sessionOrder, setSessionOrder] = useState({});
  const [hiddenSessions, setHiddenSessions] = useState({});
  const [treeContext, setTreeContext] = useState(null);
  const [draggingRow, setDraggingRow] = useState(null);
  const [directoryPath, setDirectoryPath] = useState("");
  const [permissionMode, setPermissionMode] = useState("自动");
  const [model, setModel] = useState("Opus 5.5");
  const [effort, setEffort] = useState("默认");
  const [fast, setFast] = useState(false);
  const [runtimeMenu, setRuntimeMenu] = useState(null);
  const [appFontSize, setAppFontSize] = useState(12);
  const [termFontSize, setTermFontSize] = useState(12.5);
  const [followSessionBranch, setFollowSessionBranch] = useState(false);
  const [mcpServers, setMcpServers] = useState([
    {
      id: "files",
      name: "Filesystem",
      description: "项目文件读写",
      transport: "stdio",
      endpoint: "~/project/claude-picker",
      enabled: true,
      connected: true,
      tools: ["read_file", "write_file", "list_directory", "search_files"],
    },
    {
      id: "git",
      name: "Git",
      description: "仓库状态与提交记录",
      transport: "stdio",
      endpoint: "当前项目仓库",
      enabled: true,
      connected: true,
      tools: ["git_status", "git_diff", "git_log", "git_show"],
    },
    {
      id: "docs",
      name: "Docs",
      description: "检索项目文档",
      transport: "HTTP",
      endpoint: "https://docs.example.com/mcp",
      enabled: true,
      connected: false,
      tools: ["search_documents", "read_document"],
    },
  ]);
  const [selectedMcpId, setSelectedMcpId] = useState("files");
  const [addingMcp, setAddingMcp] = useState(false);
  const [newMcpName, setNewMcpName] = useState("");
  const [newMcpEndpoint, setNewMcpEndpoint] = useState("");
  const [newMcpTransport, setNewMcpTransport] = useState("stdio");
  const contextParts = [
    { label: "系统指令", value: 8.2, color: "#a798b6" },
    { label: "工具定义", value: 12.6, color: "#8ba8ba" },
    { label: "会话消息", value: 31.4, color: "#d3a37e" },
    { label: "文件与工具结果", value: 16.2, color: "#a3b391" },
  ];
  const contextUsed = contextParts.reduce(
    (total, part) => total + part.value,
    0,
  );
  const contextTotal = 200;
  const contextPercent = (contextUsed / contextTotal) * 100;
  const selectedMcp = mcpServers.find((server) => server.id === selectedMcpId);

  function updateMcp(id, changes) {
    setMcpServers((current) =>
      current.map((server) =>
        server.id === id ? { ...server, ...changes } : server,
      ),
    );
  }

  function renderContextMeter() {
    return (
      <button
        type="button"
        className="context-meter"
        aria-label={`上下文占用 ${contextUsed.toFixed(1)}k / ${contextTotal}k`}
        onClick={() => setModal("context")}
      >
        <span
          className="context-ring"
          style={{
            "--context-progress": `${contextPercent}%`,
            "--context-color":
              contextPercent >= 80
                ? "#d68f87"
                : contextPercent >= 60
                  ? "#cfb36d"
                  : "#a6b991",
          }}
        />
        <span className="context-tooltip" role="tooltip">
          <strong>上下文窗口</strong>
          <span>
            {contextUsed.toFixed(1)}k / {contextTotal}k ·{" "}
            {contextPercent.toFixed(1)}%
          </span>
          <small>
            剩余 {(contextTotal - contextUsed).toFixed(1)}k · 演示数据
          </small>
        </span>
      </button>
    );
  }
  const [floatingMinimized, setFloatingMinimized] = useState(false);
  const [floatingPosition, setFloatingPosition] = useState(() => ({
    x: Math.max(12, window.innerWidth - 384),
    y: Math.max(56, window.innerHeight - 218),
  }));
  const floatingRef = useRef(null);
  const floatingDragMoved = useRef(false);
  const [projectIndex, setProjectIndex] = useState(0);
  const [sessionProjectIndex, setSessionProjectIndex] = useState(0);
  const [pickedBranch, setPickedBranch] = useState(initialProjects[0].branch);
  const [branchFilter, setBranchFilter] = useState("");
  const [changesCollapsed, setChangesCollapsed] = useState(false);
  const [changesWidth, setChangesWidth] = useState(228);
  const [changeRows, setChangeRows] = useState([46, 24, 30]);
  const changesPaneRef = useRef(null);
  const changeSectionsRef = useRef(null);
  const [session, setSession] = useState(projects[0].sessions[0]);
  const [sidebar, setSidebar] = useState(true);
  const [terminal, setTerminal] = useState(true);
  const [workbench, setWorkbench] = useState(true);
  const [tab, setTab] = useState("工作区");
  const [files, setFiles] = useState(initialFiles);
  const [selectedPath, setSelectedPath] = useState(initialFiles[0].path);
  const [query, setQuery] = useState("");
  const [message, setMessage] = useState("");
  const [history, setHistory] = useState(initialHistory);
  const [branch, setBranch] = useState(projects[0].branch);
  const [menu, setMenu] = useState(null);
  const [modal, setModal] = useState(null);
  const [sessionTitle, setSessionTitle] = useState("");
  const [sessionMode, setSessionMode] = useState("current");
  const [sessionBranch, setSessionBranch] = useState("feature/new-task");
  const [extraSessions, setExtraSessions] = useState({});
  const [toast, setToast] = useState("");
  const [diffMode, setDiffMode] = useState("统一");
  const [fileView, setFileView] = useState("差异");
  const [fileContents, setFileContents] = useState({});
  const [drafts, setDrafts] = useState({});
  const [branchContext, setBranchContext] = useState(null);
  const [prompt, setPrompt] = useState("");
  const [sent, setSent] = useState("");
  const [busy, setBusy] = useState(false);
  const [amend, setAmend] = useState(false);
  const [density, setDensity] = useState("舒适");
  const [terminalWidth, setTerminalWidth] = useState(30);
  const project = projects[projectIndex];
  const sessionProject = projects[sessionProjectIndex];
  const selected = files.find((file) => file.path === selectedPath);
  const staged = files.filter((file) => file.staged);
  const notify = (text) => {
    setToast(text);
    window.clearTimeout(window.prototypeToast);
    window.prototypeToast = window.setTimeout(() => setToast(""), 2800);
  };

  useEffect(() => {
    const handleKey = (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "n") {
        event.preventDefault();
        setModal("session");
      }
      if ((event.metaKey || event.ctrlKey) && event.key === "j") {
        event.preventDefault();
        setTerminal((current) => !current);
      }
      if ((event.metaKey || event.ctrlKey) && event.key === "b") {
        event.preventDefault();
        setSidebar((current) => !current);
      }
      if (event.key === "Escape") {
        setModal(null);
        setMenu(null);
        setBranchContext(null);
        setTreeContext(null);
        setRuntimeMenu(null);
      }
    };
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  }, []);

  useEffect(() => {
    if (!menu && !branchContext && !treeContext && !runtimeMenu) return;
    const dismiss = (event) => {
      if (!event.target.closest(".project-menu-wrap, .branch-context")) {
        setMenu(null);
        setBranchContext(null);
      }
      if (!event.target.closest(".tree-context") && event.button !== 2)
        setTreeContext(null);
      if (!event.target.closest(".runtime-options")) setRuntimeMenu(null);
    };
    window.addEventListener("pointerdown", dismiss);
    return () => window.removeEventListener("pointerdown", dismiss);
  }, [menu, branchContext, treeContext, runtimeMenu]);

  useEffect(() => {
    if (terminal) return;
    const containFloating = () => {
      const bounds = floatingRef.current?.getBoundingClientRect();
      if (!bounds) return;
      setFloatingPosition((position) => ({
        x: Math.max(
          12,
          Math.min(window.innerWidth - bounds.width - 12, position.x),
        ),
        y: Math.max(
          52,
          Math.min(window.innerHeight - bounds.height - 12, position.y),
        ),
      }));
    };
    containFloating();
    window.addEventListener("resize", containFloating);
    return () => window.removeEventListener("resize", containFloating);
  }, [terminal, floatingMinimized]);

  function dragFloating(event) {
    if (event.button !== 0) return;
    const button = event.target.closest("button");
    if (button && button !== event.currentTarget) return;
    const handle = event.currentTarget;
    const panel = floatingRef.current;
    const start = { ...floatingPosition };
    const pointerX = event.clientX;
    const pointerY = event.clientY;
    floatingDragMoved.current = false;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = (move) => {
      const deltaX = move.clientX - pointerX;
      const deltaY = move.clientY - pointerY;
      if (Math.hypot(deltaX, deltaY) <= 4 && !floatingDragMoved.current) return;
      floatingDragMoved.current = true;
      setRuntimeMenu(null);
      setFloatingPosition({
        x: Math.max(
          12,
          Math.min(
            window.innerWidth - panel.offsetWidth - 12,
            start.x + deltaX,
          ),
        ),
        y: Math.max(
          52,
          Math.min(
            window.innerHeight - panel.offsetHeight - 12,
            start.y + deltaY,
          ),
        ),
      });
    };
    const finish = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
      window.setTimeout(() => {
        floatingDragMoved.current = false;
      }, 0);
    };
    handle.onpointerup = finish;
    handle.onpointercancel = finish;
  }

  function toggleProject(index) {
    setTreeCursor(`project-${index}`);
    setExpandedProjects((current) =>
      current.includes(index)
        ? current.filter((item) => item !== index)
        : [...current, index],
    );
  }

  function navigateTree(event) {
    const rows = [
      ...event.currentTarget.querySelectorAll(
        ".project-row, .session-row, .more-sessions",
      ),
    ];
    const current = rows.indexOf(event.target.closest("button"));
    if (current < 0) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      rows[
        Math.max(
          0,
          Math.min(
            rows.length - 1,
            current + (event.key === "ArrowDown" ? 1 : -1),
          ),
        )
      ].focus();
    }
    const group = event.target.closest(".project-group");
    const projectRow = group?.querySelector(".project-row");
    if (event.key === "ArrowRight" && event.target === projectRow) {
      event.preventDefault();
      if (projectRow.getAttribute("aria-expanded") === "false")
        projectRow.click();
      else group.querySelector(".session-row, .more-sessions")?.focus();
    }
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      if (
        event.target === projectRow &&
        projectRow.getAttribute("aria-expanded") === "true"
      )
        projectRow.click();
      else projectRow?.focus();
    }
  }

  function projectSessions(index) {
    const all = [...(extraSessions[index] ?? []), ...projects[index].sessions];
    const order = sessionOrder[index] ?? all;
    return [
      ...all.filter((name) => !order.includes(name)),
      ...order.filter((name) => all.includes(name)),
    ].filter((name) => !(hiddenSessions[index] ?? []).includes(name));
  }

  function sessionTime(index, name) {
    const originalIndex = projects[index].sessions.indexOf(name);
    return originalIndex <= 0 ? "刚刚" : `${originalIndex + 1} 小时前`;
  }

  function openTreeContext(event, index, name = null) {
    event.preventDefault();
    setMenu(null);
    setBranchContext(null);
    setTreeContext({
      index,
      name,
      x: Math.min(event.clientX, innerWidth - 210),
      y: Math.min(event.clientY, innerHeight - 190),
    });
  }

  function treeAction(action) {
    const { index, name } = treeContext;
    if (action === "新建对话") {
      if (index !== projectIndex) selectProject(index);
      setExpandedProjects((current) => [...new Set([...current, index])]);
      setModal("session");
    }
    if (action === "置顶") {
      if (name)
        setSessionOrder((current) => ({
          ...current,
          [index]: [
            name,
            ...projectSessions(index).filter((item) => item !== name),
          ],
        }));
      else
        setProjectOrder((current) => [
          index,
          ...current.filter((item) => item !== index),
        ]);
    }
    if (action === "展开" || action === "收起") toggleProject(index);
    if (action === "在访达中显示")
      notify(`访达定位演示 · ~/project/${projects[index].name}`);
    if (action === "从列表移除") {
      if (name)
        setHiddenSessions((current) => ({
          ...current,
          [index]: [...(current[index] ?? []), name],
        }));
      else
        setProjectOrder((current) => current.filter((item) => item !== index));
    }
    setTreeContext(null);
  }

  function dropRow(event, index, name = null) {
    event.preventDefault();
    if (
      !draggingRow ||
      (draggingRow.index === index && draggingRow.name === name) ||
      (!draggingRow.name && !name && draggingRow.index === index)
    )
      return;
    if (!name && !draggingRow.name) {
      setProjectOrder((current) => {
        const order = current.filter((item) => item !== draggingRow.index);
        order.splice(order.indexOf(index), 0, draggingRow.index);
        return order;
      });
    }
    if (name && draggingRow.name && draggingRow.index === index) {
      const order = projectSessions(index).filter(
        (item) => item !== draggingRow.name,
      );
      order.splice(order.indexOf(name), 0, draggingRow.name);
      setSessionOrder((current) => ({ ...current, [index]: order }));
    }
    setDraggingRow(null);
  }

  function selectProject(index, keepSession = false) {
    setProjectIndex(index);
    setBranch(projects[index].branch);
    if (!keepSession) {
      setSession(projects[index].sessions[0]);
      setSessionProjectIndex(index);
    }
    setFiles(
      initialFiles.map((file) => ({
        ...file,
        path: index
          ? file.path.replace("ClaudeDeck", "Application")
          : file.path,
      })),
    );
    setSelectedPath(
      index ? "Sources/Application/main.swift" : initialFiles[0].path,
    );
    setMessage("");
    setQuery("");
    setMenu(null);
    setBranchContext(null);
    setFileView("差异");
  }

  function openBranchContext(event, name) {
    event.preventDefault();
    setBranchContext({
      name,
      x: Math.min(event.clientX, window.innerWidth - 218),
      y: Math.min(event.clientY, window.innerHeight - 238),
    });
  }

  function checkoutBranch(name) {
    setBranch(name.replace(/^origin\//, ""));
    setMenu(null);
    notify("已切换演示分支");
  }

  function branchAction(action) {
    const name = branchContext.name;
    if (action === "切换分支") setBranch(name);
    notify(`${action} · ${name}（演示）`);
    setBranchContext(null);
    setMenu(null);
  }

  function originalContent(path) {
    if (path.endsWith(".md")) {
      return "# 界面交互说明\n\n项目、会话与工作台共用当前项目上下文。\n\n## 文件操作\n\n- 点击变更文件查看差异。\n- 在同一面板切换预览与编辑。\n- 保存后继续查看其他文件。";
    }
    if (path.endsWith(".css")) {
      return ".workspace {\n  display: flex;\n  min-height: 0;\n  background: #18191c;\n}\n\n.file-row {\n  display: flex;\n  align-items: center;\n  gap: 8px;\n}";
    }
    if (path.endsWith(".jsx")) {
      return 'export default function Workspace() {\n  return (\n    <main className="workspace">\n      <ChangedFiles />\n      <FilePreview />\n    </main>\n  );\n}';
    }
    if (path.endsWith("Models.swift")) {
      return "struct AppSettings: Codable {\n    var sidebarWidth: Double = 248\n    var terminalCollapsed = false\n    var thirdPaneVisible = true\n}\n\nstruct Project {\n    var title: String\n    var path: String\n}";
    }
    return changes
      .filter((line) => line[0] !== "del")
      .map((line) => line[3])
      .join("\n");
  }

  const savedContent =
    fileContents[selectedPath] ?? originalContent(selectedPath);
  const draftContent = drafts[selectedPath] ?? savedContent;
  const hasEdits = draftContent !== savedContent;

  function saveFile() {
    setFileContents((current) => ({
      ...current,
      [selectedPath]: draftContent,
    }));
    setFiles((current) =>
      current.map((file) =>
        file.path === selectedPath
          ? { ...file, status: "M", staged: false }
          : file,
      ),
    );
    notify("演示文件已保存到浏览器内存");
  }

  function renderFile() {
    if (!selected) return renderDiff();
    return (
      <>
        <div
          className="file-view-tabs"
          role="tablist"
          aria-label="文件查看方式"
        >
          {["差异", "预览", "编辑"].map((view) => (
            <button
              key={view}
              role="tab"
              aria-selected={fileView === view}
              className={fileView === view ? "selected" : ""}
              onClick={() => setFileView(view)}
            >
              {view}
            </button>
          ))}
          {fileView === "编辑" && (
            <button
              className="save-file"
              disabled={!hasEdits}
              onClick={saveFile}
            >
              <Check size={13} />
              {hasEdits ? "保存修改" : "已保存"}
            </button>
          )}
        </div>
        {fileView === "差异" ? (
          renderDiff()
        ) : (
          <>
            <div className="diff-heading">
              <span>
                <FileText size={16} />
                {selectedPath.split("/").pop()}
              </span>
              <small>
                {fileView === "编辑" ? "浏览器内演示编辑" : "文件预览"}
              </small>
            </div>
            <div className="file-path">{selectedPath}</div>
            {fileView === "编辑" ? (
              <textarea
                className="file-editor"
                aria-label="编辑文件内容"
                spellCheck={false}
                value={draftContent}
                onChange={(event) =>
                  setDrafts((current) => ({
                    ...current,
                    [selectedPath]: event.target.value,
                  }))
                }
              />
            ) : selectedPath.endsWith(".md") ? (
              <article className="document">
                {savedContent
                  .split("\n")
                  .map((line, index) =>
                    line.startsWith("# ") ? (
                      <h1 key={index}>{line.slice(2)}</h1>
                    ) : line.startsWith("## ") ? (
                      <h2 key={index}>{line.slice(3)}</h2>
                    ) : (
                      <p key={index}>{line}</p>
                    ),
                  )}
              </article>
            ) : (
              <div className="source-preview">
                {savedContent.split("\n").map((line, index) => (
                  <div key={index}>
                    <span>{index + 1}</span>
                    <code>{line || " "}</code>
                  </div>
                ))}
              </div>
            )}
          </>
        )}
      </>
    );
  }

  function stage(path) {
    setFiles((current) =>
      current.map((file) =>
        file.path === path ? { ...file, staged: !file.staged } : file,
      ),
    );
  }

  function commit() {
    setHistory((current) => [
      [message.trim(), "demo" + (current.length + 1), "刚刚"],
      ...(amend ? current.slice(1) : current),
    ]);
    const remaining = files.filter((file) => !file.staged);
    setFiles(remaining);
    setSelectedPath(remaining[0]?.path ?? "");
    setAmend(false);
    setMessage("");
    notify("演示提交已创建，真实仓库未发生修改");
  }

  function beginResize(event) {
    const body = event.currentTarget.parentElement;
    event.currentTarget.setPointerCapture(event.pointerId);
    const move = (e) => {
      const rect = body.getBoundingClientRect();
      const sidebarWidth = sidebar ? 248 : 48;
      setTerminalWidth(
        Math.max(
          24,
          Math.min(
            57,
            ((e.clientX - rect.left - sidebarWidth) /
              (rect.width - sidebarWidth)) *
              100,
          ),
        ),
      );
    };
    event.currentTarget.onpointermove = move;
    event.currentTarget.onpointerup = (e) => {
      e.currentTarget.onpointermove = null;
      e.currentTarget.onpointerup = null;
    };
  }

  function trackPaneDrag(event, onMove) {
    if (event.button !== 0) return;
    event.preventDefault();
    const handle = event.currentTarget;
    handle.setPointerCapture(event.pointerId);
    handle.onpointermove = onMove;
    const finish = () => {
      handle.onpointermove = null;
      handle.onpointerup = null;
      handle.onpointercancel = null;
    };
    handle.onpointerup = finish;
    handle.onpointercancel = finish;
  }

  function resizeChangesWidth(event) {
    const pane = changesPaneRef.current;
    const startWidth = pane.getBoundingClientRect().width;
    const startX = event.clientX;
    const maximum = Math.max(
      170,
      pane.parentElement.getBoundingClientRect().width - 185,
    );
    trackPaneDrag(event, (move) =>
      setChangesWidth(
        Math.max(170, Math.min(maximum, startWidth + move.clientX - startX)),
      ),
    );
  }

  function changeSectionHeights() {
    return [
      ...changeSectionsRef.current.querySelectorAll("[data-change-section]"),
    ].map((element) => element.getBoundingClientRect().height);
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
      setChangeRows(
        adjustedChangeRows(heights, divider, move.clientY - startY),
      ),
    );
  }

  function renderChangeDivider(divider) {
    return (
      <div
        className="change-row-divider"
        role="separator"
        aria-orientation="horizontal"
        aria-label={
          divider === 0
            ? "调整未暂存与已暂存区域高度"
            : "调整文件列表与提交区域高度"
        }
        tabIndex={0}
        title="上下拖动调整高度，双击恢复默认"
        onPointerDown={(event) => resizeChangeSections(event, divider)}
        onDoubleClick={() => setChangeRows([46, 24, 30])}
        onKeyDown={(event) => {
          if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
          event.preventDefault();
          setChangeRows(
            adjustedChangeRows(
              changeSectionHeights(),
              divider,
              event.key === "ArrowUp" ? -16 : 16,
            ),
          );
        }}
      >
        <span />
      </div>
    );
  }

  function renderDiff() {
    const before = originalContent(selectedPath).split("\n");
    const after = savedContent.split("\n");
    const visibleChanges =
      fileContents[selectedPath] !== undefined
        ? [
            ...before.map((line, index) => ["del", index + 1, "", line]),
            ...after.map((line, index) => ["add", "", index + 1, line]),
          ]
        : selectedPath.endsWith("main.swift")
          ? changes
          : before.map((line, index) => [
              index < before.length - 2 ? "context" : "add",
              index + 1,
              index + 1,
              line,
            ]);
    return (
      <>
        <div className="diff-heading">
          <span>
            <FileCode size={16} />
            {selected?.path.split("/").pop() ?? "选择文件查看差异"}
          </span>
          <div className="segmented">
            {["并排", "统一"].map((mode) => (
              <button
                className={diffMode === mode ? "chosen" : ""}
                onClick={() => setDiffMode(mode)}
                key={mode}
              >
                {mode}
              </button>
            ))}
          </div>
        </div>
        {selected ? (
          <>
            <div className="file-path">
              {selected.path}
              <span>
                <b className="green">+{selected.add}</b>
                <b className="red">−{selected.del}</b>
              </span>
            </div>
            <div className="hunk">
              <code>
                {selectedPath.endsWith("main.swift") &&
                fileContents[selectedPath] === undefined
                  ? "@@ −38,15 +38,18 @@"
                  : `@@ −1,${before.length} +1,${after.length} @@`}
              </code>
              <button onClick={() => stage(selected.path)}>
                {selected.staged ? "取消暂存" : "暂存文件"}
                <Plus size={13} />
              </button>
            </div>
            <div
              className={`code-diff ${diffMode === "并排" ? "split-diff" : ""}`}
            >
              {diffMode === "并排"
                ? ["before", "after"].map((side) => (
                    <div key={side}>
                      {visibleChanges
                        .filter((line) =>
                          side === "before"
                            ? line[0] !== "add"
                            : line[0] !== "del",
                        )
                        .map((line, i) => (
                          <div className={`code-line ${line[0]}`} key={i}>
                            <span>{side === "before" ? line[1] : line[2]}</span>
                            <code>{line[3]}</code>
                          </div>
                        ))}
                    </div>
                  ))
                : visibleChanges.map((line, i) => (
                    <div className={`code-line ${line[0]}`} key={i}>
                      <span>{line[1]}</span>
                      <span>{line[2]}</span>
                      <em>
                        {line[0] === "add"
                          ? "+"
                          : line[0] === "del"
                            ? "−"
                            : " "}
                      </em>
                      <code>{line[3]}</code>
                    </div>
                  ))}
            </div>
            <div className="diff-end">
              <Checks size={16} />
              已显示全部文件差异
            </div>
          </>
        ) : (
          <div className="empty">
            <Check size={30} />
            <h3>{files.length ? "选择文件查看差异" : "工作区已清理"}</h3>
            <p>
              {files.length
                ? "从左侧变更列表中选择一个文件"
                : "下一次修改会显示在这里"}
            </p>
          </div>
        )}
      </>
    );
  }

  function renderComposer() {
    return (
      <form
        className="terminal-input"
        onSubmit={(event) => {
          event.preventDefault();
          if (!prompt.trim()) return;
          setSent(prompt);
          setPrompt("");
          setBusy(true);
          setTimeout(() => setBusy(false), 900);
        }}
      >
        <textarea
          aria-label="终端演示输入"
          value={prompt}
          onChange={(event) => setPrompt(event.target.value)}
          placeholder="继续对话，或输入 / 查看命令"
        />
        <div className="terminal-controls">
          <div className="runtime-options">
            {[
              {
                id: "mode",
                label: "模式",
                value: permissionMode,
                values: ["自动", "手动", "接受编辑", "规划"],
                select: setPermissionMode,
              },
              {
                id: "model",
                label: "模型",
                value: model,
                values: ["Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Fable 5.5"],
                select: setModel,
              },
              {
                id: "effort",
                label: "推理强度",
                value: effort,
                values: ["默认", "低", "高", "极高", "最高"],
                select: setEffort,
              },
            ].map((setting) => (
              <div className="runtime-setting" key={setting.id}>
                <button
                  type="button"
                  className="runtime-value"
                  title={setting.label}
                  aria-label={`${setting.label}：${setting.value}`}
                  aria-expanded={runtimeMenu === setting.id}
                  onClick={() =>
                    setRuntimeMenu(
                      runtimeMenu === setting.id ? null : setting.id,
                    )
                  }
                >
                  {setting.value}
                </button>
                {runtimeMenu === setting.id && (
                  <div
                    className="runtime-popover"
                    role="menu"
                    aria-label={`选择${setting.label}`}
                  >
                    {setting.values.map((value) => (
                      <button
                        type="button"
                        role="menuitemradio"
                        aria-checked={setting.value === value}
                        key={value}
                        onClick={() => {
                          setting.select(value);
                          setRuntimeMenu(null);
                        }}
                      >
                        {value}
                        {setting.value === value && <Check size={12} />}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            ))}
            <button
              type="button"
              className={`fast-toggle ${fast ? "fast-on" : ""}`}
              title={`快速模式：${fast ? "开启" : "关闭"}`}
              aria-label={`快速模式${fast ? "开启" : "关闭"}`}
              aria-pressed={fast}
              onClick={() => setFast(!fast)}
            >
              <Lightning size={13} weight={fast ? "fill" : "regular"} />
            </button>
            {renderContextMeter()}
          </div>
          <button
            className="send"
            aria-label="发送演示消息"
            disabled={!prompt.trim() || busy}
          >
            <ArrowUp size={16} />
          </button>
        </div>
      </form>
    );
  }

  return (
    <div
      className={`app ${density === "紧凑" ? "compact" : ""}`}
      style={{
        "--app-scale": appFontSize / 12,
        "--terminal-font-size": `${termFontSize}px`,
      }}
    >
      <header className="titlebar">
        <div className={`window-brand ${sidebar ? "" : "sidebar-hidden"}`}>
          <div className="window-controls">
            <i />
            <i />
            <i />
          </div>
        </div>
        {terminal && workbench && (
          <div
            className="titlebar-spacer"
            style={{ flexBasis: `${terminalWidth}%` }}
          />
        )}
        {workbench ? (
          <div className="workbench-header">
            <div className="project-menu-wrap">
              <button
                className="branch-picker"
                aria-label="选择分支"
                onClick={() => setMenu(menu === "branch" ? null : "branch")}
                onContextMenu={(event) => openBranchContext(event, branch)}
              >
                <GitBranch size={15} />
                <b>{branch}</b>
                <CaretDown size={12} />
              </button>
              {menu === "branch" && (
                <div
                  className="dropdown project-branch-dropdown"
                  role="dialog"
                  aria-label="项目与分支"
                >
                  <div className="branch-project-list">
                    <div className="menu-title">项目</div>
                    {projectOrder.map((index) => (
                      <button
                        key={index}
                        className={projectIndex === index ? "selected" : ""}
                        title={`~/project/${projects[index].name}`}
                        onClick={() => {
                          selectProject(index, true);
                          setPickedBranch(projects[index].branch);
                          setBranchFilter("");
                          setMenu("branch");
                        }}
                      >
                        <Folder
                          size={14}
                          weight={projectIndex === index ? "fill" : "regular"}
                        />
                        <span>{projects[index].name}</span>
                      </button>
                    ))}
                  </div>
                  <div className="branch-options">
                    <label className="search">
                      <MagnifyingGlass size={13} />
                      <input
                        aria-label="筛选分支"
                        placeholder="筛选分支…"
                        value={branchFilter}
                        onChange={(event) =>
                          setBranchFilter(event.target.value)
                        }
                      />
                    </label>
                    {["本地分支", "远程分支"].map((group) => (
                      <div key={group}>
                        <div className="menu-title">{group}</div>
                        {[
                          ...new Set([
                            project.branch,
                            "main",
                            "feature/session-layout",
                            "origin/main",
                          ]),
                        ]
                          .filter(
                            (name) =>
                              name.includes(branchFilter) &&
                              name.startsWith("origin/") ===
                                (group === "远程分支"),
                          )
                          .map((name) => (
                            <button
                              key={name}
                              className={`${pickedBranch === name ? "picked" : ""} ${branch === name ? "current" : ""}`}
                              onClick={() => setPickedBranch(name)}
                              onDoubleClick={() => checkoutBranch(name)}
                              onKeyDown={(event) => {
                                if (event.key === "Enter") {
                                  event.preventDefault();
                                  checkoutBranch(name);
                                }
                              }}
                              onContextMenu={(event) => {
                                setPickedBranch(name);
                                openBranchContext(event, name);
                              }}
                            >
                              <GitBranch size={14} />
                              <span>{name}</span>
                              {branch === name && <Check size={13} />}
                            </button>
                          ))}
                      </div>
                    ))}
                    <div className="branch-picker-hint">
                      双击签出 · 右键更多操作
                    </div>
                  </div>
                </div>
              )}
            </div>
            <nav className="git-nav">
              {tabs.map(([name, Icon]) => (
                <button
                  className={tab === name ? "selected" : ""}
                  onClick={() => setTab(name)}
                  key={name}
                >
                  <Icon size={16} />
                  {name}
                  {name === "工作区" && <span>{files.length}</span>}
                </button>
              ))}
              <IconButton
                icon={ArrowsClockwise}
                label="刷新演示数据"
                onClick={() => {
                  setFiles(initialFiles);
                  setSelectedPath(initialFiles[0].path);
                  notify("演示数据已恢复");
                }}
              />
            </nav>
            <IconButton
              icon={Minus}
              label="收起工作台"
              onClick={() => setWorkbench(false)}
            />
          </div>
        ) : (
          <IconButton
            icon={Code}
            label="展开工作台"
            className="icon-button titlebar-restore"
            onClick={() => setWorkbench(true)}
          />
        )}
      </header>
      <div className="layout">
        <aside className={`sidebar ${sidebar ? "" : "collapsed"}`}>
          {sidebar ? (
            <>
              <div className="sidebar-heading">
                <img src={appIcon} alt="" />
                <div className="sidebar-brand">
                  <strong>Claude Code</strong>
                  <small>
                    {projectOrder.length} 个目录 ·{" "}
                    {projectOrder.reduce(
                      (count, index) =>
                        count +
                        1 +
                        (expandedProjects.includes(index)
                          ? (showAllSessions.includes(index)
                              ? projectSessions(index).length
                              : Math.min(5, projectSessions(index).length)) +
                            (projectSessions(index).length > 5 ? 1 : 0)
                          : 0),
                      0,
                    )}{" "}
                    行
                  </small>
                </div>
                <div className="sidebar-header-actions">
                  <IconButton
                    icon={SidebarSimple}
                    label="收起侧边栏"
                    onClick={() => setSidebar(false)}
                  />
                  {!terminal && (
                    <IconButton
                      icon={Terminal}
                      label="展开终端"
                      onClick={() => setTerminal(true)}
                    />
                  )}
                </div>
              </div>
              <div className="project-list" onKeyDown={navigateTree}>
                {projectOrder.map((index) => {
                  const item = projects[index];
                  const expanded = expandedProjects.includes(index);
                  return (
                    <section className="project-group" key={item.name}>
                      <button
                        className={`project-row ${index === projectIndex ? "current" : ""} ${treeCursor === `project-${index}` ? "cursor" : ""}`}
                        aria-expanded={expanded}
                        draggable
                        onDragStart={() => setDraggingRow({ index })}
                        onDragEnd={() => setDraggingRow(null)}
                        onDragOver={(event) => event.preventDefault()}
                        onDrop={(event) => dropRow(event, index)}
                        onContextMenu={(event) => openTreeContext(event, index)}
                        onClick={() => toggleProject(index)}
                      >
                        {expanded ? (
                          <CaretDown size={10} />
                        ) : (
                          <CaretRight size={10} />
                        )}
                        <Folder size={15} weight="fill" />
                        <strong>{item.name}</strong>
                        <span>{projectSessions(index).length}</span>
                      </button>
                      {expanded && (
                        <div className="sessions">
                          {projectSessions(index)
                            .slice(
                              0,
                              showAllSessions.includes(index) ? undefined : 5,
                            )
                            .map((name) => (
                              <button
                                className={`session-row ${sessionProjectIndex === index && session === name ? "selected" : ""}`}
                                key={name}
                                draggable
                                onDragStart={() =>
                                  setDraggingRow({ index, name })
                                }
                                onDragEnd={() => setDraggingRow(null)}
                                onDragOver={(event) => event.preventDefault()}
                                onDrop={(event) => dropRow(event, index, name)}
                                onContextMenu={(event) =>
                                  openTreeContext(event, index, name)
                                }
                                onClick={() => {
                                  if (index !== projectIndex)
                                    selectProject(index);
                                  if (followSessionBranch)
                                    setBranch(projects[index].branch);
                                  setSession(name);
                                  setTreeCursor(`session-${index}-${name}`);
                                  setTerminal(true);
                                }}
                              >
                                <span
                                  className={`session-marker ${busy && index === projectIndex && session === name ? "running" : ""}`}
                                >
                                  {busy &&
                                    index === projectIndex &&
                                    session === name && (
                                      <CircleNotch size={12} />
                                    )}
                                </span>
                                <span>
                                  <b>{name}</b>
                                  <small>{sessionTime(index, name)}</small>
                                </span>
                              </button>
                            ))}
                          {projectSessions(index).length > 5 && (
                            <button
                              className={`more-sessions ${treeCursor === `more-${index}` ? "cursor" : ""}`}
                              onClick={() => {
                                setTreeCursor(`more-${index}`);
                                setShowAllSessions((current) =>
                                  current.includes(index)
                                    ? current.filter((item) => item !== index)
                                    : [...current, index],
                                );
                              }}
                            >
                              {showAllSessions.includes(index)
                                ? "收起"
                                : `展开其余 ${projectSessions(index).length - 5} 条`}
                              {showAllSessions.includes(index) ? (
                                <CaretUp size={9} />
                              ) : (
                                <CaretDown size={9} />
                              )}
                            </button>
                          )}
                        </div>
                      )}
                    </section>
                  );
                })}
              </div>
              <button
                className="add-directory"
                onClick={() => setModal("directory")}
              >
                <Plus size={12} />
                添加目录
              </button>
              <div className="sidebar-bottom">
                <IconButton
                  icon={Gear}
                  label="界面设置"
                  onClick={() => setModal("settings")}
                />
                <div className="usage-bars">
                  <div
                    className="usage-row"
                    title="本 5 小时窗口 40%，23:50 重置"
                  >
                    <div className="usage-track">
                      <i style={{ width: "40%" }} />
                    </div>
                    <span>23:50&nbsp; 40%</span>
                  </div>
                  <div
                    className="usage-row weekly"
                    title="本周 26%，11-18 重置"
                  >
                    <div className="usage-track">
                      <i style={{ width: "26%" }} />
                    </div>
                    <span>11-18&nbsp; 26%</span>
                  </div>
                </div>
              </div>
            </>
          ) : (
            <>
              <IconButton
                icon={SidebarSimple}
                label="展开项目侧栏"
                onClick={() => setSidebar(true)}
              />
              {!terminal && (
                <IconButton
                  icon={Terminal}
                  label="展开终端"
                  onClick={() => setTerminal(true)}
                />
              )}
              {projectOrder.map((index) => (
                <IconButton
                  icon={Folder}
                  key={projects[index].name}
                  label={projects[index].name}
                  active={index === projectIndex}
                  onClick={() => selectProject(index)}
                />
              ))}
              <IconButton
                icon={Plus}
                label="新建会话"
                onClick={() => setModal("session")}
              />
            </>
          )}
        </aside>

        {terminal ? (
          <section
            className="terminal-pane"
            style={{ flexBasis: workbench ? `${terminalWidth}%` : "100%" }}
          >
            <IconButton
              icon={CaretDoubleLeft}
              label="收起终端"
              className="icon-button terminal-collapse"
              onClick={() => setTerminal(false)}
            />
            <div className="terminal-content">
              <div className="terminal-intro">
                <img src={appIcon} alt="Claude" />
                <div>
                  <strong>Claude Code</strong>
                  <span>
                    {model} · {sessionProject.name}
                  </span>
                </div>
              </div>
              <p className="terminal-user">整理一下当前分支的界面与交互。</p>
              <div className="terminal-response">
                <span className="orange">●</span>
                <div>
                  我先查看项目结构和当前布局，再梳理各区域的交互关系。
                  <div className="tool-call">
                    <CaretRight size={12} />
                    <b>Read</b>
                    <span>Sources/ClaudeDeck/main.swift</span>
                    <Check size={13} />
                  </div>
                  <div className="tool-call">
                    <CaretRight size={12} />
                    <b>Read</b>
                    <span>Web/src/App.jsx</span>
                    <Check size={13} />
                  </div>
                </div>
              </div>
              <div className="terminal-response">
                <span className="orange">●</span>
                <div>
                  当前界面包含三个主要区域。
                  <ul>
                    <li>项目与会话，负责定位工作上下文。</li>
                    <li>终端，承载与 Claude 的对话。</li>
                    <li>工作台，查看变更、分支与文件。</li>
                  </ul>
                  你可以在右侧查看本次界面调整的文件差异。
                </div>
              </div>
              <div className="terminal-complete">
                <Check size={13} />
                完成 · 用时 18 秒
              </div>
              {sent && (
                <>
                  <p className="terminal-user">{sent}</p>
                  <div className="terminal-response">
                    <span className="orange">●</span>
                    <div>
                      {busy
                        ? "正在整理演示回复…"
                        : "已收到。这是界面原型中的演示对话，可继续体验右侧工作台。"}
                    </div>
                  </div>
                </>
              )}
            </div>
            {renderComposer()}
          </section>
        ) : null}

        {terminal && workbench && (
          <div
            className="resizer"
            role="separator"
            aria-label="拖动调整终端宽度"
            onPointerDown={beginResize}
            onDoubleClick={() => setTerminalWidth(30)}
          />
        )}

        {workbench ? (
          <main className="workbench">
            <>
              {tab === "工作区" ? (
                <div className="workspace">
                  {changesCollapsed ? (
                    <aside className="changes-rail">
                      <IconButton
                        icon={CaretRight}
                        label="展开变更文件"
                        onClick={() => setChangesCollapsed(false)}
                      />
                      <span>变更 {files.length}</span>
                    </aside>
                  ) : (
                    <>
                      <section
                        className="changes-pane"
                        ref={changesPaneRef}
                        style={{ width: changesWidth }}
                      >
                        <div className="section-heading">
                          <IconButton
                            icon={CaretDoubleLeft}
                            label="收起变更文件"
                            onClick={() => setChangesCollapsed(true)}
                          />
                          <strong>
                            变更文件 <span>{files.length}</span>
                          </strong>
                          <IconButton
                            icon={Plus}
                            label="全部暂存"
                            onClick={() =>
                              setFiles((current) =>
                                current.map((file) => ({
                                  ...file,
                                  staged: true,
                                })),
                              )
                            }
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
                          {[false, true].map((isStaged, divider) => (
                            <React.Fragment key={String(isStaged)}>
                              <div
                                className="file-group"
                                data-change-section={
                                  isStaged ? "staged" : "unstaged"
                                }
                              >
                                <div className="group-label">
                                  <CaretDown size={11} />
                                  {isStaged ? "已暂存" : "未暂存"}
                                  <span>
                                    {
                                      files.filter(
                                        (file) => file.staged === isStaged,
                                      ).length
                                    }
                                  </span>
                                  {isStaged && (
                                    <button
                                      title="取消全部暂存"
                                      onClick={() =>
                                        setFiles((current) =>
                                          current.map((file) => ({
                                            ...file,
                                            staged: false,
                                          })),
                                        )
                                      }
                                    >
                                      <Minus size={13} />
                                    </button>
                                  )}
                                </div>
                                <div className="file-group-scroll">
                                  {files
                                    .filter(
                                      (file) =>
                                        file.staged === isStaged &&
                                        file.path
                                          .toLowerCase()
                                          .includes(query.toLowerCase()),
                                    )
                                    .map((file) => (
                                      <div
                                        key={file.path}
                                        className={`file-row ${selectedPath === file.path ? "selected" : ""}`}
                                      >
                                        <button
                                          className="file-select"
                                          title={file.path}
                                          onClick={() => {
                                            setSelectedPath(file.path);
                                            setFileView("差异");
                                          }}
                                        >
                                          <FileCode size={15} />
                                          <span>
                                            <b>{file.path.split("/").pop()}</b>
                                            <small>
                                              {file.path
                                                .split("/")
                                                .slice(0, -1)
                                                .join("/")}
                                            </small>
                                          </span>
                                          <em
                                            className={
                                              file.staged
                                                ? "green"
                                                : file.status === "?"
                                                  ? "blue"
                                                  : "amber"
                                            }
                                          >
                                            {file.status}
                                          </em>
                                        </button>
                                        <IconButton
                                          icon={file.staged ? Minus : Plus}
                                          label={
                                            (file.staged
                                              ? "取消暂存 "
                                              : "暂存 ") + file.path
                                          }
                                          onClick={() => stage(file.path)}
                                        />
                                      </div>
                                    ))}
                                </div>
                              </div>
                              {renderChangeDivider(divider)}
                            </React.Fragment>
                          ))}
                          <div
                            className="commit-form"
                            data-change-section="commit"
                          >
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
                              onChange={(event) =>
                                setMessage(event.target.value)
                              }
                            />
                            <div className="commit-options">
                              <label>
                                <input
                                  type="checkbox"
                                  checked={amend}
                                  onChange={(event) =>
                                    setAmend(event.target.checked)
                                  }
                                />
                                Amend
                              </label>
                              <DotsThree size={16} />
                            </div>
                            <button
                              className="primary commit-button"
                              disabled={!staged.length || !message.trim()}
                              onClick={commit}
                            >
                              <Check size={15} />
                              提交
                              {staged.length > 0 && ` ${staged.length} 个文件`}
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
                        onDoubleClick={() => setChangesWidth(228)}
                        onKeyDown={(event) => {
                          if (
                            event.key !== "ArrowLeft" &&
                            event.key !== "ArrowRight"
                          )
                            return;
                          event.preventDefault();
                          const maximum = Math.max(
                            170,
                            changesPaneRef.current.parentElement.getBoundingClientRect()
                              .width - 185,
                          );
                          setChangesWidth(
                            Math.max(
                              170,
                              Math.min(
                                maximum,
                                changesPaneRef.current.getBoundingClientRect()
                                  .width +
                                  (event.key === "ArrowLeft" ? -16 : 16),
                              ),
                            ),
                          );
                        }}
                      />
                    </>
                  )}
                  <section className="diff-pane">{renderFile()}</section>
                </div>
              ) : tab === "提交历史" ? (
                <div className="history-page">
                  <div className="page-heading">
                    <h2>提交历史</h2>
                    <span>{branch}</span>
                  </div>
                  {history.map(([title, hash, when]) => (
                    <button
                      className="history-row"
                      key={hash}
                      onClick={() => {
                        setSelectedPath(files[0]?.path ?? "");
                        setTab("工作区");
                      }}
                    >
                      <GitCommit size={19} />
                      <span>
                        <strong>{title}</strong>
                        <small>曾长亮 · {when}</small>
                      </span>
                      <code>{hash}</code>
                      <CaretRight size={14} />
                    </button>
                  ))}
                </div>
              ) : tab === "分支" ? (
                <div className="history-page">
                  <div className="page-heading">
                    <h2>本地分支</h2>
                    <button onClick={() => setModal("session")}>
                      <Plus size={14} />
                      新建会话
                    </button>
                  </div>
                  {[project.branch, "main", "feature/session-layout"].map(
                    (name) => (
                      <div className="history-row" key={name}>
                        <GitBranch size={18} />
                        <span>
                          <strong>{name}</strong>
                          <small>
                            {name === branch
                              ? "当前分支 · 工作区所在位置"
                              : "最近更新于 2 小时前"}
                          </small>
                        </span>
                        <button
                          disabled={name === branch}
                          onClick={() => {
                            setBranch(name);
                            notify("演示分支已切换");
                          }}
                        >
                          {name === branch ? <Check size={14} /> : "切换"}
                        </button>
                      </div>
                    ),
                  )}
                </div>
              ) : tab === "工作树" ? (
                <div className="history-page">
                  <div className="page-heading">
                    <h2>工作树</h2>
                    <button
                      onClick={() => {
                        setSessionMode("worktree");
                        setModal("session");
                      }}
                    >
                      <Plus size={14} />
                      新建工作树会话
                    </button>
                  </div>
                  <div className="history-row">
                    <TreeStructure size={20} />
                    <span>
                      <strong>{project.name}</strong>
                      <small>~/project/{project.name}</small>
                    </span>
                    <code>{branch}</code>
                  </div>
                </div>
              ) : (
                <div className="history-page">
                  <div className="page-heading">
                    <h2>更多 Git 操作</h2>
                  </div>
                  {[
                    ["合并与冲突", GitMerge],
                    ["Stash 暂存", Stack],
                    ["操作日志", ClockCounterClockwise],
                  ].map(([name, Icon]) => (
                    <button
                      className="history-row"
                      key={name}
                      onClick={() =>
                        notify(name + "入口已选中，详细流程待确认")
                      }
                    >
                      <Icon size={20} />
                      <span>
                        <strong>{name}</strong>
                      </span>
                      <CaretRight size={15} />
                    </button>
                  ))}
                </div>
              )}
            </>
          </main>
        ) : (
          <div className="workbench-rail">
            <IconButton
              icon={Code}
              label="展开工作台"
              onClick={() => setWorkbench(true)}
            />
            <span>工作台</span>
          </div>
        )}
      </div>
      {!terminal &&
        (floatingMinimized ? (
          <button
            ref={floatingRef}
            className={`composer-bubble ${busy ? "busy" : ""}`}
            style={{ left: floatingPosition.x, top: floatingPosition.y }}
            aria-label="展开悬浮输入框"
            title="展开输入框 · 拖动可移动"
            onPointerDown={dragFloating}
            onClick={() => {
              if (floatingDragMoved.current) {
                floatingDragMoved.current = false;
                return;
              }
              setFloatingMinimized(false);
            }}
          >
            <img src={appIcon} alt="" />
          </button>
        ) : (
          <section
            ref={floatingRef}
            className={`floating-composer ${floatingPosition.y < 220 ? "near-top" : ""}`}
            style={{ left: floatingPosition.x, top: floatingPosition.y }}
            aria-label="悬浮输入框"
          >
            <div
              className="floating-composer-header"
              onPointerDown={dragFloating}
            >
              <img src={appIcon} alt="" />
              <small role="status">{busy ? "正在思考…" : "当前会话"}</small>
              <IconButton
                icon={Minus}
                label="缩小为圆形浮标"
                onClick={() => {
                  setRuntimeMenu(null);
                  floatingDragMoved.current = false;
                  setFloatingMinimized(true);
                }}
              />
              <IconButton
                icon={Terminal}
                label="恢复第二栏"
                onClick={() => setTerminal(true)}
              />
            </div>
            {renderComposer()}
          </section>
        ))}
      {treeContext && (
        <div
          className="branch-context tree-context"
          role="menu"
          aria-label="项目与会话操作"
          style={{ left: treeContext.x, top: treeContext.y }}
        >
          <div className="menu-title">
            {treeContext.name ?? projects[treeContext.index].name}
          </div>
          {[
            "新建对话",
            "置顶",
            ...(!treeContext.name
              ? [
                  expandedProjects.includes(treeContext.index)
                    ? "收起"
                    : "展开",
                  "在访达中显示",
                ]
              : []),
            "从列表移除",
          ].map((action) => (
            <button
              role="menuitem"
              key={action}
              onClick={() => treeAction(action)}
            >
              {action}
            </button>
          ))}
        </div>
      )}
      {branchContext && (
        <div
          className="branch-context"
          role="menu"
          aria-label="分支操作"
          style={{ left: branchContext.x, top: branchContext.y }}
        >
          <div className="menu-title">
            <GitBranch size={13} />
            {branchContext.name}
          </div>
          {[
            ["切换分支", GitBranch],
            ["获取", ArrowsClockwise],
            ["拉取", ArrowDown],
            ["推送", ArrowUp],
            ["合并到当前分支", GitMerge],
          ].map(([action, Icon]) => (
            <button
              role="menuitem"
              key={action}
              onClick={() => branchAction(action)}
            >
              <Icon size={14} />
              {action}
            </button>
          ))}
        </div>
      )}
      {toast && (
        <div className="toast" role="status">
          <Check size={16} />
          {toast}
        </div>
      )}
      {(modal === "context" || modal === "mcp") && (
        <div className="modal-backdrop" onClick={() => setModal(null)}>
          <section
            className="modal information-dialog"
            role="dialog"
            aria-modal="true"
            aria-label={modal === "context" ? "模型上下文" : "MCP 服务"}
            onClick={(event) => event.stopPropagation()}
          >
            <div className="modal-header">
              <h2>{modal === "context" ? "模型上下文" : "MCP 服务"}</h2>
              <IconButton
                icon={X}
                label="关闭弹窗"
                onClick={() => setModal(null)}
              />
            </div>
            {modal === "context" ? (
              <>
                <p className="modal-description">
                  当前会话的上下文窗口分布 · 演示数据
                </p>
                <div className="context-summary">
                  <div>
                    <span>{model}</span>
                    <strong>
                      {contextUsed.toFixed(1)}
                      <small>k / {contextTotal}k</small>
                    </strong>
                    <p>
                      已使用 {contextPercent.toFixed(1)}% · 剩余{" "}
                      {(contextTotal - contextUsed).toFixed(1)}k
                    </p>
                  </div>
                  <div
                    className="context-large-ring"
                    style={{ "--context-progress": `${contextPercent}%` }}
                  >
                    <span>
                      {contextPercent.toFixed(0)}
                      <small>%</small>
                    </span>
                  </div>
                </div>
                <div className="context-allocation" aria-label="上下文分布">
                  {contextParts.map((part) => (
                    <span
                      key={part.label}
                      style={{
                        width: `${(part.value / contextTotal) * 100}%`,
                        background: part.color,
                      }}
                    />
                  ))}
                </div>
                <div className="context-breakdown">
                  {contextParts.map((part) => (
                    <div key={part.label}>
                      <span>
                        <i style={{ background: part.color }} />
                        {part.label}
                      </span>
                      <strong>{part.value.toFixed(1)}k</strong>
                      <small>
                        {((part.value / contextTotal) * 100).toFixed(1)}%
                      </small>
                    </div>
                  ))}
                  <div>
                    <span>
                      <i className="remaining-color" />
                      可用上下文
                    </span>
                    <strong>{(contextTotal - contextUsed).toFixed(1)}k</strong>
                    <small>{(100 - contextPercent).toFixed(1)}%</small>
                  </div>
                </div>
                <div className="information-note">
                  数值用于确认原型排版，当前模型的实际容量与使用量待接入。
                </div>
              </>
            ) : (
              <>
                <p className="modal-description">
                  查看工具能力、连接状态与服务配置。所有管理操作均在浏览器内演示。
                </p>
                <div className="mcp-heading">
                  <span>
                    {
                      mcpServers.filter(
                        (server) => server.enabled && server.connected,
                      ).length
                    }{" "}
                    / {mcpServers.length} 个服务已连接
                  </span>
                  <button onClick={() => setAddingMcp(!addingMcp)}>
                    <Plus size={14} />
                    添加服务
                  </button>
                </div>
                {addingMcp && (
                  <form
                    className="mcp-add-form"
                    onSubmit={(event) => {
                      event.preventDefault();
                      if (!newMcpName.trim() || !newMcpEndpoint.trim()) return;
                      const id = `custom-${Date.now()}`;
                      setMcpServers((current) => [
                        ...current,
                        {
                          id,
                          name: newMcpName.trim(),
                          description: "自定义服务",
                          endpoint: newMcpEndpoint.trim(),
                          transport: newMcpTransport,
                          enabled: true,
                          connected: false,
                          tools: [],
                        },
                      ]);
                      setSelectedMcpId(id);
                      setAddingMcp(false);
                      setNewMcpName("");
                      setNewMcpEndpoint("");
                    }}
                  >
                    <label>
                      名称
                      <input
                        aria-label="MCP 服务名称"
                        value={newMcpName}
                        onChange={(event) => setNewMcpName(event.target.value)}
                        placeholder="例如：Project Docs"
                      />
                    </label>
                    <label>
                      传输方式
                      <select
                        aria-label="MCP 传输方式"
                        value={newMcpTransport}
                        onChange={(event) =>
                          setNewMcpTransport(event.target.value)
                        }
                      >
                        <option>stdio</option>
                        <option>HTTP</option>
                      </select>
                    </label>
                    <label className="mcp-endpoint-field">
                      {newMcpTransport === "HTTP" ? "服务地址" : "启动命令"}
                      <input
                        aria-label="MCP 服务地址或命令"
                        value={newMcpEndpoint}
                        onChange={(event) =>
                          setNewMcpEndpoint(event.target.value)
                        }
                      />
                    </label>
                    <button
                      className="primary"
                      disabled={!newMcpName.trim() || !newMcpEndpoint.trim()}
                    >
                      添加
                    </button>
                  </form>
                )}
                <div className="mcp-workspace">
                  <div className="mcp-server-list">
                    {mcpServers.map((server) => (
                      <button
                        key={server.id}
                        className={
                          selectedMcpId === server.id ? "selected" : ""
                        }
                        onClick={() => setSelectedMcpId(server.id)}
                      >
                        <span
                          className={`mcp-status ${!server.enabled ? "disabled" : server.connected ? "connected" : "disconnected"}`}
                        />
                        <span>
                          <strong>{server.name}</strong>
                          <small>
                            {!server.enabled
                              ? "已停用"
                              : server.connected
                                ? "已连接"
                                : "未连接"}{" "}
                            · {server.transport}
                          </small>
                        </span>
                      </button>
                    ))}
                  </div>
                  {selectedMcp ? (
                    <div className="mcp-detail">
                      <div className="mcp-detail-heading">
                        <h3>{selectedMcp.name}</h3>
                        <label className="mcp-enable">
                          启用
                          <input
                            type="checkbox"
                            role="switch"
                            aria-label={`启用 ${selectedMcp.name}`}
                            checked={selectedMcp.enabled}
                            onChange={(event) =>
                              updateMcp(selectedMcp.id, {
                                enabled: event.target.checked,
                              })
                            }
                          />
                        </label>
                      </div>
                      <p>{selectedMcp.description}</p>
                      <dl>
                        <dt>传输方式</dt>
                        <dd>{selectedMcp.transport}</dd>
                        <dt>配置</dt>
                        <dd>{selectedMcp.endpoint}</dd>
                      </dl>
                      <div className="mcp-actions">
                        <button
                          disabled={!selectedMcp.enabled}
                          onClick={() =>
                            updateMcp(selectedMcp.id, { connected: true })
                          }
                        >
                          <ArrowsClockwise size={13} />
                          重新连接
                        </button>
                        <button
                          onClick={() => {
                            const remaining = mcpServers.filter(
                              (server) => server.id !== selectedMcp.id,
                            );
                            setMcpServers(remaining);
                            setSelectedMcpId(remaining[0]?.id ?? "");
                          }}
                        >
                          移除服务
                        </button>
                      </div>
                      <h4>
                        可用工具 <span>{selectedMcp.tools.length}</span>
                      </h4>
                      {selectedMcp.tools.length ? (
                        <div className="mcp-tools">
                          {selectedMcp.tools.map((toolName) => (
                            <code key={toolName}>{toolName}</code>
                          ))}
                        </div>
                      ) : (
                        <p className="information-note">暂无已发现的工具。</p>
                      )}
                    </div>
                  ) : (
                    <div className="mcp-empty">添加服务以查看工具与配置。</div>
                  )}
                </div>
              </>
            )}
          </section>
        </div>
      )}
      {modal && modal !== "context" && modal !== "mcp" && (
        <div className="modal-backdrop" onClick={() => setModal(null)}>
          <section
            className="modal"
            role="dialog"
            aria-modal="true"
            aria-label={
              {
                session: "新建会话",
                directory: "添加目录",
                settings: "界面设置",
              }[modal]
            }
            onClick={(event) => event.stopPropagation()}
          >
            <div className="modal-header">
              <h2>
                {
                  {
                    session: "新建会话",
                    directory: "添加目录",
                    settings: "界面设置",
                  }[modal]
                }
              </h2>
              <IconButton
                icon={X}
                label="关闭弹窗"
                onClick={() => setModal(null)}
              />
            </div>
            {modal === "directory" ? (
              <>
                <p className="modal-description">
                  输入一个目录路径，演示添加到左侧项目列表。
                </p>
                <label className="field">
                  目录路径
                  <input
                    autoFocus
                    placeholder="~/project/my-project"
                    value={directoryPath}
                    onChange={(event) => setDirectoryPath(event.target.value)}
                  />
                </label>
                <div className="modal-footer">
                  <button onClick={() => setModal(null)}>取消</button>
                  <button
                    className="primary"
                    disabled={
                      !directoryPath.trim().replace(/\/+$/, "").split("/").pop()
                    }
                    onClick={() => {
                      const index = projects.length;
                      const name = directoryPath
                        .trim()
                        .replace(/\/+$/, "")
                        .split("/")
                        .pop();
                      setProjects((current) => [
                        ...current,
                        { name, branch: "main", sessions: [] },
                      ]);
                      setProjectOrder((current) => [...current, index]);
                      setExpandedProjects((current) => [...current, index]);
                      setDirectoryPath("");
                      setModal(null);
                    }}
                  >
                    添加
                  </button>
                </div>
              </>
            ) : modal === "session" ? (
              <>
                <p className="modal-description">
                  在 {project.name} 中开始新的工作。
                </p>
                <label className="field">
                  会话名称
                  <input
                    autoFocus
                    placeholder="例如：优化订单列表"
                    value={sessionTitle}
                    onChange={(event) => setSessionTitle(event.target.value)}
                  />
                </label>
                <div className="mode-choice">
                  {[
                    ["current", "当前分支", GitBranch],
                    ["worktree", "独立工作树", TreeStructure],
                  ].map(([value, title, Icon]) => (
                    <button
                      key={value}
                      className={sessionMode === value ? "selected" : ""}
                      onClick={() => setSessionMode(value)}
                    >
                      <Icon size={19} />
                      <strong>{title}</strong>
                      <small>
                        {value === "current"
                          ? "继续在项目目录中工作"
                          : "在独立目录中并行任务"}
                      </small>
                    </button>
                  ))}
                </div>
                {sessionMode === "worktree" && (
                  <label className="field">
                    新分支名称
                    <input
                      value={sessionBranch}
                      onChange={(event) => setSessionBranch(event.target.value)}
                    />
                  </label>
                )}
                <dl className="session-summary">
                  <dt>项目</dt>
                  <dd>~/project/{project.name}</dd>
                  <dt>基准分支</dt>
                  <dd>{branch}</dd>
                  <dt>工作目录</dt>
                  <dd>
                    {sessionMode === "current"
                      ? "项目根目录"
                      : `.worktrees/${sessionBranch.split("/").pop()}`}
                  </dd>
                  {sessionMode === "worktree" && (
                    <>
                      <dt>目标分支</dt>
                      <dd>{sessionBranch}</dd>
                    </>
                  )}
                </dl>
                <div className="modal-footer">
                  <button onClick={() => setModal(null)}>取消</button>
                  <button
                    className="primary"
                    disabled={
                      !sessionTitle.trim() ||
                      (sessionMode === "worktree" && !sessionBranch.trim())
                    }
                    onClick={() => {
                      setExtraSessions((current) => ({
                        ...current,
                        [projectIndex]: [
                          sessionTitle.trim(),
                          ...(current[projectIndex] ?? []),
                        ],
                      }));
                      setSession(sessionTitle.trim());
                      setSessionProjectIndex(projectIndex);
                      setSessionTitle("");
                      setModal(null);
                      setTerminal(true);
                      notify("演示会话已创建");
                    }}
                  >
                    <Plus size={15} />
                    创建会话
                  </button>
                </div>
              </>
            ) : (
              <>
                <p className="modal-description">
                  预览不同的信息密度与工作区布局。
                </p>
                <section className="original-settings-section">
                  <h3>界面字号</h3>
                  <label className="font-slider">
                    字号
                    <input
                      type="range"
                      aria-label="界面字号"
                      min="9"
                      max="20"
                      step="0.5"
                      value={appFontSize}
                      onChange={(event) =>
                        setAppFontSize(Number(event.target.value))
                      }
                    />
                    <output>{appFontSize.toFixed(1)}</output>
                  </label>
                  <p className="font-preview" style={{ fontSize: appFontSize }}>
                    预览：Claude Code · 会话列表 · 侧边栏
                  </p>
                </section>
                <section className="original-settings-section">
                  <h3>终端字号</h3>
                  <label className="font-slider">
                    字号
                    <input
                      type="range"
                      aria-label="终端字号"
                      min="9"
                      max="22"
                      step="0.5"
                      value={termFontSize}
                      onChange={(event) =>
                        setTermFontSize(Number(event.target.value))
                      }
                    />
                    <output>{termFontSize.toFixed(1)}</output>
                  </label>
                </section>
                <section className="original-settings-section">
                  <h3>会话与分支</h3>
                  <label className="follow-session-setting">
                    <span>打开会话时，Git 工作台跳到该会话的分支</span>
                    <input
                      type="checkbox"
                      role="switch"
                      aria-label="跟随会话分支"
                      checked={followSessionBranch}
                      onChange={(event) =>
                        setFollowSessionBranch(event.target.checked)
                      }
                    />
                  </label>
                  <p>
                    分支取自会话记录里最后的
                    gitBranch。工作区干净且同仓库没有其它会话在运行时自动签出，否则只在
                    Git 工作台顶部提示。原型使用演示分支。
                  </p>
                </section>
                <section className="original-settings-section">
                  <h3>工具服务</h3>
                  <button
                    className="settings-mcp-entry"
                    onClick={() => setModal("mcp")}
                  >
                    <PlugsConnected size={15} />
                    查看和管理 MCP 服务
                    <CaretRight size={13} />
                  </button>
                </section>
                <label className="field">
                  信息密度
                  <div className="segmented">
                    {["舒适", "紧凑"].map((name) => (
                      <button
                        key={name}
                        className={density === name ? "chosen" : ""}
                        onClick={() => setDensity(name)}
                      >
                        {name}
                      </button>
                    ))}
                  </div>
                </label>
                <div className="settings-row">
                  显示项目侧栏
                  <input
                    type="checkbox"
                    checked={sidebar}
                    onChange={(event) => setSidebar(event.target.checked)}
                  />
                </div>
                <div className="settings-row">
                  显示终端
                  <input
                    type="checkbox"
                    checked={terminal}
                    onChange={(event) => setTerminal(event.target.checked)}
                  />
                </div>
                <div className="settings-row">
                  显示工作台
                  <input
                    type="checkbox"
                    checked={workbench}
                    onChange={(event) => setWorkbench(event.target.checked)}
                  />
                </div>
                <div className="modal-footer">
                  <button className="primary" onClick={() => setModal(null)}>
                    完成
                  </button>
                </div>
              </>
            )}
          </section>
        </div>
      )}
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
