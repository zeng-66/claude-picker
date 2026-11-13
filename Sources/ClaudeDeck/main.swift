import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - 常量

let kWindowW: CGFloat = 1180
let kWindowH: CGFloat = 700
let kSidebarW: CGFloat = 322
let kSidebarMinW: CGFloat = 250
let kSidebarMaxW: CGFloat = 560
/// 项目展开时默认只显示前 5 条会话
let kMaxVisibleSessions = 5
/// 终端区顶部留白，给 claude 启动 banner 留呼吸空间
let kTerminalTopPad: CGFloat = 12
/// 终端底色（与 TerminalPane 的 nativeBackgroundColor 保持一致）
let kTermBg = Color(red: 0.055, green: 0.062, blue: 0.078)

// MARK: - 启动参数

struct LaunchArgs {
    var outPath = ""
    var root = ""
    var homeLabel = "~"
    var names: [String] = []
    var startDir = ""
    var startSid = ""
}

func parseArgs() -> LaunchArgs {
    var a = LaunchArgs()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let k = it.next() {
        switch k {
        case "--out":        a.outPath = it.next() ?? ""
        case "--root":       a.root = it.next() ?? ""
        case "--home-label": a.homeLabel = it.next() ?? "~"
        case "--start":      a.startDir = it.next() ?? ""
        case "--resume":     a.startSid = it.next() ?? ""
        default:             a.names.append(k)
        }
    }
    return a
}

// MARK: - 树形行

enum TreeRow: Equatable {
    case project(Int)
    case session(Int, Int)     // (项目下标, 会话下标)
    case more(Int)             // 展开更多 / 收起

    var key: String {
        switch self {
        case .project(let i):        return "p\(i)"
        case .session(let i, let s): return "p\(i)s\(s)"
        case .more(let i):           return "m\(i)"
        }
    }
}

// MARK: - 状态

@MainActor
final class Store: ObservableObject {
    @Published var projects: [Project]
    @Published var sel: Int = 0              // 光标落在 rows 的第几行
    @Published var pane: Int = 0             // 0 树 / 1 终端
    @Published var activeRow: TreeRow?       // 终端里正在跑的会话对应的树行（高亮用）
    /// 所有活着的终端会话，key 见 `key(cwd:sid:)`；切换会话不再杀掉旧终端
    private var panes: [String: TerminalSession] = [:]
    /// 当前显示在右侧的会话 key
    @Published var activeKey: String = ""
    /// 正在跑（进程未退出）的会话 key 集合 → 会话行显示转圈
    @Published var runningKeys: Set<String> = []
    /// 已跑完但用户还没点进去看的会话 key 集合 → 会话行显示绿点
    @Published var unreadKeys: Set<String> = []

    var active: TerminalSession? { activeKey.isEmpty ? nil : panes[activeKey] }
    @Published var activeLabel: String = ""
    @Published var activePath: String = ""
    @Published var settings: AppSettings = SettingsStore.load()
    @Published var options = ClaudeConfig.loadOptions()
    @Published var activeMode: PermissionMode = ClaudeConfig.loadOptions().mode
    @Published var usage = UsageSnapshot(session: nil, weekly: nil)
    @Published var usageLoading = false
    @Published var showSettings = false
    // Git 面板状态
    @Published var gitStatus = GitStatus()
    private var gitContext = ""
    private var gitStatusRequest = UUID()
    private var gitExtrasRequest = UUID()
    private var gitDiffRequest = UUID()
    @Published var gitLoading = false
    @Published var showGit = false
    @Published var gitMessage = ""          // 提交信息输入框（@State 不可用，绑定到 Store）
    @Published var gitActionOutput = ""     // 最近一次 git 动作的输出
    @Published var gitActionRunning = false
    // v2：分支 / diff / worktree
    @Published var gitTab = 0               // 面板分段：0 状态 / 1 分支 / 2 工作树
    @Published var gitBranches: [GitBranch] = []
    @Published var gitBranchesLoading = false
    @Published var gitWorktrees: [GitWorktree] = []
    @Published var gitWorktreesLoading = false
    @Published var gitNewBranch = ""        // 新建分支输入
    @Published var gitWorktreePath = ""     // 新建 worktree 路径输入
    @Published var gitWorktreeBranch = ""   // 新建 worktree 分支输入
    @Published var gitDiffText = ""
    @Published var gitDiffTitle = ""
    @Published var gitDiffLoading = false
    @Published var showGitDiff = false
    @Published var dragging: TreeRow?
    @Published var sidebarW: CGFloat
    @Published var hoverRow: Int?
    /// 当前鼠标悬停的会话 id（SwiftUI 的 @State 在 CommandLineTools 工具链下不可用）
    @Published var hoverSession: String?
    @Published var hoverDivider = false
    var dragStartW: CGFloat?

    private var hiddenProjects: Set<String>
    private var hiddenSessions: Set<String>

    var onFocusTerminal: (() -> Void)?
    var onLeaveTerminal: (() -> Void)?
    var onDone: (() -> Void)?

    init(_ projects: [Project]) {
        self.projects = projects
        let st = SettingsStore.load()
        self.sidebarW = CGFloat(min(max(st.sidebarWidth, Double(kSidebarMinW)), Double(kSidebarMaxW)))
        let o = TreeOrderStore.load()
        self.hiddenProjects = Set(o.hiddenProjects)
        self.hiddenSessions = Set(o.hiddenSessions)
    }

    // MARK: 栏宽拖动

    func beginResize() { dragStartW = sidebarW }

    func resizeTo(_ delta: CGFloat) {
        guard let base = dragStartW else { return }
        sidebarW = min(max(base + delta, kSidebarMinW), kSidebarMaxW)
    }

    func endResize() {
        dragStartW = nil
        settings.sidebarWidth = Double(sidebarW)
        SettingsStore.save(settings)
    }

    // MARK: 删除

    /// 当前选中行是否可删除（家目录永远不可删）
    var canRemoveCurrent: Bool {
        switch currentRow {
        case .project(let i): return projects.indices.contains(i) && !projects[i].isHome
        case .session:        return true
        case .more, nil:      return false
        }
    }

    func removeCurrent() {
        switch currentRow {
        case .project(let i): removeProject(i)
        case .session(let i, let s): removeSession(i, s)
        default: break
        }
    }

    func removeProject(_ i: Int) {
        guard projects.indices.contains(i), !projects[i].isHome else { return }
        let p = projects.remove(at: i)
        hiddenProjects.insert(p.path)
        hiddenSessions.subtract(p.sessions.map(\.id))
        if sel > rows.count - 1 { sel = max(rows.count - 1, 0) }
        persistTree()
    }

    func removeSession(_ p: Int, _ s: Int) {
        guard projects.indices.contains(p), projects[p].sessions.indices.contains(s) else { return }
        let sess = projects[p].sessions.remove(at: s)
        hiddenSessions.insert(sess.id)
        if sel > rows.count - 1 { sel = max(rows.count - 1, 0) }
        persistTree()
    }


    // MARK: 行

    var rows: [TreeRow] {
        var out: [TreeRow] = []
        for (i, p) in projects.enumerated() {
            out.append(.project(i))
            guard p.expanded else { continue }
            let limit = p.showAll ? p.sessions.count : min(p.sessions.count, kMaxVisibleSessions)
            for s in 0..<limit { out.append(.session(i, s)) }
            if p.sessions.count > kMaxVisibleSessions {
                out.append(.more(i))
            }
        }
        return out
    }

    var currentRow: TreeRow? { rows.indices.contains(sel) ? rows[sel] : nil }

    var currentProjectIndex: Int? {
        switch currentRow {
        case .project(let i), .more(let i): return i
        case .session(let i, _):            return i
        case nil:                           return nil
        }
    }

    var currentProject: Project? {
        guard let i = currentProjectIndex, projects.indices.contains(i) else { return nil }
        return projects[i]
    }

    var terminalRunning: Bool { active != nil }

    // MARK: 光标移动

    func up() {
        guard pane == 0 else { return }
        if sel > 0 { sel -= 1 }
    }

    func down() {
        guard pane == 0 else { return }
        if sel < rows.count - 1 { sel += 1 }
    }

    /// → 展开项目 / 从项目跳到第一条会话
    func right() {
        guard pane == 0, let r = currentRow else { return }
        switch r {
        case .project(let i):
            if !projects[i].expanded {
                projects[i].expanded = true
                persistTree()
            } else if !projects[i].sessions.isEmpty {
                if rows.indices.contains(sel + 1) { sel += 1 }
            }
        case .session, .more:
            break
        }
    }

    /// ← 收起项目 / 从会话跳回项目
    func left() {
        guard pane == 0, let r = currentRow else { return }
        switch r {
        case .session(let i, _), .more(let i):
            if projects[i].expanded { projects[i].expanded = false; persistTree() }
            let key = TreeRow.project(i).key
            if let idx = rows.firstIndex(where: { $0.key == key }) { sel = idx }
        case .project(let i):
            if projects[i].expanded { projects[i].expanded = false; persistTree() }
        }
    }

    func focusTerminal() {
        guard terminalRunning else { return }
        pane = 1
        onFocusTerminal?()
    }

    func focusTree() {
        pane = 0
        clampSel()
    }

    private func clampSel() {
        if sel > rows.count - 1 { sel = max(rows.count - 1, 0) }
    }

    // MARK: 动作

    func toggleExpand(_ i: Int) {
        guard projects.indices.contains(i) else { return }
        projects[i].expanded.toggle()
        persistTree()
    }

    func toggleShowAll(_ i: Int) {
        guard projects.indices.contains(i) else { return }
        projects[i].showAll.toggle()
        persistTree()
    }

    /// 回车
    func confirm() {
        guard let r = currentRow else { return }
        switch r {
        case .project(let i):
            toggleExpand(i)
        case .session(let i, let s):
            guard projects.indices.contains(i),
                  projects[i].sessions.indices.contains(s) else { return }
            let ss = projects[i].sessions[s]
            open(cwd: ss.cwd, sid: ss.id, label: ss.title)
        case .more(let i):
            toggleShowAll(i)
        }
    }

