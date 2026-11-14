import Foundation

/// T4 卡（task-5）：`git.log` 的桥接版本。
///
/// `GitService.swift` 本体只提供 `log(projectPath:limit:)`，而 `protocol.js` 声明的
/// 是 `GitService.log(projectPath:limit:skip:branch:)`（分页 + 指定分支）。本卡不改本体
/// （其它卡正在并行改它），按协议签名在扩展里补齐；参数都不给默认值，避免与既有
/// `log(projectPath:limit:)` 在 `log(projectPath:)` 这种调用上产生重载歧义。
extension GitService {
    func log(projectPath: String, limit: Int, skip: Int, branch: String?) async throws -> [GitCommit] {
        guard limit > 0 else { return [] }

        var revision: [String] = []
        if let branch, !branch.isEmpty {
            guard Self.readIsSafeRevision(branch) else {
                throw GitError.commandFailed("非法的分支名：\(branch)", recoverable: false)
            }
            revision = [branch]
        }

        let format = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%s"
        var arguments = ["log", "--max-count=\(limit)"]
        if skip > 0 { arguments.append("--skip=\(skip)") }
        arguments += revision
        arguments.append("--pretty=format:\(format)")

        let output = try await readGit(arguments, in: projectPath, timeout: 60)
        guard output.succeeded else {
            // 空仓库没有 HEAD，`git log` 会失败；这是「0 条提交」，不是错误。
            if Self.readIsUnbornRepository(output.stderr) { return [] }
            throw Self.readFailure(output, projectPath: projectPath)
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

    // MARK: - 只读命令

    /// 与 `GitService.swift` 的私有 `git(_:in:timeout:)` 同一形状：仍然只经 `ProcessRunner`
    /// 起 `/bin/zsh -lc` + 参数数组，不在这里另起 `Process`，也不拼 shell 字符串。
    private func readGit(_ arguments: [String],
                         in projectPath: String,
                         timeout: TimeInterval) async throws -> ProcessOutput {
        do {
            return try await runner.run("git", arguments: ["-C", projectPath] + arguments, timeout: timeout)
        } catch let error as ProcessRunnerError {
            throw GitError.commandFailed(error.message)
        }
    }

    /// 只读路径能确定的三类错误码，与 `GitService.swift` 的 `translate` 保持一致。
    /// （本体的 `translate` 是 private，扩展里够不到，所以在这里判同一组 stderr 特征。）
    private static func readFailure(_ output: ProcessOutput, projectPath: String) -> GitError {
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = detail.lowercased()
        if lower.contains("not a git repository") {
            return .notARepository(projectPath, detail: detail)
        }
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return .permissionDenied(detail.isEmpty ? "没有权限：\(projectPath)" : detail)
        }
        return .commandFailed("git 执行失败（退出码 \(output.exitCode)）",
                              detail: detail.isEmpty ? nil : detail)
    }

    private static func readIsUnbornRepository(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("does not have any commits")
            || lower.contains("unknown revision")
            || lower.contains("bad default revision")
    }

    /// 与本体 `isValidRevision` 同一规则：挡 `-` 开头（会被 git 当选项）和空白/控制字符。
    private static func readIsSafeRevision(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar != " " && !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}
