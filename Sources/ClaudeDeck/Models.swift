import Foundation

// MARK: - 会话（从 ~/.claude/projects 读取）

struct Session: Identifiable, Equatable {
    let id: String          // sessionId
    let cwd: String
    let title: String       // 首条人类消息提炼的标题
    let date: Date
}

enum SessionScanner {
    static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// 返回 cwd -> 会话（按时间倒序）
    static func scan() -> [String: [Session]] {
        var out: [String: [Session]] = [:]
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return out }
        for d in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: d, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                if let s = parse(f) { out[s.cwd, default: []].append(s) }
            }
        }
        for k in out.keys { out[k]?.sort { $0.date > $1.date } }
        return out
    }

    private static func head(_ url: URL, bytes: Int = 131072) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: bytes)) ?? Data()
        var s = String(decoding: data, as: UTF8.self)
        if let i = s.lastIndex(of: "\n") { s = String(s[s.startIndex..<i]) }
        return s
    }

    private static func parse(_ url: URL) -> Session? {
        let sid = url.deletingPathExtension().lastPathComponent
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date(timeIntervalSince1970: 0)
        var cwd: String?
        var title: String?
        var sawImage = false
        for line in head(url).split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if title != nil { continue }
            guard (obj["type"] as? String) == "user" else { continue }
            if let side = obj["isSidechain"] as? Bool, side { continue }
            if let o = obj["origin"] as? [String: Any], let k = o["kind"] as? String, k != "human" { continue }
            guard let msg = obj["message"] as? [String: Any] else { continue }
            let text = plainText(msg["content"])
            if let t = summarize(text) { title = t }
            if text.contains("[Image") { sawImage = true }
        }
        guard let c = cwd else { return nil }
        let fallback = sawImage ? "图片对话" : "空会话"
        return Session(id: sid, cwd: c, title: title ?? fallback, date: mtime)
    }

    private static func plainText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        return ""
    }

    /// 把首条人类消息压成一行标题；噪声（启动命令 / 系统提醒 / 粘贴块）返回 nil 继续找下一条
    static func summarize(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // Claude Code 自己注入的命令回显与系统提醒，不是人说的话
        if t.hasPrefix("<local-command-") { return nil }
        if t.hasPrefix("<command-name>") || t.hasPrefix("<command-message>") { return nil }
        if t.hasPrefix("Caveat:") { return nil }
        if t.hasPrefix("<") && t.contains("system-reminder") { return nil }

        // 去掉粘贴块标记，保留其中第一行内容
        if let r = t.range(of: "<pasted_content") {
            var body = String(t[r.upperBound...])
            if let close = body.range(of: "</pasted_content>") { body = String(body[..<close.lowerBound]) }
            if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) }
            t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 去掉 markdown 链接尾巴 [@File.java](file://...)
        while let r = t.range(of: "\\[@[^\\]]*\\]\\([^)]*\\)", options: .regularExpression) {
            t.removeSubrange(r)
        }
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // 启动命令噪声
        if t.hasPrefix("cd ") && t.count < 80 { return nil }
        if t == "claude" || t.hasPrefix("claude ") { return nil }
        if t == "1" || t == "status" || t == "继续" { return nil }

        // 纯图片/附件占位符，没有文字信息
        if t.range(of: "^\\[Image[^\\]]*\\]$", options: .regularExpression) != nil { return nil }
        if t.range(of: "^\\[Image: source: [^\\]]*\\]$", options: .regularExpression) != nil { return nil }
        if t.range(of: "^\\[[^\\]]*\\.(png|jpg|jpeg|gif|webp)\\]$", options: [.regularExpression, .caseInsensitive]) != nil { return nil }

        if t.count > 46 {
            let cut = t.index(t.startIndex, offsetBy: 46)
            t = String(t[..<cut]) + "…"
        }
        return t
    }
}

// MARK: - 目录（侧边栏树节点）

struct Project: Identifiable {
    let id: Int
    let title: String
    let path: String
    let isHome: Bool
    var sessions: [Session]
    var expanded: Bool = false
    var showAll: Bool = false       // 展开后是否显示全部会话（默认只显示前 5 条）

