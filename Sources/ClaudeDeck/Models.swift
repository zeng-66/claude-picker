import Foundation

// MARK: - 会话（从 ~/.claude/projects 读取）

struct Session: Identifiable, Equatable {
    let id: String          // sessionId
    let cwd: String
    let title: String       // 首条人类消息提炼的标题
    let summary: String?    // Claude Code 写入的会话总结（jsonl 尾部 "type":"summary" 记录），没有则 nil
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
        return Session(id: sid, cwd: c, title: title ?? fallback, summary: tailSummary(url), date: mtime)
    }

    /// 从文件尾部扫出最后一条会话总结记录：
    /// 新版 CLI 写 {"type":"summary","summary":"..."}，本机 2.1.323 写的是
    /// {"type":"ai-title","aiTitle":"..."}（haiku 生成的会话标题），两种都认。
    /// Claude Code 在每轮结束时把它追加在 jsonl 末尾，所以只读尾段即可。
    static func tailSummary(_ url: URL, bytes: Int = 65536) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: start)
        let data = (try? fh.read(upToCount: bytes)) ?? Data()
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        // 从中间截断时第一行不完整，丢掉
        if start > 0, let i = text.firstIndex(of: "\n") { text = String(text[text.index(after: i)...]) }
        var out: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true)
        where line.contains("\"type\":\"summary\"") || line.contains("\"type\": \"summary\"")
            || line.contains("\"type\":\"ai-title\"") || line.contains("\"type\": \"ai-title\"") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = obj["type"] as? String else { continue }
            if t == "summary", let s = obj["summary"] as? String, !s.isEmpty {
                out = s
            } else if t == "ai-title", let s = obj["aiTitle"] as? String, !s.isEmpty {
                out = s
            }
        }
        return out
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
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 {
                    box.snap.errorText = "接口限流，稍后自动重试"
                    return
                }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    box.snap.errorText = "解析失败"
                    return
                }
                // 接口给的是 6 位小数（2026-11-18T10:00:00.581642+00:00），ISO8601 只认 3 位，截到毫秒再解析
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                func parseDate(_ s: String) -> Date? {
                    if let d = iso.date(from: s) { return d }
                    if let dot = s.firstIndex(of: ".") {
                        let tzIdx = s[s.index(after: dot)...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
                        if let tzIdx {
                            let head = String(s[..<dot])
                            let frac = String(s[s.index(after: dot)..<tzIdx].prefix(3))
                            let tail = String(s[tzIdx...])
                            if let d = iso.date(from: "\(head).\(frac)\(tail)") { return d }
                        }
                    }
                    return ISO8601DateFormatter().date(from: s)
                }

                func win(_ key: String) -> UsageWindow? {
                    guard let d = obj[key] as? [String: Any] else { return nil }
                    let pct = (d["utilization"] as? Double) ?? Double(d["utilization"] as? Int ?? 0)
                    var reset: Date?
                    if let s = d["resets_at"] as? String { reset = parseDate(s) }
                    return UsageWindow(percent: pct, resetsAt: reset)
                }
                box.snap.session = win("five_hour")
                box.snap.weekly = win("seven_day")
                if box.snap.session == nil && box.snap.weekly == nil {
                    box.snap.errorText = code == 200 ? "无数据" : "HTTP \(code)"
                }
            }.resume()
            sem.wait()
            let snap = box.snap
            DispatchQueue.main.async { MainActor.assumeIsolated { done(snap) } }
        }
    }
}

// MARK: - Git

struct GitFileChange: Identifiable, Sendable {
    var id: String { "\(status) \(path)" }
    /// porcelain v1 双字符状态，如 " M"、"??"、"A "
    let status: String
    let path: String
    /// 是否已暂存（第一列非空且非 ?）
    var staged: Bool {
        guard !status.isEmpty else { return false }
        let first = status.prefix(1)
        return first != " " && first != "?"
    }
    var untracked: Bool { status == "??" }

