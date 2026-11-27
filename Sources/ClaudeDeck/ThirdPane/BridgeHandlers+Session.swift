import Foundation

/// 会话操作：打开已有会话、新建会话（当前分支 / 独立工作树）。
enum SessionHandlers: BridgeModule {
    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        let dict = params as? [String: Any] ?? [:]
        switch method {
        // 点一条会话：把终端切到该会话（没在跑就 `claude --resume` 起来）。主线程执行。
        case "session.open":
            let projectPath = BridgeSupport.optionalString(dict, "projectPath") ?? ""
            let cwd = BridgeSupport.optionalString(dict, "cwd") ?? ""
            let sessionId = BridgeSupport.optionalString(dict, "sessionId")
            if sessionId?.hasPrefix("-") == true {
                throw GitError.commandFailed("无效的会话 ID", recoverable: false)
            }
            let requestedProvider = BridgeSupport.optionalString(dict, "provider").map(AgentProvider.parse)
            try BridgeSupport.onMain {
                let store = try AppHandlers.delegate().store
                // 会话自带的 cwd 最准（worktree 会话的 cwd 不是项目根）；其次是传入的 cwd，再次是项目根。
                var target = cwd.isEmpty ? projectPath : cwd
                var title: String?
                var hitProvider: AgentProvider? = requestedProvider
                var effectiveSessionId = sessionId
                if let sessionId {
                    var matched = false
                    for project in store.projects {
                        if let hit = project.sessions.first(where: { $0.id == sessionId && (requestedProvider == nil || $0.provider == requestedProvider) }) {
                            title = hit.title
                            target = hit.cwd
                            hitProvider = hit.provider
                            matched = true
                            break
                        }
                    }
                    if !matched, let resolved = store.resolveSegment(id: sessionId) {
                        title = resolved.head.title
                        target = resolved.head.cwd
                        hitProvider = AgentProvider.parse(resolved.segment.provider)
                    }
                }
                guard !target.isEmpty else {
                    throw GitError.commandFailed("session.open 需要 cwd 或 projectPath", recoverable: false)
                }
                let provider = hitProvider ?? store.settings.defaultProvider
                try validateLaunch(provider, store: store)
                let label = title
                    ?? store.projectIndex(owning: target).map { store.projects[$0].title }
                    ?? (target as NSString).lastPathComponent
                if let currentId = effectiveSessionId, currentId.hasPrefix("pending-") {
                    let bound = store.tryBindPendingSession(sessionId: currentId, cwd: target, provider: provider)
                    effectiveSessionId = bound
                    if bound.hasPrefix("pending-"),
                       !store.hasLiveSession(cwd: target, id: bound, provider: provider),
                       !store.hasPane(cwd: target, id: bound, provider: provider) {
                        throw GitError.commandFailed("会话尚未取得原始 ID，无法恢复", recoverable: true)
                    }
                }
                store.open(cwd: target, sid: effectiveSessionId, label: label, provider: provider)
            }
            return .handled(NSNull())

        // 新建会话。`title` 可选；`mode == "worktree"` 时先在 `<项目>/.worktrees/<分支>` 建好工作树（后台线程，
        // 检出大仓库可能要几秒），成功后才起会话 —— 工作树没建成就不会留下一条空会话。
        case "session.create":
            let projectPath = try BridgeSupport.projectPath(dict)
            // 名称可留空：留空时不传 `--name`，标题等首轮对话后由 CLI 的摘要回填。
            let title = (BridgeSupport.optionalString(dict, "title") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let mode = BridgeSupport.optionalString(dict, "mode") ?? "current"
            let requested = BridgeSupport.optionalString(dict, "provider").map(AgentProvider.parse)
            let provider = try BridgeSupport.onMain {
                let store = try AppHandlers.delegate().store
                let provider = requested ?? store.settings.defaultProvider
                try validateLaunch(provider, store: store)
                return provider
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw GitError.commandFailed("项目目录不存在：\(projectPath)", recoverable: false)
            }
            var cwd = projectPath
            var branch: String?
            let workspace = dict["workspace"] as? [String: Any] ?? [:]
            if mode == "current", let tree = BridgeSupport.optionalString(workspace, "worktreePath") {
                let registered = try BridgeSupport.blocking { try await GitService().worktrees(projectPath: projectPath) }
                guard let match = registered.first(where: { !$0.isPrunable && !$0.isBare && resolvedPath($0.path) == resolvedPath(tree) }) else {
                    throw GitError.commandFailed("工作树不存在或已不可用：\(tree)", recoverable: true)
                }
                if let expected = BridgeSupport.optionalString(workspace, "branch"), expected != match.branch {
                    throw GitError.commandFailed("工作树的检出分支已变化，请重新选择", recoverable: true)
                }
                cwd = resolvedPath(match.path)
                branch = match.branch
            } else if mode == "current", let target = BridgeSupport.optionalString(workspace, "branch") {
                try BridgeSupport.blocking {
                    try await GitService().switchWorkspaceBranch(projectPath: projectPath, branch: target)
                }
                branch = target
            } else if mode == "worktree" {
                let target = try BridgeSupport.string(dict, "branch")
                let base = BridgeSupport.optionalString(dict, "baseBranch")
                let result = try BridgeSupport.blocking {
                    try await GitService().createWorktree(
                        CreateWorktreeInput(projectPath: projectPath, branch: target, baseBranch: base))
                }
                cwd = result.path
                branch = result.branch
            }
            let workingDirectory = cwd
            let surface = BridgeSupport.optionalString(dict, "openMode").flatMap(InteractionMode.init(rawValue:))
            let sessionId = try BridgeSupport.onMain {
                try AppHandlers.delegate().store
                    .open(cwd: workingDirectory, sid: nil, label: title.isEmpty ? "新建会话" : title,
                          name: title.isEmpty ? nil : title, provider: provider, boundBranch: branch,
                          surfaceOverride: surface)
            }
            var result: [String: Any] = [
                "sessionId": sessionId,
                "cwd": cwd,
                "mode": mode,
                "provider": provider.rawValue,
            ]
            if let branch { result["branch"] = branch }
            return .handled(result)

        // 跨引擎接力续聊：从原会话提取四层 `<thread-handoff>` 上下文，在同目录以目标引擎启动新会话。
        case "session.handoff":
            let sessionId = try BridgeSupport.string(dict, "sessionId")
            let targetProvider = AgentProvider.parse(try BridgeSupport.string(dict, "targetProvider"))
            let sourceProvider = BridgeSupport.optionalString(dict, "sourceProvider").map(AgentProvider.parse)
            let projectPath = BridgeSupport.optionalString(dict, "projectPath") ?? ""
            let cwd = BridgeSupport.optionalString(dict, "cwd") ?? ""
            let outcome = try BridgeSupport.onMain {
                try AppHandlers.delegate().store.handoff(
                    sessionId: sessionId,
                    sourceProvider: sourceProvider,
                    targetProvider: targetProvider,
                    projectPath: projectPath,
                    cwd: cwd
                )
            }
            return .handled(outcome)

        // 换打开方式：终端 / Swttch / 结构化聊天。先结束当前回合并释放会话，失败时保留原界面。
        case "session.setOpenMode":
            let sessionId = try BridgeSupport.string(dict, "sessionId")
            guard let mode = InteractionMode(rawValue: try BridgeSupport.string(dict, "mode")) else {
                throw GitError.commandFailed("未知的打开方式", recoverable: false)
            }
            try BridgeSupport.blocking {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            do {
                                let store = try AppHandlers.delegate().store
                                if let provider = store.session(id: sessionId)?.provider {
                                    try validateLaunch(provider, store: store)
                                }
                                store.switchOpenMode(sessionId: sessionId, to: mode) { result in
                                    continuation.resume(with: result.mapError { $0 as Error })
                                }
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
            return .handled(["sessionId": sessionId, "mode": mode.rawValue])

        case "sessionChat.snapshot":
            let sessionId = try BridgeSupport.string(dict, "sessionId")
            let data = try BridgeSupport.onMain {
                try JSONSerialization.data(withJSONObject: SessionChatHub.shared.snapshot(sessionId: sessionId))
            }
            return .handled(try JSONSerialization.jsonObject(with: data))

        case "sessionChat.send":
            let sessionId = try BridgeSupport.string(dict, "sessionId")
            let text = try BridgeSupport.string(dict, "text")
            try BridgeSupport.onMain {
                let store = try AppHandlers.delegate().store
                if !SessionChatHub.shared.isLive(sessionId) {
                    guard let session = store.session(id: sessionId) else {
                        throw GitError.commandFailed("找不到这条会话", recoverable: false)
                    }
                    try validateLaunch(session.provider, store: store)
                    try store.startStructured(cwd: session.cwd, sid: sessionId, provider: session.provider, isNew: false)
                }
                try SessionChatHub.shared.send(sessionId: sessionId, text: text)
            }
            return .handled(NSNull())

        case "sessionChat.respond":
            let sessionId = try BridgeSupport.string(dict, "sessionId")
            let requestId = try BridgeSupport.string(dict, "requestId")
            let allow = dict["allow"] as? Bool ?? false
            try BridgeSupport.onMain { try SessionChatHub.shared.respond(sessionId: sessionId, requestId: requestId, allow: allow) }
            return .handled(NSNull())

        case "sessionChat.runtime":
            let sessionId = try BridgeSupport.string(dict, "sessionId")
            let key = try BridgeSupport.string(dict, "key")
            let value = try BridgeSupport.string(dict, "value")
            try BridgeSupport.onMain {
                try AppHandlers.delegate().store.setStructuredRuntime(sessionId: sessionId, key: key, value: value)
            }
            return .handled(NSNull())

        case "sessionChat.interrupt":
            let sessionId = try BridgeSupport.string(dict, "sessionId")
            try BridgeSupport.onMain { SessionChatHub.shared.interrupt(sessionId: sessionId) }
            return .handled(NSNull())

        default:
            return .unknown
        }
    }

    @MainActor
    private static func validateLaunch(_ provider: AgentProvider, store: Store) throws {
        if store.settings.disabledProviders.contains(provider) {
            throw GitError.commandFailed("\(provider.label) 已停用，请在 CLI 引擎设置中启用", recoverable: true)
        }
        if ProcessInfo.processInfo.environment["CLAUDE_PICKER_TEST_SHELL"] == nil,
           let error = CliBinaryLocator.launchError(provider) {
            throw GitError.commandFailed("\(provider.label)：\(error)", recoverable: true)
        }
    }

}
