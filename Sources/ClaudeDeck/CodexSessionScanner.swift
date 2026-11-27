import Foundation
import SQLite3

enum CodexSessionScanner {
    private static let dateParser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let fallbackDateParser = Date.ISO8601FormatStyle()

    private static func parseDate(_ raw: String) -> Date? {
        (try? dateParser.parse(raw)) ?? (try? fallbackDateParser.parse(raw))
    }

    private static var home: URL {
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func metadata(_ url: URL) -> [String: Any]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        // 首行 session_meta 带着完整的基础指令与 AGENTS.md，项目指令长时会超过几十 KB；读到换行为止（上限 2MB）。
        var bytes = Data()
        var end: Data.Index?
        while end == nil, bytes.count < 2 * 1024 * 1024 {
            guard let chunk = try? file.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            let start = bytes.count
            bytes.append(chunk)
            end = bytes[start...].firstIndex(of: 10)
        }
        guard let end,
              let row = try? JSONSerialization.jsonObject(with: bytes.prefix(upTo: end)) as? [String: Any],
              row["type"] as? String == "session_meta" else { return nil }
        return row["payload"] as? [String: Any]
    }

    /// 按会话 ID 找 rollout（文件名以 `-<ID>.jsonl` 结尾），多份时取最近修改的。
    static func find(id: String) -> Session? {
        guard UUID(uuidString: id) != nil,
              let files = FileManager.default.enumerator(at: home.appendingPathComponent("sessions"),
                                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else { return nil }
        let suffix = "-\(id).jsonl"
        let names = titles()
        return files.compactMap { entry -> Session? in
            guard let file = entry as? URL, file.lastPathComponent.hasSuffix(suffix) else { return nil }
            return parse(file, titles: names)
        }.filter { $0.id == id }.max { $0.date < $1.date }
    }

    /// 会话标题：`session_index.jsonl` 的 `thread_name`（改名会追加新行，后写的为准）优先，
    /// 其次是 `state_5.sqlite` 的 threads.name / title / first_user_message。都没有时才退回「Codex · 短 ID」。
    static func titles() -> [String: String] {
        var map: [String: String] = [:]
        if let database = (try? FileManager.default.contentsOfDirectory(atPath: home.path))?
            .filter({ $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }).sorted().last {
            var db: OpaquePointer?
            if sqlite3_open_v2(home.appendingPathComponent(database).path, &db,
                               SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db {
                defer { sqlite3_close_v2(db) }
                sqlite3_busy_timeout(db, 500)
                var stmt: OpaquePointer?
                let sql = "SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), first_user_message) FROM threads"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                    defer { sqlite3_finalize(stmt) }
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let id = sqlite3_column_text(stmt, 0), let title = sqlite3_column_text(stmt, 1),
                              let clean = tidy(String(cString: title)) else { continue }
                        map[String(cString: id)] = clean
                    }
                }
            } else if db != nil {
                sqlite3_close_v2(db)
            }
        }
        if let data = try? Data(contentsOf: home.appendingPathComponent("session_index.jsonl")) {
            for line in data.split(separator: 10) {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let id = row["id"] as? String, let name = (row["thread_name"] as? String).flatMap(tidy) else { continue }
                map[id] = name
            }
        }
        return map
    }

    private static func tidy(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    static func parse(_ url: URL) -> Session? { parse(url, titles: titles()) }

    static func parse(_ url: URL, titles: [String: String]) -> Session? {
        guard let info = metadata(url),
              let id = info["id"] as? String, UUID(uuidString: id) != nil,
              let cwd = info["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
        let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let started = (info["timestamp"] as? String).flatMap(parseDate)
        return Session(id: id, cwd: cwd, title: titles[id] ?? "Codex · \(id.prefix(8))", summary: nil,
                       date: updated ?? started ?? .distantPast, fileURL: url, provider: .codex,
                       gitBranch: (info["git"] as? [String: Any])?["branch"] as? String)
    }

    /// rollout 尾部最近一条 `token_count`：上一回合占用的上下文与模型窗口。
    static func contextUsage(_ url: URL) -> (used: Int, total: Int)? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        guard let data = try? file.readToEnd() else { return nil }
        for line in data.split(separator: 10).reversed() where line.count < 64 * 1024 {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = row["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let used = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int,
                  let total = info["model_context_window"] as? Int else { continue }
            return (used, total)
        }
        return nil
    }

    static func scan() -> [String: [Session]] {
        // 子代理 / 分叉的 rollout（文件名形如 `<父ID>_<子ID>.jsonl`）沿用父会话的 session_meta.id，
        // 同一 ID 会扫出多份：只留最近更新的那份，否则侧栏会出现重复行。
        var latest: [String: Session] = [:]
        for session in list(in: home.appendingPathComponent("sessions"), titles: titles())
        where latest[session.id].map({ session.date > $0.date }) ?? true {
            latest[session.id] = session
        }
        var sessions: [String: [Session]] = [:]
        for session in latest.values {
            sessions[session.cwd, default: []].append(session)
        }
        return sessions
    }

    static func newConversation(in cwd: String, since: Date, ignoring ids: Set<String>) -> Session? {
        // rollout 按日期分目录。Codex 用哪个时区落目录不确定，首条消息也可能跨过零点：
        // 开始时刻与当前时刻、本地与 UTC 的日期目录都查一遍。
        let calendar = Calendar(identifier: .iso8601)
        var folders: [String] = []
        for moment in [since, Date()] {
            for zone in [TimeZone.current, TimeZone(secondsFromGMT: 0)!] {
                let fields = calendar.dateComponents(in: zone, from: moment)
                guard let year = fields.year, let month = fields.month, let day = fields.day else { continue }
                let folder = String(format: "sessions/%04d/%02d/%02d", year, month, day)
                if !folders.contains(folder) { folders.append(folder) }
            }
        }
        let names = titles()
        let candidates = folders.flatMap { list(in: home.appendingPathComponent($0), titles: names) }
        var unique: [String: Session] = [:]
        for session in candidates where unique[session.id].map({ session.date > $0.date }) ?? true {
            unique[session.id] = session
        }
        let matches = unique.values.filter { session in
            guard !ids.contains(session.id), resolvedPath(session.cwd) == resolvedPath(cwd),
                  let source = session.fileURL, let meta = metadata(source),
                  let timestamp = meta["timestamp"] as? String,
                  let started = parseDate(timestamp) else { return false }
            // 跳过子代理 rollout，避免子代理落盘导致主会话无法唯一匹配。
            if let origin = meta["source"] as? [String: Any], origin["subagent"] != nil { return false }
            return started >= since.addingTimeInterval(-3)
        }
        return matches.count == 1 ? matches.first : matches.sorted { $0.date > $1.date }.first
    }

    private static func list(in root: URL, titles: [String: String]) -> [Session] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { entry in
            guard let file = entry as? URL, file.pathExtension == "jsonl" else { return nil }
            return parse(file, titles: titles)
        }
    }
}