    var latest: Date { sessions.first?.date ?? .distantPast }
    var subtitle: String {
        let home = NSHomeDirectory()
        // 家目录标题已经是 ~，副标题给真实路径，避免两行都是 ~
        if isHome { return home }
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - 树形顺序 / 展开状态持久化

struct TreeOrder: Codable {
    var projects: [String] = []
    var sessions: [String: [String]] = [:]
    var expanded: [String] = []
    /// 被删除（从列表移除）的目录 / 会话，scan 时过滤掉
    var hiddenProjects: [String] = []
    var hiddenSessions: [String] = []
}

enum TreeOrderStore {
    static var fileURL: URL {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/claude-picker", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("tree.json")
    }

    static func load() -> TreeOrder {
        guard let data = try? Data(contentsOf: fileURL),
              let o = try? JSONDecoder().decode(TreeOrder.self, from: data) else { return TreeOrder() }
        return o
    }

    static func save(_ o: TreeOrder) {
        guard let data = try? JSONEncoder().encode(o) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 界面设置（应用字体 / 终端字体两套）

struct AppSettings: Codable, Equatable {
    var appFontName: String = ""        // 空 = 系统字体
    var appFontSize: Double = 12.5
    var termFontName: String = "SFMono-Regular"
    var termFontSize: Double = 12.5
    var sidebarCollapsed: Bool = false
    var sidebarWidth: Double = 322

    init() {}

    /// 老版本 settings.json 没有新字段，缺哪个就用默认值，避免解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        appFontName = try c.decodeIfPresent(String.self, forKey: .appFontName) ?? d.appFontName
        appFontSize = try c.decodeIfPresent(Double.self, forKey: .appFontSize) ?? d.appFontSize
        termFontName = try c.decodeIfPresent(String.self, forKey: .termFontName) ?? d.termFontName
        termFontSize = try c.decodeIfPresent(Double.self, forKey: .termFontSize) ?? d.termFontSize
        sidebarCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? d.sidebarCollapsed
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? d.sidebarWidth
    }
}

enum SettingsStore {
    static var fileURL: URL {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/claude-picker", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    static func save(_ s: AppSettings) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 状态栏选项（对应 claude CLI 的能力）

enum PermissionMode: String, CaseIterable {
    case auto, manual, plan, acceptEdits, bypassPermissions, dontAsk

    var label: String {
        switch self {
        case .auto: return "自动"
        case .manual: return "手动"
        case .plan: return "规划"
        case .acceptEdits: return "接受编辑"
        case .bypassPermissions: return "跳过确认"
        case .dontAsk: return "不再询问"
        }
    }

    /// 写进 settings.json 的 `permissions.defaultMode` 值
    var configValue: String {
        self == .manual ? "default" : rawValue
    }

    /// 从 settings.json 的 `permissions.defaultMode` 还原
    static func fromConfig(_ s: String?) -> PermissionMode {
        guard let s, s != "default" else { return .manual }
        return PermissionMode(rawValue: s) ?? .manual
    }

    /// 运行时切换时发给 claude 的斜杠命令（nil = 只能靠启动参数）
    var slashCommand: String? {
        switch self {
        case .plan: return "/plan\n"
        default: return nil
        }
    }
}

enum ModelChoice: String, CaseIterable {
    case opus, sonnet, haiku, fable

    var label: String {
        switch self {
        case .opus: return "Opus 5.5"
        case .sonnet: return "Sonnet 5.5"
        case .haiku: return "Haiku 5.5"
        case .fable: return "Fable 5.5"
        }
    }

    /// settings.json 的 `model` 键存的别名
    var configValue: String { rawValue }

    /// `modelSettings` 的键要用 canonical 模型名，别名无效
    var canonicalId: String { "claude-\(rawValue)-5-5" }
}

enum EffortChoice: String, CaseIterable {
    case medium, low, high, xhigh, max

    var label: String {
        switch self {
        case .medium: return "默认"
        case .low: return "低"
        case .high: return "高"
        case .xhigh: return "极高"
        case .max: return "最高"
        }
    }
}

// MARK: - 运行参数（状态栏 + 新建会话共用）

struct RenderOptions: Equatable {
    var mode: PermissionMode = .auto
    var model: ModelChoice = .opus
    var effort: EffortChoice = .medium
    var fast: Bool = false

    /// 拼进 `claude` 命令行的启动参数
    func flags() -> String {
        // --permission-mode 只认 CLI 的六个 choice（没有 "default"）；
        // settings.json 的 permissions.defaultMode 才用 "default" 表示手动。
        var a = ["--permission-mode \(mode.rawValue)"]
        a.append("--model \(model.rawValue)")
        a.append("--effort \(effort.rawValue)")
        return a.joined(separator: " ")
    }
}

// MARK: - claude CLI 真实配置读写（~/.claude/settings.json）

/// 状态栏四项的唯一真源：直接读写 `~/.claude/settings.json`。
/// - 模式   -> permissions.defaultMode（"default" 等价于手动）
/// - 模型   -> model（别名 opus/sonnet/haiku/fable）
/// - 推理   -> modelSettings[canonicalId].effortLevel（max 不被接受，会回落 medium）
/// - 快速   -> fastMode
enum ClaudeConfig {
    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func write(_ obj: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    /// 读成状态栏用的四元组
    static func loadOptions() -> RenderOptions {
        let o = read()
        var r = RenderOptions()

        if let m = o["model"] as? String, let mm = ModelChoice(rawValue: m) {
            r.model = mm
        } else {
            r.model = .sonnet
        }

        let perms = o["permissions"] as? [String: Any]
        r.mode = PermissionMode.fromConfig(perms?["defaultMode"] as? String)

        r.effort = effortFor(model: r.model, in: o)
        r.fast = (o["fastMode"] as? Bool) ?? false
        return r
    }

    static func effortFor(model: ModelChoice, in obj: [String: Any]) -> EffortChoice {
        let ms = obj["modelSettings"] as? [String: Any]
        let entry = ms?[model.canonicalId] as? [String: Any]
        let raw = entry?["effortLevel"] as? String
        return raw.flatMap(EffortChoice.init(rawValue:)) ?? .medium
    }

    static func setModel(_ m: ModelChoice) {
        var o = read()
        o["model"] = m.configValue
        write(o)
    }

    static func setMode(_ m: PermissionMode) {
        var o = read()
        var perms = (o["permissions"] as? [String: Any]) ?? [:]
        perms["defaultMode"] = m.configValue
        o["permissions"] = perms
        write(o)
    }

    static func setEffort(_ e: EffortChoice, for model: ModelChoice) {
        var o = read()
        var ms = (o["modelSettings"] as? [String: Any]) ?? [:]
        var entry = (ms[model.canonicalId] as? [String: Any]) ?? [:]
        entry["effortLevel"] = e.rawValue
        ms[model.canonicalId] = entry
        o["modelSettings"] = ms
        write(o)
    }

    static func setFast(_ on: Bool) {
        var o = read()
        o["fastMode"] = on
        write(o)
    }
}

// MARK: - Usage 额度（来自 api.anthropic.com/api/oauth/usage）

struct UsageWindow: Equatable {
    var percent: Double        // 0...100
    var resetsAt: Date?
}

struct UsageSnapshot: Equatable {
    var session: UsageWindow?      // five_hour
    var weekly: UsageWindow?       // seven_day
    var fetchedAt: Date = Date()
    var errorText: String?
}

/// 读 Keychain 里的 OAuth token，然后请求用量接口。不阻塞主线程。
enum UsageFetcher {
    static func loadToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String, !tok.isEmpty else { return nil }
        return tok
    }

    static func fetch(_ done: @escaping @Sendable @MainActor (UsageSnapshot) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let tok = loadToken() else {
                DispatchQueue.main.async { MainActor.assumeIsolated { done(UsageSnapshot(session: nil, weekly: nil, errorText: "无凭据")) } }
                return
            }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 12

            let sem = DispatchSemaphore(value: 0)
            final class Box: @unchecked Sendable { var snap = UsageSnapshot(session: nil, weekly: nil) }
            let box = Box()
            URLSession.shared.dataTask(with: req) { data, resp, err in
                defer { sem.signal() }
                if let err {
                    box.snap.errorText = err.localizedDescription
                    return
                }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    box.snap.errorText = "解析失败"
                    return
                }
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                func win(_ key: String) -> UsageWindow? {
                    guard let d = obj[key] as? [String: Any] else { return nil }
                    let pct = (d["utilization"] as? Double) ?? Double(d["utilization"] as? Int ?? 0)
                    var reset: Date?
                    if let s = d["resets_at"] as? String {
                        reset = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
                    }
                    return UsageWindow(percent: pct, resetsAt: reset)
                }
                box.snap.session = win("five_hour")
                box.snap.weekly = win("seven_day")
                if box.snap.session == nil && box.snap.weekly == nil { box.snap.errorText = "无数据" }
            }.resume()
            sem.wait()
            let snap = box.snap
            DispatchQueue.main.async { MainActor.assumeIsolated { done(snap) } }
        }
    }
}
