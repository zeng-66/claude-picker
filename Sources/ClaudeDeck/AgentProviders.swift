import Foundation
import SQLite3

// MARK: - 多引擎抽象（Claude Code / Antigravity / 预留扩展）

enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case claude
    case antigravity
    case codex
    case dsh

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .codex: return "Codex CLI"
        case .dsh: return "DeepSeek Harness"
        }
    }

    var shortLabel: String {
        switch self {
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        case .dsh: return "DeepSeek"
        }
    }

    var badge: String {
        switch self {
        case .claude: return "C"
        case .antigravity: return "A"
        case .codex: return "Cx"
        case .dsh: return "Ds"
        }
    }

    var commandName: String {
        switch self {
        case .claude: return "claude"
        case .antigravity: return "agy"
        case .codex: return "codex"
        case .dsh: return "dsh-tui"
        }
    }

    var supportsFast: Bool { self == .claude }
    var hotModeSwitchable: Bool { self == .claude }
    var supportsGraphicalChat: Bool { self == .claude }
    /// 可由结构化协议驱动：Claude stream-json、Antigravity ACP、Codex App Server。DeepSeek 只走终端。
    var supportsStructuredChat: Bool { self != .dsh }

    static func parse(_ raw: String?) -> AgentProvider {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else {
            return .claude
        }
        if s == "agy" || s == "antigravity" { return .antigravity }
        return AgentProvider(rawValue: s) ?? .claude
    }
}

// MARK: - CLI 可执行文件定位与诊断

