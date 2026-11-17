import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Work 领域层的公共小件：可跨线程传递的 JSON 值、时间、同步子进程、登录 shell 环境。
// 领域层全部跑在自己的串行队列上（见 WorkCore），不依赖 MainActor。

// MARK: - JSON

/// `[String: Any]` 不是 Sendable，领域层跨队列只传这个值类型。
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(any value: Any?) {
        guard let value else { self = .null; return }
        switch value {
        case let v as JSONValue: self = v
        case is NSNull: self = .null
        case let v as String: self = .string(v)
        case let v as NSNumber:
            // JSONSerialization 把 true/false 也装成 NSNumber，必须先认出布尔。
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue) }
            else { self = .number(v.doubleValue) }
        case let v as [Any]: self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, item) in v { out[k] = JSONValue(any: item) }
            self = .object(out)
        default: self = .string(String(describing: value))
        }
    }

    /// 还原成 `JSONSerialization` 能编码的对象。整数值的数字还原成 Int64，避免出现 `1.0`。
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v):
            if v.rounded() == v, abs(v) < 9_007_199_254_740_992 { return Int64(v) }
            return v
        case .string(let v): return v
        case .array(let v): return v.map(\.any)
        case .object(let v): return v.mapValues(\.any)
        }
    }

    static func parse(_ data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: object)
    }

    static func parse(_ text: String?) -> JSONValue? {
        guard let text, !text.isEmpty else { return nil }
        return parse(Data(text.utf8))
    }

    func serialized(pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: options) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
    var intValue: Int? { doubleValue.map { Int($0) } }
    var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var isNull: Bool { self == .null }

    /// 非空字符串，否则 nil。
    var text: String? { stringValue.flatMap { $0.isEmpty ? nil : $0 } }

    static func obj(_ pairs: [String: JSONValue?]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for (k, v) in pairs { if let v { out[k] = v } }
        return .object(out)
    }

    static func str(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
    static func int(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }

    /// 超长文本截断，并在末尾注明省略了多少（工具输入输出可能有几 MB）。
    func truncated(limit: Int) -> JSONValue {
        switch self {
        case .string(let v):
            return .string(WorkText.clip(v, limit: limit))
        case .array(let items):
            return .array(items.prefix(200).map { $0.truncated(limit: limit) })
        case .object(let dict):
            return .object(dict.mapValues { $0.truncated(limit: limit) })
        default:
            return self
        }
    }
}

enum WorkText {
    static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…（已截断，原文共 \(text.count) 个字符）"
    }

    /// 日志与导出用：抹掉常见的凭据形态。宁可多抹，不漏。
    static func redact(_ text: String) -> String {
        var out = text
        let patterns = [
            #"(?i)(authorization\s*[:=]\s*)(bearer\s+)?[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)((?:api[_-]?key|access[_-]?token|token|secret|password|passwd|pwd)["']?\s*[:=]\s*["']?)[^\s"',;]{4,}"#,
            #"sk-[A-Za-z0-9_-]{16,}"#,
            #"(?i)(https?://[^\s/:@]+:)[^\s/@]+@"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            let template: String
            switch index {
            case 0: template = "$1***"
            case 1: template = "$1***"
            case 3: template = "$1***@"
            default: template = "***"
            }
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }

    static func sha256(_ text: String) -> String {
        Hashing.sha256(Data(text.utf8))
    }
}

import CryptoKit

enum Hashing {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 时间

enum WorkClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso(_ date: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: iso)
    }
}

// MARK: - 同步子进程

struct ProcResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let launchError: String?

    var ok: Bool { launchError == nil && !timedOut && exitCode == 0 }

    /// 失败时给人看的一行原因。
    var failureText: String {
        if let launchError { return "无法启动：\(launchError)" }
        if timedOut { return "命令超时" }
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "退出码 \(exitCode)" : out
    }
}

