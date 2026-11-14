import AppKit
import Combine
import WebKit

// 界面整体由网页外壳渲染（Web/src/shell，按 docs/app-layout-prototype 实现）：
// 项目侧栏、标题栏、输入区、Git 工作台、弹窗都在一个 WKWebView 里；
// 原生侧只负责三件事 —— 状态（Store）、终端（SwiftTerm，嵌在网页留出的「洞」下面）、窗口与快捷键。

// MARK: - 常量

let kWindowW: CGFloat = 1360
let kWindowH: CGFloat = 800
let kWindowMinW: CGFloat = 1040
let kWindowMinH: CGFloat = 600
/// 网页标题栏高度（原型 .titlebar 的 44px），红绿灯按它垂直居中。
let kTitlebarH: CGFloat = 44
/// 红绿灯左边距（原型 .window-brand 的 padding-left）。
let kTrafficLightX: CGFloat = 13
/// 项目展开时默认只显示前 5 条会话（与网页侧栏的 VISIBLE_SESSIONS 一致）
let kMaxVisibleSessions = 5

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

// MARK: - 时间

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

/// 路径规范化：项目与会话的 cwd 一律用解析过符号链接的形态比较（/tmp 与 /private/tmp 是同一个目录）。
func resolvedPath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
}

// MARK: - 状态

@MainActor
final class Store: ObservableObject {
    @Published var projects: [Project]
    /// 所有活着的终端会话，key 见 `key(cwd:sid:)`；切换会话不会杀掉旧终端
    private var panes: [String: TerminalSession] = [:]
    /// 当前显示在第二栏的会话 key
    @Published var activeKey: String = ""
    /// 当前会话的 session id（新建会话是预生成的那个）
    @Published private(set) var activeSessionId: String = ""
    /// 正在跑（Claude 在执行任务）的会话 key 集合 → 会话行显示转圈
    @Published var runningKeys: Set<String> = []
    /// 已跑完但用户还没点进去看的会话 key 集合 → 会话行显示绿点
    @Published var unreadKeys: Set<String> = []

    var active: TerminalSession? { activeKey.isEmpty ? nil : panes[activeKey] }
    @Published var activeLabel: String = ""
    @Published var activePath: String = ""
    @Published var settings: AppSettings = SettingsStore.load()
    @Published var options = ClaudeConfig.loadOptions()
    @Published var activeMode: PermissionMode = ClaudeConfig.loadOptions().mode
    @Published var usage = UsageCache.load() ?? UsageSnapshot(session: nil, weekly: nil)
    private var usageRetryScheduled = false
    @Published var usageLoading = false

    private var hiddenProjects: Set<String>
    private var hiddenSessions: Set<String>
    /// 新建会话时用户起的名字，优先于 claude 自动生成的标题
    private var customTitles: [String: String]

    /// 要把键盘交给终端时回调（打开会话、从树里按 Tab）
    var onFocusTerminal: (() -> Void)?
    /// 当前会话换了（打开 / 切换 / 关闭）：窗口据此换终端视图
    var onActiveChanged: (() -> Void)?

    private var stateObserver: AnyCancellable?
    private var pushScheduled = false
    private var lastPushed = Data()