    func openNew(_ i: Int) {
        guard projects.indices.contains(i) else { return }
        let p = projects[i]
        open(cwd: p.path, sid: nil, label: "新建 · \(p.title)")
    }

    /// 多终端会话 key：同一目录下每个 session 各占一个终端
    func key(cwd: String, sid: String) -> String {
        URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path + "|" + sid
    }

    func open(cwd: String, sid: String?, label: String) {
        // 新建会话：先预生成 session id，会话一建立就有稳定标识，也能立刻插到列表最前
        let newId = sid == nil ? UUID().uuidString.lowercased() : nil
        let k = key(cwd: cwd, sid: sid ?? newId ?? "")
        if panes[k] == nil {
            let t = TerminalSession(cwd: cwd, resumeId: sid, sessionId: newId,
                                    options: options,
                                    fontName: settings.termFontName,
                                    fontSize: settings.termFontSize)
            t.onExit = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.runningKeys.remove(k)
                    self.refreshSession(cwd: cwd, sid: sid ?? newId ?? "")
                }
            }
            // 行首转圈跟随任务状态，后台任务完成后才标记未读。
            t.onBusy = { [weak self, weak t] busy in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if busy {
                        self.runningKeys.insert(k)
                    } else {
                        self.runningKeys.remove(k)
                        self.refreshSession(cwd: cwd, sid: sid ?? newId ?? "")
                        if self.activeKey != k, t?.awayOutput == true {
                            self.unreadKeys.insert(k)
                        }
                    }
                }
            }
            panes[k] = t
        }
        if let newId { insertNewSession(cwd: cwd, id: newId) }
        unreadKeys.remove(k)
        locateRow(cwd: cwd, sid: sid ?? newId)
        // 切换视图只抑制重绘，任务状态持续跟随 Claude 的忙闲信号。
        if activeKey != k, let prev = panes[activeKey] { prev.noteDetached() }
        panes[k]?.noteActivated()
        activeKey = k
        activeLabel = label
        activePath = cwd
        activeMode = options.mode
        refreshSession(cwd: cwd, sid: sid ?? newId ?? "")
        pane = 1
        onFocusTerminal?()
        refreshGit()
    }

    /// 新建会话插到该项目会话列表最前（tree.json 存的也是这个顺序 → 重启后仍在最前）
    private func insertNewSession(cwd: String, id: String) {
        let std = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        guard let i = projects.firstIndex(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == std
        }) else { return }
        guard !projects[i].sessions.contains(where: { $0.id == id }) else { return }
        let s = Session(id: id, cwd: std, title: "新建会话", summary: nil, date: Date())
        projects[i].sessions.insert(s, at: 0)
        projects[i].expanded = true
        persistTree()
    }

    /// 让树里的光标与高亮跟随终端正在跑的会话
    private func locateRow(cwd: String, sid: String?) {
        let std = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        for (i, p) in projects.enumerated() {
            let pstd = URL(fileURLWithPath: p.path).resolvingSymlinksInPath().path
            guard pstd == std else { continue }
            if !p.expanded { projects[i].expanded = true }
            break
        }
        if let sid, let idx = rows.firstIndex(where: { r in
            guard case .session(let i, let s) = r,
                  projects.indices.contains(i),
                  projects[i].sessions.indices.contains(s) else { return false }
            return projects[i].sessions[s].id == sid
        }) {
            sel = idx
            activeRow = rows[idx]
            return
        }
        // 新建会话：定位到该项目行
        if let idx = rows.firstIndex(where: { r in
            guard case .project(let i) = r, projects.indices.contains(i) else { return false }
            return URL(fileURLWithPath: projects[i].path).resolvingSymlinksInPath().path == std
        }) {
            sel = idx
            activeRow = rows[idx]
        }
    }

    /// 打开历史会话或结束一轮任务后重新读取元数据，避免一直展示启动时的快照。
    func refreshSession(cwd: String, sid: String) {
        let sessionKey = key(cwd: cwd, sid: sid)
        let source = projects.flatMap(\.sessions).first { key(cwd: $0.cwd, sid: $0.id) == sessionKey }?.fileURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let updated = source.flatMap { SessionScanner.parse($0) } ?? SessionScanner.find(id: sid)
            guard let updated else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for i in self.projects.indices {
                    guard let j = self.projects[i].sessions.firstIndex(where: {
                        self.key(cwd: $0.cwd, sid: $0.id) == sessionKey
                    }), self.key(cwd: updated.cwd, sid: updated.id) == sessionKey,
                    updated.date >= self.projects[i].sessions[j].date else { continue }
                    self.projects[i].sessions[j] = updated
                    if self.activeKey == sessionKey { self.activeLabel = updated.title }
                    return
                }
            }
        }
    }

    func closeTerminal() {
        let k = activeKey
        if !k.isEmpty {
            panes[k]?.terminate()
            panes.removeValue(forKey: k)
            runningKeys.remove(k)
            unreadKeys.remove(k)
        }
        activeKey = ""
        activeRow = nil
        pane = 0
        clampSel()
    }

    /// 退出 App 时把所有还活着的终端一起关掉（多终端并存后不能只关当前那个）
    func terminateAll() {
        for (_, t) in panes { t.terminate() }
        panes.removeAll()
        runningKeys.removeAll()
        unreadKeys.removeAll()
        activeKey = ""
    }

    // MARK: 排序

    func moveProject(from: Int, to: Int) {
        guard projects.indices.contains(from), projects.indices.contains(to), from != to else { return }
        guard from >= 1, to >= 1 else { return }   // 家目录固定第一位
        let p = projects.remove(at: from)
        projects.insert(p, at: to)
        persistTree()
        if let idx = rows.firstIndex(where: { $0.key == TreeRow.project(to).key }) { sel = idx }
    }

    /// 置顶 = 挪到「家目录下面第一个」，不会跑到家目录前面
    func pinProject(_ i: Int) {
        guard projects.indices.contains(i), i > 1 else { return }
        moveProject(from: i, to: 1)
    }

    func moveSession(_ p: Int, from: Int, to: Int) {
        guard projects.indices.contains(p),
              projects[p].sessions.indices.contains(from),
              projects[p].sessions.indices.contains(to), from != to else { return }
        let s = projects[p].sessions.remove(at: from)
        projects[p].sessions.insert(s, at: to)
        persistTree()
    }

    func pinSession(_ p: Int, _ s: Int) {
        guard projects.indices.contains(p), projects[p].sessions.indices.contains(s), s > 0 else { return }
        moveSession(p, from: s, to: 0)
    }

    func moveSessionToProject(_ fromP: Int, _ fromS: Int, _ toP: Int) {
        guard fromP != toP,
              projects.indices.contains(fromP), projects.indices.contains(toP),
              projects[fromP].sessions.indices.contains(fromS) else { return }
        let s = projects[fromP].sessions.remove(at: fromS)
        projects[toP].sessions.insert(s, at: 0)
        projects[toP].expanded = true
        persistTree()
    }

    // MARK: 持久化

    func persistTree() {
        var o = TreeOrder()
        o.projects = projects.filter { !$0.isHome }.map(\.path)
        var sm: [String: [String]] = [:]
        var ex: [String] = []
        for p in projects {
            sm[p.path] = p.sessions.map(\.id)
            if p.expanded { ex.append(p.path) }
        }
        o.sessions = sm
        o.expanded = ex
        o.hiddenProjects = Array(hiddenProjects)
        o.hiddenSessions = Array(hiddenSessions)
        TreeOrderStore.save(o)
    }

    // MARK: 添加目录

    @discardableResult
    func addDirectory(_ path: String) -> Bool {
        let std = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: std, isDirectory: &isDir), isDir.boolValue else { return false }
        // 之前「从列表移除」过的目录，这次重新添加就取消隐藏，否则重启后仍会被过滤掉
        hiddenProjects.remove(std)
        if let i = projects.firstIndex(where: { $0.path == std }) {
            projects[i].expanded = true
            if let idx = rows.firstIndex(where: { $0.key == TreeRow.project(i).key }) { sel = idx }
            persistTree()
            return true
        }
        let id = (projects.map(\.id).filter { $0 >= 0 }.max() ?? 0) + 1
        var p = Project(id: id, title: (std as NSString).lastPathComponent,
                        path: std, isHome: false, sessions: [])
        p.expanded = true
        // 新建目录插到最前（家目录恒为第 0 位），persistTree 写入的顺序即重启后的顺序
        projects.insert(p, at: 1)
        if let idx = rows.firstIndex(where: { $0.key == TreeRow.project(1).key }) { sel = idx }
        persistTree()
        return true
    }

    // MARK: 侧边栏收起

    func toggleSidebar() {
        settings.sidebarCollapsed.toggle()
        SettingsStore.save(settings)
        if settings.sidebarCollapsed {
            pane = 1
            if terminalRunning { onFocusTerminal?() }
        } else {
            pane = 0
        }
    }

    /// 收起状态下点首字母：展开侧栏并定位到该项目
    func revealProject(_ i: Int) {
        guard projects.indices.contains(i) else { return }
        if settings.sidebarCollapsed {
            settings.sidebarCollapsed = false
            SettingsStore.save(settings)
        }
        projects[i].expanded = true
        pane = 0
        if let idx = rows.firstIndex(where: { $0.key == TreeRow.project(i).key }) { sel = idx }
        persistTree()
    }

    // MARK: 字体

    func appFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let base = CGFloat(settings.appFontSize)
        let s = base * (size / 12.5)
        if settings.appFontName.isEmpty {
            return .system(size: s, weight: weight)
        }
        return .custom(settings.appFontName, size: s)
    }

    func applyFonts() {
        SettingsStore.save(settings)
        for t in panes.values {
            t.applyFont(fontName: settings.termFontName, fontSize: settings.termFontSize)
        }
    }

    // MARK: 状态栏联动（写进正在运行的 claude）

    /// Shift+Tab 的实际循环顺序（PTY 实测：auto → accept edits → plan → manual → auto）
    static let modeCycle: [PermissionMode] = [.auto, .manual, .acceptEdits, .plan]

    func cycleTo(_ target: PermissionMode) {
        guard activeMode != target else { return }
        // Shift+Tab 连发太快会被 claude 吞掉，逐步间隔 320ms 发。
        if let cur = Self.modeCycle.firstIndex(of: activeMode),
           let dst = Self.modeCycle.firstIndex(of: target) {
            let steps = (dst - cur + Self.modeCycle.count) % Self.modeCycle.count
            sendShiftTab(times: steps)
        }
        activeMode = target
        // 持久化：下次新建 / 恢复会话直接带上
        ClaudeConfig.setMode(target)
        options.mode = target
    }

    private func sendShiftTab(times: Int) {
        guard times > 0, let s = active else { return }
        s.send("\u{1b}[Z")
        guard times > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, self.active === s else { return }
            self.sendShiftTab(times: times - 1)
        }
    }

    var activeModel: ModelChoice {
        get { options.model }
    }

    func setModel(_ m: ModelChoice) {
        guard options.model != m else { return }
        options.model = m
        options.effort = ClaudeConfig.effortFor(model: m, in: ClaudeConfig.read())
        ClaudeConfig.setModel(m)
        active?.send("/model \(m.rawValue)\n")
    }

    func setEffort(_ e: EffortChoice) {
        guard options.effort != e else { return }
        options.effort = e
        ClaudeConfig.setEffort(e, for: options.model)
        active?.send("/effort \(e.rawValue)\n")
    }

    func toggleFast() {
        options.fast.toggle()
        ClaudeConfig.setFast(options.fast)
        active?.send("/fast\n")
    }

    /// 从磁盘重读四项（窗口重新激活时用，避免外部改动不同步）
    func reloadClaudeOptions() {
        let o = ClaudeConfig.loadOptions()
        if options != o { options = o }
        if activeMode != o.mode { activeMode = o.mode }
    }

    // MARK: 用量

    func refreshUsage() {
        guard !usageLoading else { return }
        usageLoading = true
        UsageFetcher.fetch { [weak self] snap in
            guard let self else { return }
            self.usage = snap
            self.usageLoading = false
        }
    }

    // MARK: Git

    /// Git 工作目录：优先当前终端 cwd，退回当前选中项目路径
    var gitCwd: String {
        activePath.isEmpty ? (currentProject?.path ?? "") : activePath
    }

    func refreshGit() {
        let cwd = gitCwd
        if gitContext != cwd {
            gitContext = cwd
            gitStatus = GitStatus()
            gitBranches = []; gitWorktrees = []
            gitMessage = ""; gitActionOutput = ""
            gitNewBranch = ""; gitWorktreePath = ""; gitWorktreeBranch = ""
            gitExtrasRequest = UUID(); gitDiffRequest = UUID()
            gitBranchesLoading = false; gitWorktreesLoading = false
            showGitDiff = false; gitDiffLoading = false; gitDiffText = ""
        }
        let request = UUID()
        gitStatusRequest = request
        guard !cwd.isEmpty else { gitLoading = false; return }
        gitLoading = true
        GitRunner.fetchStatus(cwd: cwd) { [weak self] st in
            guard let self, self.gitStatusRequest == request else { return }
            guard self.gitCwd == cwd else { self.refreshGit(); return }
            self.gitStatus = st
            self.gitLoading = false
            if let error = st.errorText { self.gitActionOutput = error }
            if self.showGit { self.refreshGitExtras() }
        }
    }

    /// Bind each mutation to the displayed repository and refresh after completion.
    private func runGit(_ cmdGroups: [[String]], resultPrefix: String = "",
                        onSuccess: (() -> Void)? = nil) {
        guard !gitActionRunning, !gitLoading, gitContext == gitCwd,
              gitStatus.isRepo, !gitStatus.repoRoot.isEmpty else { return }
        let cwd = gitStatus.repoRoot
        let context = gitCwd
        gitActionRunning = true
        GitRunner.perform(cmdGroups, cwd: cwd) { [weak self] r in
            guard let self else { return }
            self.gitActionRunning = false
            if self.gitCwd == context {
                self.gitActionOutput = resultPrefix + (r.ok ? "：完成" : "：失败")
                    + (r.output.isEmpty ? "" : "\n" + r.output)
                if r.ok { onSuccess?() }
            }
            self.refreshGit()
        }
    }

    private func confirmGitDiscard(_ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确认放弃改动？"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "放弃改动")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func gitStageAll() {
        runGit([["add", "-A"]], resultPrefix: "暂存全部变更")
    }

    func gitUnstageAll() {
        runGit([gitStatus.hasHead ? ["reset"] : ["rm", "--cached", "-r", "-f", "--", "."]], resultPrefix: "取消全部暂存")
    }

    func gitCommit() {
        let msg = gitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            gitActionOutput = "提交信息为空"
            return
        }
        guard gitStatus.stagedCount > 0, !gitStatus.changes.contains(where: \.conflicted) else { return }
        runGit([["commit", "-m", msg]], resultPrefix: "提交") {
            if self.gitMessage.trimmingCharacters(in: .whitespacesAndNewlines) == msg { self.gitMessage = "" }
        }
    }

    func gitFetch() {
        runGit([["fetch", "--all", "--prune"]], resultPrefix: "获取远程更新")
    }

    func gitPull() {
        runGit([["pull", "--ff-only"]], resultPrefix: "拉取")
    }

    func gitPush() {
        guard !gitStatus.detached, gitStatus.hasHead else { return }
        if gitStatus.hasRemote {
            runGit([["push"]], resultPrefix: "推送")
        } else if gitStatus.remotes.count == 1, let remote = gitStatus.remotes.first {
            runGit([["push", "--set-upstream", "--", remote, gitStatus.branch]], resultPrefix: "推送并设置跟踪分支")
        } else {
            gitActionOutput = "请先在终端设置跟踪分支（没有远程仓库或存在多个远程仓库）"
        }
    }

    func gitDiscardAll() {
        guard confirmGitDiscard("将还原所有未暂存的已跟踪文件，并删除未跟踪文件和目录；已暂存内容保留。此操作无法撤销。") else { return }
        var groups: [[String]] = []
        if gitStatus.changes.contains(where: { !$0.untracked && $0.unstaged }) { groups.append(["restore", "--worktree", "--", "."]) }
        groups.append(["clean", "-fd"])
        runGit(groups, resultPrefix: "放弃未暂存改动")
    }

    func gitStage(_ file: GitFileChange) {
        runGit([["add", "--"] + file.paths], resultPrefix: "暂存 \(file.path)")
    }

    func gitUnstage(_ file: GitFileChange) {
        runGit([gitStatus.hasHead ? ["reset", "--"] + file.paths : ["rm", "--cached", "-f", "--"] + file.paths], resultPrefix: "取消暂存 \(file.path)")
    }

    func gitDiscard(_ file: GitFileChange) {
        guard file.unstaged, !file.conflicted, confirmGitDiscard("将放弃 \(file.path) 的未暂存改动；已暂存内容保留。此操作无法撤销。") else { return }
        if file.untracked {
            runGit([["clean", "-fd", "--", file.path]], resultPrefix: "删除 \(file.path)")
        } else {
            runGit([["restore", "--worktree", "--", file.path]], resultPrefix: "还原 \(file.path)")
        }
    }

    // MARK: Git v2：分支 / diff / worktree

    /// 面板打开或切 tab 时刷新分支与 worktree 列表
    func refreshGitExtras() {
        guard gitContext == gitCwd, gitStatus.isRepo, !gitStatus.repoRoot.isEmpty else { return }
        let cwd = gitStatus.repoRoot
        let context = gitCwd
        let request = UUID()
        gitExtrasRequest = request
        gitBranchesLoading = true; gitWorktreesLoading = true
        GitRunner.fetchBranches(cwd: cwd) { [weak self] list, error in
            guard let self, self.gitExtrasRequest == request, self.gitCwd == context else { return }
            if let error { self.gitActionOutput = "读取分支失败：\n" + error }
            self.gitBranches = list
            self.gitBranchesLoading = false
        }
        GitRunner.fetchWorktrees(cwd: cwd) { [weak self] list, error in
            guard let self, self.gitExtrasRequest == request, self.gitCwd == context else { return }
            if let error { self.gitActionOutput = "读取工作树失败：\n" + error }
            self.gitWorktrees = list
            self.gitWorktreesLoading = false
        }
    }

    func gitCheckout(_ branch: GitBranch) {
        // 远程分支：创建同名本地跟踪分支
        if branch.remote {
            let local = String(branch.name.split(separator: "/").dropFirst().joined(separator: "/"))
            if let existing = gitBranches.first(where: { !$0.remote && $0.upstream == branch.name }) {
                runGit([["switch", "--", existing.name]], resultPrefix: "切换到 \(existing.name)")
            } else {
                runGit([["switch", "--track", "-c", local, "--", branch.ref]], resultPrefix: "切换到 \(local)")
            }
        } else {
            runGit([["switch", "--", branch.name]], resultPrefix: "切换到 \(branch.name)")
        }
    }

    func gitCreateBranch() {
        let name = gitNewBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            gitActionOutput = "分支名为空"
            return
        }
        runGit([["check-ref-format", "--branch", name], ["switch", "-c", name]], resultPrefix: "新建分支 \(name)") {
            if self.gitNewBranch.trimmingCharacters(in: .whitespacesAndNewlines) == name { self.gitNewBranch = "" }
        }
    }

    func gitWorktreeAdd() {
        let inputPath = gitWorktreePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputPath.isEmpty else {
            gitActionOutput = "worktree 路径为空"
            return
        }
        let path = (inputPath as NSString).expandingTildeInPath
        let branch = gitWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups: [[String]]
        if branch.isEmpty {
            groups = [["worktree", "add", "--", path]]
        } else if gitBranches.contains(where: { !$0.remote && $0.name == branch }) {
            groups = [["worktree", "add", "--", path, branch]]
        } else {
            groups = [["check-ref-format", "--branch", branch], ["worktree", "add", "-b", branch, "--", path]]
        }
        runGit(groups, resultPrefix: "新建 worktree \(path)") {
            if self.gitWorktreePath.trimmingCharacters(in: .whitespacesAndNewlines) == inputPath { self.gitWorktreePath = "" }
            if self.gitWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines) == branch { self.gitWorktreeBranch = "" }
        }
    }

    func gitWorktreeRemove(_ wt: GitWorktree) {
        guard wt.path != gitStatus.repoRoot else { return }
        let alert = NSAlert()
        alert.messageText = "移除工作树？"
        alert.informativeText = "将移除目录 \(wt.path)。分支仍保留；包含未提交内容或被锁定的工作树会拒绝移除。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runGit([["worktree", "remove", "--", wt.path]], resultPrefix: "移除 worktree \(wt.path)")
    }

    /// 在工作树中打开某个 worktree 目录（作为新项目加入侧边栏）
    func gitOpenWorktree(_ wt: GitWorktree) {
        _ = addDirectory(wt.path)
        showGit = false
        open(cwd: wt.path, sid: nil, label: (wt.path as NSString).lastPathComponent)
    }

    // MARK: Git diff

    private func showDiff(_ args: [String], title: String) {
        let cwd = gitStatus.repoRoot.isEmpty ? gitCwd : gitStatus.repoRoot
        guard !cwd.isEmpty else { return }
        guard gitContext == gitCwd, !gitLoading else { return }
        let context = gitCwd
        let request = UUID()
        gitDiffRequest = request
        gitDiffTitle = title
        gitDiffText = ""
        gitDiffLoading = true
        showGitDiff = true
        let safeArgs = [args[0], "--no-ext-diff", "--no-textconv"] + args.dropFirst()
        GitRunner.fetchDiff(Array(safeArgs), cwd: cwd) { [weak self] text in
            guard let self else { return }
            guard self.gitDiffRequest == request, self.gitCwd == context else { return }
            self.gitDiffText = text.isEmpty ? "（无差异）" : text
            self.gitDiffLoading = false
        }
    }

    /// 工作区未暂存改动
    func gitDiffWorking() {
        showDiff(["diff"], title: "工作区改动（未暂存）")
    }

    /// 暂存区改动
    func gitDiffStaged() {
        showDiff(["diff", "--cached"], title: "暂存区改动")
    }

    /// 单个文件改动（未跟踪文件用 /dev/null 对比）
    func gitDiffFile(_ file: GitFileChange, staged: Bool? = nil) {
        if file.untracked {
            showDiff(["diff", "--no-index", "--", "/dev/null", file.path], title: file.path)
        } else if staged ?? file.staged {
            showDiff(["diff", "--cached", "--"] + file.paths, title: "\(file.path)（暂存区）")
        } else {
            showDiff(["diff", "--", file.path], title: file.path)
        }
    }

    /// 某次提交的完整改动
    func gitDiffCommit(_ entry: GitLogEntry) {
        showDiff(["show", "--format=%h %s%n作者：%an%n时间：%cr", entry.id], title: "提交 \(entry.id)")
    }

    /// 某个分支相对当前 HEAD 的差异
    func gitDiffBranch(_ branch: GitBranch) {
        showDiff(["diff", "HEAD...\(branch.ref)", "--stat"], title: "分支 \(branch.name) 相对 HEAD")
    }

    /// 两个提交之间的差异
    func gitDiffBetween(_ from: GitLogEntry, _ to: GitLogEntry) {
        showDiff(["diff", "\(from.id)", "\(to.id)"], title: "\(from.id) → \(to.id)")
    }
}

