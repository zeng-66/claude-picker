import Foundation

/// Git 只读与写操作。方法名对齐 `Web/src/bridge/protocol.js` 的 METHODS。
///
/// 已接只读：`git.status` / `git.diff` / `git.log` / `git.show` /
/// `git.branches` / `git.tags` / `git.remotes` / `git.worktrees`；
/// 分支写操作：`git.switchBranch` / `createBranch` / `deleteBranch` / `merge` /
/// `fetch` / `pull` / `push`。其余写操作（stage / commit / stash …）仍返回 `.unknown`，
/// 由 `Bridge` 统一回 `NOT_IMPLEMENTED`，不假装成功。
///
/// `BridgeModule.handle` 是同步接口，这里用 `blocking(_:)` 等 async 结果；
/// `Bridge.reply` 把 `git.*` 整体放到后台线程执行，所以等待不会占住主线程。
enum GitHandlers: BridgeModule {
    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        let params = params as? [String: Any] ?? [:]
        let service = GitService()

        switch method {
        case "git.status":
            let path = try projectPath(params)
            return .handled(try encode(blocking { try await service.status(projectPath: path) }))

        case "git.diff":
            let path = try projectPath(params)
            let file = try string(params, "filePath")
            let staged = boolean(params, "staged")
            return .handled(try encode(blocking {
                try await service.diff(projectPath: path, path: file, staged: staged)
            }))

        case "git.log":
            let path = try projectPath(params)
            let limit = integer(params, "limit", fallback: 50, range: 1...500)
            let skip = integer(params, "skip", fallback: 0, range: 0...Int.max)
            let branch = (params["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .handled(try encode(blocking {
                try await service.log(projectPath: path, limit: limit, skip: skip, branch: branch)
            }))

        case "git.show":
            let path = try projectPath(params)
            let hash = try string(params, "hash")
            return .handled(try encode(blocking {
                try await service.show(projectPath: path, hash: hash)
            }))

        case "git.branches":
            let path = try projectPath(params)
            return .handled(try encode(blocking { try await service.branches(projectPath: path) }))

        case "git.tags":
            let path = try projectPath(params)
            return .handled(try encode(blocking { try await service.tags(projectPath: path) }))

        case "git.remotes":
            let path = try projectPath(params)
            return .handled(try encode(blocking { try await service.remotes(projectPath: path) }))

        case "git.worktrees":
            let path = try projectPath(params)
            return .handled(try encode(blocking { try await service.worktrees(projectPath: path) }))

        // —— 分支写操作（右键分支菜单）。成功统一回 `{ok:true}`，前端随后自行刷新状态。
        case "git.switchBranch":
            let path = try projectPath(params)
            let branch = try string(params, "branch")
            return try done { try await service.switchBranch(projectPath: path, branch: branch) }

        case "git.createBranch":
            let path = try projectPath(params)
            // 参数名对齐 protocol.js：{ name, from? }
            let branch = try string(params, "name")
            let start = optionalString(params, "from")
            return try done { try await service.createBranch(projectPath: path, branch: branch, startPoint: start) }

        case "git.deleteBranch":
            let path = try projectPath(params)
            let branch = try string(params, "branch")
            return try done { try await service.deleteBranch(projectPath: path, branch: branch) }

        case "git.merge":
            let path = try projectPath(params)
            let branch = try string(params, "branch")
            return try done { try await service.merge(projectPath: path, branch: branch) }

        case "git.fetch":
            let path = try projectPath(params)
            let remote = optionalString(params, "remote")
            return try done { try await service.fetch(projectPath: path, remote: remote) }

        case "git.pull":
            let path = try projectPath(params)
            let remote = optionalString(params, "remote")
            let branch = optionalString(params, "branch")
            return try done { try await service.pull(projectPath: path, remote: remote, branch: branch) }

        case "git.push":
            let path = try projectPath(params)
            let remote = optionalString(params, "remote")
            let branch = optionalString(params, "branch")
            let setUpstream = boolean(params, "setUpstream")
            return try done {
                try await service.push(projectPath: path, remote: remote, branch: branch, setUpstream: setUpstream)
            }

        default:
            return .unknown
        }
    }

    // MARK: - 参数

    private static func projectPath(_ params: [String: Any]) throws -> String {
        let raw = try string(params, "projectPath")
        // 前端只有 `~/project/<id>` 这种展示路径（mock/projects.js），在这里展开成绝对路径。
        return (raw as NSString).expandingTildeInPath
    }

    private static func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty else {
            // GitErrorCode 只有 SPEC 的 8 个码（没有 INVALID_PARAMS），这里复用 COMMAND_FAILED。
            throw GitError.commandFailed("缺少参数：\(key)", recoverable: false)
        }
        return value
    }

    private static func integer(_ params: [String: Any],
                                _ key: String,
                                fallback: Int,
                                range: ClosedRange<Int>) -> Int {
        let raw = (params[key] as? NSNumber)?.intValue ?? (params[key] as? Int) ?? fallback
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    private static func optionalString(_ params: [String: Any], _ key: String) -> String? {
        (params[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 无返回值的写操作：等它跑完，回 `{ok: true}`。
    private static func done(_ operation: @escaping @Sendable () async throws -> Void) throws -> BridgeOutcome {
        try blocking { try await operation() }
        return .handled(["ok": true])
    }

    private static func boolean(_ params: [String: Any], _ key: String) -> Bool {
        if let value = params[key] as? Bool { return value }
        return (params[key] as? NSNumber)?.boolValue ?? false
    }

    // MARK: - 同步桥 → async 能力层

    /// 在调用线程上等待一个 async 操作完成。`BridgeModule.handle` 是同步接口，
    /// 不改桥本身就只能这样把结果带回去；操作在 `Task.detached` 上跑，
    /// 不依赖主线程（`ProcessRunner` 用 `DispatchQueue.global` 等子进程），因此不会自锁。
    private static func blocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
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

    /// 能力层的 Codable DTO → `JSONSerialization` 能编码的对象，交给 `Bridge.reply`。
    private static func encode<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
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
