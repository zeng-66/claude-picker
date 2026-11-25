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

    private static var cache: URL {
        let home = ProcessInfo.processInfo.environment["DSH_HOME"] ?? "\(NSHomeDirectory())/.dsh"
        return URL(fileURLWithPath: home).appendingPathComponent("storages/session_projcache/sessions")
    }

    private static func sessions() -> [(session: Session, created: Date)] {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh-tui/session-index.json")
        guard let data = try? Data(contentsOf: url),
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
                                  provider: .dsh, gitBranch: entry.branch)
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
            $0.created >= since && !ids.contains($0.session.id) && resolvedPath($0.session.cwd) == resolvedPath(cwd)
        }
        return matches.count == 1 ? matches.first?.session : nil
    }
}