// MARK: - 背景磨砂

struct BehindBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

// MARK: - Claude 吉祥物 Clawd

struct ClawdMark: View {
    /// 内容包围盒：x 0…15、y 6…15，中心 (7.5, 10.5)。
    /// 用等边 viewBox 包住这个中心，Canvas 才会把 Clawd 光学居中，
    /// 否则原始 -4.5/-7 的 24×24 viewBox 会让形象整体偏下、与文字对不齐。
    private static let viewBox = CGRect(x: 0, y: 3, width: 15, height: 15)

    /// (x, y, w, h, kind) —— kind: b=身体 e=眼
    private static let cells: [(CGFloat, CGFloat, CGFloat, CGFloat, Character)] = [
        (3, 11, 1, 4, "b"), (5, 11, 1, 4, "b"), (9, 11, 1, 4, "b"), (11, 11, 1, 4, "b"),
        (2, 6, 11, 7, "b"),
        (0, 9, 2, 2, "b"), (13, 9, 2, 2, "b"),
        (4, 8, 1, 2, "e"), (10, 8, 1, 2, "e"),
    ]

    private static func color(_ kind: Character) -> Color {
        kind == "e"
            ? Color(red: 0.102, green: 0.102, blue: 0.102)
            : Color(red: 0.843, green: 0.467, blue: 0.341)
    }

