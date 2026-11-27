import Foundation

/// Work 的执行目录：校验项目、准备独立 worktree、计算「当前代码版本」与相对基线的差异。
///
/// 路径检查都在宿主这一侧做：项目必须是已登记目录，解析符号链接后比较实际位置；
/// worktree 只建在 `<项目>/.worktrees/` 下。git 参数走参数数组，不拼 shell 字符串。
/// 全部是同步调用，只能在后台线程用。
struct WorkspaceVersion: Sendable, Equatable {
    /// 不是 Git 仓库时为 nil：无法把审阅绑定到代码版本。
    var head: String?
    /// 工作目录的完整树（含未提交、未跟踪文件）的 tree id。
    var tree: String?
    var isRepository: Bool

    var json: JSONValue {
        .obj(["head": .str(head), "tree": .str(tree), "isRepository": .bool(isRepository)])
    }
}

struct PreparedWorkspace: Sendable {
    var path: String
    var branch: String?
    var baseCommit: String?
    var isolation: String
}

enum WorkspaceService {
    private static func git(_ args: [String], in dir: String, timeout: TimeInterval = 60,
                            env extra: [String: String] = [:]) -> ProcResult {
        var env = LoginEnv.shared.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        for (k, v) in extra { env[k] = v }
        return Proc.run(LoginEnv.shared.git, ["-C", dir] + args, env: env, timeout: timeout)
    }

