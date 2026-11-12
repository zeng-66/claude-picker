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
    @Published var active: TerminalSession?
    @Published var activeLabel: String = ""
    @Published var activePath: String = ""
    @Published var settings: AppSettings = SettingsStore.load()
    @Published var options = ClaudeConfig.loadOptions()
    @Published var activeMode: PermissionMode = ClaudeConfig.loadOptions().mode
    @Published var usage = UsageSnapshot(session: nil, weekly: nil)
    @Published var usageLoading = false
    @Published var showSettings = false
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

    func open(cwd: String, sid: String?, label: String) {
        active?.terminate()
        locateRow(cwd: cwd, sid: sid)
        let t = TerminalSession(cwd: cwd, resumeId: sid,
                                options: options,
                                fontName: settings.termFontName,
                                fontSize: settings.termFontSize)
        active = t
        activeLabel = label
        activePath = cwd
        activeMode = options.mode
        pane = 1
        onFocusTerminal?()
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

    func closeTerminal() {
        active?.terminate()
        active = nil
        activeRow = nil
        pane = 0
        clampSel()
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
        projects.append(p)
        if let idx = rows.firstIndex(where: { $0.key == TreeRow.project(projects.count - 1).key }) { sel = idx }
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
        active?.applyFont(fontName: settings.termFontName, fontSize: settings.termFontSize)
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
        .frame(width: 30, height: 30)
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
                Text(String(format: "%.0f%%", percent))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(usageColor(percent))
                if let w = snapshot.weekly {
                    Text(String(format: "周 %.0f%%", w.percent))
                        .font(.system(size: 8.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.32))
                }
            }
        }
        .help(helpText)
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

    /// 终端正在跑这条会话：主色实底 + 描边；仅光标停留：淡灰底
    private var sessionFill: AnyShapeStyle {
        if live { return AnyShapeStyle(kTint.opacity(0.26)) }
        if cursor { return AnyShapeStyle(.white.opacity(0.075)) }
        return AnyShapeStyle(hovered ? .white.opacity(0.038) : .clear)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(selected ? kTint : .white.opacity(0.42))
                    .frame(width: 17, height: 21, alignment: .center)
                    .padding(.leading, 31)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(store.appFont(10.8, selected ? .medium : .regular))
                        .foregroundStyle(.white.opacity(selected ? 1.0 : 0.76))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(relativeText(session.date))
                        .font(store.appFont(8.2))
                        .foregroundStyle(.white.opacity(0.28))
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
            HStack(spacing: 6) {
                Spacer().frame(width: 22)
                Image(systemName: project.showAll ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.36))
                Text(project.showAll ? "收起" : "展开其余 \(hidden) 条")
                    .font(store.appFont(10))
                    .foregroundStyle(.white.opacity(selected ? 0.9 : 0.42))
                Spacer(minLength: 0)
            }
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
            .help("切换 Fast mode（走 usage credits，单价更高）")

            Spacer(minLength: 8)

            UsageRing(snapshot: store.usage, loading: store.usageLoading)

            if store.active != nil {
                sep
                Button {
                    store.closeTerminal()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭当前终端 ⌘Esc")
                .padding(.trailing, 10)
            }
        }
        .frame(height: 30)
        .background {
            Rectangle().fill(.black.opacity(0.16))
        }
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
        }
    }

    private var sep: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(width: 1, height: 12)
    }

    /// borderlessButton 样式会把复合 label 当模板图渲染，所以 label 只用单个 Text。
    private func menu<C: View>(label: String, value: String, @ViewBuilder items: () -> C) -> some View {
        Menu {
            items()
        } label: {
            Text("\(label)  \(value)  ⌄")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                ClawdMark().frame(width: 30, height: 30)
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
                    StatusBarView(store: store)
                }
            } else {
                VStack(spacing: 10) {
                    ClawdMark().frame(width: 42, height: 42).opacity(0.26)
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
    private var usageTimer: Timer?

    init(store: Store, outPath: String) {
        self.store = store
        self.outPath = outPath
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
            if ev.keyCode == 11 && ev.modifierFlags.contains(.command) {
                self.store.toggleSidebar()
                return nil
            }
            if self.store.pane == 1 {
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
        usageTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refreshUsage() }
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
    }

    func applicationWillTerminate(_ n: Notification) {
        store.active?.terminate()
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
        guard !hiddenP.contains(k) else { continue }
        let kept = v.filter { !hiddenS.contains($0.id) }
        if !kept.isEmpty { map[k] = kept }
    }
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
