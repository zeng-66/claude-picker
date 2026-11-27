import Foundation

/// 本机统一工作树命令（如 `~/.local/bin/ai-worktree`）。设置里配置了它的绝对路径后，
/// 创建工作树改由 `ai-worktree ensure` 创建或复用，App 只负责传参、解析 JSON 和用 Git 复核结果。
/// 契约见 `docs/worktree-unified-entry-plan.md` §3。
enum WorktreeCommand {
    /// 命令会对远端做一次 fetch，给足时间；前端请求超时为 150 秒。
    static let timeout: TimeInterval = 120

    /// 与 ai-worktree `component()` 同一规则：ASCII 字母数字开头，最多 100 个字母、数字、点、横线或下划线，不以点结尾。
    static func isValidComponent(_ value: String) -> Bool {
        guard (1...100).contains(value.count), !value.hasSuffix(".") else { return false }
        let scalars = Array(value.unicodeScalars)
        func alnum(_ s: Unicode.Scalar) -> Bool { s.isASCII && CharacterSet.alphanumerics.contains(s) }
        guard alnum(scalars[0]) else { return false }
        return scalars.allSatisfy { alnum($0) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// 校验设置里的命令路径。空字符串表示不启用（项目内 `.worktrees` 模式）。
    /// 返回去掉首尾空白后的原始路径（保留符号链接本身，方便用户辨认）。
    static func validateExecutable(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "" }
        guard path.hasPrefix("/") else {
            throw GitError.commandFailed("工作树命令必须是绝对路径：\(path)", recoverable: true)
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw GitError.commandFailed("工作树命令不存在：\(path)", recoverable: true)
        }
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            throw GitError.commandFailed("工作树命令没有执行权限：\(path)", recoverable: true)
        }
        return path
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 命令自己的报错形如 `ai-worktree: <原因>`，去掉前缀后原样给界面。
    static func failureMessage(_ stderr: String, command: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = URL(fileURLWithPath: command).lastPathComponent + ": "
        let lines = text.split(separator: "\n").map(String.init)
        let last = lines.last(where: { $0.hasPrefix(prefix) }) ?? lines.last ?? ""
        return last.hasPrefix(prefix) ? String(last.dropFirst(prefix.count)) : last
    }

    struct Reply: Equatable {
        let action: String
        let repoRoot: String
        let task: String?
        let path: String
        let branch: String?
        let head: String?
        let baseRef: String?
        let baseCommit: String?
    }

    /// 解析 stdout 最后一个非空行。缺少 action / path / repo_root 或 action 不认识都算格式无效。
    static func parseReply(_ stdout: String) -> Reply? {
        guard let line = stdout.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = json["action"] as? String, ["created", "reused"].contains(action),
              let path = json["path"] as? String, path.hasPrefix("/"),
              let repoRoot = json["repo_root"] as? String, repoRoot.hasPrefix("/") else { return nil }
        return Reply(action: action, repoRoot: repoRoot, task: json["task"] as? String, path: path,
                     branch: json["branch"] as? String, head: json["head"] as? String,
                     baseRef: json["base_ref"] as? String, baseCommit: json["base_commit"] as? String)
    }
}

extension GitService {
    /// 统一模式：`<command> ensure --repo … --task … --json`，再用 Git 复核返回的目录。
    /// 参数一律写成 `--key=value`，以 `-` 开头的值也不会被当成选项。
    func ensureUnifiedWorktree(_ input: CreateWorktreeInput, command rawCommand: String) async throws -> WorktreeResult {
        let command = try WorktreeCommand.validateExecutable(rawCommand)
        let projectPath = input.projectPath
        guard await isRepository(path: projectPath) else { throw GitError.notARepository(projectPath) }

        func trimmed(_ value: String?) -> String? {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        guard let task = trimmed(input.task) else {
            throw GitError.commandFailed("统一工作树需要填写任务标识", recoverable: true)
        }
        let name = trimmed(input.name)
        let subtask = trimmed(input.subtask)
        for (label, value) in [("任务标识", task), ("名称", name), ("子任务", subtask)] {
            if let value, !WorktreeCommand.isValidComponent(value) {
                throw GitError.commandFailed("\(label)只能包含字母、数字、点、横线和下划线，最多 100 个字符：\(value)",
                                             recoverable: true)
            }
        }
        let combined = [task, name, subtask].compactMap { $0 }.joined(separator: "-")
        guard WorktreeCommand.isValidComponent(combined) else {
            throw GitError.commandFailed("任务标识、名称和子任务合起来不能超过 100 个字符", recoverable: true)
        }
        let branch = trimmed(input.branch)
        // 未指定基线时与项目模式一致，从项目当前分支起步；否则 ai-worktree 只能在恰好一个远端时自行推断。
        var base = trimmed(input.baseBranch)
        if base == nil, let head = try? await runner.run("git", arguments: ["-C", projectPath, "symbolic-ref", "--quiet", "--short", "HEAD"]),
           head.succeeded {
            base = trimmed(head.stdout)
        }
        for value in [branch, base].compactMap({ $0 }) where !Self.isValidRevision(value) {
            throw GitError.commandFailed("非法的引用名：\(value)", recoverable: true)
        }

        let repo = WorktreeCommand.canonical(projectPath)
        var arguments = ["GIT_TERMINAL_PROMPT=0", command, "ensure", "--repo=\(repo)", "--task=\(task)"]
        if let name { arguments.append("--name=\(name)") }
        if let subtask { arguments.append("--subtask=\(subtask)") }
        if let base { arguments.append("--base=\(base)") }
        if let branch { arguments.append("--branch=\(branch)") }
        arguments.append("--json")

        let output: ProcessOutput
        do {
            output = try await runner.run("env", arguments: arguments, timeout: WorktreeCommand.timeout)
        } catch let error as ProcessRunnerError {
            if case .timedOut = error {
                throw GitError.commandFailed("工作树命令超时（\(Int(WorktreeCommand.timeout))s）", recoverable: true)
            }
            throw GitError.commandFailed("工作树命令不可用：\(command)", detail: error.message, recoverable: true)
        }
        guard output.succeeded else {
            let message = WorktreeCommand.failureMessage(output.stderr, command: command)
            // 命令原因已在 message 里，不再放进 detail，免得界面重复显示。
            throw GitError.commandFailed(message.isEmpty ? "工作树命令失败（退出码 \(output.exitCode)）" : message,
                                         recoverable: true)
        }
        guard let reply = WorktreeCommand.parseReply(output.stdout) else {
            throw GitError.commandFailed("工作树命令返回格式无效", detail: String(output.stdout.prefix(200)), recoverable: true)
        }
        return try await verifyUnifiedReply(reply, projectPath: projectPath)
    }

    /// 返回的目录必须是所选仓库登记过、可用的工作树，分支与 common dir 都对得上，否则不登记会话。
    private func verifyUnifiedReply(_ reply: WorktreeCommand.Reply, projectPath: String) async throws -> WorktreeResult {
        let list = try await worktrees(projectPath: projectPath)
        guard let main = list.first,
              WorktreeCommand.canonical(main.path) == WorktreeCommand.canonical(reply.repoRoot) else {
            throw GitError.commandFailed("工作树命令返回的主仓库与所选项目不一致：\(reply.repoRoot)", recoverable: true)
        }
        let target = WorktreeCommand.canonical(reply.path)
        guard let entry = list.first(where: { WorktreeCommand.canonical($0.path) == target }) else {
            throw GitError.commandFailed("返回的目录不在该仓库的 Git 工作树登记中：\(reply.path)", recoverable: true)
        }
        guard !entry.isPrunable, !entry.isBare,
              FileManager.default.fileExists(atPath: target) else {
            throw GitError.commandFailed("Git 登记的工作树已不可用：\(reply.path)", recoverable: true)
        }
        guard entry.branch == reply.branch else {
            throw GitError.commandFailed("工作树的检出分支与命令返回不一致：\(entry.branch ?? "detached HEAD")",
                                         recoverable: true)
        }
        let expected = try await commonDirectory(of: projectPath)
        let actual = try await commonDirectory(of: target)
        guard expected == actual else {
            throw GitError.commandFailed("返回的目录属于另一个仓库：\(reply.path)", recoverable: true)
        }
        // 用 Git 登记的原样路径：侧栏的工作树节点按 `git worktree list` 的路径匹配会话 cwd，
        // 规范化后的形式（如 /private/tmp → /tmp）会让会话和工作树节点对不上。
        return WorktreeResult(path: entry.path, branch: entry.branch, action: reply.action, mode: "unified",
                              task: reply.task, baseRef: reply.baseRef, baseCommit: reply.baseCommit,
                              head: entry.head ?? reply.head)
    }

    private func commonDirectory(of path: String) async throws -> String {
        let output: ProcessOutput
        do {
            output = try await runner.run("git", arguments: ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        } catch let error as ProcessRunnerError {
            throw GitError.commandFailed(error.message)
        }
        guard output.succeeded else {
            throw GitError.commandFailed("无法读取仓库信息：\(path)", detail: output.stderr, recoverable: true)
        }
        return WorktreeCommand.canonical(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 设置页「检测」：只读执行 `<command> repo-root --repo <项目>`，返回主仓库路径。
    func worktreeCommandRepoRoot(command rawCommand: String, projectPath: String) async throws -> String {
        let command = try WorktreeCommand.validateExecutable(rawCommand)
        guard !command.isEmpty else { throw GitError.commandFailed("尚未填写工作树命令", recoverable: true) }
        let output: ProcessOutput
        do {
            output = try await runner.run("env", arguments: ["GIT_TERMINAL_PROMPT=0", command, "repo-root",
                                                             "--repo=\(WorktreeCommand.canonical(projectPath))"],
                                          timeout: 30)
        } catch let error as ProcessRunnerError {
            throw GitError.commandFailed("工作树命令不可用：\(command)", detail: error.message, recoverable: true)
        }
        guard output.succeeded else {
            let message = WorktreeCommand.failureMessage(output.stderr, command: command)
            throw GitError.commandFailed(message.isEmpty ? "工作树命令失败（退出码 \(output.exitCode)）" : message,
                                         recoverable: true)
        }
        let root = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.hasPrefix("/") else {
            throw GitError.commandFailed("工作树命令返回格式无效", detail: String(output.stdout.prefix(200)), recoverable: true)
        }
        return WorktreeCommand.canonical(root)
    }
}