    /// 绘制尺寸由内部 .frame 决定（外部 .frame 只能裁剪），所以要显式参数化。
    var size: CGFloat = 30

    var body: some View {
        Canvas { ctx, size in
            let vb = Self.viewBox
            let scale = min(size.width / vb.width, size.height / vb.height)
            let ox = (size.width - vb.width * scale) / 2 - vb.minX * scale
            let oy = (size.height - vb.height * scale) / 2 - vb.minY * scale
            for c in Self.cells {
                let r = CGRect(x: ox + c.0 * scale,
                               y: oy + c.1 * scale,
                               width: c.2 * scale + 0.5,
                               height: c.3 * scale + 0.5)
                ctx.fill(Path(r), with: .color(Self.color(c.4)))
            }
        }
        .frame(width: size, height: size)
        .drawingGroup()
    }
}

// MARK: - 时间 / 颜色

func relativeText(_ d: Date) -> String {
    let s = Date().timeIntervalSince(d)
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(Int(s / 60)) 分钟前" }
    if s < 86400 { return "\(Int(s / 3600)) 小时前" }
    let days = Int(s / 86400)
    if days < 30 { return "\(days) 天前" }
    if days < 365 { return "\(days / 30) 个月前" }
    return "\(days / 365) 年前"
}

let kTint = Color(red: 0.95, green: 0.55, blue: 0.35)

/// 用量百分比 → 颜色（绿 → 黄 → 红）
func usageColor(_ pct: Double) -> Color {
    let p = max(0, min(100, pct))
    if p <= 50 {
        let t = p / 50
        return Color(red: 0.30 + 0.62 * t, green: 0.78 - 0.03 * t, blue: 0.45 - 0.22 * t)
    } else if p <= 80 {
        let t = (p - 50) / 30
        return Color(red: 0.92 + 0.03 * t, green: 0.75 - 0.32 * t, blue: 0.23 + 0.02 * t)
    } else {
        let t = (p - 80) / 20
        return Color(red: 0.95 - 0.03 * t, green: 0.43 - 0.20 * t, blue: 0.25 + 0.05 * t)
    }
}

// MARK: - 用量圆环

struct UsageRing: View {
    let snapshot: UsageSnapshot
    let loading: Bool

    private var percent: Double { snapshot.session?.percent ?? 0 }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.11), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, percent / 100)))
                    .stroke(usageColor(percent),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if loading {
                    Circle().fill(.white.opacity(0.55)).frame(width: 3, height: 3)
                }
            }
            .frame(width: 21, height: 21)

            VStack(alignment: .leading, spacing: 0) {
                // 左 = 重置时间，右 = 已用百分比
                Text("\(Self.fmt(snapshot.session?.resetsAt, "HH:mm"))  \(String(format: "%.0f%%", percent))")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(usageColor(percent))
                Text("\(Self.fmt(snapshot.weekly?.resetsAt, "MM-dd"))  \(String(format: "%.0f%%", snapshot.weekly?.percent ?? 0))")
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
        .help(helpText)
    }

    private static func fmt(_ d: Date?, _ pattern: String) -> String {
        guard let d else { return pattern == "HH:mm" ? "--:--" : "--/--" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = pattern
        return f.string(from: d)
    }

    private var helpText: String {
        if let e = snapshot.errorText { return "用量读取失败：\(e)" }
        var s = "本 5 小时窗口 \(String(format: "%.0f%%", percent))"
        if let r = snapshot.session?.resetsAt {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            s += "，\(f.string(from: r)) 重置"
        }
        if let w = snapshot.weekly {
            s += "\n本周 \(String(format: "%.0f%%", w.percent))"
        }
        return s
    }
}

// MARK: - 拖放

struct RowDrop: DropDelegate {
    let target: TreeRow
    let store: Store

    func validateDrop(info: DropInfo) -> Bool {
        store.dragging != nil && store.dragging != target
    }

    func dropEntered(info: DropInfo) {
        guard let from = store.dragging, from != target else { return }
        MainActor.assumeIsolated {
            switch (from, target) {
            case let (.project(a), .project(b)):
                store.moveProject(from: a, to: b)
            case let (.session(pa, sa), .session(pb, sb)):
                if pa == pb {
                    store.moveSession(pa, from: sa, to: sb)
                } else {
                    store.moveSessionToProject(pa, sa, pb)
                }
            case let (.session(pa, sa), .project(pb)):
                store.moveSessionToProject(pa, sa, pb)
            default:
                break
            }
            store.dragging = target
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { store.dragging = nil }
        return true
    }
}

// MARK: - 树行视图

struct ProjectRowView: View {
    let store: Store
    let index: Int
    let project: Project
    let selected: Bool
    let live: Bool
    let cursor: Bool
    let hovered: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    /// 终端正在跑这个目录：主色实底；仅光标停留：淡灰底
    private var projectFill: AnyShapeStyle {
        if live { return AnyShapeStyle(kTint.opacity(0.34)) }
        if cursor { return AnyShapeStyle(.white.opacity(0.085)) }
        return AnyShapeStyle(hovered ? .white.opacity(0.05) : .clear)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.34))
                    .rotationEffect(.degrees(project.expanded ? 90 : 0))
                    .frame(width: 10)

