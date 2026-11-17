import Foundation
import SQLite3

/// 系统自带 SQLite 的薄封装。只做三件事：绑定参数、读行、事务。
/// 连接只在 WorkCore 的串行队列上使用（另开了 FULLMUTEX 兜底）。
struct DBError: Error, CustomStringConvertible, Sendable {
    let code: Int32
    let message: String
    var description: String { "SQLite(\(code)): \(message)" }
    /// 唯一键冲突：领域层据此判定「重复事件 / 重复命令」，不是故障。
    var isConstraint: Bool { code == SQLITE_CONSTRAINT }
}

enum DBValue: Sendable, Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    static func of(_ value: String?) -> DBValue { value.map { .text($0) } ?? .null }
    static func of(_ value: Int?) -> DBValue { value.map { .int(Int64($0)) } ?? .null }
    static func of(_ value: Bool) -> DBValue { .int(value ? 1 : 0) }
}

struct DBRow: Sendable {
    let values: [String: DBValue]

    func string(_ key: String) -> String? {
        switch values[key] {
        case .text(let v)?: return v
        case .int(let v)?: return String(v)
        case .real(let v)?: return String(v)
        default: return nil
        }
    }

    func text(_ key: String) -> String { string(key) ?? "" }

    func int(_ key: String) -> Int? {
        switch values[key] {
        case .int(let v)?: return Int(v)
        case .real(let v)?: return Int(v)
        case .text(let v)?: return Int(v)
        default: return nil
        }
    }

    func bool(_ key: String) -> Bool { (int(key) ?? 0) != 0 }
    func json(_ key: String) -> JSONValue? { JSONValue.parse(string(key)) }
}

final class SQLiteDB: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var depth = 0
    let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let db { sqlite3_close(db) }
            throw DBError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private func failure(_ rc: Int32) -> DBError {
        DBError(code: rc & 0xff, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库已关闭")
    }

    func exec(_ sql: String) throws {
        guard let handle else { throw DBError(code: SQLITE_MISUSE, message: "数据库已关闭") }
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "执行失败"
            sqlite3_free(error)
            throw DBError(code: rc & 0xff, message: message)
        }
    }

    private func prepare(_ sql: String, _ params: [DBValue]) throws -> OpaquePointer {
        guard let handle else { throw DBError(code: SQLITE_MISUSE, message: "数据库已关闭") }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw failure(rc) }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32
            switch value {
            case .null: bound = sqlite3_bind_null(statement, index)
            case .int(let v): bound = sqlite3_bind_int64(statement, index, v)
            case .real(let v): bound = sqlite3_bind_double(statement, index, v)
            case .text(let v): bound = sqlite3_bind_text(statement, index, v, -1, Self.transient)
            }
            if bound != SQLITE_OK {
                sqlite3_finalize(statement)
                throw failure(bound)
            }
        }
        return statement
    }

    /// 执行一条写语句，返回受影响行数。
    @discardableResult
    func run(_ sql: String, _ params: [DBValue] = []) throws -> Int {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var rc = sqlite3_step(statement)
        while rc == SQLITE_ROW { rc = sqlite3_step(statement) }
        guard rc == SQLITE_DONE else { throw failure(rc) }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ params: [DBValue] = []) throws -> [DBRow] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var rows: [DBRow] = []
        let count = sqlite3_column_count(statement)
        var names: [String] = []
        for i in 0..<count { names.append(String(cString: sqlite3_column_name(statement, i))) }
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw failure(rc) }
            var values: [String: DBValue] = [:]
            for i in 0..<count {
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: values[names[Int(i)]] = .int(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT: values[names[Int(i)]] = .real(sqlite3_column_double(statement, i))
                case SQLITE_TEXT:
                    values[names[Int(i)]] = sqlite3_column_text(statement, i).map { .text(String(cString: $0)) } ?? .null
                default: values[names[Int(i)]] = .null
                }
            }
            rows.append(DBRow(values: values))
        }
        return rows
    }

    func first(_ sql: String, _ params: [DBValue] = []) throws -> DBRow? {
        try query(sql, params).first
    }

    var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    /// 事务。可嵌套：内层用 SAVEPOINT，任何一层抛错只回滚到该层的起点并继续向外抛。
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let name = "sp\(depth)"
        if depth == 0 { try exec("BEGIN IMMEDIATE") } else { try exec("SAVEPOINT \(name)") }
        depth += 1
        do {
            let value = try body()
            depth -= 1
            if depth == 0 { try exec("COMMIT") } else { try exec("RELEASE \(name)") }
            return value
        } catch {
            depth -= 1
            if depth == 0 { try? exec("ROLLBACK") } else { try? exec("ROLLBACK TO \(name); RELEASE \(name)") }
            throw error
        }
    }

    var userVersion: Int {
        get { (try? first("PRAGMA user_version"))?.int("user_version") ?? 0 }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }
}
