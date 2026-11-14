import Foundation

/// 桥方法的分发单元。每个能力域（Git / 文件 / 应用 / 会话）各实现一个，
/// 在自己的文件里处理自己的方法名，互不干扰 —— 这样多个任务卡可以并行推进，
/// 不必抢 `Bridge.swift` 这个单点。
protocol BridgeModule {
    /// 处理一条请求。不认识的 method 一律返回 `.unknown`，
    /// 由 `Bridge` 汇总后统一回 `NOT_IMPLEMENTED`。
    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome
}

/// 三态而不是「返回 nil 表示不支持」：`result` 本身可以是 null，
/// 和「这个模块不认识这个方法」必须能区分开。
enum BridgeOutcome {
    case handled(Any)
    case unknown
}

extension GitError {
    /// 桥信封里的 `error` 对象。字段与 `Web/src/bridge/protocol.js` 的错误体一致。
    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "code": code.rawValue,
            "message": message,
            "recoverable": recoverable,
        ]
        if let detail { object["detail"] = detail }
        return object
    }
}

// MARK: - 处理函数共用的小工具

/// 各 `BridgeHandlers+*.swift` 共用：参数读取、async → 同步等待、主线程跳转、Codable → JSON。
enum BridgeSupport {
    // MARK: 参数

    static func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty else {
            throw GitError.commandFailed("缺少参数：\(key)", recoverable: false)
        }
        return value
    }

    static func optionalString(_ params: [String: Any], _ key: String) -> String? {
        (params[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func boolean(_ params: [String: Any], _ key: String) -> Bool {
        if let value = params[key] as? Bool { return value }
        return (params[key] as? NSNumber)?.boolValue ?? false
    }

    static func integer(_ params: [String: Any], _ key: String) -> Int? {
        (params[key] as? NSNumber)?.intValue
    }

    /// 项目路径：前端可能传 `~/project/x` 这种简写，统一展开成绝对路径。
    static func projectPath(_ params: [String: Any]) throws -> String {
        (try string(params, "projectPath") as NSString).expandingTildeInPath
    }

    // MARK: 同步桥 → async 能力层

    /// 在调用线程上等一个 async 操作完成。`BridgeModule.handle` 是同步接口；操作在
    /// `Task.detached` 上跑，不依赖调用线程，因此不会自锁。只在后台线程的处理函数里用。
    static func blocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
        }
        return try box.wait()
    }

    /// 无返回值的写操作：等它跑完，回 `{ok: true}`。
    static func done(_ operation: @escaping @Sendable () async throws -> Void) throws -> BridgeOutcome {
        try blocking { try await operation() }
        return .handled(["ok": true])
    }

    /// 能力层的 Codable DTO → `JSONSerialization` 能编码的对象。
    static func encode<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: 主线程

    /// 在主线程上执行一段读写 `Store` 的代码：已经在主线程就直接跑，在后台线程就同步跳过去。
    static func onMain<T: Sendable>(_ body: @MainActor @Sendable () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(body)
        }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }

    /// 跨线程搬运一次结果：`Task.detached` 写入，调用线程 `wait()` 取走。
    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let condition = NSCondition()
        private var finished = false
        private var value: T?
        private var failure: Error?

        func store(_ result: Result<T, Error>) {
            condition.lock()
            switch result {
            case .success(let value): self.value = value
            case .failure(let error): self.failure = error
            }
            finished = true
            condition.broadcast()
            condition.unlock()
        }

        func wait() throws -> T {
            condition.lock()
            while !finished { condition.wait() }
            condition.unlock()
            if let failure { throw failure }
            guard let value else {
                throw GitError.commandFailed("桥处理没有返回结果", recoverable: false)
            }
            return value
        }
    }
}