                Image(systemName: project.isHome ? "house.fill" : "folder.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(selected ? 1.0 : 0.58))
                    .frame(width: 16)

                Text(project.title)
                    .font(store.appFont(13.5, .semibold))
                    .foregroundStyle(.white.opacity(selected ? 1.0 : 0.80))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if !project.sessions.isEmpty {
                    Text("\(project.sessions.count)")
                        .font(store.appFont(9.5, .medium))
                        .foregroundStyle(.white.opacity(0.32))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(projectFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(kTint.opacity(live ? 0.55 : 0), lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onDrag {
                store.dragging = .project(index)
                return NSItemProvider(object: TreeRow.project(index).key as NSString)
            }
            .onDrop(of: [UTType.plainText], delegate: RowDrop(target: .project(index), store: store))
        }
        .buttonStyle(.plain)
        .onHover { onHover($0) }
        .contextMenu {
            Button("新建对话") { store.openNew(index) }
            Button("置顶") { store.pinProject(index) }
                .disabled(index <= 1)
            Divider()
            Button(project.expanded ? "收起" : "展开") { store.toggleExpand(index) }
            Button("在访达中显示") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
            }
            Divider()
            Button("从列表移除", role: .destructive) { store.removeProject(index) }
                .disabled(project.isHome)
        }
        .opacity(store.dragging == .project(index) ? 0.45 : 1)
    }
}

struct SessionRowView: View {
    let store: Store
    let projectIndex: Int
    let sessionIndex: Int
    let session: Session
    let selected: Bool
    let live: Bool
    let cursor: Bool
    let action: () -> Void

    private var hovered: Bool { store.hoverSession == session.id }

    /// 会话行状态标记用的 key，与 Store.open 里的终端 key 一致
    private var markKey: String { store.key(cwd: session.cwd, sid: session.id) }

    /// Claude 正在执行任务 → 转圈
    private var running: Bool { store.runningKeys.contains(markKey) }

    /// 跑完了但还没点进来看 → 绿点常驻
    private var unread: Bool { store.unreadKeys.contains(markKey) }

    /// 行首标记位：在跑 → 转圈；跑完未读 → 小绿点；其余留空。
    /// （SwiftUI 的 @State 在 CommandLineTools 工具链下不可用，转动由 TimelineView 驱动）
    @ViewBuilder private var rowIcon: some View {
        ZStack {
            if running {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(kTint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
                }
            } else if unread {
                Circle()
                    .fill(Color(red: 0.30, green: 0.85, blue: 0.48))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 17, height: 21, alignment: .center)
        .padding(.leading, 24)
    }

    /// 终端正在跑这条会话：主色实底 + 描边；仅光标停留：淡灰底
    private var sessionFill: AnyShapeStyle {
        if live { return AnyShapeStyle(kTint.opacity(0.26)) }
        if cursor { return AnyShapeStyle(.white.opacity(0.075)) }
        return AnyShapeStyle(hovered ? .white.opacity(0.038) : .clear)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                rowIcon

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(store.appFont(10.8, selected ? .medium : .regular))
                        .foregroundStyle(.white.opacity(selected ? 1.0 : 0.76))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(relativeText(session.date))
                        .font(store.appFont(8.2))
                        .foregroundStyle(.white.opacity(0.28))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 8)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(sessionFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(kTint.opacity(live ? 0.55 : 0), lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onDrag {
                store.dragging = .session(projectIndex, sessionIndex)
                return NSItemProvider(object: TreeRow.session(projectIndex, sessionIndex).key as NSString)
            }
            .onDrop(of: [UTType.plainText],
                    delegate: RowDrop(target: .session(projectIndex, sessionIndex), store: store))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { store.hoverSession = session.id }
            else if store.hoverSession == session.id { store.hoverSession = nil }
        }
        .contextMenu {
            Button("置顶") { store.pinSession(projectIndex, sessionIndex) }
                .disabled(sessionIndex == 0)
            Button("新建对话") { store.openNew(projectIndex) }
            Divider()
            Button("从列表移除", role: .destructive) {
                store.removeSession(projectIndex, sessionIndex)
            }
        }
        .opacity(store.dragging == .session(projectIndex, sessionIndex) ? 0.45 : 1)
    }
}

struct MoreRowView: View {
    let store: Store
    let projectIndex: Int
    let project: Project
    let selected: Bool
    let live: Bool
    let cursor: Bool
    let action: () -> Void

    private var hidden: Int {
        let limit = project.showAll ? project.sessions.count : min(project.sessions.count, kMaxVisibleSessions)
        return max(project.sessions.count - limit, 0)
    }

    var body: some View {
        Button(action: action) {
            // 文字左缘 49 + 外层 6 = 55，与会话标题严格同列；箭头跟在文字后面，不再突出到文字左边
            HStack(spacing: 5) {
                Text(project.showAll ? "收起" : "展开其余 \(hidden) 条")
                    .font(store.appFont(10))
                    .foregroundStyle(.white.opacity(selected ? 0.9 : 0.42))
                Image(systemName: project.showAll ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.36))
                    .frame(width: 9)
                Spacer(minLength: 0)
            }
            .padding(.leading, 49)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? AnyShapeStyle(kTint.opacity(0.16)) : AnyShapeStyle(.clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 设置面板

struct SettingsPanel: View {
    @ObservedObject var store: Store
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("设置")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background { Circle().fill(.white.opacity(0.08)) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("界面字号") {
                        sizeSlider(title: "字号", value: Binding(
                            get: { store.settings.appFontSize },
                            set: { store.settings.appFontSize = $0; store.applyFonts() }),
                            range: 9...20)
                        Text("预览：Claude Code · 会话列表 · 侧边栏")
                            .font(store.appFont(12.5))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    section("终端字号") {
                        sizeSlider(title: "字号", value: Binding(
                            get: { store.settings.termFontSize },
                            set: { store.settings.termFontSize = $0; store.applyFonts() }),
                            range: 9...22)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 420)
        .background {
            ZStack {
                BehindBlur(material: .hudWindow)
                Color.black.opacity(0.35)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
            content()
        }
    }

    private func sizeSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 34, alignment: .leading)
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = ($0 * 2).rounded() / 2 }
            ), in: range)
                .controlSize(.small)
                .tint(kTint)
                .labelsHidden()
            Text(String(format: "%.1f", value.wrappedValue))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 30, alignment: .trailing)
        }
    }
}

// MARK: - Git 面板

struct GitPanel: View {
    @ObservedObject var store: Store
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(kTint)
                Text("Git")
                    .font(store.appFont(13, .semibold))
                    .foregroundStyle(.white)
                if store.gitLoading {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                }
                Spacer()
                Button {
                    store.refreshGit()
                    store.refreshGitExtras()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("刷新状态")
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭（Esc）")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(.white.opacity(0.08))

            // 分段切换：状态 / 分支 / 工作树
            HStack(spacing: 0) {
                tabButton(0, "状态")
                tabButton(1, "分支")
                tabButton(2, "工作树")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch store.gitTab {
                    case 1:
                        branchesSection
                    case 2:
                        worktreesSection
                    default:
                        branchRow
                        actionBar
                        changesSection
                        logsSection
                    }
                    if !store.gitActionOutput.isEmpty {
                        outputBox
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 560)
        .frame(maxHeight: 620)
        .onAppear { store.refreshGitExtras() }
        .background {
            ZStack {
                BehindBlur(material: .hudWindow)
                Color.black.opacity(0.35)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    // MARK: 子视图

    private var branchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Text(abbrevPath(store.gitStatus.repoRoot.isEmpty ? store.gitCwd : store.gitStatus.repoRoot))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            HStack(spacing: 6) {
                badge("分支：\(store.gitStatus.branch)", color: .white.opacity(0.74))
                if !store.gitStatus.upstream.isEmpty {
                    badge("上游：\(store.gitStatus.upstream)", color: .white.opacity(0.5))
                }
                if store.gitStatus.ahead > 0 {
                    badge("↑\(store.gitStatus.ahead)", color: Color(red: 0.55, green: 0.85, blue: 0.55))
                }
                if store.gitStatus.behind > 0 {
                    badge("↓\(store.gitStatus.behind)", color: Color(red: 0.55, green: 0.75, blue: 0.95))
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                actionButton("获取", icon: "arrow.clockwise", disabled: store.gitStatus.remotes.isEmpty) { store.gitFetch() }
                actionButton("拉取", icon: "arrow.down.circle", disabled: !store.gitStatus.hasRemote) { store.gitPull() }
                actionButton("推送", icon: "arrow.up.circle", disabled: store.gitStatus.detached || !store.gitStatus.hasHead || store.gitStatus.remotes.isEmpty) { store.gitPush() }
                actionButton("暂存全部", icon: "plus.square.on.square", disabled: store.gitStatus.changes.isEmpty) { store.gitStageAll() }
                actionButton("取消暂存", icon: "minus.square", disabled: store.gitStatus.stagedCount == 0) { store.gitUnstageAll() }
                actionButton("放弃未暂存", icon: "trash", disabled: !store.gitStatus.changes.contains(where: \.unstaged) || store.gitStatus.changes.contains(where: \.conflicted), danger: true) { store.gitDiscardAll() }
                Spacer()
                if store.gitActionRunning {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                }
            }
            HStack(spacing: 6) {
                TextField("提交信息…", text: $store.gitMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.07))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                            }
                    }
                    .onSubmit { store.gitCommit() }
                actionButton("提交", icon: "checkmark.circle.fill",
                           disabled: store.gitStatus.changes.contains(where: \.conflicted) || store.gitStatus.stagedCount == 0 || store.gitMessage.trimmingCharacters(in: .whitespaces).isEmpty) {
                    store.gitCommit()
                }
            }
        }
    }

