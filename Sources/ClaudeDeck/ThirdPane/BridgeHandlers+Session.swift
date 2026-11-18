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
            let requestedProvider = BridgeSupport.optionalString(dict, "provider").map(AgentProvider.parse)
            try BridgeSupport.onMain {
                let store = try AppHandlers.delegate().store
                // 会话自带的 cwd 最准（worktree 会话的 cwd 不是项目根）；其次是传入的 cwd，再次是项目根。
                var target = cwd.isEmpty ? projectPath : cwd
                var title: String?
                var hitProvider: AgentProvider? = requestedProvider
                if let sessionId {
                    for project in store.projects {
                        if let hit = project.sessions.first(where: { $0.id == sessionId && (requestedProvider == nil || $0.provider == requestedProvider) }) {
                            title = hit.title
                            target = hit.cwd
                            hitProvider = hit.provider
                            break
                        }
                    }
                }
                guard !target.isEmpty else {
                    throw GitError.commandFailed("session.open 需要 cwd 或 projectPath", recoverable: false)
                }
                let label = title
                    ?? store.projectIndex(owning: target).map { store.projects[$0].title }
                    ?? (target as NSString).lastPathComponent
                store.open(cwd: target, sid: sessionId, label: label, provider: hitProvider)
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
            let provider = BridgeSupport.optionalString(dict, "provider").map(AgentProvider.parse)
            if let provider, CliBinaryLocator.find(provider) == nil,
               ProcessInfo.processInfo.environment["CLAUDE_PICKER_TEST_SHELL"] == nil {
                throw GitError.commandFailed("本机未检测到 \(provider.label)（\(provider.commandName)），请先安装后再创建会话", recoverable: false)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw GitError.commandFailed("项目目录不存在：\(projectPath)", recoverable: false)
            }
            var cwd = projectPath
            var branch: String?
            if mode == "worktree" {
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
            let sessionId = try BridgeSupport.onMain {
                try AppHandlers.delegate().store
                    .open(cwd: workingDirectory, sid: nil, label: title.isEmpty ? "新建会话" : title,
                          name: title.isEmpty ? nil : title, provider: provider)
            }
            var result: [String: Any] = [
                "sessionId": sessionId,
                "cwd": cwd,
                "mode": mode,
                "provider": (provider ?? .claude).rawValue,
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

        default:
            return .unknown
        }
    }
}