    var statusLabel: String {
        if untracked { return "未跟踪" }
        let first = String(status.prefix(1))
        let second = String(status.suffix(1))
        switch first {
        case "A": return "新增"
        case "M": return "已改"
        case "D": return "删除"
        case "R": return "重命名"
        case "?": return "未跟踪"
        default: break
        }
        switch second {
        case "M": return "已改"
        case "D": return "删除"
        case "A": return "新增"
        default: return "其他"
        }
    }
}

struct GitLogEntry: Identifiable, Sendable {
    let id: String
    let subject: String
    let author: String
    let relTime: String
}

struct GitStatus: Sendable {
    var isRepo = false
    var branch = ""
    var upstream = ""
    var ahead = 0
    var behind = 0
    var changes: [GitFileChange] = []
    var logs: [GitLogEntry] = []
    var repoRoot = ""
    var errorText: String?

    var dirtyCount: Int { changes.count }
    var stagedCount: Int { changes.filter { $0.staged }.count }
    var hasRemote: Bool { !upstream.isEmpty }
}

struct GitActionResult: Sendable {
    var ok: Bool
    var output: String
}

enum GitRunner {
    private static let gitPath = "/usr/bin/git"

    private static func env() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["LC_ALL"] = "C"
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        if let path = e["PATH"], !path.contains("/opt/homebrew/bin") {
            e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        }
        return e
    }

    /// 同步跑一条 git 命令（后台队列专用，勿在主线程调）。返回 (exitCode, stdout+stderr 合并文本)。
    private static func runSync(_ args: [String], cwd: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        p.environment = env()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, text)
    }

    /// 采集完整状态（后台）。
    static func fetchStatus(cwd: String, _ done: @escaping @Sendable @MainActor (GitStatus) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var st = GitStatus()
            guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else {
                st.errorText = "路径不存在"
                DispatchQueue.main.async { MainActor.assumeIsolated { done(st) } }
                return
            }
            let (rootCode, rootOut) = runSync(["rev-parse", "--show-toplevel"], cwd: cwd)
            guard rootCode == 0 else {
                DispatchQueue.main.async { MainActor.assumeIsolated { done(st) } }
                return
            }
            st.isRepo = true
            st.repoRoot = rootOut.trimmingCharacters(in: .whitespacesAndNewlines)

            // 分支 + upstream + ahead/behind（一次 status -sb 拿全）
            let (_, sb) = runSync(["status", "--porcelain=v1", "-b"], cwd: st.repoRoot)
            var fileLines: [String] = []
            for line in sb.split(separator: "\n") {
                let l = String(line)
                if l.hasPrefix("## ") {
                    let body = l.dropFirst(3)
                    // "main...origin/main [ahead 1, behind 2]" 或 "## main" 或 "## HEAD (no branch)"
                    var s = String(body)
                    if let br = s.range(of: " [") {
                        let track = String(s[br.upperBound...])
                        s = String(s[..<br.lowerBound])
                        let nums = track.split(whereSeparator: { $0 < "0" || $0 > "9" })
                        if track.contains("ahead"), nums.count >= 1 { st.ahead = Int(nums[0]) ?? 0 }
                        if track.contains("behind"), let last = nums.last { st.behind = Int(last) ?? 0 }
                    }
                    if let dots2 = s.range(of: "...") {
                        st.branch = String(s[..<dots2.lowerBound])
                        st.upstream = String(s[dots2.upperBound...])
                    } else {
                        st.branch = s
                    }
                } else if !l.isEmpty {
                    fileLines.append(l)
                }
            }
            if st.branch == "HEAD (no branch)" || st.branch.hasPrefix("HEAD ") {
                let (c2, out2) = runSync(["rev-parse", "--short", "HEAD"], cwd: st.repoRoot)
                st.branch = c2 == 0 ? "detached \(out2.trimmingCharacters(in: .whitespacesAndNewlines))" : "detached"
            }
            for l in fileLines {
                guard l.count >= 4 else { continue }
                let status = String(l.prefix(2))
                var path = String(l.dropFirst(3))
                if let arrow = path.range(of: " -> ") {
                    path = String(path[arrow.upperBound...])
                }
                if path.hasPrefix("\"") && path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
                st.changes.append(GitFileChange(status: status, path: path))
            }

            // 最近提交
            let logFmt = "%h\u{1f}%s\u{1f}%an\u{1f}%cr"
            let (lc, lo) = runSync(["log", "--oneline", "--format=\(logFmt)", "-15"], cwd: st.repoRoot)
            if lc == 0 {
                for line in lo.split(separator: "\n") {
                    let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                    guard parts.count >= 4 else { continue }
                    st.logs.append(GitLogEntry(id: String(parts[0]), subject: String(parts[1]), author: String(parts[2]), relTime: String(parts[3])))
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(st) } }
        }
    }

    /// 执行一组 git 动作命令（后台），全部完成后回主线程。用于 pull/push/stage/commit 等。
    static func perform(_ cmdGroups: [[String]], cwd: String, _ done: @escaping @Sendable @MainActor (GitActionResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var allOk = true
            var out: [String] = []
            for args in cmdGroups where !args.isEmpty {
                let (code, text) = runSync(args, cwd: cwd)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if code != 0 { allOk = false }
                if !trimmed.isEmpty { out.append(trimmed) }
            }
            let result = GitActionResult(ok: allOk, output: out.joined(separator: "\n"))
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    // MARK: - v2：分支 / diff / worktree

    /// 后台采集分支列表（本地 + 远程），回主线程。
    static func fetchBranches(cwd: String, _ done: @escaping @Sendable @MainActor ([GitBranch]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var branches: [GitBranch] = []
            // --format: %(refname:strip=2)|%(HEAD)|%(upstream:short)|%(objectname:short)
            let (code, out) = runSync(["branch", "-a", "--format=%(refname:strip=2)|%(HEAD)|%(upstream:short)|%(objectname:short)"], cwd: cwd)
            if code == 0 {
                for line in out.split(separator: "\n") {
                    let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 2, !parts[0].isEmpty else { continue }
                    let name = parts[0]
                    if name.contains("->") { continue } // 远程 HEAD 指针行
                    let current = parts.count >= 2 && parts[1] == "*"
                    let upstream = parts.count >= 3 ? parts[2] : ""
                    let sha = parts.count >= 4 ? parts[3] : ""
                    let remote = name.hasPrefix("remotes/")
                    let display = remote ? String(name.dropFirst("remotes/".count)) : name
                    branches.append(GitBranch(name: display, remote: remote, current: current, upstream: upstream, sha: sha))
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(branches) } }
        }
    }

    /// 后台采集 worktree 列表，回主线程。
    static func fetchWorktrees(cwd: String, _ done: @escaping @Sendable @MainActor ([GitWorktree]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var trees: [GitWorktree] = []
            let (code, out) = runSync(["worktree", "list", "--porcelain"], cwd: cwd)
            if code == 0 {
                var path = "", head = "", branch = "", isBare = false
                func flush() {
                    if !path.isEmpty {
                        trees.append(GitWorktree(path: path, branch: isBare ? "(bare)" : branch, head: String(head.prefix(7))))
                    }
                    path = ""; head = ""; branch = ""; isBare = false
                }
                for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
                    let l = String(line)
                    if l.isEmpty { flush(); continue }
                    if l.hasPrefix("worktree ") { path = String(l.dropFirst("worktree ".count)) }
                    else if l.hasPrefix("HEAD ") { head = String(l.dropFirst("HEAD ".count)) }
                    else if l.hasPrefix("branch ") { branch = String(l.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "") }
                    else if l == "bare" { isBare = true }
                    else if l == "detached" { branch = "(detached)" }
                }
                flush()
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(trees) } }
        }
    }

    /// 后台生成 diff 文本，回主线程。args 为 git diff/show 的完整参数组。
    static func fetchDiff(_ args: [String], cwd: String, _ done: @escaping @Sendable @MainActor (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let (code, out) = runSync(args, cwd: cwd)
            let text: String
            if code != 0 {
                text = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "diff 执行失败（exit \(code)）" : out
            } else {
                text = out
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text) } }
        }
    }
}

// MARK: - Git v2 模型

struct GitBranch: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let remote: Bool
    let current: Bool
    let upstream: String
    let sha: String
}

struct GitWorktree: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let branch: String
    let head: String
}
