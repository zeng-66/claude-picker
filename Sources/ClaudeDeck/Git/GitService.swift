import Foundation

/// Git 能力层：只读查询 + 暂存 / 提交 / 分支 / Stash / 合并 / Worktree 写操作。
///
/// 所有方法接收 `projectPath`（项目根目录绝对路径），桥接层直接把前端传来的
/// `projectPath` 透传进来；另有 `Project` 便捷重载，供 Swift 侧直接调用。
struct GitService: Sendable {
    let runner: ProcessRunner

    init(runner: ProcessRunner = .shared) {
        self.runner = runner
    }

    // MARK: - 仓库判定

    func isRepository(path: String) async -> Bool {
        guard let output = try? await runner.run(
            "git", arguments: ["-C", path, "rev-parse", "--is-inside-work-tree"]) else { return false }
        return output.succeeded
            && output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    // MARK: - 只读

    /// `git status --porcelain=v1 -z --branch`，顺带把分支/领先落后一起拿回来，只起一次进程。
    func status(projectPath: String) async throws -> GitStatusSnapshot {
        let output = try await gitChecked(["status", "--porcelain=v1", "-z", "--branch"],
                                          in: projectPath, timeout: 60)
        return Self.parseStatus(output.stdout, projectPath: projectPath)
    }

    func log(projectPath: String, limit: Int = 50) async throws -> [GitCommit] {
        guard limit > 0 else { return [] }
        let format = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%s"
        let output = try await git(["log", "--max-count=\(limit)", "--pretty=format:\(format)"],
                                   in: projectPath)
        guard output.succeeded else {
            // 空仓库没有 HEAD，`git log` 会失败；这是「0 条提交」，不是错误。
            if Self.isUnbornRepository(output.stderr) { return [] }
            throw Self.translate(output, projectPath: projectPath)
        }
        return output.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 7 else { return nil }
            return GitCommit(hash: parts[0],
                             shortHash: parts[1],
                             message: parts[6],
                             author: parts[2],
                             authorEmail: parts[3],
                             date: parts[4],
                             parents: parts[5].split(separator: " ").map(String.init))
        }
    }

    /// 单个提交的元信息 + 文件统计 + 统一 diff。三次只读调用，按需触发。
    func show(projectPath: String, hash: String) async throws -> GitCommitDetail {
        guard Self.isValidRevision(hash) else {
            throw GitError.commandFailed("非法的提交哈希：\(hash)", recoverable: false)
        }
        let format = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%s"
        let meta = try await gitChecked(["show", "-s", "--no-color", "--format=\(format)", hash],
                                        in: projectPath)
        let parts = meta.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\u{1f}", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 7 else {
            throw GitError.commandFailed("无法解析提交信息：\(hash)", detail: meta.stdout)
        }
        let commit = GitCommit(hash: parts[0],
                               shortHash: parts[1],
                               message: parts[6],
                               author: parts[2],
                               authorEmail: parts[3],
                               date: parts[4],
                               parents: parts[5].split(separator: " ").map(String.init))

