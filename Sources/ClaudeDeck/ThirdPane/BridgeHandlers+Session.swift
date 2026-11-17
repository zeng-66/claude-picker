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
            try BridgeSupport.onMain {
                let store = try AppHandlers.delegate().store
                // 会话自带的 cwd 最准（worktree 会话的 cwd 不是项目根）；其次是传入的 cwd，再次是项目根。
                var target = cwd.isEmpty ? projectPath : cwd
                var title: String?
                if let sessionId {
                    for project in store.projects {
                        if let hit = project.sessions.first(where: { $0.id == sessionId }) {
                            title = hit.title
                            target = hit.cwd
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
                store.open(cwd: target, sid: sessionId, label: label)
            }
            return .handled(NSNull())

        // 新建会话。`title` 可选；`mode == "worktree"` 时先在 `<项目>/.worktrees/<分支>` 建好工作树（后台线程，
        // 检出大仓库可能要几秒），成功后才起会话 —— 工作树没建成就不会留下一条空会话。
        case "session.create":
            let projectPath = try BridgeSupport.projectPath(dict)
            // 名称可留空：留空时不传 `--name`，标题等首轮对话后由 Claude 的 ai-title / summary 回填。
            let title = (BridgeSupport.optionalString(dict, "title") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let mode = BridgeSupport.optionalString(dict, "mode") ?? "current"
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
                          name: title.isEmpty ? nil : title)
            }
            var result: [String: Any] = ["sessionId": sessionId, "cwd": cwd, "mode": mode]
            if let branch { result["branch"] = branch }
            return .handled(result)

        default:
            return .unknown
        }
    }
}