    private var outputBox: some View {
        Text(store.gitActionOutput)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.3))
            }
            .lineLimit(6)
            .textSelection(.enabled)
    }

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("变更文件（\(store.gitStatus.changes.count)）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                smallTextButton("工作区 diff") { store.gitDiffWorking() }
                smallTextButton("暂存区 diff") { store.gitDiffStaged() }
            }
            if store.gitStatus.changes.isEmpty {
                Text(store.gitStatus.isRepo ? "工作区干净" : "当前目录不是 Git 仓库")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(store.gitStatus.changes) { f in
                    HStack(spacing: 6) {
                        Text(f.statusLabel)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(fileStatusColor(f))
                            .frame(width: 42, alignment: .leading)
                        Text(f.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        miniButton("Δ", help: "查看该文件 diff") { store.gitDiffFile(f) }
                        if f.staged {
                            miniButton("−", help: "取消暂存") { store.gitUnstage(f) }
                        }
                        if f.unstaged {
                            miniButton("+", help: "暂存") { store.gitStage(f) }
                        }
                        if f.staged && f.unstaged {
                            miniButton("W", help: "查看未暂存 diff") { store.gitDiffFile(f, staged: false) }
                        }
                        if f.unstaged && !f.conflicted {
                            miniButton("×", help: "放弃未暂存改动", danger: true) { store.gitDiscard(f) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(0.04))
                    }
                }
            }
        }
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近提交")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if store.gitStatus.logs.isEmpty {
                Text("无提交记录")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(store.gitStatus.logs) { e in
                    HStack(spacing: 6) {
                        Text(e.id)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(kTint.opacity(0.9))
                        Text(e.subject)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("\(e.author) · \(e.relTime)")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                        miniButton("Δ", help: "查看该提交 diff") { store.gitDiffCommit(e) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(0.04))
                    }
                }
            }
        }
    }

    // MARK: 分支 / 工作树 / tab

    private func tabButton(_ idx: Int, _ title: String) -> some View {
        Button {
            store.gitTab = idx
        } label: {
            Text(title)
                .font(.system(size: 11, weight: store.gitTab == idx ? .semibold : .regular))
                .foregroundStyle(store.gitTab == idx ? AnyShapeStyle(kTint) : AnyShapeStyle(.white.opacity(0.55)))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(store.gitTab == idx ? 0.09 : 0.0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var branchesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("分支（\(store.gitBranches.count)）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                if store.gitBranchesLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                }
                Spacer()
            }
            // 新建分支
            HStack(spacing: 6) {
                TextField("新分支名…", text: $store.gitNewBranch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.07))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                            }
                    }
                    .onSubmit { store.gitCreateBranch() }
                actionButton("新建并切换", icon: "plus", disabled: store.gitNewBranch.trimmingCharacters(in: .whitespaces).isEmpty) {
                    store.gitCreateBranch()
                }
            }
            if store.gitBranches.isEmpty && !store.gitBranchesLoading {
                Text(store.gitStatus.isRepo ? "无分支信息" : "当前目录不是 Git 仓库")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(store.gitBranches) { b in
                    HStack(spacing: 6) {
                        Image(systemName: b.current ? "checkmark.circle.fill" : (b.remote ? "globe" : "arrow.triangle.branch"))
                            .font(.system(size: 9))
                            .foregroundStyle(b.current ? AnyShapeStyle(kTint) : AnyShapeStyle(.white.opacity(b.remote ? 0.35 : 0.5)))
                        Text(b.name)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(b.remote ? 0.55 : 0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(b.sha)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                        Spacer(minLength: 4)
                        if !b.upstream.isEmpty {
                            badge(b.upstream, color: .white.opacity(0.5))
                        }
                        if b.current {
                            badge("当前", color: kTint)
                        } else {
                            actionButton("切换", icon: "arrow.left.arrow.right", disabled: store.gitActionRunning) {
                                store.gitCheckout(b)
                            }
                        }
                        miniButton("Δ", help: "与当前分支比较（--stat）") { store.gitDiffBranch(b) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(b.current ? 0.07 : 0.04))
                    }
                }
            }
        }
    }

    private var worktreesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("工作树（\(store.gitWorktrees.count)）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                if store.gitWorktreesLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                }
                Spacer()
            }
            // 新建 worktree
            HStack(spacing: 6) {
                TextField("路径…", text: $store.gitWorktreePath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.07))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                            }
                    }
                TextField("分支（可选）…", text: $store.gitWorktreeBranch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.07))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                            }
                    }
                    .frame(width: 110)
                    .onSubmit { store.gitWorktreeAdd() }
                actionButton("添加", icon: "plus", disabled: store.gitWorktreePath.trimmingCharacters(in: .whitespaces).isEmpty || store.gitActionRunning) {
                    store.gitWorktreeAdd()
                }
            }
            if store.gitWorktrees.isEmpty && !store.gitWorktreesLoading {
                Text(store.gitStatus.isRepo ? "无工作树信息" : "当前目录不是 Git 仓库")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(store.gitWorktrees) { wt in
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.45))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(abbrevPath(wt.path))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(wt.branch) · \(wt.head)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        Spacer(minLength: 4)
                        actionButton("打开", icon: "square.and.arrow.up", disabled: store.gitActionRunning) {
                            store.gitOpenWorktree(wt)
                        }
                        actionButton("移除", icon: "trash", disabled: store.gitActionRunning || wt.path == store.gitStatus.repoRoot, danger: true) {
                            store.gitWorktreeRemove(wt)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(0.04))
                    }
                }
            }
        }
    }

    private func smallTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.06))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 辅助

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.06))
            }
    }

    private func actionButton(_ title: String, icon: String, disabled: Bool = false, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(disabled ? AnyShapeStyle(.white.opacity(0.28)) : (danger ? AnyShapeStyle(Color(red: 0.95, green: 0.45, blue: 0.4)) : AnyShapeStyle(.white.opacity(0.8))))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(disabled ? 0.03 : 0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || store.gitActionRunning || store.gitLoading)
    }

    private func miniButton(_ title: String, help: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(danger ? Color(red: 0.95, green: 0.45, blue: 0.4) : .white.opacity(0.6))
                .frame(width: 18, height: 18)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.06))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(store.gitActionRunning || store.gitLoading)
    }

    private func fileStatusColor(_ f: GitFileChange) -> Color {
        if f.conflicted { return .red }
        if f.untracked { return .white.opacity(0.45) }
        if f.status.contains("A") { return Color(red: 0.55, green: 0.85, blue: 0.55) }
        if f.status.contains("D") { return Color(red: 0.95, green: 0.45, blue: 0.4) }
        if f.status.contains("M") { return kTint }
        return .white.opacity(0.6)
    }

    private func abbrevPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }
}

// MARK: - Diff 查看

struct GitDiffView: View {
    @ObservedObject var store: Store
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kTint)
                Text("差分")
                    .font(store.appFont(13, .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(store.gitDiffTitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if store.gitDiffLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background { Circle().fill(.white.opacity(0.08)) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭（Esc）")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(.white.opacity(0.08))

            if store.gitDiffLoading && store.gitDiffText.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在生成差分…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let lines = store.gitDiffText.components(separatedBy: "\n")
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(diffLineColor(line))
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .background { Color.black.opacity(0.25) }
                .textSelection(.enabled)
            }
        }
        .frame(width: 680)
        .frame(maxHeight: 640)
        .background {
            ZStack {
                BehindBlur(material: .hudWindow)
                Color.black.opacity(0.35)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .white.opacity(0.4) }
        if line.hasPrefix("+") { return Color(red: 0.55, green: 0.85, blue: 0.55) }
        if line.hasPrefix("-") { return Color(red: 0.95, green: 0.45, blue: 0.4) }
        if line.hasPrefix("@@") { return Color(red: 0.5, green: 0.7, blue: 1.0) }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") { return .white.opacity(0.5) }
        return .white.opacity(0.78)
    }
}

// MARK: - 状态栏

struct StatusBarView: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 0) {
            menu(label: "模式", value: store.activeMode.label) {
                ForEach(Store.modeCycle, id: \.self) { m in
                    Button {
                        store.cycleTo(m)
                    } label: {
                        if store.activeMode == m { Label(m.label, systemImage: "checkmark") }
                        else { Text(m.label) }
                    }
                }
            }
            sep
            menu(label: "模型", value: store.options.model.label) {
                ForEach(ModelChoice.allCases, id: \.self) { m in
                    Button {
                        store.setModel(m)
                    } label: {
                        if store.options.model == m { Label(m.label, systemImage: "checkmark") }
                        else { Text(m.label) }
                    }
                }
            }
            sep
            menu(label: "推理强度", value: store.options.effort.label) {
                ForEach(EffortChoice.allCases, id: \.self) { e in
                    Button {
                        store.setEffort(e)
                    } label: {
                        if store.options.effort == e { Label(e.label, systemImage: "checkmark") }
                        else { Text(e.label) }
                    }
                }
            }
            sep
            Button {
                store.toggleFast()
            } label: {
                Text("快速模式  \(store.options.fast ? "开启" : "关闭")")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(store.options.fast
                                     ? AnyShapeStyle(kTint)
                                     : AnyShapeStyle(.white.opacity(0.74)))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 30, alignment: .center)
            .help("切换 Fast mode（走 usage credits，单价更高）")

            Spacer(minLength: 8)

            gitButton

