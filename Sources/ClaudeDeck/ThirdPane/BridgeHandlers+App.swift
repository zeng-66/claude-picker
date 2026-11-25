import AppKit
import Foundation

/// 应用级方法（`app.*`）：网页外壳读状态快照、回报布局、改设置与运行参数、操作项目树、
/// 发送提示词。全部读写 `@MainActor` 的 `Store`，在主线程上同步执行。
///
/// 数据源就是原生 `Store`：项目与会话来自启动时的 `buildProjects()`（扫
/// `~/.claude/projects/<编码路径>/*.jsonl`），忙闲标记来自终端的任务状态信号。
/// 本文件不重写扫描逻辑，也不碰 `tree.json` 的格式（那是 `Store.persistTree()` 的事）。
enum AppHandlers: BridgeModule {
    private static let methods: Set<String> = [
        "app.state", "app.layout", "app.settings", "app.runtime",
        "app.toggleProject", "app.toggleShowAll", "app.pin", "app.remove", "app.renameSession", "app.revealInFinder",
        "app.moveProject", "app.moveSession", "app.addDirectory", "app.pickDirectory",
        "app.prompt", "app.command", "app.context", "app.revealBranchSessions", "app.openURL",
    ]

    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        guard methods.contains(method) else { return .unknown }
        // `[String: Any]` 不是 Sendable，不能直接带进 / 带出 MainActor 隔离域：
        // 进出都走一次 JSON（Data 是 Sendable）。这些方法的参数与结果都很小。
        let input = try JSONSerialization.data(withJSONObject: params as? [String: Any] ?? [:])
        let output = try MainActor.assumeIsolated { () throws -> Data in
            let dict = (try JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
            let result = try run(method, dict) ?? NSNull()
            return try JSONSerialization.data(withJSONObject: ["value": result])
        }
        let wrapped = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        return .handled(wrapped?["value"] ?? NSNull())
    }

    /// 原生 `Store` 与窗口外壳只在 `AppDelegate` 上挂着。
    @MainActor
    static func delegate() throws -> AppDelegate {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else {
            throw GitError.commandFailed("应用还没完成启动", recoverable: true)
        }
        return delegate
    }

    @MainActor
    private static func run(_ method: String, _ dict: [String: Any]) throws -> Any? {
        let delegate = try delegate()
        let store = delegate.store

        func projectIndex(_ key: String = "projectPath") throws -> Int {
            let path = try BridgeSupport.string(dict, key)
            guard let index = store.projectIndex(path: path) else {
                throw GitError.commandFailed("列表里没有这个项目：\(path)", recoverable: false)
            }
            return index
        }

        switch method {
        case "app.state":
            return store.snapshot()

        case "app.layout":
            delegate.shell.applyLayout(dict)
            return nil

        case "app.refreshUsage":
            if dict["onlyIfEmpty"] as? Bool == true {
                store.refreshCodexUsage(onlyIfEmpty: true)
            } else {
                store.refreshUsage()
                store.refreshCodexUsage()
            }
            return nil

        case "app.copyText":
            let value = try BridgeSupport.string(dict, "text")
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(value, forType: .string) else {
                throw GitError.commandFailed("无法写入剪贴板", recoverable: true)
            }
            return nil

        case "app.settings":
            store.applySettings(dict)
            return nil

        case "app.runtime":
            store.applyRuntime(key: try BridgeSupport.string(dict, "key"), value: dict["value"])
            return nil

        case "app.toggleProject":
            store.toggleExpand(try projectIndex("path"))
            return nil

        case "app.toggleShowAll":
            store.toggleShowAll(try projectIndex("path"))
            return nil

        case "app.pin":
            store.pin(projectPath: try BridgeSupport.string(dict, "projectPath"),
                      sessionId: BridgeSupport.optionalString(dict, "sessionId"))
            return nil

        case "app.remove":
            store.remove(projectPath: try BridgeSupport.string(dict, "projectPath"),
                         sessionId: BridgeSupport.optionalString(dict, "sessionId"))
            return nil

        // 重命名会话；`title` 为空表示恢复成 Claude 根据对话生成的标题。
        case "app.renameSession":
            let sessionId = try BridgeSupport.string(dict, "sessionId")
            guard store.renameSession(id: sessionId, title: BridgeSupport.optionalString(dict, "title") ?? "") else {
                throw GitError.commandFailed("列表里没有这个会话：\(sessionId)", recoverable: false)
            }
            return nil

        case "app.openURL":
            // 外部链接（TAPD 工作项、素材来源）用系统默认浏览器打开；只接受 http / https。
            guard let url = URL(string: try BridgeSupport.string(dict, "url")),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw GitError.commandFailed("只能打开 http / https 链接", recoverable: false)
            }
            NSWorkspace.shared.open(url)
            return nil

        case "app.revealInFinder":
            let path = resolvedPath(try BridgeSupport.string(dict, "path"))
            guard FileManager.default.fileExists(atPath: path) else {
                throw GitError.commandFailed("目录不存在：\(path)", recoverable: false)
            }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            return nil

        case "app.moveProject":
            store.moveProject(fromPath: try BridgeSupport.string(dict, "from"),
                              toPath: try BridgeSupport.string(dict, "to"))
            return nil

        case "app.moveSession":
            store.moveSession(projectPath: try BridgeSupport.string(dict, "projectPath"),
                              fromId: try BridgeSupport.string(dict, "from"),
                              toId: try BridgeSupport.string(dict, "to"))
            return nil

        case "app.addDirectory":
            let raw = try BridgeSupport.string(dict, "path")
            guard let added = store.addDirectory(raw) else {
                throw GitError.commandFailed("目录不存在：\(raw)", recoverable: true)
            }
            return ["path": added]

        case "app.pickDirectory":
            if let picked = delegate.pickDirectory() { return ["path": picked] }
            return ["path": NSNull()]

        case "app.prompt":
            let text = try BridgeSupport.string(dict, "text")
            store.sendPrompt(text, projectPath: BridgeSupport.optionalString(dict, "projectPath")
                .map { ($0 as NSString).expandingTildeInPath })
            return ["ok": true]

        case "app.command":
            switch try BridgeSupport.string(dict, "name") {
            case "closeTerminal": store.closeTerminal()
            case "focusTerminal": delegate.focusTerminalSoon()
            default: break
            }
            return nil

        case "app.context":
            return store.contextInfo()

        // Git 工作台选中分支 → 第一栏定位到该分支对应的会话
        case "app.revealBranchSessions":
            let path = try BridgeSupport.projectPath(dict)
            let branch = try BridgeSupport.string(dict, "branch")
            guard let count = store.revealBranchSessions(projectPath: path, branch: branch) else {
                return ["enabled": false, "matched": 0]
            }
            return ["enabled": true, "matched": count]

        default:
            return nil
        }
    }
}
