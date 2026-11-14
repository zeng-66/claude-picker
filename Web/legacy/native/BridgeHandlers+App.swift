import AppKit
import Foundation

/// 应用级数据：项目列表、会话列表。这两个方法 SPEC 没定义，由 T1 卡补充，T6 卡（task-7）接线。
///
/// 数据源就是第一栏（原生 SwiftUI 侧栏）正在显示的那一份 —— `Store.projects`：
/// 启动时由 `buildProjects()` 用 `SessionScanner.scan()` 扫
/// `~/.claude/projects/<编码路径>/*.jsonl` 得到，之后 `Store.refreshSession` 就地更新。
/// 本文件**只读** `Store`，不重写扫描逻辑，也不碰 `tree.json` 的排序 / 隐藏格式
/// （那是 `Store.persistTree()` 的事）。
///
/// 于是「标题、相对时间、忙闲」天然与第一栏一致：
/// - 标题 = `Session.title`（`SessionScanner` 产出的原值）
/// - 相对时间 = 直接调 `main.swift` 的 `relativeText(_:)`，与 `SessionRowView` 同一份实现
/// - 忙 / 闲 = `Store.runningKeys` / `unreadKeys`，与 `SessionRowView.rowIcon` 同一套 key
///   （`Store.key(cwd:sid:)`），不是前端自己猜的
///
/// 线程：`WebPane.Coordinator` 的 `WKScriptMessageHandler` 在主线程回调，因此这里用
/// `MainActor.assumeIsolated` 读 `@MainActor` 的 `Store`。若哪天桥改到别的线程上回调，
/// 这里会按 Swift 6 的运行时检查直接崩，而不是悄悄返回半截数据 —— 有意的。
enum AppHandlers: BridgeModule {
    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        let dict = params as? [String: Any] ?? [:]
        switch method {
        case "app.projects":
            return .handled(try bridgedJSON { try projectsJSON() })

        case "app.sessions":
            return .handled(try bridgedJSON { try sessionsJSON(matching: nil) })

        // projectId 在 protocol.js 里声明成 string，而 Swift 侧 Project.id 是 Int，
        // 真实会话又靠 path 归类 —— 三种形态都认：数字 id / 绝对路径 / 项目标题。
        case "session.listForProject":
            let projectId = dict["projectId"] as? String ?? ""
            return .handled(try bridgedJSON { try sessionsJSON(matching: projectId) })

        case "session.open":
            let projectPath = dict["projectPath"] as? String ?? ""
            let cwd = dict["cwd"] as? String ?? ""
            let sessionId = (dict["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            try openSession(projectPath: projectPath, cwd: cwd, sessionId: sessionId)
            return .handled(NSNull())

        // 标题栏上的项目 / 分支 / 工具控件与网页之间的状态同步。
        // Git 工作台选中分支 → 第一栏定位到该分支对应的会话
        case "app.revealBranchSessions":
            let path = dict["projectPath"] as? String ?? ""
            let branch = dict["branch"] as? String ?? ""
            guard !path.isEmpty, !branch.isEmpty else {
                throw GitError.commandFailed("app.revealBranchSessions 需要 projectPath 与 branch")
            }
            return .handled(try bridgedJSON {
                let store = try currentStore()
                guard let count = store.revealBranchSessions(projectPath: path, branch: branch) else {
                    return ["enabled": false, "matched": 0]
                }
                return ["enabled": true, "matched": count]
            })

        case "app.workbenchState":
            return .handled(try bridgedJSON {
                let store = try currentStore()
                return ["projectPath": store.workbenchProject, "tool": store.workbenchTool]
            })

        case "app.reportWorkbench":
            // 先在当前线程取出 Sendable 的值，再进主线程，不把 [String: Any] 跨隔离域传。
            let path = (dict["projectPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let tool = (dict["tool"] as? String).flatMap { $0 == "git" || $0 == "files" ? $0 : nil }
            let branch = (dict["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let ahead = (dict["ahead"] as? NSNumber)?.intValue ?? 0
            let behind = (dict["behind"] as? NSNumber)?.intValue ?? 0
            try MainActor.assumeIsolated {
                let store = try currentStore()
                if let path, store.workbenchProject != path { store.workbenchProject = path }
                if let tool, store.workbenchTool != tool { store.workbenchTool = tool }
                if store.workbenchBranch != branch { store.workbenchBranch = branch }
                if store.workbenchAhead != ahead { store.workbenchAhead = ahead }
                if store.workbenchBehind != behind { store.workbenchBehind = behind }
            }
            return .handled(NSNull())

        default:
            return .unknown
        }
    }

    // MARK: - 主线程取数

    /// 在主线程序列化 JSON，再把**可跨隔离域的 `Data`** 交回非隔离的桥层。
    ///
    /// 不能直接返回 `[String: Any]`：`MainActor.assumeIsolated` 的返回值必须
    /// `Sendable`，而 `Any` 不是。绕一圈 `Data` 既满足 Swift 6 并发检查，
    /// 也让 `Bridge.reply` 拿到的一定是合法 JSON 对象。
    private static func bridgedJSON(_ build: @MainActor () throws -> Any) throws -> Any {
        let data = try MainActor.assumeIsolated {
            try JSONSerialization.data(withJSONObject: try build(), options: [.fragmentsAllowed])
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 原生 `Store` 只在 `AppDelegate` 上挂着；main.swift 的顶层 `let store` 不进桥层。
    @MainActor
    private static func currentStore() throws -> Store {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else {
            throw GitError.commandFailed("原生 Store 尚未就绪：应用还没完成启动")
        }
        return delegate.store
    }

    // MARK: - 快照

    @MainActor
    private static func projectsJSON() throws -> [[String: Any]] {
        let store = try currentStore()
        return store.projects.map { project in
            var object: [String: Any] = [
                // Swift 的 Project.id 是 Int（家目录固定 -1），前端按 path 归类、按 id 兜底。
                "id": project.id,
                "label": project.title,
                "title": project.title,
                "path": project.path,
                "subtitle": project.subtitle,
                "isHome": project.isHome,
                "expanded": project.expanded,
                "showAll": project.showAll,
                "sessionCount": project.sessions.count,
                // 第一栏同一个习惯：默认只显示前 5 条，展开后全显示。
                "sessions": project.sessions.map { sessionJSON($0, project: project, store: store) },
            ]
            if let first = project.sessions.first {
                object["latest"] = first.date.timeIntervalSince1970
                object["latestText"] = relativeText(first.date)
            } else {
                object["latest"] = NSNull()
                object["latestText"] = NSNull()
            }
            return object
        }
    }

    @MainActor
    private static func sessionsJSON(matching filter: String?) throws -> [[String: Any]] {
        let store = try currentStore()
        var result: [[String: Any]] = []
        for project in store.projects where matches(project, filter) {
            for session in project.sessions {
                result.append(sessionJSON(session, project: project, store: store))
            }
        }
        return result
    }

    @MainActor
    private static func sessionJSON(_ session: Session, project: Project, store: Store) -> [String: Any] {
        // 与原生 SessionRowView 完全同一个 key，转圈/绿点不会和第一栏错位。
        let markKey = store.key(cwd: session.cwd, sid: session.id)
        return [
            "id": session.id,
            // 桥协议里 SessionSummary.projectId 声明成 string；Swift 侧 Project.id 是 Int。
            // 以 Swift 为准返回 Int，并同时给 projectPath 当真正的归类键。
            "projectId": project.id,
            "projectPath": project.path,
            "projectTitle": project.title,
            "title": session.title,
            "summary": session.summary ?? NSNull(),
            "cwd": session.cwd,
            "date": isoText(session.date),
            "dateEpoch": session.date.timeIntervalSince1970,
            // 相对时间用原生那一份实现，逐字对齐第一栏。
            "relativeTime": relativeText(session.date),
            "fileURL": session.fileURL?.path ?? NSNull(),
            "running": store.runningKeys.contains(markKey),
            "unread": store.unreadKeys.contains(markKey),
            "live": store.activeKey == markKey,
            "mode": "terminal",
        ]
    }

    private static func isoText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// `session.listForProject` 的过滤：空值 = 全部；数字 id / 绝对路径 / 标题都认。
    private static func matches(_ project: Project, _ filter: String?) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        if filter == project.path || filter == project.title { return true }
        if let id = Int(filter), id == project.id { return true }
        let standardized = URL(fileURLWithPath: filter).resolvingSymlinksInPath().path
        return standardized == project.path
    }

    // MARK: - 切终端

    /// 复用既有的 `Store.open(cwd:sid:label:)`：protocol.js 里写的 `Store.openSession`
    /// 在 Swift 侧实际叫 `open`（T6 对照后按真实实现接线，没有另造一份）。
    private static func openSession(projectPath: String, cwd: String, sessionId: String?) throws {
        try MainActor.assumeIsolated {
            let store = try currentStore()

            // cwd 优先；只有项目路径时退回项目根；会话自带 cwd 比两者都准。
            var target = cwd.isEmpty ? projectPath : cwd
            var title: String?
            if let sessionId {
                for project in store.projects {
                    if let hit = project.sessions.first(where: { $0.id == sessionId }) {
                        title = hit.title
                        if cwd.isEmpty { target = hit.cwd }
                        break
                    }
                }
            }
            guard !target.isEmpty else {
                throw GitError.commandFailed("session.open 需要 cwd 或 projectPath")
            }
            if title == nil {
                let standardized = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
                title = store.projects.first(where: {
                    $0.path == target || $0.path == standardized || $0.path == projectPath
                })?.title
            }
            let label = title ?? (target as NSString).lastPathComponent
            store.open(cwd: target, sid: sessionId, label: label)
        }
    }
}