            UsageRing(snapshot: store.usage, loading: store.usageLoading)
                .padding(.trailing, 12)
        }
        .frame(height: 30)
        .background {
            Rectangle().fill(.black.opacity(0.16))
        }
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
        }
        .onChange(of: store.gitCwd) { _, _ in store.refreshGit() }
    }

    private var sep: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(width: 1, height: 12)
    }

    /// Git 状态按钮：分支名 + 变更计数 + ahead/behind，点击打开 Git 面板
    @ViewBuilder
    private var gitButton: some View {
        if store.gitStatus.isRepo {
            Button {
                if !store.showGit { store.refreshGit(); store.refreshGitExtras() }
                store.showGit.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.gitLoading ? "arrow.triangle.2.circlepath" : "arrow.triangle.branch")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(store.gitStatus.branch)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    if store.gitStatus.ahead > 0 {
                        Text("↑\(store.gitStatus.ahead)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.55))
                    }
                    if store.gitStatus.behind > 0 {
                        Text("↓\(store.gitStatus.behind)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 0.95))
                    }
                    if store.gitStatus.dirtyCount > 0 {
                        Text("●\(store.gitStatus.dirtyCount)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(kTint)
                    }
                }
                .foregroundStyle(store.showGit ? AnyShapeStyle(kTint) : AnyShapeStyle(.white.opacity(0.74)))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 30, alignment: .center)
            .help("Git：\(store.gitStatus.branch)（点击查看面板）")
            .padding(.trailing, 10)
        }
    }

    /// borderlessButton 的 Menu 会把 label 当模板图渲染，复合 label 里只能用 SF Symbols 图标 + Text；
    /// 不要用字面 "⌄"（U+2304）——字形重心低于大写中线，视觉上永远偏下。
    private func menu<C: View>(label: String, value: String, @ViewBuilder items: () -> C) -> some View {
        Menu {
            items()
        } label: {
            // 只能用单个 Text：Menu 的 label 若含 Image，系统会把它当 leading 图标排到文字前面。
            // 箭头用 Text(Image:) 内联在文字流里，随基线对齐，天然与文字垂直居中。
            (Text("\(label)  \(value) ")
             + Text(Image(systemName: "chevron.down"))
                .font(.system(size: 7.5, weight: .bold))
                .baselineOffset(1))   // 箭头字形重心比 CJK 低 1px，抬回文字光学中线
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // borderlessButton 的 Menu 自身高度跟 padding 走，撑满 30pt 条高才能和右侧文字基线对齐。
        .frame(height: 30, alignment: .center)
        .help(label)
    }
}

// MARK: - 主视图

struct PickerView: View {
    @ObservedObject var store: Store
    var onAdd: () -> Void
    var onCloseTerminal: () -> Void
    var onOpenSettings: () -> Void
    var onCloseSettings: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if store.settings.sidebarCollapsed {
                    collapsedRail
                    divider(active: false, resizable: false)
                } else {
                    sidebar.frame(width: store.sidebarW)
                    divider(active: true, resizable: true)
                }
                terminalArea
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

            if store.showSettings {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { onCloseSettings() }
                SettingsPanel(store: store, onClose: onCloseSettings)
                    .transition(.opacity)
            }

            if store.showGit {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { store.showGit = false }
                GitPanel(store: store, onClose: { store.showGit = false })
                    .transition(.opacity)
            }
            if store.showGitDiff {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { store.showGitDiff = false }
                GitDiffView(store: store, onClose: { store.showGitDiff = false })
                    .transition(.opacity)
            }
        }
        .background {
            ZStack {
                BehindBlur()
                LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02), .black.opacity(0.14)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
        }
    }

    // MARK: 分隔条（可左右拖动）

    @ViewBuilder
    private func divider(active: Bool, resizable: Bool) -> some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .frame(width: 7)
                .contentShape(Rectangle())
            Rectangle()
                .fill(.white.opacity(store.hoverDivider && resizable ? 0.20 : 0.10))
                .frame(width: store.hoverDivider && resizable ? 2 : 1)
        }
        .frame(width: 7)
        .onHover { inside in
            guard resizable else { return }
            store.hoverDivider = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard resizable else { return }
                    if store.dragStartW == nil { store.beginResize() }
                    store.resizeTo(g.translation.width)
                }
                .onEnded { _ in
                    guard resizable else { return }
                    store.endResize()
                }
        , including: resizable ? .all : .subviews)
    }

    // MARK: 收起后的窄条

    private var collapsedRail: some View {
        VStack(spacing: 0) {
            Button(action: { store.toggleSidebar() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.07)) }
            .help("展开侧边栏 ⌘B")
            .padding(.top, 13)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(Array(store.projects.enumerated()), id: \.offset) { i, p in
                        Button {
                            store.revealProject(i)
                        } label: {
                            Text(String(p.title.prefix(1)).uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(store.currentProjectIndex == i ? 0.95 : 0.45))
                                .frame(width: 24, height: 24)
                                .background {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(store.currentProjectIndex == i
                                              ? AnyShapeStyle(kTint.opacity(0.30))
                                              : AnyShapeStyle(.white.opacity(0.05)))
                                }
                        }
                        .buttonStyle(.plain)
                        .help(p.title)
                    }
                }
                .padding(.vertical, 10)
            }

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.06)) }
            .help("添加目录")
            .padding(.bottom, 10)
        }
        .frame(width: 44)
    }

    // MARK: 侧边栏（树）

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                ClawdMark(size: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude Code")
                        .font(store.appFont(12.5, .bold))
                        .foregroundStyle(.white)
                    Text("\(store.projects.count) 个目录 · \(store.rows.count) 行")
                        .font(store.appFont(9.5, .medium))
                        .foregroundStyle(.white.opacity(0.40))
                }
                Spacer(minLength: 0)

                HStack(spacing: 7) {
                    HeaderIconButton(symbol: "sidebar.left", help: "收起侧边栏 ⌘B",
                                     action: { store.toggleSidebar() })
                    HeaderIconButton(symbol: "gearshape.fill", help: "设置",
                                     action: onOpenSettings)
                }
                .fixedSize()
            }
            .frame(height: 40)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(store.rows.enumerated()), id: \.offset) { idx, row in
                            rowView(row, idx)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                }
                .onChange(of: store.sel) { _ in
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(store.sel, anchor: .center) }
                }
                .onChange(of: store.pane) { _ in }
            }

            Button(action: onAdd) {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text("添加目录").font(store.appFont(10.5, .medium))
                }
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(width: store.sidebarW)
    }

    @ViewBuilder
    private func rowView(_ row: TreeRow, _ idx: Int) -> some View {
        let isCursor = store.pane == 0 && store.sel == idx
        let isActive = store.activeRow != nil && store.activeRow! == row
        let selected = isCursor || isActive
        switch row {
        case .project(let i):
            if store.projects.indices.contains(i) {
                let p = store.projects[i]
                ProjectRowView(store: store, index: i, project: p, selected: selected,
                               live: isActive, cursor: isCursor,
                               hovered: false,
                               onHover: { _ in },
                               action: {
                                   store.pane = 0
                                   store.sel = idx
                                   store.toggleExpand(i)
                               })
            }
        case .session(let i, let s):
            if store.projects.indices.contains(i),
               store.projects[i].sessions.indices.contains(s) {
                let ss = store.projects[i].sessions[s]
                SessionRowView(store: store, projectIndex: i, sessionIndex: s,
                               session: ss, selected: selected,
                               live: isActive, cursor: isCursor,
                               action: {
                                   store.pane = 0
                                   store.sel = idx
                                   store.open(cwd: ss.cwd, sid: ss.id, label: ss.title)
                               })
            }
        case .more(let i):
            if store.projects.indices.contains(i) {
                MoreRowView(store: store, projectIndex: i, project: store.projects[i],
                            selected: selected,
                            live: isActive, cursor: isCursor,
                            action: {
                                store.pane = 0
                                store.sel = idx
                                store.toggleShowAll(i)
                            })
            }
        }
    }

    // MARK: 终端

    private var terminalArea: some View {
        Group {
            if let t = store.active {
                VStack(spacing: 0) {
                    TerminalPane(session: t)
                        .id(ObjectIdentifier(t))
                        .padding(.top, kTerminalTopPad)
                        .background(kTermBg)
                        .overlay(alignment: .topTrailing) {
                            // 关闭按钮悬浮在终端右上角
                            Button {
                                store.closeTerminal()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.66))
                                    .frame(width: 20, height: 20)
                                    .background { Circle().fill(.black.opacity(0.45)) }
                                    .overlay {
                                        Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                                    }
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("关闭当前终端 ⌘Esc")
                            .padding(.trailing, 14)
                            .padding(.top, kTerminalTopPad + 6)
                        }
                    StatusBarView(store: store)
                }
            } else {
                VStack(spacing: 10) {
                    ClawdMark(size: 42).opacity(0.26)
                    Text("展开左侧项目，选一个会话")
                        .font(store.appFont(11.5, .medium))
                        .foregroundStyle(.white.opacity(0.42))
                    Text("回车 = 打开 · 右键 = 新建 / 置顶 · 拖拽 = 排序")
                        .font(store.appFont(10))
                        .foregroundStyle(.white.opacity(0.24))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 窗口

final class Counter: @unchecked Sendable { var n = 0 }

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: Store
    let outPath: String
    var window: KeyableWindow!
    private var done = false
    private var activateTimer: Timer?
    private var termKeyMonitor: Any?
    /// 终端里的用户操作（按键 / 滚轮 / 点击 / 拖拽）监视器：这些操作会让 claude 重绘，
    /// 那段输出不是任务在跑，不能用来驱动会话行转圈。
    private var userInputMonitor: Any?
    private var usageTimer: Timer?

    init(store: Store, outPath: String) {
        self.store = store
        self.outPath = outPath
    }

    /// 标准「编辑」菜单：SwiftTerm 的键盘路由会把 ⌘C/⌘V/⌘A 交给 mainMenu 处理，
    /// 没有菜单栏这些快捷键就全落到「Unhandle selector」分支，终端里的内容复制不出来。
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 ClaudePicker", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 ClaudePicker", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 ClaudePicker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        // target 留空 → 走响应链，落到当前 firstResponder（也就是终端视图）的 copy:/paste:/selectAll:
        edit.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(.separator())
        edit.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let rect = NSRect(x: 0, y: 0, width: kWindowW, height: kWindowH)
        window = KeyableWindow(contentRect: rect,
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        window.title = "Claude Code"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 900, height: 520)
        window.isOpaque = true
        window.backgroundColor = NSColor(srgbRed: 0.098, green: 0.103, blue: 0.118, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.hasShadow = true
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        installMainMenu()

        let host = NSHostingView(
            rootView: PickerView(store: store,
                                 onAdd: { [weak self] in self?.addDirectory() },
                                 onCloseTerminal: { [weak self] in
                                     self?.leaveTerminalFocus()
                                     self?.store.closeTerminal()
                                 },
                                 onOpenSettings: { [weak self] in self?.store.showSettings = true },
                                 onCloseSettings: { [weak self] in self?.store.showSettings = false })
        )
        host.frame = window.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        store.onFocusTerminal = { [weak self] in self?.focusTerminalSoon() }
        store.onLeaveTerminal = { [weak self] in self?.leaveTerminalFocus() }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, !self.done else { return nil }
            if NSApp.modalWindow != nil { return ev }
            if self.store.showSettings {
                if ev.keyCode == 53 { self.store.showSettings = false; return nil }
                return ev
            }
            if self.store.showGitDiff {
                if ev.keyCode == 53 { self.store.showGitDiff = false; return nil }
                return ev
            }
            if self.store.showGit {
                if ev.keyCode == 53 { self.store.showGit = false; return nil }
                return ev
            }
            if ev.keyCode == 11 && ev.modifierFlags.contains(.command) {
                self.store.toggleSidebar()
                return nil
            }
            if self.store.pane == 1 {
                // 终端里 ⌘C/⌘V/⌘A 走系统剪贴板：SwiftTerm 的键盘路由会把带 ⌘ 的键
                // 交给 mainMenu，而本 App 没有菜单栏，这些选择器会落到「Unhandle」分支。
                if ev.modifierFlags.contains(.command),
                   let v = self.store.active?.view,
                   let chars = ev.charactersIgnoringModifiers?.lowercased() {
                    switch chars {
                    case "c": v.copy(self); return nil
                    case "v": v.paste(self); return nil
                    case "a": v.selectAll(self); return nil
                    default: break
                    }
                }
                if ev.keyCode == 53 && ev.modifierFlags.contains(.command) {
                    self.store.closeTerminal()
                    return nil
                }
                if ev.keyCode == 53 && ev.modifierFlags.contains(.option) {
                    self.leaveTerminalFocus()
                    return nil
                }
                // Tab 退出终端焦点；但 Shift+Tab 是 claude 的模式切换键，必须放行
                if ev.keyCode == 48, !ev.modifierFlags.contains(.shift) {
                    self.leaveTerminalFocus()
                    return nil
                }
                return ev
            }
            switch ev.keyCode {
            case 126: self.store.up()
            case 125: self.store.down()
            case 123: self.store.left()
            case 124: self.store.right()
            case 36, 76: self.store.confirm()
            case 51, 117: self.store.removeCurrent()   // ⌫ / ⌦ 删除当前目录或会话
            case 53: self.store.onDone?()
            case 48:
                if self.store.terminalRunning { self.store.focusTerminal() }
            default: return ev
            }
            return nil
        }

        centerWindow()

        if !args.startDir.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                if let i = self.store.projects.firstIndex(where: { $0.path == (args.startDir as NSString).standardizingPath }) {
                    self.store.projects[i].expanded = true
                    if let idx = self.store.rows.firstIndex(where: { $0.key == TreeRow.project(i).key }) {
                        self.store.sel = idx
                    }
                }
                self.store.open(cwd: args.startDir,
                                sid: args.startSid.isEmpty ? nil : args.startSid,
                                label: args.startSid.isEmpty ? "新建会话" : "恢复会话")
            }
        }

        store.refreshUsage()
        store.refreshGit()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.refreshUsage()
                self?.store.refreshGit()
            }
        }

        window.alphaValue = 0
        window.orderFrontRegardless()
        let counter = Counter()
        activateTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            counter.n += 1
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if self.window.isKeyWindow || counter.n > 40 { t.invalidate() }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = 1
        }
    }

    private func focusTerminalView() {
        guard let t = store.active else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(t.view)
        installTerminalKeyMonitor()
        installUserInputMonitor()
    }

    /// SwiftTerm 自己的 keyDown 监视器会先吃掉按键，所以这里在终端挂载后再注册一次。
    private func installTerminalKeyMonitor() {
        if let m = termKeyMonitor { NSEvent.removeMonitor(m); termKeyMonitor = nil }
        termKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.store.pane == 1 else { return ev }
            let f = ev.modifierFlags
            if ev.keyCode == 53 && (f.contains(.option) || f.contains(.command)) {
                self.leaveTerminalFocus()
                return nil
            }
            return ev
        }
    }

    /// 终端内的用户操作统一登记到当前会话，过滤紧随其后的重绘忙帧。
    /// scrollWheel / mouseDown / mouseDragged 在 SwiftTerm 里不是 open，无法在子类里 override，
    /// 所以用 AppKit 的本地事件监视器在分发前截获。
    private func installUserInputMonitor() {
        guard userInputMonitor == nil else { return }
        userInputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .keyDown]
        ) { [weak self] ev in
            guard let self, self.store.pane == 1,
                  let t = self.store.active, ev.window === self.window else { return ev }
            // 键盘事件跟随第一响应者，鼠标事件跟随命中视图，包含终端的渲染子视图。
            let target: NSView?
            if ev.type == .keyDown {
                target = self.window.firstResponder as? NSView
            } else {
                target = self.window.contentView?.hitTest(ev.locationInWindow)
            }
            if let target, target === t.view || target.isDescendant(of: t.view) {
                t.noteUserInput()
            }
            return ev
        }
    }

    private func leaveTerminalFocus() {
        if let m = termKeyMonitor { NSEvent.removeMonitor(m); termKeyMonitor = nil }
        store.pane = 0
        window.makeFirstResponder(nil)
    }

    private func centerWindow() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: f.midX - kWindowW / 2,
                                      y: f.midY - kWindowH / 2 + 30))
    }

    func focusTerminalSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.focusTerminalView()
        }
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = "添加"
        panel.message = "选择一个目录，加入侧边栏"
        // 默认打开用户主目录下的 project（若存在），否则退回主目录，避免硬编码开发者路径
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectDir = home.appendingPathComponent("project", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue {
            panel.directoryURL = projectDir
        } else {
            panel.directoryURL = home
        }
        NSApp.activate(ignoringOtherApps: true)

        let ok = panel.runModal() == .OK
        let picked = panel.url
        window.makeKeyAndOrderFront(nil)
        guard ok, let url = picked else { return }
        store.addDirectory(url.path)
    }

    func applicationDidBecomeActive(_ n: Notification) {
        window?.makeKeyAndOrderFront(nil)
        // 外部可能改过 settings.json，重新激活时同步一次
        store.reloadClaudeOptions()
        store.refreshGit()
    }

    func applicationWillTerminate(_ n: Notification) {
        store.terminateAll()
        usageTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }
}