    /// 规范化路径，与应用其余部分（`resolvedPath`）同一口径。尚不存在的文件按「已存在的最近上级目录」解析，
    /// 否则同一个目录下的新文件会得到与目录本身不同的前缀（/private/var 与 /var）。
    static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            tail.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath().standardizedFileURL
        for component in tail { resolved.appendPathComponent(component) }
        return resolved.path
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isRepository(_ path: String) -> Bool {
        let result = git(["rev-parse", "--is-inside-work-tree"], in: path, timeout: 15)
        return result.ok && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// 仓库身份：公共 git 目录的规范路径。目录识别后仓库被换掉（同路径不同仓库）时据此发现。
    static func repositoryIdentity(_ path: String) -> String? {
        let result = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path, timeout: 15)
        guard result.ok else { return nil }
        return canonical(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 启动前再校验一次项目目录：被移走、不可访问都直接失败，不降级到其他目录。
    static func validateProject(_ project: WorkProject) throws {
        guard isDirectory(project.path) else {
            throw WorkError.unavailable("项目目录不存在或不可访问：\(project.path)")
        }
        guard canonical(project.path) == project.path else {
            throw WorkError.unavailable("项目目录的实际位置已变化：\(project.path) → \(canonical(project.path))")
        }
    }

    static func slug(_ text: String) -> String {
        GitService.worktreeSlug(text)
    }

    /// 准备执行目录。已有的 worktree（之前的 Run 建过）校验后复用；否则新建分支与 worktree。
    /// 任一步失败都抛错并带上 git 的输出，不留下半个 worktree 当成可用目录。
    static func prepare(work: Work, project: WorkProject) throws -> PreparedWorkspace {
        try validateProject(project)

        if let existing = work.workspacePath, !existing.isEmpty {
            guard isDirectory(existing) else {
                throw WorkError.unavailable("这个 Work 的执行目录已不存在：\(existing)。目录不会被自动重建到别处。")
            }
            let real = canonical(existing)
            guard real == project.path || real.hasPrefix(project.path + "/") else {
                throw WorkError.unavailable("执行目录不在项目内：\(real)")
            }
            return PreparedWorkspace(path: real, branch: work.branch ?? currentBranch(real),
                                     baseCommit: work.baseCommit ?? currentHead(real), isolation: work.isolation)
        }

        let repo = isRepository(project.path)
        guard work.isolation == "worktree", repo else {
            // 不是 Git 仓库或用户选择直接在项目目录执行：没有隔离，如实记录。
            let head = repo ? currentHead(project.path) : nil
            return PreparedWorkspace(path: project.path, branch: repo ? currentBranch(project.path) : nil,
                                     baseCommit: head, isolation: "project")
        }

        let base = git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: project.path, timeout: 15)
        guard base.ok else {
            throw WorkError.unavailable("仓库还没有提交，无法创建独立工作树", detail: base.failureText)
        }
        let baseCommit = base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let stem = "work/" + work.displayId.lowercased()
        var branch = stem
        var suffix = 1
        while git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: project.path, timeout: 15).ok {
            suffix += 1
            branch = "\(stem)-\(suffix)"
        }
        let container = URL(fileURLWithPath: canonical(project.path)).appendingPathComponent(WorktreeLayout.directoryName, isDirectory: true)
        guard container.resolvingSymlinksInPath().path == container.path else {
            throw WorkError.unavailable("工作树目录必须位于项目内", detail: container.path)
        }
        var target = container.appendingPathComponent(slug(branch), isDirectory: true)
        while FileManager.default.fileExists(atPath: target.path) {
            suffix += 1
            target = container.appendingPathComponent(slug("\(stem)-\(suffix)"), isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        } catch {
            throw WorkError.unavailable("无法创建 \(container.path)", detail: error.localizedDescription)
        }
        excludeWorktrees(in: project.path)
        guard git(["check-ignore", "--quiet", "--", target.path], in: project.path, timeout: 15).ok else {
            throw WorkError.unavailable("工作树目录未被 Git 忽略", detail: "请检查本机 info/exclude 与仓库忽略规则")
        }

        let added = git(["worktree", "add", target.path, "-b", branch, baseCommit], in: project.path, timeout: 180)
        guard added.ok else {
            throw WorkError.failed("创建工作树失败", detail: added.failureText)
        }
        return PreparedWorkspace(path: canonical(target.path), branch: branch, baseCommit: baseCommit,
                                 isolation: "worktree")
    }

    /// `.worktrees/` 只写进本机的 `.git/info/exclude`，不改仓库里的 .gitignore。
    private static func excludeWorktrees(in projectPath: String) {
        guard let common = repositoryIdentity(projectPath) else { return }
        let file = URL(fileURLWithPath: common).appendingPathComponent("info/exclude")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(".worktrees/") && !lines.contains(".worktrees") else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let prefix = existing.isEmpty || existing.hasSuffix("\n") ? existing : existing + "\n"
        try? (prefix + ".worktrees/\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func currentHead(_ path: String) -> String? {
        let result = git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: path, timeout: 15)
        return result.ok ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    static func currentBranch(_ path: String) -> String? {
        let result = git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: path, timeout: 15)
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !name.isEmpty ? name : nil
    }

    // MARK: 代码版本

    /// 当前工作目录的版本：HEAD + 整个工作目录（含未提交 / 未跟踪）的 tree id。
    ///
    /// 用一份临时 index 计算，不碰真实 index：先复制真实 index（保留 stat 缓存，大仓库也快），
    /// 再 `add -A`、`write-tree`。审阅批准、验证结果都绑定这个 tree id，代码一变它就变。
    static func version(of path: String) -> WorkspaceVersion {
        guard isDirectory(path), isRepository(path) else {
            return WorkspaceVersion(head: nil, tree: nil, isRepository: false)
        }
        let head = currentHead(path)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-picker-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let indexPath = git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: path, timeout: 15)
        let realIndex = indexPath.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if indexPath.ok, FileManager.default.fileExists(atPath: realIndex) {
            try? FileManager.default.copyItem(atPath: realIndex, toPath: temp.path)
        }
        let env = ["GIT_INDEX_FILE": temp.path]
        guard git(["add", "-A"], in: path, timeout: 180, env: env).ok else {
            return WorkspaceVersion(head: head, tree: nil, isRepository: true)
        }
        let tree = git(["write-tree"], in: path, timeout: 60, env: env)
        return WorkspaceVersion(head: head,
                                tree: tree.ok ? tree.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                                isRepository: true)
    }

    struct ChangedFile: Sendable {
        var path: String
        var oldPath: String?
        var status: String          // A / M / D / R / C / T
        var added: Int?             // 二进制文件没有行数
        var deleted: Int?
        var binary: Bool

        var json: JSONValue {
            .obj(["path": .string(path), "oldPath": .str(oldPath), "status": .string(status),
                  "added": .int(added), "deleted": .int(deleted), "binary": .bool(binary)])
        }
    }