/// 领域层的同步子进程：参数数组直接交给 `Process`，不经过 shell，分支名 / 路径里的特殊字符都是字面量。
/// 输出落临时文件而不是管道，避免 64KB 管道写满卡死子进程。只能在后台线程调用。
enum Proc {
    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil,
                    env: [String: String]? = nil, timeout: TimeInterval = 30,
                    stdin: Data? = nil) -> ProcResult {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("claude-picker-proc-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return ProcResult(exitCode: -1, stdout: "", stderr: "", timedOut: false, launchError: error.localizedDescription)
        }
        defer { try? fm.removeItem(at: dir) }
        let outURL = dir.appendingPathComponent("out"), errURL = dir.appendingPathComponent("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return ProcResult(exitCode: -1, stdout: "", stderr: "", timedOut: false, launchError: "无法创建临时输出文件")
        }
        defer { try? outHandle.close(); try? errHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = env ?? LoginEnv.shared.environment
        process.standardOutput = outHandle
        process.standardError = errHandle
        var inputPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            return ProcResult(exitCode: -1, stdout: "", stderr: "", timedOut: false, launchError: error.localizedDescription)
        }
        if let stdin, let inputPipe {
            try? inputPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inputPipe.fileHandleForWriting.close()
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
        }
        let out = (try? Data(contentsOf: outURL)) ?? Data()
        let err = (try? Data(contentsOf: errURL)) ?? Data()
        return ProcResult(exitCode: timedOut ? -1 : process.terminationStatus,
                          stdout: String(decoding: out, as: UTF8.self),
                          stderr: String(decoding: err, as: UTF8.self),
                          timedOut: timedOut, launchError: nil)
    }
}

// MARK: - 登录 shell 环境

/// 从 Finder 启动的应用继承不到终端里的 PATH 和环境变量（claude、git、tapd-cli 的位置，TAPD 的令牌）。
/// 这里取一次登录 shell 的完整环境，只留在内存里，不写日志、不落盘。
final class LoginEnv: @unchecked Sendable {
    static let shared = LoginEnv()

    let environment: [String: String]

    private init() {
        var env = ProcessInfo.processInfo.environment
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "env -0"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let reader = DispatchQueue(label: "claude-picker.login-env")
        if (try? process.run()) != nil {
            reader.async { box.data = out.fileHandleForReading.readDataToEndOfFile() }
            if done.wait(timeout: .now() + 8) == .timedOut {
                process.terminate()
            } else {
                reader.sync {}
                for entry in box.data.split(separator: 0) {
                    guard let line = String(data: Data(entry), encoding: .utf8),
                          let eq = line.firstIndex(of: "=") else { continue }
                    let key = String(line[..<eq])
                    guard !key.isEmpty else { continue }
                    env[key] = String(line[line.index(after: eq)...])
                }
            }
        }
        if (env["PATH"] ?? "").isEmpty {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        // 测试可以把命令位置指到替身上，不依赖本机登录环境。
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("CLAUDE_PICKER_") {
            env[key] = value
        }
        environment = env
    }

    /// 在登录 shell 的 PATH 里找可执行文件；`extra` 是额外尝试的绝对路径。
    func find(_ name: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            candidates.append("\(dir)/\(name)")
        }
        candidates += extra
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    var git: String { find("git", extra: ["/usr/bin/git"]) ?? "/usr/bin/git" }
}

// MARK: - 领域错误

/// 领域层的命令结果不是「成功 / 异常」两态：拒绝、版本冲突都要让调用方分得清。
struct WorkError: Error, Sendable, Equatable {
    enum Code: String, Sendable {
        case rejected = "REJECTED"          // 条件不满足，命令没有生效
        case conflict = "CONFLICT"          // revision / 代码版本已变化
        case notFound = "NOT_FOUND"
        case invalid = "INVALID"            // 参数不合法
        case unavailable = "UNAVAILABLE"    // 依赖（CLI、连接、目录）不可用
        case notOwner = "NOT_OWNER"         // 另一个实例持有状态目录
        case failed = "COMMAND_FAILED"
    }

    let code: Code
    let message: String
    var detail: String? = nil

    static func rejected(_ message: String, detail: String? = nil) -> WorkError { WorkError(code: .rejected, message: message, detail: detail) }
    static func conflict(_ message: String, detail: String? = nil) -> WorkError { WorkError(code: .conflict, message: message, detail: detail) }
    static func notFound(_ message: String) -> WorkError { WorkError(code: .notFound, message: message) }
    static func invalid(_ message: String) -> WorkError { WorkError(code: .invalid, message: message) }
    static func unavailable(_ message: String, detail: String? = nil) -> WorkError { WorkError(code: .unavailable, message: message, detail: detail) }
    static func failed(_ message: String, detail: String? = nil) -> WorkError { WorkError(code: .failed, message: message, detail: detail) }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "code": code.rawValue,
            "message": message,
            "recoverable": code != .failed,
        ]
        if let detail { object["detail"] = detail }
        return object
    }
}