// MARK: - 启动

let args = parseArgs()

func buildProjects() -> [Project] {
    let rawMap = SessionScanner.scan()
    let home = NSHomeDirectory()
    // 被用户删除的目录 / 会话不再出现
    let ord = TreeOrderStore.load()
    let hiddenP = Set(ord.hiddenProjects.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    let hiddenS = Set(ord.hiddenSessions)
    var map: [String: [Session]] = [:]
    for (k, v) in rawMap {
        // scan 出的 cwd 可能是 /private/tmp 这类符号链接形式，而 hiddenProjects 存的是
        // 规范化后的路径；两边必须用同一形态比较，否则「从列表移除」重启后会重新出现。
        let kstd = URL(fileURLWithPath: k).resolvingSymlinksInPath().path
        guard !hiddenP.contains(kstd) else { continue }
        let kept = v.filter { !hiddenS.contains($0.id) }
        if !kept.isEmpty { map[kstd, default: []].append(contentsOf: kept) }
    }
    for k in map.keys { map[k]?.sort { $0.date > $1.date } }
    var seen: Set<String> = [home]
    var nid = 0

    func mk(_ path: String, _ title: String, _ isHome: Bool) -> Project {
        let p = Project(id: isHome ? -1 : nid,
                        title: title,
                        path: path,
                        isHome: isHome,
                        sessions: map[path] ?? [])
        if !isHome { nid += 1 }
        return p
    }

    var list: [Project] = [mk(home, args.homeLabel, true)]

    // 有会话的目录，按最近会话时间倒序
    let withSessions = map.keys
        .filter { $0 != home }
        .sorted { a, b in
            (map[a]?.first?.date ?? .distantPast) > (map[b]?.first?.date ?? .distantPast)
        }
    for p in withSessions where !seen.contains(p) {
        seen.insert(p)
        list.append(mk(p, (p as NSString).lastPathComponent, false))
    }

    // tree.json 里记住但还没会话的目录
    let order = ord
    for p in order.projects {
        let std = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        guard !seen.contains(std), !hiddenP.contains(std) else { continue }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: std, isDirectory: &isDir), isDir.boolValue else { continue }
        seen.insert(std)
        list.append(mk(std, (std as NSString).lastPathComponent, false))
    }

    // cc-open 传入的项目
    for n in args.names {
        let p = (args.root as NSString).appendingPathComponent(n)
        let std = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        guard !seen.contains(std) else { continue }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: std, isDirectory: &isDir), isDir.boolValue else { continue }
        seen.insert(std)
        list.append(mk(std, n, false))
    }

    // 应用保存的顺序：project 顺序 + session 顺序 + 展开状态
    if !order.projects.isEmpty {
        var byPath: [String: Project] = [:]
        for p in list { byPath[p.path] = p }
        var ordered: [Project] = []
        if let homeP = byPath[home] { ordered.append(homeP); byPath.removeValue(forKey: home) }
        for path in order.projects {
            let std = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let p = byPath.removeValue(forKey: std) { ordered.append(p) }
        }
        for p in list where byPath[p.path] != nil {
            ordered.append(p)
            byPath.removeValue(forKey: p.path)
        }
        list = ordered
    }

    for i in list.indices {
        if let saved = order.sessions[list[i].path], !saved.isEmpty {
            var byId: [String: Session] = [:]
            for s in list[i].sessions { byId[s.id] = s }
            var ordered: [Session] = []
            for sid in saved {
                if let s = byId.removeValue(forKey: sid) { ordered.append(s) }
            }
            for s in list[i].sessions where byId[s.id] != nil {
                ordered.append(s)
                byId.removeValue(forKey: s.id)
            }
            list[i].sessions = ordered
        }
        list[i].expanded = order.expanded.contains(list[i].path)
    }

    return list
}

let store = Store(buildProjects())

let app = NSApplication.shared
let delegate = AppDelegate(store: store, outPath: args.outPath)
app.delegate = delegate
app.run()

// MARK: - 头部圆形图标按钮

struct HeaderIconButton: View {
    let symbol: String
    var size: CGFloat = 10.5
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 24, height: 24, alignment: .center)
                .background { Circle().fill(.white.opacity(0.08)) }
                .overlay { Circle().strokeBorder(.white.opacity(0.06), lineWidth: 0.5) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