    /// 相对基线提交的全部变更（已提交 + 未提交 + 未跟踪），按 tree 比较，所以不依赖是否暂存或提交。
    static func changes(in path: String, base: String, tree: String) -> [ChangedFile] {
        let status = git(["diff", "--name-status", "--find-renames", "-z", base, tree], in: path, timeout: 60)
        guard status.ok else { return [] }
        var files: [ChangedFile] = []
        let parts = status.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < parts.count {
            let code = parts[index]
            let letter = String(code.prefix(1))
            if (letter == "R" || letter == "C"), index + 2 < parts.count {
                files.append(ChangedFile(path: parts[index + 2], oldPath: parts[index + 1], status: letter,
                                         added: nil, deleted: nil, binary: false))
                index += 3
            } else if index + 1 < parts.count {
                files.append(ChangedFile(path: parts[index + 1], oldPath: nil, status: letter,
                                         added: nil, deleted: nil, binary: false))
                index += 2
            } else {
                break
            }
        }
        let numstat = git(["diff", "--numstat", "--find-renames", "-z", base, tree], in: path, timeout: 60)
        if numstat.ok {
            var counts: [String: (Int?, Int?)] = [:]
            let fields = numstat.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            var i = 0
            while i < fields.count {
                let cols = fields[i].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard cols.count >= 3 else { i += 1; continue }
                var name = cols[2]
                if name.isEmpty, i + 2 < fields.count {      // 重命名：后面跟旧名、新名两段
                    name = fields[i + 2]
                    i += 2
                }
                counts[name] = (Int(cols[0]), Int(cols[1]))
                i += 1
            }
            for n in files.indices {
                if let (added, deleted) = counts[files[n].path] {
                    files[n].added = added
                    files[n].deleted = deleted
                    files[n].binary = added == nil && deleted == nil
                }
            }
        }
        return files
    }

    static let maxPatchBytes = 400_000

    /// 单个文件相对基线的补丁。超大补丁不整段返回，由界面提示改用外部工具查看。
    static func patch(in path: String, base: String, tree: String, file: String) -> JSONValue {
        let result = git(["diff", "--find-renames", base, tree, "--", file], in: path, timeout: 60)
        guard result.ok else {
            return .obj(["error": .string(result.failureText)])
        }
        let text = result.stdout
        if text.utf8.count > maxPatchBytes {
            return .obj(["tooLarge": .bool(true), "bytes": .int(text.utf8.count)])
        }
        let binary = text.contains("\nBinary files ") || text.hasPrefix("Binary files ")
            || text.contains("GIT binary patch")
        return .obj(["patch": .string(text), "binary": .bool(binary)])
    }