enum CliBinaryLocator {
    private static let loginPathCache: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let fallback = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        guard (try? p.run()) != nil else { return fallback }
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return fallback }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return s.isEmpty ? fallback : s
    }()

    static func find(_ provider: AgentProvider) -> String? {
        switch provider {
        case .claude: return findClaude()
        case .antigravity: return findAgy()
        case .codex: return findCommand("codex", override: "CLAUDE_PICKER_CODEX_BIN")
        case .dsh: return findCommand("dsh-tui", override: "CLAUDE_PICKER_DSH_TUI_BIN")
        }
    }

    static func findClaude() -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["CLAUDE_PICKER_CLAUDE_BIN"], !override.isEmpty {
            return fm.isExecutableFile(atPath: override) ? override : nil
        }
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(nvm)/\($0)/bin/claude" }
        }
        for dir in loginPathCache.split(separator: ":") {
            candidates.append("\(dir)/claude")
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static func findAgy() -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["CLAUDE_PICKER_AGY_BIN"], !override.isEmpty {
            return fm.isExecutableFile(atPath: override) ? override : nil
        }
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        for dir in loginPathCache.split(separator: ":") {
            candidates.append("\(dir)/agy")
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static func findCommand(_ command: String, override: String? = nil) -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if let override, let path = env[override], !path.isEmpty {
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        let directories = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (env["PATH"] ?? "").split(separator: ":").map(String.init)
            + loginPathCache.split(separator: ":").map(String.init)
        return directories.map { "\($0)/\(command)" }.first { fm.isExecutableFile(atPath: $0) }
    }

    static func launchError(_ provider: AgentProvider) -> String? {
        if find(provider) == nil { return "未检测到 \(provider.commandName)" }
        if provider == .dsh, findCommand("dsh") == nil { return "缺少 dsh 后端" }
        return nil
    }

    static func diagnostics() -> [[String: Any]] {
        AgentProvider.allCases.map { p in
            let found = find(p)
            let error = launchError(p)
            return [
                "id": p.rawValue,
                "label": p.label,
                "shortLabel": p.shortLabel,
                "command": p.commandName,
                "available": error == nil,
                "status": error ?? "可启动",
                "supportsChat": p.supportsGraphicalChat,
                "path": found ?? NSNull(),
            ]
        }
    }
}

// MARK: - Antigravity 运行参数与配置读写

enum AgyMode: String, CaseIterable, Sendable, Codable {
    case auto = "auto"
    case acceptEdits = "accept-edits"
    case plan = "plan"
    case defaultMode = "default"

    var label: String {
        switch self {
        case .auto: return "自动"
        case .acceptEdits: return "接受编辑"
        case .plan: return "规划"
        case .defaultMode: return "默认询问"
        }
    }

    var cliFlag: String? {
        self == .defaultMode ? nil : "--mode \(rawValue)"
    }
}

struct AgyModelEntry: Equatable, Sendable {
    let id: String
    let label: String
}

enum AgyModelCatalog {
    static let defaults: [AgyModelEntry] = [
        AgyModelEntry(id: "gemini-4-carbon-high", label: "Gemini 4 Carbon (High)"),
        AgyModelEntry(id: "gemini-4-carbon-medium", label: "Gemini 4 Carbon (Medium)"),
        AgyModelEntry(id: "gemini-4-carbon-low", label: "Gemini 4 Carbon (Low)"),
        AgyModelEntry(id: "gemini-4-hydrogen-high", label: "Gemini 4 Hydrogen (High)"),
        AgyModelEntry(id: "gemini-4-hydrogen-xhigh", label: "Gemini 4 Hydrogen (XHigh)"),
        AgyModelEntry(id: "gemini-4-hydrogen-medium", label: "Gemini 4 Hydrogen (Medium)"),
        AgyModelEntry(id: "gemini-4-argon-high", label: "Gemini 4 Argon (High)"),
        AgyModelEntry(id: "gemini-4-argon-medium", label: "Gemini 4 Argon (Medium)"),
        AgyModelEntry(id: "gemini-pro-orchestrator", label: "Orchestrator (Carbon)"),
        AgyModelEntry(id: "gemini-3.8-flash-high", label: "Gemini 3.8 Flash (High)"),
        AgyModelEntry(id: "gemini-3.8-flash-medium", label: "Gemini 3.8 Flash (Medium)"),
        AgyModelEntry(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6 (Thinking)"),
        AgyModelEntry(id: "claude-opus-4-6-thinking", label: "Claude Opus 4.6 (Thinking)"),
        AgyModelEntry(id: "gpt-oss-120b-medium", label: "GPT-OSS 120B (Medium)"),
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var dynamicList: [AgyModelEntry]? = nil

    static func entries() -> [AgyModelEntry] {
        lock.lock()
        defer { lock.unlock() }
        return dynamicList ?? defaults
    }

    static func update(_ items: [AgyModelEntry]) {
        guard !items.isEmpty else { return }
        lock.lock()
        dynamicList = items
        lock.unlock()
    }

    /// 后台刷新一次 `agy models`（TSV: `<id>\t<label>`），失败静默保留内置列表。
    static func refreshInBackground() {
        guard let bin = CliBinaryLocator.findAgy() else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["models"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let deadline = Date().addingTimeInterval(8)
            while p.isRunning, Date() < deadline { usleep(30_000) }
            if p.isRunning { p.terminate(); return }
            guard p.terminationStatus == 0 else { return }
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let parsed: [AgyModelEntry] = text.split(separator: "\n").compactMap { line in
                let cols = line.split(separator: "\t", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard cols.count == 2, !cols[0].isEmpty, !cols[1].isEmpty else { return nil }
                return AgyModelEntry(id: cols[0], label: cols[1])
            }
            update(parsed)
        }
    }

    /// 将 settings.json 里的显示名或模型 ID 归一为标准模型 ID。
    static func normalizeId(_ raw: String?) -> String {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return defaults[0].id
        }
        let list = entries()
        if let hit = list.first(where: { $0.id == s || $0.label.caseInsensitiveCompare(s) == .orderedSame }) {
            return hit.id
        }
        return s
    }

    static func displayLabel(for idOrName: String) -> String {
        let list = entries()
        if let hit = list.first(where: { $0.id == idOrName || $0.label.caseInsensitiveCompare(idOrName) == .orderedSame }) {
            return hit.label
        }
        return idOrName
    }
}

struct AgyRenderOptions: Equatable, Sendable {
    var mode: AgyMode = .auto
    var model: String = AgyModelCatalog.defaults[0].id
    var effort: EffortChoice = .high

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func flags() -> String {
        var parts: [String] = []
        if let m = mode.cliFlag { parts.append(m) }
        if !model.isEmpty { parts.append("--model \(Self.shellQuote(model))") }
        parts.append("--effort \(effort.rawValue)")
        return parts.joined(separator: " ")
    }
}

/// Antigravity 配置：模型同步进 `~/.gemini/antigravity-cli/settings.json`（仅改 `model` 键，保留权限与受信任目录等既有键）；
/// 模式与推理强度保存在本应用数据目录 `agy-runtime.json`，防止向 Go CLI 的 settings.json 写入未定义字段。
enum AgyConfig {
    static var settingsURL: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_PICKER_AGY_SETTINGS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_PICKER_AGY_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("settings.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity-cli/settings.json")
    }

    static var localPrefsURL: URL {
        AppDataDir.url.appendingPathComponent("agy-runtime.json")
    }

    static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func writeSettings(_ obj: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: settingsURL, options: .atomic)
    }

    private static func readLocalPrefs() -> [String: Any] {
        guard let data = try? Data(contentsOf: localPrefsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func writeLocalPrefs(_ obj: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: localPrefsURL, options: .atomic)
    }

    static func loadOptions() -> AgyRenderOptions {
        let s = readSettings()
        let local = readLocalPrefs()
        var out = AgyRenderOptions()
        out.model = AgyModelCatalog.normalizeId(s["model"] as? String)
        if let rawMode = local["mode"] as? String, let m = AgyMode(rawValue: rawMode) {
            out.mode = m
        }
        if let rawEffort = local["effort"] as? String, let e = EffortChoice(rawValue: rawEffort) {
            out.effort = e
        }
        return out
    }

    static func setModel(_ idOrName: String) {
        let normalized = AgyModelCatalog.normalizeId(idOrName)
        var s = readSettings()
        // Antigravity CLI 自身在 settings.json 中写入可读名称（如 "Gemini 4 Carbon (High)"）
        s["model"] = AgyModelCatalog.displayLabel(for: normalized)
        writeSettings(s)
    }

    static func setMode(_ mode: AgyMode) {
        var local = readLocalPrefs()
        local["mode"] = mode.rawValue
        writeLocalPrefs(local)
    }

    static func setEffort(_ effort: EffortChoice) {
        var local = readLocalPrefs()
        local["effort"] = effort.rawValue
        writeLocalPrefs(local)
    }
}

// MARK: - Antigravity 会话扫描（conversation_summaries.db + conversation_metadata.json + transcript.jsonl）

enum AgySessionScanner {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_PICKER_AGY_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

    private struct Candidate {
        var id: String
        var cwd: String
        var title: String?
        var preview: String?
        var date: Date
        var running: Bool
    }

    static func transcriptURL(for id: String, root dir: URL? = nil) -> URL {
        (dir ?? root)
            .appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl")
    }

    static func scan(root overrideRoot: URL? = nil) -> [String: [Session]] {
        let base = overrideRoot ?? root
        let candidates = collectCandidates(in: base)
        var out: [String: [Session]] = [:]
        for item in candidates.values {
            if let session = materialize(item, in: base) {
                out[session.cwd, default: []].append(session)
            }
        }
        for key in out.keys {
            out[key]?.sort { $0.date > $1.date }
        }
        return out
    }

    static func find(id: String, root overrideRoot: URL? = nil) -> Session? {
        let base = overrideRoot ?? root
        let candidates = collectCandidates(in: base)
        if let item = candidates[id] {
            return materialize(item, in: base)
        }
        let tURL = transcriptURL(for: id, root: base)
        guard FileManager.default.fileExists(atPath: tURL.path) else { return nil }
        return parseTranscriptOnly(id: id, url: tURL, fallbackCwd: nil)
    }

    /// 查找某个目录下在 `since` 之后新建的最近一条 Antigravity 会话（用于终端新建 `agy` 后回填真实 conversationId）。
    static func latestConversation(in cwd: String, since: Date, root overrideRoot: URL? = nil) -> Session? {
        let target = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        let all = scan(root: overrideRoot)
        var matches: [Session] = []
        for (dir, list) in all {
            let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            if resolved == target {
                matches.append(contentsOf: list.filter { $0.date >= since.addingTimeInterval(-3) })
            }
        }
        return matches.sorted { $0.date > $1.date }.first
    }

    /// 检查某条 Antigravity 会话是否处于后台生成中（供无 OSC 信号时的终端忙闲补充探测）。
    static func isConversationBusy(id: String, root overrideRoot: URL? = nil) -> Bool {
        let base = overrideRoot ?? root
        let candidates = collectCandidates(in: base)
        if let hit = candidates[id], hit.running { return true }
        let tURL = transcriptURL(for: id, root: base)
        if let mtime = (try? tURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(mtime) < 1.8 {
            return true
        }
        return false
    }

    // MARK: 内部解析

    private static func collectCandidates(in base: URL) -> [String: Candidate] {
        var map: [String: Candidate] = [:]

        // 1. SQLite 主索引：conversation_summaries.db（只读打开，绝不写锁）
        let dbPath = base.appendingPathComponent("conversation_summaries.db").path
        if FileManager.default.fileExists(atPath: dbPath) {
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db {
                defer { sqlite3_close_v2(db) }
                sqlite3_busy_timeout(db, 500)
                let sql = """
                SELECT conversation_id, title, preview, last_modified_time, workspace_uris,
                       status, parent_conversation_id, nesting_depth, not_fully_idle, killed, app_data_dir
                FROM conversation_summaries
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                    defer { sqlite3_finalize(stmt) }
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        func colText(_ idx: Int32) -> String {
                            guard let c = sqlite3_column_text(stmt, idx) else { return "" }
                            return String(cString: c)
                        }
                        let id = colText(0).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !id.isEmpty else { continue }
                        let parent = colText(6).trimmingCharacters(in: .whitespacesAndNewlines)
                        let depth = sqlite3_column_int(stmt, 7)
                        let killed = sqlite3_column_int(stmt, 9)
                        // 过滤子代理会话与已销毁会话
                        if !parent.isEmpty || depth > 0 || killed != 0 { continue }
                        guard let cwd = firstWorkspacePath(fromJSON: colText(4)) else { continue }
                        let title = nonEmpty(colText(1))
                        let preview = nonEmpty(colText(2))
                        let date = parseAnyDate(colText(3)) ?? Date(timeIntervalSince1970: 0)
                        let status = colText(5)
                        let notIdle = sqlite3_column_int(stmt, 8) != 0
                        let running = notIdle || status.contains("RUNNING")
                        map[id] = Candidate(id: id, cwd: cwd, title: title, preview: preview, date: date, running: running)
                    }
                }
            }
        }

        // 2. JSON 元数据缓存补充：cache/conversation_metadata.json
        let metaURL = base.appendingPathComponent("cache/conversation_metadata.json")
        if let data = try? Data(contentsOf: metaURL),
           let rootObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let convs = rootObj["conversations"] as? [String: Any] {
            for (id, raw) in convs {
                guard let entry = raw as? [String: Any] else { continue }
                if (entry["is_internal"] as? Bool) == true { continue }
                let summary = entry["summary"] as? [String: Any] ?? [:]
                if (summary["Internal"] as? Bool) == true { continue }
                let uris = summary["WorkspaceURIs"] as? [String] ?? []
                guard let cwd = uris.compactMap(uriToPath).first else { continue }
                let title = nonEmpty(summary["Title"] as? String)
                let preview = nonEmpty(summary["Preview"] as? String)
                let date = parseAnyDate(entry["last_modified_time"] as? String)
                    ?? parseAnyDate(summary["UpdatedAt"] as? String)
                    ?? Date(timeIntervalSince1970: 0)
                if var existing = map[id] {
                    if existing.title == nil, let title { existing.title = title }
                    if existing.preview == nil, let preview { existing.preview = preview }
                    if date > existing.date { existing.date = date }
                    map[id] = existing
                } else {
                    map[id] = Candidate(id: id, cwd: cwd, title: title, preview: preview, date: date, running: false)
                }
            }
        }

        // 3. history.jsonl 兜底发现尚未进摘要库的最新对话
        let histURL = base.appendingPathComponent("history.jsonl")
        if let data = try? Data(contentsOf: histURL),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let id = nonEmpty(obj["conversationId"] as? String),
                      let ws = nonEmpty(obj["workspace"] as? String) else { continue }
                let ts = (obj["timestamp"] as? NSNumber)?.doubleValue ?? 0
                let date = ts > 1_000_000_000_000
                    ? Date(timeIntervalSince1970: ts / 1000.0)
                    : (ts > 0 ? Date(timeIntervalSince1970: ts) : Date(timeIntervalSince1970: 0))
                let isSlash = (obj["type"] as? String) == "slash_command"
                let display = isSlash ? nil : nonEmpty(obj["display"] as? String)
                if var existing = map[id] {
                    if existing.preview == nil, let display { existing.preview = display }
                    if date > existing.date { existing.date = date }
                    map[id] = existing
                } else {
                    map[id] = Candidate(id: id, cwd: ws, title: nil, preview: display, date: date, running: false)
                }
            }
        }

        return map
    }

    private static func materialize(_ candidate: Candidate, in base: URL) -> Session? {
        let tURL = transcriptURL(for: candidate.id, root: base)
        let hasTranscript = FileManager.default.fileExists(atPath: tURL.path)
        var mtime = candidate.date
        if hasTranscript,
           let fileDate = (try? tURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           fileDate > mtime {
            mtime = fileDate
        }
        var firstPrompt: String? = candidate.preview.flatMap(cleanPromptTitle)
        if firstPrompt == nil, hasTranscript {
            firstPrompt = extractFirstPromptTitle(from: tURL)
        }
        let summary = candidate.title.flatMap(cleanPromptTitle)
        // 既没有标题也没有转录记录的纯空壳（如未发送任何消息即退出的会话）跳过，避免污染侧栏
        if summary == nil && firstPrompt == nil && !hasTranscript { return nil }
        let finalTitle = summary ?? firstPrompt ?? "Antigravity 会话"
        // 若时间戳仍是 0001-01-01，跳过无意义陈旧空项
        if mtime.timeIntervalSince1970 <= 0 && !hasTranscript { return nil }
        return Session(
            id: candidate.id,
            cwd: candidate.cwd,
            title: finalTitle,
            summary: summary,
            date: max(mtime, Date(timeIntervalSince1970: 1)),
            fileURL: hasTranscript ? tURL : nil,
            provider: .antigravity
        )
    }

    static func parseTranscriptOnly(id: String, url: URL, fallbackCwd: String?) -> Session? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date(timeIntervalSince1970: 1)
        let title = extractFirstPromptTitle(from: url) ?? "Antigravity 会话"
        guard let cwd = fallbackCwd, !cwd.isEmpty else { return nil }
        return Session(id: id, cwd: cwd, title: title, summary: nil, date: mtime, fileURL: url, provider: .antigravity)
    }

    static func extractFirstPromptTitle(from url: URL, maxBytes: Int = 131_072) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxBytes)) ?? Data()
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard (obj["type"] as? String) == "USER_INPUT" else { continue }
            if let src = obj["source"] as? String, src != "USER_EXPLICIT" { continue }
            if let content = obj["content"] as? String, let cleaned = cleanPromptTitle(content) {
                return cleaned
            }
        }
        return nil
    }

    /// 剥离 `<USER_REQUEST>`、`<ADDITIONAL_METADATA>`、`<USER_SETTINGS_CHANGE>` 等系统包装块，压成单行可读标题。
    static func cleanPromptTitle(_ raw: String) -> String? {
        var text = raw
        if let open = text.range(of: "<USER_REQUEST>"),
           let close = text.range(of: "</USER_REQUEST>", range: open.upperBound..<text.endIndex) {
            text = String(text[open.upperBound..<close.lowerBound])
        } else {
            let blockTags = ["ADDITIONAL_METADATA", "USER_SETTINGS_CHANGE", "SYSTEM_MESSAGE"]
            for tag in blockTags {
                while let open = text.range(of: "<\(tag)>"),
                      let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) {
                    text.removeSubrange(open.lowerBound..<close.upperBound)
                }
            }
            text = text.replacingOccurrences(of: "</?USER_REQUEST>", with: "", options: .regularExpression)
        }
        return SessionScanner.summarize(text)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func firstWorkspacePath(fromJSON raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return arr.compactMap(uriToPath).first
    }

    private static func uriToPath(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
            return url.path
        }
        if trimmed.hasPrefix("/") { return trimmed }
        return nil
    }

    private static func parseAnyDate(_ raw: String?) -> Date? {
        guard let s = nonEmpty(raw), !s.hasPrefix("0001-01-01") else { return nil }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        // SQLite datetime 格式：`2026-11-16 11:41:37.531512+00:00`
        let normalized = s.replacingOccurrences(of: " ", with: "T")
        if let d = isoFrac.date(from: normalized) ?? iso.date(from: normalized) { return d }
        return nil
    }
}

// MARK: - Antigravity 上下文 Token 解析

enum AgyContextUsage {
    struct Snapshot: Sendable, Equatable {
        var model: String
        var input: Int
        var cacheRead: Int
        var output: Int

        var used: Int { input + cacheRead + output }
        var windowTotal: Int {
            // Antigravity ACP 实测默认窗口为 1,048,576 (1M)；Claude 系列模型在 Agy 中为 200k
            let m = model.lowercased()
            if m.contains("claude") && used <= 200_000 { return 200_000 }
            return max(1_048_576, used)
        }
    }

    static func read(_ url: URL) -> Snapshot? {
        for bytes in [262_144, 4_194_304] {
            if let snap = scan(url, bytes: bytes) { return snap }
        }
        return nil
    }

    private static func scan(_ url: URL, bytes: Int) -> Snapshot? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? fh.seek(toOffset: start)) != nil,
              let chunk = try? fh.readToEnd(), !chunk.isEmpty else { return nil }
        let marker = Data("\"PLANNER_RESPONSE\"".utf8)
        var lines = chunk.split(separator: 0x0a)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            let record = Data(line)
            guard record.range(of: marker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
                  (obj["type"] as? String) == "PLANNER_RESPONSE" else { continue }
            func num(_ key: String) -> Int { (obj[key] as? NSNumber)?.intValue ?? 0 }
            let snap = Snapshot(
                model: (obj["model"] as? String) ?? "",
                input: num("input_tokens"),
                cacheRead: num("cache_read_tokens"),
                output: num("output_tokens")
            )
            if snap.used > 0 { return snap }
        }
        return nil
    }
}

// MARK: - 跨引擎共用会话四层交接信封（<thread-handoff>）

enum HandoffBuilder {
    struct TurnPair: Sendable {
        var role: String    // "用户" | "助手"
        var text: String
    }

    /// 从任意来源会话文件（Claude `.jsonl` 或 Antigravity `transcript.jsonl`）组装结构化四层交接信封。
    static func fromSessionFile(
        sourceProvider: AgentProvider,
        targetProvider: AgentProvider,
        title: String,
        cwd: String,
        fileURL: URL?,
        userInstruction: String? = nil
    ) -> String {
        let turns: [TurnPair]
        if let fileURL {
            turns = sourceProvider == .claude
                ? extractClaudeTurns(from: fileURL, maxTurns: 8)
                : extractAgyTurns(from: fileURL, maxTurns: 8)
        } else {
            turns = []
        }
        return composeEnvelope(
            sourceProvider: sourceProvider,
            targetProvider: targetProvider,
            title: title,
            cwd: cwd,
            turns: turns,
            transcriptPath: fileURL?.path,
            userInstruction: userInstruction
        )
    }

    static func composeEnvelope(
        sourceProvider: AgentProvider,
        targetProvider: AgentProvider,
        title: String,
        cwd: String,
        turns: [TurnPair],
        transcriptPath: String?,
        userInstruction: String?
    ) -> String {
        var lines: [String] = []
        lines.append("<thread-handoff>")
        lines.append("这是一个跨 CLI 接力会话：此前在 \(sourceProvider.label) 中进行，现在切换到 \(targetProvider.label) 继续。")
        lines.append("")
        lines.append("## 1. 会话主题")
        lines.append(title.isEmpty ? "继续此前的开发任务" : title)

        if let gitSummary = gitContextSummary(in: cwd) {
            lines.append("")
            lines.append("## 2. 当前工作区 Git 状态")
            lines.append(gitSummary)
        }

        if !turns.isEmpty {
            lines.append("")
            lines.append("## 3. 最近对话上下文摘录")
            var budget = 12_000
            var selected: [String] = []
            for turn in turns.reversed() {
                let clipped = clip(turn.text, maxChars: 2_400)
                let block = "【\(turn.role)】\n\(clipped)"
                if block.count > budget && !selected.isEmpty { break }
                budget -= block.count
                selected.append(block)
            }
            lines.append(selected.reversed().joined(separator: "\n\n"))
        }

        if let path = transcriptPath, !path.isEmpty {
            lines.append("")
            lines.append("## 4. 完整历史记录文件（只读参考）")
            lines.append("如需查阅更早的工具输出或细节，可按需只读查看：`\(path)`")
        }
        lines.append("</thread-handoff>")
        lines.append("")
        if let prompt = userInstruction?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            lines.append(prompt)
        } else {
            lines.append("请先简要确认你已同步上述交接上下文与当前工作区状态，等待我的下一步指令（或继续未完成的步骤）。")
        }
        return clip(lines.joined(separator: "\n"), maxChars: 18_000)
    }

    private static func extractClaudeTurns(from url: URL, maxTurns: Int) -> [TurnPair] {
        guard let text = readTailUTF8(url, maxBytes: 524_288) else { return [] }
        var out: [TurnPair] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["isSidechain"] as? Bool) != true else { continue }
            let type = obj["type"] as? String
            guard type == "user" || type == "assistant",
                  let msg = obj["message"] as? [String: Any] else { continue }
            let body = extractPlainContent(msg["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, !body.hasPrefix("<local-command-"), !body.hasPrefix("<command-") else { continue }
            out.append(TurnPair(role: type == "user" ? "用户" : "助手", text: body))
        }
        return Array(out.suffix(maxTurns))
    }

    private static func extractAgyTurns(from url: URL, maxTurns: Int) -> [TurnPair] {
        guard let text = readTailUTF8(url, maxBytes: 524_288) else { return [] }
        var out: [TurnPair] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "USER_INPUT" {
                if let src = obj["source"] as? String, src != "USER_EXPLICIT" { continue }
                let raw = (obj["content"] as? String) ?? ""
                let body = cleanUserRequestWrapper(raw)
                if !body.isEmpty { out.append(TurnPair(role: "用户", text: body)) }
            } else if type == "PLANNER_RESPONSE" {
                let body = ((obj["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { out.append(TurnPair(role: "助手", text: body)) }
            }
        }
        return Array(out.suffix(maxTurns))
    }

    private static func cleanUserRequestWrapper(_ raw: String) -> String {
        if let open = raw.range(of: "<USER_REQUEST>"),
           let close = raw.range(of: "</USER_REQUEST>", range: open.upperBound..<raw.endIndex) {
            return String(raw[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractPlainContent(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }
                .joined(separator: "\n")
        }
        return ""
    }

    private static func readTailUTF8(_ url: URL, maxBytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? fh.seek(toOffset: start)) != nil,
              let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }

    private static func gitContextSummary(in cwd: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }
        func runGit(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", cwd] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard runGit(["rev-parse", "--is-inside-work-tree"]) == "true" else { return nil }
        let branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"]) ?? "HEAD"
        let status = runGit(["status", "--short"]) ?? ""
        var summary = "分支：`\(branch)` · 目录：`\(cwd)`"
        if !status.isEmpty {
            summary += "\n未提交变更：\n" + clip(status, maxChars: 1_200)
        }
        return summary
    }

    private static func clip(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars)) + "\n…（已截断）"
    }
}