    init(_ projects: [Project]) {
        self.projects = projects
        let o = TreeOrderStore.load()
        self.hiddenProjects = Set(o.hiddenProjects)
        self.hiddenSessions = Set(o.hiddenSessions)
        self.customTitles = o.titles
        // 任何状态变化都把快照推给网页；同一轮事件循环里的多次改动合并成一次。
        stateObserver = objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePush() }
        }
    }

    // MARK: 快照（网页外壳的唯一数据源）

    func snapshot() -> [String: Any] {
        let projectList: [[String: Any]] = projects.map { project in
            [
                "path": project.path,
                "title": project.title,
                "isHome": project.isHome,
                "expanded": project.expanded,
                "showAll": project.showAll,
                "sessions": project.sessions.map { session -> [String: Any] in
                    let mark = key(cwd: session.cwd, sid: session.id)
                    return [
                        "id": session.id,
                        "title": session.title,
                        "cwd": session.cwd,
                        "time": relativeText(session.date),
                        "running": runningKeys.contains(mark),
                        "unread": unreadKeys.contains(mark),
                    ]
                },
            ]
        }

        var activeInfo: Any = NSNull()
        if let terminal = active {
            let owner = projectIndex(owning: terminal.cwd).map { projects[$0].path } ?? terminal.cwd
            activeInfo = [
                "sessionId": activeSessionId,
                "cwd": terminal.cwd,
                "projectPath": owner,
                "label": activeLabel,
                "busy": runningKeys.contains(activeKey),
            ] as [String: Any]
        }

        func choices<T: Hashable>(_ items: [T], id: (T) -> String, label: (T) -> String) -> [[String: String]] {
            items.map { ["id": id($0), "label": label($0)] }
        }
        // 用启动参数进到「跳过确认」之类不在循环里的模式时，也要能显示当前值
        var modes = Self.modeCycle
        if !modes.contains(activeMode) { modes.append(activeMode) }

        return [
            "home": NSHomeDirectory(),
            "projects": projectList,
            "active": activeInfo,
            "runtime": [
                "mode": activeMode.rawValue,
                "model": options.model.rawValue,
                "effort": options.effort.rawValue,
                "fast": options.fast,
                "modes": choices(modes, id: \.rawValue, label: \.label),
                "models": choices(ModelChoice.allCases, id: \.rawValue, label: \.label),
                "efforts": choices(EffortChoice.allCases, id: \.rawValue, label: \.label),
            ] as [String: Any],
            "settings": [
                "appFontSize": settings.appFontSize,
                "termFontSize": settings.termFontSize,
                "followSessionBranch": settings.followSessionBranch,
                "density": settings.density,
                "sidebar": !settings.sidebarCollapsed,
                "terminal": !settings.terminalCollapsed,
                "workbench": settings.thirdPaneVisible,
                "terminalWidth": settings.terminalWidthPercent,
            ] as [String: Any],
            "usage": usageInfo(),
        ]
    }

    private func usageInfo() -> [String: Any] {
        func window(_ value: UsageWindow?, _ pattern: String) -> Any {
            guard let value else { return NSNull() }
            var reset = pattern == "HH:mm" ? "--:--" : "--/--"
            if let date = value.resetsAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = pattern
                reset = formatter.string(from: date)
            }
            return ["percent": value.percent, "reset": reset] as [String: Any]
        }
        var note: Any = NSNull()
        if let error = usage.errorText {
            if usage.session == nil && usage.weekly == nil {
                note = "用量读取失败：\(error)"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                note = "显示的是 \(formatter.string(from: usage.fetchedAt)) 的数据（最近一次读取失败：\(error)，稍后自动重试）"
            }
        }
        return [
            "session": window(usage.session, "HH:mm"),
            "weekly": window(usage.weekly, "MM-dd"),
            "note": note,
        ]
    }

    private func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pushScheduled = false
                self.pushState()
            }
        }
    }

    /// 把快照推给网页。内容没变就不推（相对时间每分钟才变一次）。
    func pushState() {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.sortedKeys]),
              data != lastPushed else { return }
        if Bridge.emit("claude-picker:state", json: data) { lastPushed = data }
    }

    // MARK: 项目 / 会话定位

    func projectIndex(path: String) -> Int? {
        if let index = projects.firstIndex(where: { $0.path == path }) { return index }
        let resolved = resolvedPath(path)
        return projects.firstIndex { $0.path == resolved || resolvedPath($0.path) == resolved }
    }

    /// 会话所属的项目：cwd 就是项目目录，或者是它的 `.worktrees/<名字>`。
    func projectIndex(owning cwd: String) -> Int? {
        if let index = projectIndex(path: cwd) { return index }
        let resolved = resolvedPath(cwd)
        let owner = WorktreeLayout.owner(of: resolved)
        return owner == resolved ? nil : projectIndex(path: owner)
    }

    private func sessionIndex(_ project: Int, id: String) -> Int? {
        projects[project].sessions.firstIndex { $0.id == id }
    }

    private func session(id: String) -> Session? {
        for project in projects {
            if let hit = project.sessions.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    // MARK: 会话 ⇄ 分支绑定

    /// 打开会话时让 Git 工作台跟到该会话：切到会话所在项目；会话记录的分支与仓库当前分支不同时，
    /// 工作区干净且同仓库没有别的会话在跑才自动签出，否则只提示、不动仓库
    /// （同一仓库的会话共用一个工作目录，强切分支会改掉正在跑的会话脚下的文件）。
    func followSessionBranch(cwd: String, sid: String?) {
        guard settings.thirdPaneVisible else { return }
        let projectPath = projectIndex(owning: cwd).map { projects[$0].path } ?? cwd
        // 独立工作树里的会话有自己的检出目录，主工作区不需要、也不能跟着切到它的分支。
        let inWorktree = resolvedPath(projectPath) != resolvedPath(cwd)
        let sessionBranch: String? = inWorktree ? nil : sid.flatMap { session(id: $0)?.fileURL }
            .flatMap { SessionScanner.lastGitBranch($0) }
        let openingKey = key(cwd: cwd, sid: sid ?? "")
        let otherRunning = runningKeys.contains { k in
            k != openingKey && (panes[k]?.cwd == cwd)
        }

        Task { @MainActor in
            var detail: [String: Any] = ["projectPath": projectPath]
            if let sessionBranch { detail["sessionBranch"] = sessionBranch }
            let git = GitService()
            guard let sessionBranch,
                  let status = try? await git.status(projectPath: projectPath),
                  let current = status.branch
            else {
                detail["state"] = "project"
                Bridge.emit("claude-picker:follow-session", detail: detail)
                return
            }
            detail["currentBranch"] = current
            if current == sessionBranch {
                detail["state"] = "same"
            } else if !status.files.isEmpty {
                detail["state"] = "mismatch"
                detail["reason"] = "工作区有 \(status.files.count) 项未提交的变更"
            } else if otherRunning {
                detail["state"] = "mismatch"
                detail["reason"] = "同一仓库还有其它会话在运行"
            } else {
                do {
                    try await git.switchBranch(projectPath: projectPath, branch: sessionBranch)
                    detail["state"] = "switched"
                } catch let error as GitError {
                    detail["state"] = "mismatch"
                    detail["reason"] = error.detail ?? error.message
                } catch {
                    detail["state"] = "mismatch"
                    detail["reason"] = "\(error)"
                }
            }
            Bridge.emit("claude-picker:follow-session", detail: detail)
        }
    }

    /// 在 Git 工作台选中某个分支时，在第一栏定位到该分支对应的会话：
    /// 会话的分支取自其记录里最后的 gitBranch；有多个时定位最近的一个（只定位、不打开）。
    /// 返回匹配到的会话数；设置里没开「会话与分支」绑定时返回 nil。
    @discardableResult
    func revealBranchSessions(projectPath: String, branch: String) -> Int? {
        guard settings.followSessionBranch else { return nil }
        guard let pi = projectIndex(path: projectPath) else { return 0 }
        let matches = projects[pi].sessions.enumerated().filter { _, session in
            guard let url = session.fileURL else { return false }
            return SessionScanner.lastGitBranch(url) == branch
        }
        guard let first = matches.first else { return 0 }
        if !projects[pi].expanded { projects[pi].expanded = true }
        // 最近的匹配会话可能藏在「展开其余 N 条」里
        if first.offset >= kMaxVisibleSessions, !projects[pi].showAll { projects[pi].showAll = true }
        persistTree()
        Bridge.emit("claude-picker:reveal",
                    detail: ["sessionId": first.element.id, "matched": matches.count])
        return matches.count
    }

    // MARK: 删除

    func removeProject(_ i: Int) {
        guard projects.indices.contains(i), !projects[i].isHome else { return }
        let p = projects.remove(at: i)
        hiddenProjects.insert(p.path)
        hiddenSessions.subtract(p.sessions.map(\.id))
        persistTree()
    }

    func removeSession(_ p: Int, _ s: Int) {
        guard projects.indices.contains(p), projects[p].sessions.indices.contains(s) else { return }
        let sess = projects[p].sessions.remove(at: s)
        hiddenSessions.insert(sess.id)
        customTitles.removeValue(forKey: sess.id)
        persistTree()
    }

    /// 从列表移除：给了会话 id 就移除会话，否则移除整个目录（家目录不可移除）。
    func remove(projectPath: String, sessionId: String?) {
        guard let p = projectIndex(path: projectPath) else { return }
        if let sessionId {
            if let s = sessionIndex(p, id: sessionId) { removeSession(p, s) }
        } else {
            removeProject(p)
        }
    }

    // MARK: 展开

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

    // MARK: 打开会话

    func openNew(_ i: Int) {
        guard projects.indices.contains(i) else { return }
        let p = projects[i]
        open(cwd: p.path, sid: nil, label: "新建 · \(p.title)")
    }

    /// 多终端会话 key：同一目录下每个 session 各占一个终端
    func key(cwd: String, sid: String) -> String {
        URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path + "|" + sid
    }

    /// 打开（或切到）一个会话。`sid == nil` 是新建：`name` 作为会话名，`prompt` 作为首条提示词。
    @discardableResult
    func open(cwd: String, sid: String?, label: String, name: String? = nil, prompt: String? = nil) -> String {
        // 新建会话：先预生成 session id，会话一建立就有稳定标识，也能立刻插到列表最前
        let newId = sid == nil ? UUID().uuidString.lowercased() : nil
        let sessionId = sid ?? newId ?? ""
        let k = key(cwd: cwd, sid: sessionId)
        if panes[k] == nil {
            let t = TerminalSession(cwd: cwd, resumeId: sid, sessionId: newId,
                                    name: name, prompt: prompt,
                                    options: options,
                                    fontName: settings.termFontName,
                                    fontSize: settings.termFontSize)
            t.onExit = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.runningKeys.remove(k)
                    self.refreshSession(cwd: cwd, sid: sessionId)
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
                        self.refreshSession(cwd: cwd, sid: sessionId)
                        if self.activeKey != k, t?.awayOutput == true {
                            self.unreadKeys.insert(k)
                        }
                    }
                }
            }
            panes[k] = t
        }
        if let newId {
            if let name, !name.isEmpty { customTitles[newId] = name }
            insertNewSession(cwd: cwd, id: newId, title: name)
        }
        unreadKeys.remove(k)
        if let owner = projectIndex(owning: cwd), !projects[owner].expanded {
            projects[owner].expanded = true
            persistTree()
        }
        // 切换视图只抑制重绘，任务状态持续跟随 Claude 的忙闲信号。
        if activeKey != k, let prev = panes[activeKey] { prev.noteDetached() }
        panes[k]?.noteActivated()
        activeKey = k
        activeSessionId = sessionId
        activeLabel = label
        activePath = cwd
        activeMode = options.mode
        onActiveChanged?()
        refreshSession(cwd: cwd, sid: sessionId)
        if settings.followSessionBranch { followSessionBranch(cwd: cwd, sid: sid) }
        onFocusTerminal?()
        return sessionId
    }

    /// 新建会话插到所属项目会话列表最前（tree.json 存的也是这个顺序 → 重启后仍在最前）
    private func insertNewSession(cwd: String, id: String, title: String?) {
        guard let i = projectIndex(owning: cwd) else { return }
        guard !projects[i].sessions.contains(where: { $0.id == id }) else { return }
        let s = Session(id: id, cwd: resolvedPath(cwd),
                        title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "新建会话",
                        summary: nil, date: Date())
        projects[i].sessions.insert(s, at: 0)
        projects[i].expanded = true
        persistTree()
    }

    /// 用户起过名字的会话，标题始终用那个名字。
    private func retitled(_ session: Session) -> Session {
        guard let custom = customTitles[session.id], custom != session.title else { return session }
        return Session(id: session.id, cwd: session.cwd, title: custom, summary: session.summary,
                       date: session.date, fileURL: session.fileURL)
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
                    let fresh = self.retitled(updated)
                    if self.projects[i].sessions[j] != fresh { self.projects[i].sessions[j] = fresh }
                    if self.activeKey == sessionKey, self.activeLabel != fresh.title {
                        self.activeLabel = fresh.title
                    }
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
        activeSessionId = ""
        activeLabel = ""
        onActiveChanged?()
    }

    /// 退出 App 时把所有还活着的终端一起关掉（多终端并存后不能只关当前那个）
    func terminateAll() {
        for (_, t) in panes { t.terminate() }
        panes.removeAll()
        runningKeys.removeAll()
        unreadKeys.removeAll()
        activeKey = ""
        activeSessionId = ""
    }

    // MARK: 输入区发送

    /// 把输入框里的提示词交给当前会话；没有会话（或它已经退出）时在 `projectPath` 里起一个新会话。
    func sendPrompt(_ text: String, projectPath: String?) {
        if let terminal = active {
            if terminal.alive {
                deliver(text, to: terminal, attempt: 0)
                return
            }
            // 进程已退出：带着这条提示词恢复同一个会话
            let cwd = terminal.cwd, sid = activeSessionId, label = activeLabel
            panes.removeValue(forKey: activeKey)
            activeKey = ""
            open(cwd: cwd, sid: sid.isEmpty ? nil : sid, label: label, prompt: text)
            return
        }
        let candidates = [projectPath, activePath.isEmpty ? nil : activePath]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let target = candidates.first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        } ?? NSHomeDirectory()
        let title = projectIndex(path: target).map { projects[$0].title } ?? (target as NSString).lastPathComponent
        open(cwd: target, sid: nil, label: "新建 · \(title)", prompt: text)
    }

    /// 会话刚起来的头一两秒还不接受输入，稍后重试几次。
    private func deliver(_ text: String, to terminal: TerminalSession, attempt: Int) {
        if terminal.submit(text) { return }
        guard attempt < 24, terminal.alive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak terminal] in
            MainActor.assumeIsolated {
                guard let self, let terminal else { return }
                self.deliver(text, to: terminal, attempt: attempt + 1)
            }
        }
    }

    // MARK: 上下文占用

    /// 当前会话最近一次请求的上下文用量；没有会话或还没产生过请求时各项为 0。
    func contextInfo() -> [String: Any] {
        let configured = (ClaudeConfig.read()["model"] as? String)
        var info: [String: Any] = [
            "sessionId": activeSessionId.isEmpty ? NSNull() : activeSessionId,
            "model": options.model.label,
            "used": 0,
            "total": 200_000,
            "parts": [[String: Any]](),
        ]
        guard !activeSessionId.isEmpty else { return info }
        let file = session(id: activeSessionId)?.fileURL ?? SessionScanner.find(id: activeSessionId)?.fileURL
        guard let file, let usage = ContextUsage.read(file) else {
            info["total"] = (configured ?? "").lowercased().contains("[1m]") ? 1_000_000 : 200_000
            return info
        }
        info["model"] = usage.model.isEmpty ? options.model.label : usage.modelLabel
        info["used"] = usage.used
        info["total"] = usage.total(configuredModel: configured)
        info["parts"] = [
            ["label": "缓存命中", "value": usage.cacheRead],
            ["label": "缓存写入", "value": usage.cacheCreation],
            ["label": "新增输入", "value": usage.input],
            ["label": "模型输出", "value": usage.output],
        ]
        return info
    }

    // MARK: 排序

    func moveProject(from: Int, to: Int) {
        guard projects.indices.contains(from), projects.indices.contains(to), from != to else { return }
        guard from >= 1, to >= 1 else { return }   // 家目录固定第一位
        let p = projects.remove(at: from)
        projects.insert(p, at: to)
        persistTree()
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

    /// 置顶：给了会话 id 就置顶会话，否则置顶目录。
    func pin(projectPath: String, sessionId: String?) {
        guard let p = projectIndex(path: projectPath) else { return }
        if let sessionId {
            if let s = sessionIndex(p, id: sessionId) { pinSession(p, s) }
        } else {
            pinProject(p)
        }
    }

    func moveProject(fromPath: String, toPath: String) {
        guard let from = projectIndex(path: fromPath), let to = projectIndex(path: toPath) else { return }
        moveProject(from: from, to: to)
    }

    func moveSession(projectPath: String, fromId: String, toId: String) {
        guard let p = projectIndex(path: projectPath),
              let from = sessionIndex(p, id: fromId), let to = sessionIndex(p, id: toId) else { return }
        moveSession(p, from: from, to: to)
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
        o.titles = customTitles
        TreeOrderStore.save(o)
    }

    // MARK: 添加目录

    /// 把一个目录加进侧栏。返回规范化后的路径；目录不存在返回 nil。
    @discardableResult
    func addDirectory(_ path: String) -> String? {
        let std = resolvedPath(path.trimmingCharacters(in: .whitespacesAndNewlines))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: std, isDirectory: &isDir), isDir.boolValue else { return nil }
        // 之前「从列表移除」过的目录，这次重新添加就取消隐藏，否则重启后仍会被过滤掉
        hiddenProjects.remove(std)
        if let i = projectIndex(path: std) {
            projects[i].expanded = true
            persistTree()
            return projects[i].path
        }
        let id = (projects.map(\.id).filter { $0 >= 0 }.max() ?? 0) + 1
        var p = Project(id: id, title: (std as NSString).lastPathComponent,
                        path: std, isHome: false, sessions: [])
        p.expanded = true
        // 新建目录插到最前（家目录恒为第 0 位），persistTree 写入的顺序即重启后的顺序
        projects.insert(p, at: min(1, projects.count))
        persistTree()
        return std
    }

    // MARK: 设置

    /// 网页外壳改设置（字号、密度、三栏显隐、终端栏宽度…），落盘并让终端字号即时生效。
    func applySettings(_ patch: [String: Any]) {
        var next = settings
        func number(_ key: String) -> Double? { (patch[key] as? NSNumber)?.doubleValue }
        func flag(_ key: String) -> Bool? { patch[key] as? Bool ?? (patch[key] as? NSNumber)?.boolValue }
        if let v = number("appFontSize") { next.appFontSize = min(max(v, 9), 20) }
        if let v = number("termFontSize") { next.termFontSize = min(max(v, 9), 22) }
        if let v = flag("followSessionBranch") { next.followSessionBranch = v }
        if let v = patch["density"] as? String, v == "comfortable" || v == "compact" { next.density = v }
        if let v = flag("sidebar") { next.sidebarCollapsed = !v }
        if let v = flag("terminal") { next.terminalCollapsed = !v }
        if let v = flag("workbench") { next.thirdPaneVisible = v }
        if let v = number("terminalWidth") { next.terminalWidthPercent = min(max(v, 24), 57) }
        guard next != settings else { return }
        let fontChanged = next.termFontSize != settings.termFontSize
        settings = next
        SettingsStore.save(next)
        if fontChanged {
            for t in panes.values {
                t.applyFont(fontName: next.termFontName, fontSize: next.termFontSize)
            }
        }
    }

    // MARK: 运行参数（写进正在运行的 claude）

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

    func setFast(_ on: Bool) {
        guard options.fast != on else { return }
        options.fast = on
        ClaudeConfig.setFast(on)
        active?.send("/fast\n")
    }

    /// 网页输入区的四项运行参数。未知的键或取值直接忽略。
    func applyRuntime(key: String, value: Any?) {
        switch key {
        case "mode":
            if let raw = value as? String, let mode = PermissionMode(rawValue: raw) { cycleTo(mode) }
        case "model":
            if let raw = value as? String, let model = ModelChoice(rawValue: raw) { setModel(model) }
        case "effort":
            if let raw = value as? String, let effort = EffortChoice(rawValue: raw) { setEffort(effort) }
        case "fast":
            if let on = value as? Bool ?? (value as? NSNumber)?.boolValue { setFast(on) }
        default:
            break
        }
    }

    /// 从磁盘重读四项（窗口重新激活时用，避免外部改动不同步）
    func reloadClaudeOptions() {
        let o = ClaudeConfig.loadOptions()
        if options != o { options = o }
        if active == nil, activeMode != o.mode { activeMode = o.mode }
    }

    // MARK: 用量

    /// 取用量。成功：替换并写缓存。失败（限流 / 网络 / 无凭据）：保留上次的数字，只记下错误给悬停提示，
    /// 30 秒后补取一次——不能让一次失败把用量条清成空白。
    func refreshUsage() {
        guard !usageLoading else { return }
        usageLoading = true
        UsageFetcher.fetch { [weak self] snap in
            guard let self else { return }
            self.usageLoading = false
            if snap.session != nil || snap.weekly != nil {
                self.usage = snap
                UsageCache.save(snap)
                return
            }
            var kept = self.usage
            kept.errorText = snap.errorText
            self.usage = kept
            guard !self.usageRetryScheduled else { return }
            self.usageRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                MainActor.assumeIsolated {
                    self?.usageRetryScheduled = false
                    self?.refreshUsage()
                }
            }
        }
    }
}