    /// 工作目录里是否有未提交的内容（清理 worktree 前检查用）。
    static func hasUncommittedChanges(_ path: String) -> Bool {
        let result = git(["status", "--porcelain"], in: path, timeout: 30)
        return !result.ok || !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Turn Checkpoint（隐藏 Git Ref 快照与回退）

    struct CheckpointSnapshot: Sendable, Equatable {
        var head: String?
        var tree: String
        var gitRef: String
    }

    static let maxCheckpointFileBytes: UInt64 = 20 * 1024 * 1024

    /// 创建一轮代码检查点：使用临时 index `write-tree` 后生成锚定 commit，并写入隐藏命名空间
    /// `refs/claude-picker/checkpoints/<workId>/<seq>`，确保 `git gc` 不会回收历史快照对象，且不污染分支与 `git status`。
    static func createCheckpoint(in path: String, workId: String, seq: Int, label: String) -> CheckpointSnapshot? {
        guard isDirectory(path), isRepository(path) else { return nil }
        let head = currentHead(path)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-picker-cp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let indexPath = git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: path, timeout: 15)
        let realIndex = indexPath.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if indexPath.ok, FileManager.default.fileExists(atPath: realIndex) {
            try? FileManager.default.copyItem(atPath: realIndex, toPath: temp.path)
        }
        let env = ["GIT_INDEX_FILE": temp.path]

        // 跳过超过 20MB 的未跟踪大文件，防止误把构建大产物打包进 .git/objects
        var pathspecs = ["add", "-A", "--", "."]
        let untracked = git(["ls-files", "--others", "--exclude-standard", "-z"], in: path, timeout: 30)
        if untracked.ok {
            for rel in untracked.stdout.split(separator: "\0").map(String.init) where !rel.isEmpty {
                let full = URL(fileURLWithPath: path).appendingPathComponent(rel).path
                if let size = (try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? NSNumber,
                   size.uint64Value > maxCheckpointFileBytes {
                    pathspecs.append(":(exclude)\(rel)")
                }
            }
        }
        guard git(pathspecs, in: path, timeout: 180, env: env).ok else { return nil }
        let treeOut = git(["write-tree"], in: path, timeout: 60, env: env)
        guard treeOut.ok else { return nil }
        let tree = treeOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tree.isEmpty else { return nil }

        var commitArgs = ["commit-tree", tree, "-m", label.isEmpty ? "cp-checkpoint" : label]
        if let head, !head.isEmpty { commitArgs += ["-p", head] }
        let commitEnv = [
            "GIT_AUTHOR_NAME": "ClaudePicker",
            "GIT_AUTHOR_EMAIL": "checkpoint@local",
            "GIT_COMMITTER_NAME": "ClaudePicker",
            "GIT_COMMITTER_EMAIL": "checkpoint@local",
        ]
        let commitOut = git(commitArgs, in: path, timeout: 30, env: commitEnv)
        guard commitOut.ok else { return nil }
        let commitSha = commitOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commitSha.isEmpty else { return nil }

        let ref = "refs/claude-picker/checkpoints/\(workId)/\(seq)"
        guard git(["update-ref", ref, commitSha], in: path, timeout: 15).ok else { return nil }
        return CheckpointSnapshot(head: head, tree: tree, gitRef: ref)
    }

    /// 回退工作区到指定快照树：
    /// 1. 共享目录（`isolation == "project"`）若检测到自上一轮结束以来存在外部手工改动且 `!force`，抛 `conflict` 保护用户代码；
    /// 2. 独占 `worktree` 下若本轮智能体自己执行过 `git commit` 使 `HEAD` 前进，安全回拨 `HEAD` 到快照时刻；
    /// 3. 精确还原文件树并删除该快照之后新增的文件，不触碰 `.gitignore` 忽略项（如 `node_modules`、`.env`）。
    static func revertToCheckpoint(
        in path: String,
        targetTree: String,
        targetHead: String?,
        isolation: String,
        expectedCurrentTree: String?,
        force: Bool
    ) throws -> [String] {
        guard isDirectory(path), isRepository(path) else {
            throw WorkError.unavailable("当前目录不是 Git 仓库，无法执行检查点回退")
        }
        let current = version(of: path)
        guard let currentTree = current.tree else {
            throw WorkError.unavailable("无法读取当前工作目录状态")
        }
        if currentTree == targetTree {
            return []
        }
        if isolation != "worktree", !force, let expected = expectedCurrentTree, !expected.isEmpty, currentTree != expected {
            throw WorkError.conflict("检测到工作目录在上一轮结束后有外部未保存改动，为防误覆盖已暂停回退。确认覆盖可选择强制回退。")
        }

        let diffFiles = changes(in: path, base: targetTree, tree: currentTree)
        let affectedPaths = diffFiles.map(\.path)

        // 独占 worktree 中若 HEAD 在 targetHead 之后前进过，先安全复位 HEAD
        if isolation == "worktree",
           let targetHead, !targetHead.isEmpty,
           let curHead = current.head, curHead != targetHead,
           git(["merge-base", "--is-ancestor", targetHead, curHead], in: path, timeout: 15).ok {
            _ = git(["reset", "--soft", targetHead], in: path, timeout: 30)
        }

        // 删除 targetTree 中不存在、在后续轮次新增的文件（仅限非忽略跟踪树里的 A 状态项）
        let fm = FileManager.default
        let rootPath = canonical(path)
        for item in diffFiles where item.status == "A" {
            let fileURL = URL(fileURLWithPath: rootPath).appendingPathComponent(item.path).standardizedFileURL
            if fileURL.path.hasPrefix(rootPath + "/") {
                try? fm.removeItem(at: fileURL)
            }
        }

        // 将 targetTree 中的全部文件内容写回工作目录（空树时无需 checkout `.`）
        let lsTree = git(["ls-tree", targetTree], in: path, timeout: 15)
        if lsTree.ok, !lsTree.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let co = git(["checkout", targetTree, "--", "."], in: path, timeout: 120)
            guard co.ok else {
                throw WorkError.failed("恢复代码快照失败", detail: co.failureText)
            }
        }
        return affectedPaths
    }
}
