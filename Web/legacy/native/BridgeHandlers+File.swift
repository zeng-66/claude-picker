import Foundation

/// 文件树与文件内容。方法名对齐 `Web/src/bridge/protocol.js` 的 METHODS。
///
/// T5 卡（task-6）接 `file.list` / `file.read` / `file.stat`；
/// T9 卡（task-10）接 `file.write`，未列出的方法继续落到 `.unknown`。
enum FileHandlers: BridgeModule {
    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        switch method {
        case "file.list":
            let input = try object(params, method: method)
            let projectPath = try requiredString(input, "projectPath", method: method)
            let path = try optionalString(input, "path", method: method) ?? ""
            let includeIgnored = bool(input, "includeIgnored") ?? false
            let nodes = try awaitSync {
                try await FileService().list(projectPath: projectPath,
                                             path: path,
                                             includeIgnored: includeIgnored)
            }
            return .handled(try jsonValue(nodes))

        case "file.read":
            let input = try object(params, method: method)
            let projectPath = try requiredString(input, "projectPath", method: method)
            let filePath = try requiredString(input, "filePath", method: method)
            let maxBytes = number(input, "maxBytes").map(Int.init)
            let file = try awaitSync {
                try await FileService().read(projectPath: projectPath,
                                             path: filePath,
                                             maxBytes: maxBytes ?? FileService.textPreviewLimit)
            }
            return .handled(try jsonValue(file))

        case "file.stat":
            let input = try object(params, method: method)
            let projectPath = try requiredString(input, "projectPath", method: method)
            let filePath = try requiredString(input, "filePath", method: method)
            let stat = try awaitSync {
                try await FileService().stat(projectPath: projectPath, path: filePath)
            }
            return .handled(try jsonValue(stat))

        default:
            return .unknown
        }
    }

    // MARK: - 参数

    private static func object(_ params: Any?, method: String) throws -> [String: Any] {
        guard let input = params as? [String: Any] else {
            throw GitError.commandFailed("\(method) 缺少参数对象", recoverable: false)
        }
        return input
    }

    private static func optionalString(_ input: [String: Any], _ key: String,
                                       method: String) throws -> String? {
        guard let raw = input[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else {
            throw GitError.commandFailed("\(method) 的 \(key) 必须是字符串", recoverable: false)
        }
        return value
    }

    private static func requiredString(_ input: [String: Any], _ key: String,
                                       method: String) throws -> String {
        guard let value = try optionalString(input, key, method: method), !value.isEmpty else {
            throw GitError.commandFailed("\(method) 缺少参数：\(key)", recoverable: false)
        }
        return value
    }

    private static func number(_ input: [String: Any], _ key: String) -> Double? {
        guard let raw = input[key], !(raw is NSNull) else { return nil }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? Double { return value }
        return nil
    }

    private static func bool(_ input: [String: Any], _ key: String) -> Bool? {
        (input[key] as? NSNumber)?.boolValue
    }

    // MARK: - 同步桥

    /// `BridgeModule.handle` 是同步 throws，`FileService` 是 async；这里把异步读
    /// 转成一次阻塞等待。读目录 / 读文件都是毫秒级，且不依赖主线程回调，不会死锁。
    private static func awaitSync<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = SyncBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
            done.signal()
        }
        done.wait()
        guard let outcome = box.load() else {
            throw GitError.commandFailed("文件操作超时", recoverable: true)
        }
        return try outcome.get()
    }

    private final class SyncBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<T, Error>?

        func store(_ value: Result<T, Error>) {
            lock.lock()
            outcome = value
            lock.unlock()
        }

        func load() -> Result<T, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }
    }

    // MARK: - JSON

    /// Codable → JSONSerialization 能处理的容器（桥回包只认这个）。
    private static func jsonValue<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [])
    }
}
