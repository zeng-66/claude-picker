import Foundation

/// The desktop launcher uses the dsh-TUI profile. Join its index to DSH's
/// local metadata cache so sessions from other profiles are not offered as TUI history.
enum DeepSeekSessionScanner {
    private struct Index: Decodable {
        struct Entry: Decodable {
            struct Details: Decodable {
                let modifiedAt: Double
                let title: String?
            }
            let derived: Details?
            let branch: String?
        }
        let entries: [String: Entry]
    }

    private struct CachedSession: Decodable {
        struct Record: Decodable {
            struct Identity: Decodable {
                let cwd: String
                let createdAt: Double
            }
            let identity: Identity
        }
        let record: Record
    }

    private static var dshHome: URL {
        let home = ProcessInfo.processInfo.environment["DSH_HOME"] ?? "\(NSHomeDirectory())/.dsh"
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    private static var cache: URL {
        dshHome.appendingPathComponent("storages/session_projcache/sessions")
    }

    /// 查找 DeepSeek v4 会话的完整事件流文件（`~/.dsh/sessions/<cwd>/<id>/session.v4.jsonl(.zstd)`）。
    static func transcriptURL(for id: String, cwd: String? = nil) -> URL? {
        HandoffBuilder.dshTranscriptURL(for: id, cwd: cwd)
    }

    private static var indexURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CLAUDE_PICKER_DSH_TUI_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("session-index.json")
        }
        if env["CLAUDE_PICKER_TEST_SHELL"] != nil {
            return AppDataDir.url.appendingPathComponent("dsh-tui/session-index.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh-tui/session-index.json")
    }

    private static func sessions() -> [(session: Session, created: Date)] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return [] }
        return index.entries.compactMap { id, entry in
            let uuid = id.hasPrefix("session-") ? String(id.dropFirst(8)) : id
            guard UUID(uuidString: uuid) != nil, let details = entry.derived else { return nil }
            let url = cache.appendingPathComponent(id).appendingPathExtension("json")
            guard let data = try? Data(contentsOf: url),
                  let record = (try? JSONDecoder().decode(CachedSession.self, from: data))?.record,
                  record.identity.cwd.hasPrefix("/") else { return nil }
            let title = details.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let session = Session(id: id, cwd: record.identity.cwd,
                                  title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "DeepSeek · \(uuid.prefix(8))",
                                  summary: nil, date: Date(timeIntervalSince1970: details.modifiedAt / 1000),
                                  fileURL: url, provider: .dsh, gitBranch: entry.branch)
            return (session, Date(timeIntervalSince1970: record.identity.createdAt / 1000))
        }
    }

    static func scan() -> [String: [Session]] {
        Dictionary(grouping: sessions().map(\.session), by: \.cwd)
    }

    static func find(id: String) -> Session? {
        sessions().first { $0.session.id == id }?.session
    }

    static func newConversation(in cwd: String, since: Date, ignoring ids: Set<String>) -> Session? {
        let matches = sessions().filter {
            $0.created >= since.addingTimeInterval(-3) && !ids.contains($0.session.id) && resolvedPath($0.session.cwd) == resolvedPath(cwd)
        }
        return matches.count == 1 ? matches.first?.session : nil
    }
}