        let numstat = try await gitChecked(["show", "--numstat", "--format=", "--no-color", hash],
                                           in: projectPath)
        let files = Self.parseNumstat(numstat.stdout)
        let patch = try await gitChecked(["show", "--patch", "--format=", "--no-color", hash],
                                         in: projectPath)
        return GitCommitDetail(commit: commit,
                               files: files,
                               additions: files.reduce(0) { $0 + $1.additions },
                               deletions: files.reduce(0) { $0 + $1.deletions },
                               patch: patch.stdout)
    }

    /// 工作区（或暂存区）相对 HEAD 的 diff。
    func diff(projectPath: String, path: String, staged: Bool = false) async throws -> DiffResult {
        var arguments = ["diff", "--no-color"]
        if staged { arguments.append("--cached") }
        arguments += ["--", path]
        let output = try await gitChecked(arguments, in: projectPath)
        let (additions, deletions) = Self.countPatchLines(output.stdout)
        return DiffResult(path: path,
                          staged: staged,
                          binary: output.stdout.contains("Binary files") && output.stdout.contains(" differ"),
                          additions: additions,
                          deletions: deletions,
                          patch: output.stdout)
    }

    /// 本地 + 远程分支，带 ahead/behind 与当前分支标记。
    func branches(projectPath: String) async throws -> [GitBranchInfo] {
        let format = "%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track)%1f%(objectname:short)%1f%(symref)"
        let output = try await gitChecked(["for-each-ref", "--format=\(format)", "refs/heads", "refs/remotes"],
                                          in: projectPath)
        return output.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 7, parts[6].isEmpty else { return nil }  // 跳过 origin/HEAD 这类符号引用
            let full = parts[0]
            let track = parts[4]
            return GitBranchInfo(name: parts[1],
                             isCurrent: parts[2] == "*",
                             isRemote: full.hasPrefix("refs/remotes/"),
                             upstream: parts[3].isEmpty ? nil : parts[3],
                             ahead: Self.trackCount("ahead ", in: track),
                             behind: Self.trackCount("behind ", in: track),
                             upstreamGone: track.contains("gone"),
                             lastCommit: parts[5])
        }
    }

    func tags(projectPath: String) async throws -> [GitTag] {
        let format = "%(refname:short)%1f%(objectname:short)%1f%(creatordate:iso-strict)%1f%(subject)"
        let output = try await gitChecked(["for-each-ref", "--format=\(format)", "refs/tags"],
                                          in: projectPath)
        return output.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            return GitTag(name: parts[0], hash: parts[1], date: parts[2], subject: parts[3])
        }
    }

    func remotes(projectPath: String) async throws -> [GitRemote] {
        let output = try await gitChecked(["remote", "-v"], in: projectPath)
        var order: [String] = []
        var fetch: [String: String] = [:]
        var push: [String: String] = [:]
        for line in output.stdout.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count == 2 else { continue }
            let kind = fields[1].hasSuffix(" (push)") ? "push" : "fetch"
            guard let name = fields[0].split(separator: " ").first.map(String.init) else { continue }
            let url = fields[1]
                .replacingOccurrences(of: " (fetch)", with: "")
                .replacingOccurrences(of: " (push)", with: "")
            if !order.contains(name) { order.append(name) }
            if kind == "push" { push[name] = url } else { fetch[name] = url }
        }
        return order.map { name in
            GitRemote(name: name, fetchURL: fetch[name] ?? "", pushURL: push[name] ?? fetch[name] ?? "")
        }
    }

    func worktrees(projectPath: String) async throws -> [GitWorktreeInfo] {
        let output = try await gitChecked(["worktree", "list", "--porcelain"], in: projectPath)

        // 每个 worktree 是一段以空行分隔的 key value 块。
        var blocks: [[String]] = []
        var current: [String] = []
        for line in output.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                if !current.isEmpty { blocks.append(current); current = [] }
            } else {
                current.append(String(line))
            }
        }
        if !current.isEmpty { blocks.append(current) }

        return blocks.compactMap { block -> GitWorktreeInfo? in
            var path: String?
            var head: String?
            var branch: String?
            var bare = false
            var locked = false
            var prunable = false
            for line in block {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst("HEAD ".count)) }
                else if line.hasPrefix("branch ") {
                    branch = String(line.dropFirst("branch ".count))
                        .replacingOccurrences(of: "refs/heads/", with: "")
                }
                else if line == "bare" { bare = true }
                else if line.hasPrefix("locked") { locked = true }
                else if line.hasPrefix("prunable") { prunable = true }
            }
            guard let path else { return nil }
            return GitWorktreeInfo(path: path, head: head, branch: branch,
                               isBare: bare, isLocked: locked, isPrunable: prunable)
        }
    }

    func stashes(projectPath: String) async throws -> [GitStash] {
        let format = "%gd%x1f%H%x1f%gs%x1f%aI"
        let output = try await gitChecked(["stash", "list", "--format=\(format)"], in: projectPath)
        return output.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, let index = Int(parts[0].dropFirst("stash@{".count).dropLast()) else { return nil }
            return GitStash(index: index, ref: parts[0], hash: parts[1], message: parts[2], date: parts[3])
        }
    }

    /// HEAD detached 时抛 `DETACHED_HEAD`，而不是返回 "HEAD" 糊弄调用方。
    func currentBranch(projectPath: String) async throws -> String {
        let output = try await gitChecked(["rev-parse", "--abbrev-ref", "HEAD"], in: projectPath)
        let name = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != "HEAD", !name.isEmpty else { throw GitError.detachedHead() }
        return name
    }

    // MARK: - 暂存与提交

    /// 暂存：`git add -A` 同时覆盖修改、删除与未跟踪目录。路径一律按字面量处理，
    /// 文件名里的 `:` `*` `[` 不会被当成 pathspec 魔法。
    func stage(projectPath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await gitChecked(["--literal-pathspecs", "add", "-A", "--"] + paths, in: projectPath, timeout: 60)
    }

    /// 取消暂存。还没有任何提交的仓库没有 HEAD，`restore --staged` 用不了，改走 `rm --cached`。
    func unstage(projectPath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let head = try await git(["rev-parse", "--verify", "--quiet", "HEAD"], in: projectPath)
        if head.succeeded {
            _ = try await gitChecked(["--literal-pathspecs", "restore", "--staged", "--"] + paths,
                                     in: projectPath, timeout: 60)
        } else {
            _ = try await gitChecked(["--literal-pathspecs", "rm", "--cached", "-r", "-q", "--"] + paths,
                                     in: projectPath, timeout: 60)
        }
    }

    /// 提交。钩子的输出可能在 stdout 也可能在 stderr，失败时两边都带回去原样展示。
    func commit(projectPath: String, message: String, options: CommitOptions = CommitOptions()) async throws -> CommitResult {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw GitError.commandFailed("提交信息不能为空", recoverable: true)
        }
        var arguments = ["commit", "-m", text]
        if options.amend { arguments.append("--amend") }
        if options.signOff { arguments.append("--signoff") }
        if options.noVerify { arguments.append("--no-verify") }
        if options.allowEmpty { arguments.append("--allow-empty") }
        let output = try await git(arguments, in: projectPath, timeout: Self.networkTimeout)
        guard output.succeeded else {
            let detail = [output.stderr, output.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let lower = detail.lowercased()
            if lower.contains("not a git repository") { throw GitError.notARepository(projectPath, detail: detail) }
            if lower.contains("nothing to commit") || lower.contains("no changes added to commit") {
                throw GitError.commandFailed("没有已暂存的变更可以提交", detail: detail)
            }
            throw GitError.commandFailed("提交失败", detail: detail.isEmpty ? nil : detail)
        }
        let head = try await gitChecked(["rev-parse", "HEAD"], in: projectPath)
        let hash = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommitResult(hash: hash, shortHash: String(hash.prefix(7)), message: text, amended: options.amend)
    }

    // MARK: - 分支写操作（右键分支菜单）

    /// 网络操作（fetch / pull / push）给更长的超时；仍有上限，避免卡死在认证提示上。
    static let networkTimeout: TimeInterval = 120

    /// 新建分支（不切换）。`startPoint` 为空时从 HEAD 分出。
    func createBranch(projectPath: String, branch: String, startPoint: String? = nil) async throws {
        try await validateBranchName(branch, in: projectPath)
        if try await localBranchExists(branch, in: projectPath) { throw GitError.branchExists(branch) }
        var args = ["branch", "--no-track", branch]
        if let startPoint {
            try Self.requireSafeRevision(startPoint)
            args = ["branch", "--no-track", branch, startPoint]
        }
        _ = try await gitChecked(args, in: projectPath)
    }

    /// 签出分支。远程分支（`origin/foo`）会建同名本地跟踪分支；本地已有同名分支时直接切过去。
    /// 工作区导航不得把未提交改动带到另一条分支。
    func switchWorkspaceBranch(projectPath: String, branch: String) async throws {
        let snapshot = try await status(projectPath: projectPath)
        guard snapshot.branch != branch else { return }
        guard snapshot.clean else {
            throw GitError.commandFailed("当前工作区有未提交改动，请先处理后再切换分支", recoverable: true)
        }
        try await switchBranch(projectPath: projectPath, branch: branch)
    }

    func switchBranch(projectPath: String, branch: String) async throws {
        try Self.requireSafeRevision(branch)
        let remotes = try await remoteNames(in: projectPath)
        if case let (remote, name)? = Self.splitRemoteBranch(branch, remotes: remotes) {
            if try await localBranchExists(name, in: projectPath) {
                _ = try await gitChecked(["switch", name], in: projectPath)
            } else {
                _ = try await gitChecked(["switch", "--track", "-c", name, "\(remote)/\(name)"], in: projectPath)
            }
            return
        }
        _ = try await gitChecked(["switch", branch], in: projectPath)
    }

    /// 把 `branch` 合并进当前分支。冲突时 git 把 CONFLICT 写在 stdout，这里一并判断。
    func merge(projectPath: String, branch: String) async throws {
        try Self.requireSafeRevision(branch)
        let output = try await git(["merge", "--no-edit", branch], in: projectPath)
        guard output.succeeded else {
            if output.stdout.contains("CONFLICT") {
                throw GitError.mergeConflict(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw Self.translate(output, projectPath: projectPath)
        }
    }

    /// 删除本地分支。只用 `-d`：未合并的分支 git 会拒绝，不做强删。
    func deleteBranch(projectPath: String, branch: String) async throws {
        try Self.requireSafeRevision(branch)
        _ = try await gitChecked(["branch", "-d", branch], in: projectPath)
    }

    /// 获取远程引用。`remote` 为空时取全部远程。
    func fetch(projectPath: String, remote: String? = nil) async throws {
        var args = ["fetch", "--prune"]
        if let remote {
            try Self.requireSafeRevision(remote)
            args.append(remote)
        } else {
            args.append("--all")
        }
        _ = try await gitChecked(args, in: projectPath, timeout: Self.networkTimeout)
    }

    /// 更新分支（只快进，不在后台替用户做合并提交）：
    /// - 当前分支：`git pull --ff-only`；
    /// - 其它本地分支：`git fetch <remote> <上游>:<本地>`，不切换分支直接快进。
    func pull(projectPath: String, remote: String? = nil, branch: String? = nil) async throws {
        let current = try? await currentBranch(projectPath: projectPath)
        guard let branch, branch != current else {
            var args = ["pull", "--ff-only"]
            if let remote { try Self.requireSafeRevision(remote); args.append(remote) }
            _ = try await gitChecked(args, in: projectPath, timeout: Self.networkTimeout)
            return
        }
        try Self.requireSafeRevision(branch)
        guard case let (upRemote, upBranch)? = try await upstream(of: branch, in: projectPath) else {
            throw GitError.commandFailed("分支 \(branch) 没有上游分支，无法更新", recoverable: true)
        }
        _ = try await gitChecked(["fetch", upRemote, "\(upBranch):\(branch)"],
                                 in: projectPath, timeout: Self.networkTimeout)
    }

    /// 推送本地分支。有上游推到上游；没有上游推到 `remote`（默认 origin / 第一个远程）并建立跟踪。
    func push(projectPath: String, remote: String? = nil, branch: String? = nil, setUpstream: Bool = false) async throws {
        let name: String
        if let branch { name = branch } else { name = try await currentBranch(projectPath: projectPath) }
        try Self.requireSafeRevision(name)
        if !setUpstream, case let (upRemote, upBranch)? = try await upstream(of: name, in: projectPath) {
            _ = try await gitChecked(["push", upRemote, "refs/heads/\(name):refs/heads/\(upBranch)"],
                                     in: projectPath, timeout: Self.networkTimeout)
            return
        }
        let remotes = try await remoteNames(in: projectPath)
        guard let target = remote ?? (remotes.contains("origin") ? "origin" : remotes.first) else {
            throw GitError.commandFailed("仓库没有配置远程，无法推送", recoverable: true)
        }
        try Self.requireSafeRevision(target)
        _ = try await gitChecked(["push", "--set-upstream", target, "refs/heads/\(name):refs/heads/\(name)"],
                                 in: projectPath, timeout: Self.networkTimeout)
    }

    // MARK: - 分支辅助

    private func validateBranchName(_ name: String, in projectPath: String) async throws {
        try Self.requireSafeRevision(name)
        let output = try await git(["check-ref-format", "--branch", name], in: projectPath)
        guard output.succeeded else {
            throw GitError.commandFailed("分支名不合法：\(name)", recoverable: true)
        }
    }

    private func localBranchExists(_ name: String, in projectPath: String) async throws -> Bool {
        try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: projectPath).succeeded
    }

    private func remoteNames(in projectPath: String) async throws -> [String] {
        try await gitChecked(["remote"], in: projectPath).stdout
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// `foo` 的上游，拆成 (远程名, 远程上的分支名)。没有上游返回 nil。
    private func upstream(of branch: String, in projectPath: String) async throws -> (String, String)? {
        let remote = try await git(["config", "--get", "branch.\(branch).remote"], in: projectPath)
        let merge = try await git(["config", "--get", "branch.\(branch).merge"], in: projectPath)
        let r = remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = merge.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote.succeeded, merge.succeeded, !r.isEmpty, r != ".", m.hasPrefix("refs/heads/") else { return nil }
        return (r, String(m.dropFirst("refs/heads/".count)))
    }

    /// `origin/feat/x` → ("origin", "feat/x")；不是已知远程前缀返回 nil。
    private static func splitRemoteBranch(_ ref: String, remotes: [String]) -> (String, String)? {
        for remote in remotes.sorted(by: { $0.count > $1.count }) where ref.hasPrefix(remote + "/") {
            let name = String(ref.dropFirst(remote.count + 1))
            if !name.isEmpty { return (remote, name) }
        }
        return nil
    }

    private static func requireSafeRevision(_ value: String) throws {
        guard isValidRevision(value) else {
            throw GitError.commandFailed("非法的引用名：\(value)", recoverable: false)
        }
    }



    // MARK: - Stash

    func stashSave(projectPath: String, message: String?, includeUntracked: Bool = false) async throws {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            arguments += ["-m", message]
        }
        let output = try await gitChecked(arguments, in: projectPath, timeout: 60)
        if output.stdout.contains("No local changes to save") {
            throw GitError.commandFailed("没有可以保存的本地变更", recoverable: true)
        }
    }

    func stashApply(projectPath: String, index: Int) async throws {
        _ = try await gitChecked(["stash", "apply", try Self.stashRef(index)], in: projectPath, timeout: 60)
    }

    func stashPop(projectPath: String, index: Int) async throws {
        _ = try await gitChecked(["stash", "pop", try Self.stashRef(index)], in: projectPath, timeout: 60)
    }

    func stashDrop(projectPath: String, index: Int) async throws {
        _ = try await gitChecked(["stash", "drop", try Self.stashRef(index)], in: projectPath)
    }

    private static func stashRef(_ index: Int) throws -> String {
        guard index >= 0 else { throw GitError.commandFailed("非法的 Stash 下标：\(index)", recoverable: false) }
        return "stash@{\(index)}"
    }

    // MARK: - 合并与冲突

    /// 是否处于合并中、正在合并进来的引用、还没解决的冲突文件。
    func mergeState(projectPath: String) async throws -> GitMergeState {
        // 先确认是仓库：非仓库要报 NOT_A_REPOSITORY，而不是「没有在合并」。
        _ = try await gitChecked(["rev-parse", "--git-dir"], in: projectPath)
        let head = try await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: projectPath)
        guard head.succeeded else { return GitMergeState(merging: false, head: nil, conflicts: []) }
        let named = try await git(["name-rev", "--name-only", "--no-undefined", "MERGE_HEAD"], in: projectPath)
        var name = named.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.succeeded || name.isEmpty {
            name = String(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(7))
        }
        if name.hasPrefix("remotes/") { name = String(name.dropFirst("remotes/".count)) }
        let unmerged = try await gitChecked(["diff", "--name-only", "--diff-filter=U", "-z"], in: projectPath)
        let conflicts = unmerged.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        return GitMergeState(merging: true, head: name, conflicts: conflicts)
    }

    /// 解决单个冲突文件：`ours` / `theirs` 整份采用一边后暂存；`mark` 只暂存（已手工解决）。
    func resolveConflict(projectPath: String, path: String, strategy: String) async throws {
        switch strategy {
        case "ours", "theirs":
            let side = try await git(["--literal-pathspecs", "checkout", "--\(strategy)", "--", path], in: projectPath)
            if side.succeeded {
                _ = try await gitChecked(["--literal-pathspecs", "add", "--", path], in: projectPath)
            } else if side.stderr.contains("does not have") {
                // 「一边改、一边删」的冲突：被采用的那一边没有这个文件，即删除。
                _ = try await gitChecked(["--literal-pathspecs", "rm", "-q", "--", path], in: projectPath)
            } else {
                throw Self.translate(side, projectPath: projectPath)
            }
        case "mark":
            _ = try await gitChecked(["--literal-pathspecs", "add", "-A", "--", path], in: projectPath)
        default:
            throw GitError.commandFailed("未知的冲突解决方式：\(strategy)", recoverable: false)
        }
    }

    func mergeAbort(projectPath: String) async throws {
        _ = try await gitChecked(["merge", "--abort"], in: projectPath, timeout: 60)
    }

    /// 冲突全部解决后生成合并提交。`core.editor=true` 让 git 直接采用准备好的合并信息。
    func mergeContinue(projectPath: String) async throws {
        let output = try await git(["-c", "core.editor=true", "merge", "--continue"],
                                   in: projectPath, timeout: Self.networkTimeout)
        guard output.succeeded else {
            let detail = [output.stderr, output.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if detail.lowercased().contains("unmerged") || detail.lowercased().contains("conflict") {
                throw GitError.mergeConflict(detail)
            }
            throw GitError.commandFailed("无法完成合并", detail: detail.isEmpty ? nil : detail)
        }
    }

    // MARK: - 引用日志

    func reflog(projectPath: String, limit: Int = 60) async throws -> [GitReflogEntry] {
        let output = try await git(["reflog", "-n", "\(max(1, min(limit, 500)))",
                                    "--format=%h%x1f%gd%x1f%gs%x1f%cI"], in: projectPath)
        guard output.succeeded else {
            if Self.isUnbornRepository(output.stderr) { return [] }
            throw Self.translate(output, projectPath: projectPath)
        }
        return output.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            return GitReflogEntry(hash: parts[0], selector: parts[1], message: parts[2], date: parts[3])
        }
    }

    // MARK: - Worktree

    /// Worktree 的目录名：分支名里的 `/` 等字符换成 `-`。
    static func worktreeSlug(_ branch: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var slug = ""
        var pendingDash = false
        for scalar in branch.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if allowed.contains(scalar) {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        return slug.isEmpty ? "worktree" : slug
    }

    /// 新建分支并在 `项目根/.worktrees/{slug}` 检出。执行前逐项检查，任何一项不满足都不动磁盘：
    /// 是仓库 → 分支名合法 → 分支不存在 → 基准引用存在 → 目标路径在项目内 → 目标路径未被占用。
    func createWorktree(_ input: CreateWorktreeInput) async throws -> WorktreeResult {
        let projectPath = input.projectPath
        guard await isRepository(path: projectPath) else { throw GitError.notARepository(projectPath) }
        let branch = input.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        try await validateBranchName(branch, in: projectPath)
        if try await localBranchExists(branch, in: projectPath) { throw GitError.branchExists(branch) }

        let base: String
        if let given = input.baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
            try Self.requireSafeRevision(given)
            base = given
        } else {
            base = "HEAD"
        }
        let baseCheck = try await git(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: projectPath)
        guard baseCheck.succeeded else {
            throw GitError.commandFailed("基准分支不存在或仓库还没有提交：\(base)", recoverable: true)
        }

        let root = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().standardizedFileURL
        let container = root.appendingPathComponent(".worktrees", isDirectory: true)
        let target: URL
        if let custom = input.path?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            target = URL(fileURLWithPath: custom, relativeTo: root).standardizedFileURL
        } else {
            target = container.appendingPathComponent(Self.worktreeSlug(branch), isDirectory: true)
        }
        guard target.path.hasPrefix(root.path + "/") else {
            throw GitError.permissionDenied("Worktree 路径必须在项目目录内：\(target.path)")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            throw GitError.worktreePathExists(target.path)
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw GitError.permissionDenied("无法创建目录 \(target.deletingLastPathComponent().path)：\(error.localizedDescription)")
        }
        await excludeWorktreesDirectory(in: projectPath)

        let output = try await git(["worktree", "add", target.path, "-b", branch, base],
                                   in: projectPath, timeout: Self.networkTimeout)
        guard output.succeeded else {
            let lower = output.stderr.lowercased()
            if lower.contains("already exists") {
                throw lower.contains("branch")
                    ? GitError.branchExists(branch, detail: output.stderr)
                    : GitError.worktreePathExists(target.path, detail: output.stderr)
            }
            throw Self.translate(output, projectPath: projectPath)
        }
        return WorktreeResult(path: target.path, branch: branch)
    }

    /// 移除一个附加 worktree（主工作树不可移除）。分支保留。
    func removeWorktree(_ input: RemoveWorktreeInput) async throws {
        let list = try await worktrees(projectPath: input.projectPath)
        let wanted = URL(fileURLWithPath: input.path).resolvingSymlinksInPath().standardizedFileURL.path
        guard let index = list.firstIndex(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == wanted
        }) else {
            throw GitError.commandFailed("不是这个仓库的 Worktree：\(input.path)", recoverable: false)
        }
        guard index > 0 else {
            throw GitError.commandFailed("主工作树不能移除", recoverable: false)
        }
        var arguments = ["worktree", "remove"]
        if input.force { arguments.append("--force") }
        arguments.append(list[index].path)
        let output = try await git(arguments, in: input.projectPath, timeout: 60)
        guard output.succeeded else {
            let lower = output.stderr.lowercased()
            if lower.contains("contains modified or untracked files") || lower.contains("is dirty") {
                throw GitError.dirtyWorktree(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw Self.translate(output, projectPath: input.projectPath)
        }
    }

    /// 把 `.worktrees/` 写进 `.git/info/exclude`（只影响本机，不改仓库里的 .gitignore），
    /// 否则每个 worktree 目录都会作为未跟踪内容出现在主工作区的变更列表里。
    private func excludeWorktreesDirectory(in projectPath: String) async {
        guard let output = try? await git(["rev-parse", "--git-common-dir"], in: projectPath),
              output.succeeded else { return }
        let raw = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonDir = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: projectPath).appendingPathComponent(raw)
        let file = commonDir.appendingPathComponent("info/exclude")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(".worktrees/") && !lines.contains(".worktrees") else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let prefix = existing.isEmpty || existing.hasSuffix("\n") ? existing : existing + "\n"
        try? (prefix + ".worktrees/\n").write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - 进程封装

    private func git(_ arguments: [String], in projectPath: String,
                     timeout: TimeInterval = ProcessRunner.defaultTimeout) async throws -> ProcessOutput {
        do {
            // 没有终端可以输密码：关掉交互式凭据提示，认证失败直接报错而不是挂到超时。
            return try await runner.run("env",
                                        arguments: ["GIT_TERMINAL_PROMPT=0", "git", "-C", projectPath] + arguments,
                                        timeout: timeout)
        } catch let error as ProcessRunnerError {
            throw GitError.commandFailed(error.message)
        }
    }

    private func gitChecked(_ arguments: [String], in projectPath: String,
                            timeout: TimeInterval = ProcessRunner.defaultTimeout) async throws -> ProcessOutput {
        let output = try await git(arguments, in: projectPath, timeout: timeout)
        guard output.succeeded else { throw Self.translate(output, projectPath: projectPath) }
        return output
    }

    // MARK: - 输出解析

    private struct BranchHeader {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var detached = false
    }

    private static func parseStatus(_ raw: String, projectPath: String) -> GitStatusSnapshot {
        var fields = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if fields.last?.isEmpty == true { fields.removeLast() }

        var header = BranchHeader()
        var index = 0
        if let first = fields.first, first.hasPrefix("## ") {
            header = parseBranchHeader(String(first.dropFirst(3)))
            index = 1
        }

        var files: [GitFile] = []
        while index < fields.count {
            let entry = fields[index]
            index += 1
            let chars = Array(entry)
            guard chars.count >= 3 else { continue }
            let x = String(chars[0])
            let y = String(chars[1])
            var path = String(chars[3...])
            var oldPath: String?

            // porcelain v1 -z 的重命名格式：`XY <新路径>\0<旧路径>\0`。
            if (x == "R" || x == "C"), index < fields.count {
                oldPath = fields[index]
                index += 1
            }
            if path.isEmpty { path = oldPath ?? "" }
            guard !path.isEmpty else { continue }

            let untracked = x == "?" && y == "?"
            let state: GitFile.State
            if untracked {
                state = .untracked
            } else if x == "D" || y == "D" {
                state = .deleted
            } else if x == "A" || x == "C" || x == "R" {
                state = .added
            } else {
                state = .modified
            }
            let label: String
            switch state {
            case .untracked: label = "?"
            case .deleted: label = "D"
            case .added: label = "A"
            case .modified: label = "M"
            }
            files.append(GitFile(path: path,
                                 oldPath: oldPath,
                                 kind: FileKind(path: path),
                                 state: state,
                                 label: label,
                                 staged: !untracked && x != " " && x != "?",
                                 unstaged: !untracked && y != " " && y != "?",
                                 untracked: untracked,
                                 indexStatus: x,
                                 workTreeStatus: y,
                                 binary: nil))
        }

        return GitStatusSnapshot(projectPath: projectPath,
                                 branch: header.branch,
                                 detachedHead: header.detached,
                                 upstream: header.upstream,
                                 ahead: header.ahead,
                                 behind: header.behind,
                                 files: files)
    }

    private static func parseBranchHeader(_ raw: String) -> BranchHeader {
        var header = BranchHeader()
        var text = raw
        if text.hasPrefix("No commits yet on ") {
            header.branch = String(text.dropFirst("No commits yet on ".count))
            return header
        }
        if text.hasPrefix("HEAD (no branch)") {
            header.detached = true
            return header
        }
        if let range = text.range(of: " [") {
            let track = String(text[range.lowerBound...])
            header.ahead = trackCount("ahead ", in: track)
            header.behind = trackCount("behind ", in: track)
            text = String(text[..<range.lowerBound])
        }
        if let range = text.range(of: "...") {
            header.branch = String(text[..<range.lowerBound])
            let upstream = String(text[range.upperBound...])
            header.upstream = upstream.isEmpty ? nil : upstream
        } else if !text.isEmpty {
            header.branch = text
        }
        return header
    }

    private static func trackCount(_ keyword: String, in track: String) -> Int {
        guard let range = track.range(of: keyword) else { return 0 }
        let digits = track[range.upperBound...].prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private static func parseNumstat(_ raw: String) -> [GitCommitFile] {
        raw.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return nil }
            // 重命名时 numstat 是 `add\tdel\told => new`，只保留展示用的后一段。
            let path = parts[2].contains(" => ")
                ? parts[2].components(separatedBy: " => ").last ?? parts[2]
                : parts[2]
            let binary = parts[0] == "-" || parts[1] == "-"
            return GitCommitFile(path: path,
                                 additions: Int(parts[0]) ?? 0,
                                 deletions: Int(parts[1]) ?? 0,
                                 binary: binary)
        }
    }

    private static func countPatchLines(_ patch: String) -> (Int, Int) {
        var additions = 0
        var deletions = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+") && !line.hasPrefix("+++") { additions += 1 }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { deletions += 1 }
        }
        return (additions, deletions)
    }

    /// 接受 40 位哈希、短哈希，以及 `HEAD` / 分支名 / tag 这类修订名。
    /// 只挡两类危险输入：以 `-` 开头（会被 git 当成选项）和带空白/控制字符的串。
    private static func isValidRevision(_ hash: String) -> Bool {
        guard !hash.isEmpty, hash.count <= 256, !hash.hasPrefix("-") else { return false }
        return hash.unicodeScalars.allSatisfy { scalar in
            scalar != " " && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func isUnbornRepository(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("does not have any commits")
            || lower.contains("unknown revision")
            || lower.contains("bad default revision")
    }

    /// 把 git 的 stderr 翻成 SPEC §11.1 的错误码。只读路径能确定的三类在这里判，
    /// 写路径的 BRANCH_EXISTS / WORKTREE_PATH_EXISTS 留给 T7 / T8 / T11 在调用前判定。
    private static func translate(_ output: ProcessOutput, projectPath: String) -> GitError {
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = detail.lowercased()
        if lower.contains("not a git repository") {
            return .notARepository(projectPath, detail: detail)
        }
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return .permissionDenied(detail.isEmpty ? "没有权限：\(projectPath)" : detail)
        }
        if lower.contains("would be overwritten") || lower.contains("your local changes") {
            return .dirtyWorktree(detail)
        }
        if lower.contains("conflict") {
            return .mergeConflict(detail)
        }
        return .commandFailed("git 执行失败（退出码 \(output.exitCode)）",
                              detail: detail.isEmpty ? nil : detail)
    }
}

// MARK: - 便捷重载

/// `Project` 来自 `Models.swift`（同一 target）。这里只取 `path`，
/// 不让能力层依赖 UI 模型的其它字段。
extension GitService {
    func isRepository(project: Project) async -> Bool {
        let path = project.path
        return await isRepository(path: path)
    }

    func status(project: Project) async throws -> GitStatusSnapshot {
        let path = project.path
        return try await status(projectPath: path)
    }

    func log(project: Project, limit: Int = 50) async throws -> [GitCommit] {
        let path = project.path
        return try await log(projectPath: path, limit: limit)
    }

    func branches(project: Project) async throws -> [GitBranchInfo] {
        let path = project.path
        return try await branches(projectPath: path)
    }

    func tags(project: Project) async throws -> [GitTag] {
        let path = project.path
        return try await tags(projectPath: path)
    }

    func remotes(project: Project) async throws -> [GitRemote] {
        let path = project.path
        return try await remotes(projectPath: path)
    }

    func worktrees(project: Project) async throws -> [GitWorktreeInfo] {
        let path = project.path
        return try await worktrees(projectPath: path)
    }

    func currentBranch(project: Project) async throws -> String {
        let path = project.path
        return try await currentBranch(projectPath: path)
    }
}