// MARK: - 窗口

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: Store
    let outPath: String
    var window: KeyableWindow!
    /// 窗口内容：网页外壳 + 终端视图
    private(set) var shell: ShellView!
    private var activateTimer: Timer?
    private var usageTimer: Timer?
    private var stateTimer: Timer?
    /// 终端里的用户操作（按键 / 滚轮 / 点击 / 拖拽）监视器：这些操作会让 claude 重绘，
    /// 那段输出不是任务在跑，不能用来驱动会话行转圈。
    private var userInputMonitor: Any?

    init(store: Store, outPath: String) {
        self.store = store
        self.outPath = outPath
    }

    // MARK: 菜单

    /// 标准菜单：终端与网页里的 ⌘C / ⌘V / ⌘A / ⌘Z 都靠「编辑」菜单沿响应链分发；
    /// 「显示」菜单里的布局快捷键由键盘监视器统一处理（终端有焦点时网页收不到按键）。
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 ClaudePicker", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        addCommand(appMenu, "设置…", "openSettings", key: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 ClaudePicker", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 ClaudePicker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        addCommand(fileMenu, "新建会话", "newSession", key: "n")
        let closeItem = fileMenu.addItem(withTitle: "关闭当前终端",
                                         action: #selector(AppDelegate.closeTerminal(_:)), keyEquivalent: "")
        closeItem.target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        // target 留空 → 走响应链，落到当前 firstResponder（终端视图或网页）
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(.separator())
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        addCommand(viewMenu, "收起 / 展开项目侧栏", "toggleSidebar", key: "b")
        addCommand(viewMenu, "收起 / 展开终端", "toggleTerminal", key: "j")
        addCommand(viewMenu, "收起 / 展开工作台", "toggleWorkbench", key: "\\")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    private func addCommand(_ menu: NSMenu, _ title: String, _ command: String, key: String) {
        let item = menu.addItem(withTitle: title, action: #selector(AppDelegate.runCommand(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = command
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        sendCommand(command)
    }

    @objc private func closeTerminal(_ sender: Any?) {
        store.closeTerminal()
    }

    /// 布局与弹窗的状态在网页里：原生只把命令转过去。会弹出输入框的命令先把键盘交给网页。
    private func sendCommand(_ name: String) {
        if name == "newSession" || name == "openSettings" { shell.focusWeb() }
        Bridge.emit("claude-picker:command", detail: ["name": name])
    }

    // MARK: 启动

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let rect = NSRect(x: 0, y: 0, width: kWindowW, height: kWindowH)
        window = KeyableWindow(contentRect: rect,
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        window.title = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Claude Code"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // 拖动窗口只认网页标题栏上回报的空白区域（ShellView 的拖动条），内容区点击不移动窗口。
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: kWindowMinW, height: kWindowMinH)
        window.isOpaque = true
        window.backgroundColor = kTerminalBackground
        window.appearance = NSAppearance(named: .darkAqua)
        window.hasShadow = true
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.delegate = self

        installMainMenu()

        shell = ShellView(frame: rect)
        shell.autoresizingMask = [.width, .height]
        window.contentView = shell
        shell.showTerminal(store.active?.view)

        store.onFocusTerminal = { [weak self] in self?.focusTerminalSoon() }
        store.onActiveChanged = { [weak self] in
            guard let self else { return }
            self.shell.showTerminal(self.store.active?.view)
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.window === self.window else { return ev }
            if NSApp.modalWindow != nil { return ev }
            let flags = ev.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags == .command {
                switch ev.keyCode {
                case 11: self.sendCommand("toggleSidebar"); return nil      // ⌘B
                case 38: self.sendCommand("toggleTerminal"); return nil     // ⌘J
                case 45: self.sendCommand("newSession"); return nil         // ⌘N
                case 42: self.sendCommand("toggleWorkbench"); return nil    // ⌘\
                default: break
                }
            }
            guard self.isTerminalFocused, let terminal = self.store.active else { return ev }
            // 终端里 ⌘C/⌘V/⌘A 走系统剪贴板：SwiftTerm 的键盘路由会把带 ⌘ 的键交给 mainMenu，
            // 这里直接调终端视图的实现，不依赖菜单项的启用状态。
            if flags == .command, let chars = ev.charactersIgnoringModifiers?.lowercased() {
                switch chars {
                case "c": terminal.view.copy(self); return nil
                case "v": terminal.view.paste(self); return nil
                case "a": terminal.view.selectAll(self); return nil
                default: break
                }
            }
            if ev.keyCode == 53 && flags == .command {      // ⌘Esc 关闭当前终端
                self.store.closeTerminal()
                return nil
            }
            if ev.keyCode == 53 && flags == .option {       // ⌥Esc 把键盘交回项目树
                self.leaveTerminalFocus()
                return nil
            }
            // Tab 退出终端焦点；Shift+Tab 是 claude 的模式切换键，必须放行
            if ev.keyCode == 48, flags.isEmpty {
                self.leaveTerminalFocus()
                return nil
            }
            return ev
        }
        installUserInputMonitor()

        centerWindow()

        if !args.startDir.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.store.open(cwd: args.startDir,
                                sid: args.startSid.isEmpty ? nil : args.startSid,
                                label: args.startSid.isEmpty ? "新建会话" : "恢复会话")
            }
        }

        store.refreshUsage()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.refreshUsage()
            }
        }
        // 会话行上的相对时间（「3 分钟前」）要跟着走
        stateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.pushState()
            }
        }

        window.alphaValue = 0
        window.orderFrontRegardless()
        layoutTrafficLights()
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        activateTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                counter.n += 1
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                if self.window.isKeyWindow || counter.n > 40 {
                    self.activateTimer?.invalidate()
                    self.activateTimer = nil
                }
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = 1
        }
    }

    // MARK: 红绿灯

    /// 把红绿灯垂直居中到 44pt 的网页标题栏里。系统在窗口尺寸变化、进出全屏、激活状态变化时
    /// 会把按钮摆回默认位置，所以这些时机都要重摆一次。
    private func layoutTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        var frame = container.frame
        frame.size.height = kTitlebarH
        frame.origin.y = window.frame.height - kTitlebarH
        container.frame = frame
        let spacing = mini.frame.minX - close.frame.minX
        let y = (kTitlebarH - close.frame.height) / 2
        for (index, button) in [close, mini, zoom].enumerated() {
            button.setFrameOrigin(NSPoint(x: kTrafficLightX + CGFloat(index) * spacing, y: y))
        }
    }

    func windowDidResize(_ notification: Notification) { layoutTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { layoutTrafficLights() }
    func windowDidResignKey(_ notification: Notification) { layoutTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutTrafficLights() }

    // MARK: 焦点

    /// 终端视图（或它的渲染子视图）是否持有键盘焦点。
    private var isTerminalFocused: Bool {
        guard let terminal = store.active?.view, let responder = window?.firstResponder as? NSView else { return false }
        return responder === terminal || responder.isDescendant(of: terminal)
    }

    private func focusTerminalView() {
        guard let t = store.active else { return }
        window.makeKeyAndOrderFront(nil)
        shell.focusTerminal(t.view)
    }

    func focusTerminalSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.focusTerminalView()
        }
    }

    /// 把键盘从终端交回网页里的项目树。
    private func leaveTerminalFocus() {
        shell.focusWeb()
        Bridge.emit("claude-picker:command", detail: ["name": "focusTree"])
    }

    /// 终端内的用户操作统一登记到当前会话，过滤紧随其后的重绘忙帧。
    /// scrollWheel / mouseDown / mouseDragged 在 SwiftTerm 里不是 open，无法在子类里 override，
    /// 所以用 AppKit 的本地事件监视器在分发前截获。
    private func installUserInputMonitor() {
        guard userInputMonitor == nil else { return }
        userInputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .keyDown]
        ) { [weak self] ev in
            guard let self, let t = self.store.active, ev.window === self.window else { return ev }
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

    private func centerWindow() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let width = min(kWindowW, f.width - 40)
        let height = min(kWindowH, f.height - 40)
        window.setFrame(NSRect(x: f.midX - width / 2, y: f.midY - height / 2 + 20,
                               width: width, height: height), display: false)
    }

    // MARK: 添加目录

    /// 「添加目录」弹窗里的「选择…」：用系统面板挑一个目录，返回路径；取消返回 nil。
    func pickDirectory() -> String? {
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
        window.makeKeyAndOrderFront(nil)
        return ok ? panel.url?.path : nil
    }

    // MARK: 生命周期

    func applicationDidBecomeActive(_ n: Notification) {
        window?.makeKeyAndOrderFront(nil)
        // 外部可能改过 settings.json，重新激活时同步一次
        store.reloadClaudeOptions()
    }

    func applicationWillTerminate(_ n: Notification) {
        store.terminateAll()
        usageTimer?.invalidate()
        stateTimer?.invalidate()
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
        // 在 `<项目>/.worktrees/<名字>` 里跑的会话归到 `<项目>` 名下（会话自己的 cwd 不变）。
        let kstd = WorktreeLayout.owner(of: URL(fileURLWithPath: k).resolvingSymlinksInPath().path)
        guard !hiddenP.contains(kstd) else { continue }
        let kept = v.filter { !hiddenS.contains($0.id) }.map { session -> Session in
            // 用户新建会话时起的名字优先于 claude 自动生成的标题
            guard let custom = ord.titles[session.id] else { return session }
            return Session(id: session.id, cwd: session.cwd, title: custom, summary: session.summary,
                           date: session.date, fileURL: session.fileURL)
        }
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
