import Foundation
import SQLite3

enum CodexSessionScanner {
    private static let dateParser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static var home: URL {
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func metadata(_ url: URL) -> [String: Any]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 32 * 1024),
              let end = bytes.firstIndex(of: 10),
              let row = try? JSONSerialization.jsonObject(with: bytes.prefix(upTo: end)) as? [String: Any],
              row["type"] as? String == "session_meta" else { return nil }
        return row["payload"] as? [String: Any]
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
        let started = (info["timestamp"] as? String).flatMap { try? dateParser.parse($0) }
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
        let utc = Calendar(identifier: .iso8601)
        let fields = utc.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: since)
        guard let year = fields.year, let month = fields.month, let day = fields.day else { return nil }
        let root = home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", year, month, day))
        let matches = list(in: root, titles: titles()).filter { session in
            guard !ids.contains(session.id), resolvedPath(session.cwd) == resolvedPath(cwd),
                  let source = session.fileURL, let timestamp = metadata(source)?["timestamp"] as? String,
                  let started = try? dateParser.parse(timestamp) else { return false }
            return started >= since
        }
        return matches.count == 1 ? matches.first : nil
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
