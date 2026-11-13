import Foundation

// Compiled together with Git.swift; uses isolated repositories, never the checkout's index.
@main
struct GitRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    @discardableResult
    static func git(_ args: [String], at path: String) throws -> String {
        let (code, output) = GitRunner.runSync(args, cwd: path)
        try check(code == 0, "git \(args): \(output)")
        return output
    }

    static func status(_ path: String) async -> GitStatus {
        await withCheckedContinuation { continuation in
            GitRunner.fetchStatus(cwd: path) { continuation.resume(returning: $0) }
        }
    }

    static func branches(_ path: String) async -> [GitBranch] {
        await withCheckedContinuation { continuation in
            GitRunner.fetchBranches(cwd: path) { list, _ in continuation.resume(returning: list) }
        }
    }

    static func trees(_ path: String) async -> [GitWorktree] {
        await withCheckedContinuation { continuation in
            GitRunner.fetchWorktrees(cwd: path) { list, _ in continuation.resume(returning: list) }
        }
    }

    static func perform(_ commands: [[String]], at path: String) async -> GitActionResult {
        await withCheckedContinuation { continuation in
            GitRunner.perform(commands, cwd: path) { continuation.resume(returning: $0) }
        }
    }

    static func diff(_ args: [String], at path: String) async -> String {
        await withCheckedContinuation { continuation in
            GitRunner.fetchDiff(args, cwd: path) { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("picker-git-test-\(UUID())")
        let repo = base.appendingPathComponent("repo").path
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try git(["init", "-b", "main"], at: repo)
        try git(["config", "user.name", "Git Regression"], at: repo)
        try git(["config", "user.email", "git-test@example.invalid"], at: repo)
        try git(["config", "commit.gpgsign", "false"], at: repo)
        try git(["config", "core.hooksPath", "/dev/null"], at: repo)
        let initial = await status(repo)
        try check(initial.branch == "main" && !initial.hasHead && !initial.detached, "unborn branch")
        print("PASS unborn branch")

        let filename = "中文 \"quoted\" -> tab\tline\n[literal].txt"
        let file = URL(fileURLWithPath: repo).appendingPathComponent(filename)
        try "first\n".write(to: file, atomically: true, encoding: .utf8)
        let untracked = await status(repo)
        try check(untracked.changes.count == 1 && untracked.changes[0].path == filename, "NUL filename parsing")
        let newDiff = await diff(["diff", "--no-index", "--", "/dev/null", filename], at: repo)
        try check(newDiff.contains("+first") && !newDiff.contains("执行失败"), "no-index exit 1 is success")
        try git(["add", "--", filename], at: repo)
        try git(["rm", "--cached", "-r", "--", "."], at: repo)
        try check(fm.fileExists(atPath: file.path), "unborn unstage preserves file")
        print("PASS special filenames, untracked diff, unborn unstage")

        try git(["add", "--", filename], at: repo)
        try git(["commit", "-m", "initial"], at: repo)
        let renamed = "重命名 -> new\nfile.txt"
        try git(["mv", "--", filename, renamed], at: repo)
        let renamedStatus = await status(repo)
        try check(renamedStatus.changes.count == 1, "rename is one entry")
        let change = renamedStatus.changes[0]
        try check(change.path == renamed && change.originalPath == filename, "rename preserves both paths")
        try git(["reset", "--"] + change.paths, at: repo)
        let afterReset = await status(repo)
        try check(afterReset.stagedCount == 0, "unstage rename removes both index changes")
        try git(["add", "-A"], at: repo)
        try git(["commit", "-m", "rename"], at: repo)
        print("PASS rename and unstage both paths")

        let renamedURL = URL(fileURLWithPath: repo).appendingPathComponent(renamed)
        try "staged\n".write(to: renamedURL, atomically: true, encoding: .utf8)
        try git(["add", "--", renamed], at: repo)
        try "unstaged\n".write(to: renamedURL, atomically: true, encoding: .utf8)
        let mixed = await status(repo)
        try check(mixed.changes[0].staged && mixed.changes[0].unstaged, "mixed index/worktree state")
        try git(["restore", "--worktree", "--", renamed], at: repo)
        let restored = try String(contentsOf: renamedURL, encoding: .utf8)
        try check(restored == "staged\n", "discard preserves staged content")
        try git(["commit", "-m", "staged"], at: repo)
        print("PASS mixed state and discard preserves index")

        let failure = await perform([["check-ref-format", "--branch", "bad name"], ["branch", "must-not-exist"]], at: repo)
        try check(!failure.ok, "failed action reports failure")
        let afterFailure = await branches(repo)
        try check(!afterFailure.contains(where: { $0.name == "must-not-exist" }), "command group stops on failure")
        print("PASS stop command group on failure")

        let remote = base.appendingPathComponent("remote.git").path
        try git(["init", "--bare", remote], at: repo)
        try git(["remote", "add", "origin", remote], at: repo)
        try git(["push", "--set-upstream", "--", "origin", "main"], at: repo)
        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], at: repo)
        try git(["branch", "origin/main"], at: repo)
        let branchList = await branches(repo)
        let sameNames = branchList.filter { $0.name == "origin/main" }
        try check(sameNames.count == 2 && Set(sameNames.map(\.id)).count == 2, "local/remote distinction and identity")
        try check(!branchList.contains(where: { $0.name == "origin/HEAD" }), "skip symbolic remote HEAD")
        let tracked = await status(repo)
        try check(tracked.remotes == ["origin"] && tracked.upstream == "origin/main", "remote and upstream status")
        try git(["branch", "feature/nested", "main"], at: remote)
        try git(["fetch", "origin"], at: repo)
        try git(["switch", "--track", "-c", "feature/nested", "--", "refs/remotes/origin/feature/nested"], at: repo)
        try git(["switch", "--", "main"], at: repo)
        try git(["commit", "--allow-empty", "-m", "ahead"], at: repo)
        let ahead = await status(repo)
        try check(ahead.ahead == 1 && ahead.behind == 0, "ahead counts")
        print("PASS remote branches, initial push, tracking, ahead counts")

        let wt = base.appendingPathComponent("工作树\nwith space").path
        try git(["worktree", "add", "-b", "worktree-test", "--", wt], at: repo)
        let worktrees = await trees(repo)
        try check(worktrees.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == URL(fileURLWithPath: wt).resolvingSymlinksInPath() && $0.branch == "worktree-test" }), "worktree NUL parsing: expected \(wt.debugDescription); actual \(worktrees.map { ($0.path, $0.branch) })")
        try "keep".write(toFile: wt + "/dirty.txt", atomically: true, encoding: .utf8)
        let remove = await perform([["worktree", "remove", "--", wt]], at: repo)
        try check(!remove.ok && fm.fileExists(atPath: wt + "/dirty.txt"), "dirty worktree removal refuses")
        print("PASS worktree parsing and dirty removal protection")

        try git(["switch", "--detach"], at: repo)
        let detached = await status(repo)
        try check(detached.detached && detached.hasHead, "detached status")
        try git(["switch", "main"], at: repo)
        try check(!GitFileChange(status: "UU", path: "conflict").staged, "conflict isn't committable staged change")
        try git(["branch", "conflict-side"], at: repo)
        try "main-side\n".write(to: renamedURL, atomically: true, encoding: .utf8)
        try git(["commit", "-am", "main side"], at: repo)
        try git(["switch", "conflict-side"], at: repo)
        try "other-side\n".write(to: renamedURL, atomically: true, encoding: .utf8)
        try git(["commit", "-am", "other side"], at: repo)
        try git(["switch", "main"], at: repo)
        let merge = await perform([["merge", "conflict-side"]], at: repo)
        let conflict = await status(repo)
        try check(!merge.ok && conflict.changes.contains(where: \.conflicted) && conflict.stagedCount == 0, "real merge conflict status")
        try git(["merge", "--abort"], at: repo)
        let readError: String? = await withCheckedContinuation { continuation in
            GitRunner.fetchBranches(cwd: base.path) { _, error in continuation.resume(returning: error) }
        }
        try check(readError != nil, "branch read failure is reported")
        print("PASS detached, real merge conflicts, and list errors")

        let large = String(repeating: "large diff output exceeds a pipe buffer\n", count: 12000)
        try large.write(to: renamedURL, atomically: true, encoding: .utf8)
        let largeDiff = await diff(["diff", "--", renamed], at: repo)
        try check(largeDiff.utf8.count > 400_000 && largeDiff.contains("+large diff"), "large output drains without deadlock")
        let badDiff = await diff(["show", "not-a-revision"], at: repo)
        try check(badDiff.contains("执行失败"), "diff error visible")
        print("PASS large diff and error output")
        print("All Git regression checks passed")
    }
}
