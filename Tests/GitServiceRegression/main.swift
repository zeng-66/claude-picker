import Foundation

// GitService / FileService 回归自检。独立编译：
//   swiftc Sources/ClaudeDeck/Models.swift Sources/ClaudeDeck/Git/*.swift \
//          Tests/GitServiceRegression/main.swift -o /tmp/gitreg && /tmp/gitreg
// 不对接 Package.swift 的测试目标（项目既有回归脚本都是这套玩法）。

var failures = 0

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL \(message)")
    }
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// 用 shell 拿「标准答案」——故意不走被测的 ProcessRunner，避免自己验自己。
func shell(_ command: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func shellCount(_ command: String) -> Int {
    Int(shell(command).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
}

let repo = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let git = GitService()
let files = FileService()

// MARK: - 1. 对 claude-picker 自身跑只读方法，和 git 命令行逐条对数

do {
    let snapshot = try await git.status(projectPath: repo)
    let expected = shellCount("git -C \(shellQuote(repo)) status --porcelain | wc -l")
    check(snapshot.files.count == expected,
          "status 条数 \(snapshot.files.count) != git status --porcelain \(expected)")

    let commits = try await git.log(projectPath: repo, limit: 20)
    let expectedCommits = shellCount("git -C \(shellQuote(repo)) log --oneline -20 | wc -l")
    check(commits.count == expectedCommits,
          "log 条数 \(commits.count) != git log --oneline -20 \(expectedCommits)")
    check(commits.allSatisfy { !$0.hash.isEmpty && $0.hash.count == 40 }, "log 每条的 hash 都是完整 40 位")

    let branches = try await git.branches(projectPath: repo)
    let expectedBranches = shellCount("git -C \(shellQuote(repo)) branch -a | grep -vF -- \" -> \" | wc -l")
    check(branches.count == expectedBranches,
          "branches 条数 \(branches.count) != git branch -a \(expectedBranches)")
    check(branches.filter(\.isCurrent).count == 1, "branches 恰好一个 isCurrent")

    let expectedBranch = shell("git -C \(shellQuote(repo)) rev-parse --abbrev-ref HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = try await git.currentBranch(projectPath: repo)
    check(branch == expectedBranch, "currentBranch \(branch) != \(expectedBranch)")

    let worktrees = try await git.worktrees(projectPath: repo)
    let expectedWorktrees = shell("git -C \(shellQuote(repo)) worktree list --porcelain | grep -c '^worktree '")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    check(String(worktrees.count) == expectedWorktrees,
          "worktrees 条数 \(worktrees.count) != \(expectedWorktrees)")

    let isRepo = await git.isRepository(path: repo)
    check(isRepo, "isRepository 对自身应为 true")
} catch {
    failures += 1
    print("FAIL 只读方法抛出异常：\(error)")
}

// MARK: - 2. 非仓库 → NOT_A_REPOSITORY

do {
    _ = try await git.status(projectPath: "/tmp")
    failures += 1
    print("FAIL /tmp 不是仓库，status 应当抛错")
} catch let error as GitError {
    check(error.code == .notARepository, "/tmp 的错误码应为 NOT_A_REPOSITORY，实际 \(error.code.rawValue)")
} catch {
    failures += 1
    print("FAIL /tmp 抛的不是 GitError：\(error)")
}

// MARK: - 3. 越界路径 → PERMISSION_DENIED

do {
    _ = try await files.read(projectPath: repo, path: "../../../etc/passwd")
    failures += 1
    print("FAIL 越界读取应当被拒绝")
} catch let error as GitError {
    check(error.code == .permissionDenied, "../../../etc/passwd 的错误码应为 PERMISSION_DENIED，实际 \(error.code.rawValue)")
} catch {
    failures += 1
    print("FAIL 越界读取抛的不是 GitError：\(error)")
}

do {
    _ = try await files.read(projectPath: repo, path: "/etc/passwd")
    failures += 1
    print("FAIL 绝对路径 /etc/passwd 应当被拒绝")
} catch let error as GitError {
    check(error.code == .permissionDenied, "绝对路径的错误码应为 PERMISSION_DENIED，实际 \(error.code.rawValue)")
}

// MARK: - 4. 正常读文件 + 目录列举

do {
    let content = try await files.read(projectPath: repo, path: "Package.swift")
    check(content.content?.contains("ClaudeDeck") == true, "Package.swift 应能读出内容")
    check(!content.isBinary, "Package.swift 不应判成二进制")
    check(content.size > 0 && !content.truncated, "Package.swift 的 size/truncated 应正常")

    let rootNodes = try await files.list(projectPath: repo)
    check(!rootNodes.contains { $0.name == ".git" }, "list 默认不返回 .git")
    check(!rootNodes.contains { $0.name == "node_modules" }, "list 默认不返回 node_modules")
    check(rootNodes.contains { $0.name == "Package.swift" }, "list 应返回 Package.swift")

    let withIgnored = try await files.list(projectPath: repo, includeIgnored: true)
    check(withIgnored.contains { $0.name == ".git" }, "includeIgnored 时应返回 .git")
} catch {
    failures += 1
    print("FAIL 文件读取/列举抛出异常：\(error)")
}

// MARK: - 5. 单引号路径：证明 shell 转义没把参数拼坏

do {
    let weird = FileManager.default.temporaryDirectory
        .appendingPathComponent("git service 'regression' \(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: weird, withIntermediateDirectories: true)
    _ = shell("git -C \(shellQuote(weird.path)) init -q")
    try "hello\n".write(to: weird.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

    let snapshot = try await git.status(projectPath: weird.path)
    check(snapshot.files.count == 1, "单引号路径下 status 应只有 1 条，实际 \(snapshot.files.count)")
    check(snapshot.files.first?.state == .untracked, "a.txt 应为 untracked")
    let weirdIsRepo = await git.isRepository(path: weird.path)
    check(weirdIsRepo, "单引号路径也应识别为仓库")
    try? FileManager.default.removeItem(at: weird)
} catch {
    failures += 1
    print("FAIL 单引号路径失败（shell 转义可能有问题）：\(error)")
}

// MARK: - 6. 错误体可编码（T3 直接进桥信封）

do {
    let data = try JSONEncoder().encode(GitError.notARepository("/tmp"))
    let json = String(decoding: data, as: UTF8.self)
    check(json.contains("\"code\":\"NOT_A_REPOSITORY\""), "错误体应含 code=NOT_A_REPOSITORY，实际 \(json)")
    check(json.contains("\"recoverable\":"), "错误体应含 recoverable")
}

// MARK: - 7. detached HEAD → DETACHED_HEAD

do {
    let detached = FileManager.default.temporaryDirectory
        .appendingPathComponent("git-service-detached-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: detached, withIntermediateDirectories: true)
    func run(_ arguments: [String]) async throws -> String {
        let output = try await ProcessRunner.shared.run(
            "/usr/bin/git", arguments: arguments, workingDirectory: detached.path)
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    _ = try await run(["init", "-q"])
    try "x\n".write(to: detached.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    _ = try await run(["add", "."])
    _ = try await run(["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "init"])
    let head = try await run(["rev-parse", "HEAD"])
    let before = try await git.currentBranch(projectPath: detached.path)
    check(before == "master" || before == "main", "detached 前应能取到分支名，实际 \(before)")
    _ = try await run(["checkout", "-q", head])
    do {
        _ = try await git.currentBranch(projectPath: detached.path)
        failures += 1
        print("FAIL detached HEAD 下 currentBranch 应当抛错")
    } catch let error as GitError {
        check(error.code == .detachedHead, "detached HEAD 的错误码应为 DETACHED_HEAD，实际 \(error.code.rawValue)")
    }
    try? FileManager.default.removeItem(at: detached)
} catch {
    failures += 1
    print("FAIL detached HEAD 用例准备失败：\(error)")
}

// MARK: - 8. 暂存 / 提交 / Stash / 文件保存（只在临时仓库里做，绝不碰真实项目）

do {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("gitreg-write-\(UUID().uuidString)").path
    let q = shellQuote
    // 临时目录可能经过符号链接（/var → /private/var）；统一用 realpath，和能力层返回的路径可比。
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    let work = URL(fileURLWithPath: base).resolvingSymlinksInPath().path + "/work"
    _ = shell("""
        git init -q -b main \(q(work)) && cd \(q(work)) && \
        git config user.email t@t && git config user.name t
        """)
    let porcelain = { shell("git -C \(q(work)) status --porcelain") }

    // 还没有任何提交的仓库：暂存 → 取消暂存（没有 HEAD，走 rm --cached）
    try "one\n".write(toFile: work + "/a.txt", atomically: true, encoding: .utf8)
    try await git.stage(projectPath: work, paths: ["a.txt"])
    check(porcelain().hasPrefix("A  a.txt"), "空仓库 stage 后应为 A，实际 \(porcelain())")
    try await git.unstage(projectPath: work, paths: ["a.txt"])
    check(porcelain().hasPrefix("?? a.txt"), "空仓库 unstage 后应回到未跟踪，实际 \(porcelain())")

    // 提交：空消息拒绝；正常提交；提交后工作区干净
    try await git.stage(projectPath: work, paths: ["a.txt"])
    do {
        _ = try await git.commit(projectPath: work, message: "   ")
        failures += 1; print("FAIL 空提交信息应当被拒绝")
    } catch is GitError {}
    let first = try await git.commit(projectPath: work, message: "first")
    check(first.hash.count == 40 && !first.amended, "commit 应返回完整哈希")
    check(shell("git -C \(q(work)) log -1 --format=%s").contains("first"), "git log 应能看到提交")
    check(porcelain().isEmpty, "提交后工作区应干净")

    // 没有暂存内容时提交：报错而不是假成功
    do {
        _ = try await git.commit(projectPath: work, message: "empty")
        failures += 1; print("FAIL 没有暂存内容时提交应当报错")
    } catch let error as GitError {
        check(error.code == .commandFailed, "空提交错误码应为 COMMAND_FAILED，实际 \(error.code.rawValue)")
    }
    let allowed = try await git.commit(projectPath: work, message: "empty ok",
                                       options: CommitOptions(allowEmpty: true))
    check(!allowed.hash.isEmpty, "--allow-empty 应能提交")

    // amend：不产生新提交，只改写最近一条
    let countBefore = shellCount("git -C \(q(work)) rev-list --count HEAD")
    let amended = try await git.commit(projectPath: work, message: "empty renamed",
                                       options: CommitOptions(amend: true, allowEmpty: true))
    check(amended.amended, "amend 结果应带 amended = true")
    check(shellCount("git -C \(q(work)) rev-list --count HEAD") == countBefore, "amend 不应增加提交数")
    check(shell("git -C \(q(work)) log -1 --format=%s").contains("empty renamed"), "amend 应改写提交信息")

    // 有 HEAD 之后：修改 → 暂存（M 在索引列）→ 取消暂存（M 在工作区列）；文件名带空格和冒号
    try "two\n".write(toFile: work + "/a.txt", atomically: true, encoding: .utf8)
    try "x\n".write(toFile: work + "/odd: name [1].txt", atomically: true, encoding: .utf8)
    try await git.stage(projectPath: work, paths: ["a.txt", "odd: name [1].txt"])
    let staged = try await git.status(projectPath: work)
    check(staged.files.allSatisfy { $0.staged && !$0.unstaged }, "stage 后两个文件都应只在索引里")
    try await git.unstage(projectPath: work, paths: ["a.txt", "odd: name [1].txt"])
    let unstaged = try await git.status(projectPath: work)
    check(unstaged.files.allSatisfy { !$0.staged }, "unstage 后索引里不应再有变更")

    // 删除也能暂存
    try await git.stage(projectPath: work, paths: ["a.txt", "odd: name [1].txt"])
    _ = try await git.commit(projectPath: work, message: "second")
    try FileManager.default.removeItem(atPath: work + "/odd: name [1].txt")
    try await git.stage(projectPath: work, paths: ["odd: name [1].txt"])
    check(porcelain().hasPrefix("D  "), "删除的文件 stage 后应为 D，实际 \(porcelain())")
    try await git.unstage(projectPath: work, paths: ["odd: name [1].txt"])
    _ = shell("git -C \(q(work)) checkout -q -- .")

    // Stash：保存（含未跟踪）→ 列表 → 应用 → 弹出 → 删除
    do {
        try await git.stashSave(projectPath: work, message: nil)
        failures += 1; print("FAIL 干净工作区保存 stash 应当报错")
    } catch is GitError {}
    try "three\n".write(toFile: work + "/a.txt", atomically: true, encoding: .utf8)
    try "new\n".write(toFile: work + "/new.txt", atomically: true, encoding: .utf8)
    try await git.stashSave(projectPath: work, message: "wip one", includeUntracked: true)
    check(porcelain().isEmpty, "stashSave 后工作区应干净")
    var stashes = try await git.stashes(projectPath: work)
    check(stashes.count == 1 && stashes[0].message.contains("wip one"), "stashes 应列出刚保存的一条")
    try await git.stashApply(projectPath: work, index: 0)
    check(porcelain().contains("a.txt") && porcelain().contains("new.txt"), "stashApply 应恢复变更")
    stashes = try await git.stashes(projectPath: work)
    check(stashes.count == 1, "apply 之后记录仍在")
    _ = shell("cd \(q(work)) && git checkout -q -- . && git clean -fdq")
    try await git.stashPop(projectPath: work, index: 0)
    stashes = try await git.stashes(projectPath: work)
    check(stashes.isEmpty && !porcelain().isEmpty, "stashPop 应恢复变更并移除记录")
    try await git.stashSave(projectPath: work, message: "wip two", includeUntracked: true)
    try await git.stashDrop(projectPath: work, index: 0)
    stashes = try await git.stashes(projectPath: work)
    check(stashes.isEmpty, "stashDrop 应删除记录")

    // 文件保存：原子写、mtime 比对、越界拒绝、保留可执行位
    try "#!/bin/sh\necho hi\n".write(toFile: work + "/run.sh", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work + "/run.sh")
    let before = try await files.read(projectPath: work, path: "run.sh")
    let savedAt = try await files.write(projectPath: work, path: "run.sh", content: "#!/bin/sh\necho bye\n",
                                        expectedModifiedAt: before.modifiedAt)
    let after = try await files.read(projectPath: work, path: "run.sh")
    check(after.content == "#!/bin/sh\necho bye\n", "write 后应读到新内容")
    check(after.modifiedAt == savedAt, "write 返回的 mtime 应与随后 read 的一致")
    let mode = (try FileManager.default.attributesOfItem(atPath: work + "/run.sh")[.posixPermissions] as? NSNumber)?.intValue
    check(mode == 0o755, "write 应保留可执行位，实际 \(String(mode ?? 0, radix: 8))")
    check(shell("ls -A \(q(work))").contains(".tmp") == false, "write 不应留下临时文件")
    do {
        _ = try await files.write(projectPath: work, path: "run.sh", content: "stale",
                                  expectedModifiedAt: "2001-01-01T00:00:00Z")
        failures += 1; print("FAIL mtime 不一致时 write 应当拒绝覆盖")
    } catch let error as GitError {
        check(error.detail == FileService.staleFileMarker, "外部修改的错误应带 STALE_FILE 标记")
    }
    let untouched = try await files.read(projectPath: work, path: "run.sh")
    check(untouched.content == "#!/bin/sh\necho bye\n", "被拒绝的 write 不应改动文件")
    do {
        _ = try await files.write(projectPath: work, path: "../escape.txt", content: "x")
        failures += 1; print("FAIL 越界写入应当被拒绝")
    } catch let error as GitError {
        check(error.code == .permissionDenied, "越界写入错误码应为 PERMISSION_DENIED，实际 \(error.code.rawValue)")
    }

    try? FileManager.default.removeItem(atPath: base)
} catch {
    failures += 1
    print("FAIL 暂存 / 提交 / Stash / 保存用例：\(error)")
}

// MARK: - 9. 分支写操作：临时仓库 + 本地 bare 远程

do {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("gitreg-branch-\(UUID().uuidString)").path
    let remote = base + "/remote.git", work = base + "/work", other = base + "/other"
    let q = shellQuote
    _ = shell("""
        mkdir -p \(q(base)) && git init -q --bare -b main \(q(remote)) && \
        git init -q -b main \(q(work)) && cd \(q(work)) && \
        git config user.email t@t && git config user.name t && \
        echo a > a.txt && git add a.txt && git commit -qm init && \
        git remote add origin \(q(remote)) && git push -qu origin main 2>/dev/null
        """)
    let head = { (dir: String, ref: String) in
        shell("git -C \(q(dir)) rev-parse \(ref)").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 新建 + 重名
    try await git.createBranch(projectPath: work, branch: "feat/x")
    check(!head(work, "refs/heads/feat/x").isEmpty, "createBranch 应创建 feat/x")
    do {
        try await git.createBranch(projectPath: work, branch: "feat/x")
        failures += 1; print("FAIL 重名分支应抛 BRANCH_EXISTS")
    } catch let error as GitError {
        check(error.code == .branchExists, "重名分支错误码应为 BRANCH_EXISTS，实际 \(error.code.rawValue)")
    }

    let dirty = URL(fileURLWithPath: work).appendingPathComponent("dirty.txt")
    try "unsaved work".write(to: dirty, atomically: true, encoding: .utf8)
    do {
        try await git.switchWorkspaceBranch(projectPath: work, branch: "feat/x")
        failures += 1
        print("FAIL 工作区导航不得切换有改动的仓库")
    } catch let error as GitError {
        let branch = try await git.currentBranch(projectPath: work)
        check(error.code == .commandFailed && branch == "main", "工作区导航失败应保留原分支")
        check(FileManager.default.fileExists(atPath: dirty.path), "工作区导航失败应保留未提交文件")
    }
    try FileManager.default.removeItem(at: dirty)
    try await git.switchWorkspaceBranch(projectPath: work, branch: "feat/x")
    let cleanCheckout = try await git.currentBranch(projectPath: work)
    check(cleanCheckout == "feat/x", "干净工作区应允许导航到目标分支")
    try await git.switchBranch(projectPath: work, branch: "main")

    // 签出 + 在分支上提交 + 推送（无上游 → 建立上游）
    try await git.switchBranch(projectPath: work, branch: "feat/x")
    let afterSwitch = try await git.currentBranch(projectPath: work)
    check(afterSwitch == "feat/x", "switchBranch 后当前分支应为 feat/x")
    _ = shell("cd \(q(work)) && echo b > b.txt && git add b.txt && git commit -qm b")
    try await git.push(projectPath: work, branch: "feat/x")
    check(head(remote, "refs/heads/feat/x") == head(work, "HEAD"), "push 后远程 feat/x 应与本地一致")
    check(shell("git -C \(q(work)) config branch.feat/x.remote").contains("origin"), "首次 push 应建立上游")

    // 切回 main，把 feat/x 合并进来（快进）
    try await git.switchBranch(projectPath: work, branch: "main")
    try await git.merge(projectPath: work, branch: "feat/x")
    check(head(work, "main") == head(work, "feat/x"), "merge 后 main 应包含 feat/x")

    // 别处推一个新提交，fetch + 更新非当前分支（不切换直接快进）
    _ = shell("""
        git clone -q \(q(remote)) \(q(other)) 2>/dev/null && cd \(q(other)) && \
        git config user.email t@t && git config user.name t && git switch -q feat/x && \
        echo c > c.txt && git add c.txt && git commit -qm c && git push -q 2>/dev/null
        """)
    try await git.fetch(projectPath: work)
    try await git.pull(projectPath: work, branch: "feat/x")
    check(head(work, "refs/heads/feat/x") == head(other, "HEAD"), "pull 非当前分支应快进到远程")
    let afterPull = try await git.currentBranch(projectPath: work)
    check(afterPull == "main", "更新非当前分支不应切换分支")

    // 远程分支签出：建跟踪分支
    _ = shell("cd \(q(other)) && git switch -qc feat/y && git push -qu origin feat/y 2>/dev/null")
    try await git.fetch(projectPath: work)
    try await git.switchBranch(projectPath: work, branch: "origin/feat/y")
    let afterRemote = try await git.currentBranch(projectPath: work)
    check(afterRemote == "feat/y", "签出 origin/feat/y 应得到本地 feat/y")

    // 删除：未合并的 feat/y 之外，main 上已合并的旧分支可删；当前分支不可删
    try await git.switchBranch(projectPath: work, branch: "main")
    _ = shell("cd \(q(work)) && git branch done-branch")
    try await git.deleteBranch(projectPath: work, branch: "done-branch")
    check(shell("git -C \(q(work)) branch --list done-branch").isEmpty, "deleteBranch 应删除已合并分支")

    // 非法引用名
    do {
        try await git.switchBranch(projectPath: work, branch: "--orphan")
        failures += 1; print("FAIL 以 - 开头的分支名应被拒绝")
    } catch is GitError {}

    try? FileManager.default.removeItem(atPath: base)
} catch {
    failures += 1
    print("FAIL 分支写操作用例：\(error)")
}

// MARK: - 10. 合并冲突：状态 → 逐个解决 → 继续 / 终止

do {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("gitreg-merge-\(UUID().uuidString)").path
    let q = shellQuote
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    let work = URL(fileURLWithPath: base).resolvingSymlinksInPath().path + "/work"
    _ = shell("""
        git init -q -b main \(q(work)) && cd \(q(work)) && \
        git config user.email t@t && git config user.name t && \
        echo base > a.txt && echo base > b.txt && git add . && git commit -qm init && \
        git switch -qc feat && echo feat > a.txt && echo feat > b.txt && git commit -qam feat && \
        git switch -q main && echo main > a.txt && echo main > b.txt && git commit -qam main
        """)

    let idle = try await git.mergeState(projectPath: work)
    check(!idle.merging && idle.conflicts.isEmpty, "没有合并时 mergeState 应为空")

    do {
        try await git.merge(projectPath: work, branch: "feat")
        failures += 1; print("FAIL 冲突的合并应抛 MERGE_CONFLICT")
    } catch let error as GitError {
        check(error.code == .mergeConflict, "冲突错误码应为 MERGE_CONFLICT，实际 \(error.code.rawValue)")
    }
    var state = try await git.mergeState(projectPath: work)
    check(state.merging && state.head == "feat", "合并中应识别出来源分支 feat，实际 \(state.head ?? "nil")")
    check(state.conflicts.sorted() == ["a.txt", "b.txt"], "应列出两个冲突文件，实际 \(state.conflicts)")

    // 冲突没解决完不能继续
    do {
        try await git.mergeContinue(projectPath: work)
        failures += 1; print("FAIL 冲突未解决时 mergeContinue 应当失败")
    } catch is GitError {}

    try await git.resolveConflict(projectPath: work, path: "a.txt", strategy: "ours")
    try await git.resolveConflict(projectPath: work, path: "b.txt", strategy: "theirs")
    state = try await git.mergeState(projectPath: work)
    check(state.merging && state.conflicts.isEmpty, "两个文件解决后不应再有冲突")
    try await git.mergeContinue(projectPath: work)
    state = try await git.mergeState(projectPath: work)
    check(!state.merging, "mergeContinue 后合并应结束")
    check(shell("cat \(q(work + "/a.txt"))").contains("main"), "ours 应保留当前分支的内容")
    check(shell("cat \(q(work + "/b.txt"))").contains("feat"), "theirs 应采用传入分支的内容")
    check(shellCount("git -C \(q(work)) rev-list --count --merges HEAD") == 1, "应生成一个合并提交")

    // 再造一次冲突，走终止
    _ = shell("""
        cd \(q(work)) && git switch -qc feat2 && echo other > a.txt && git commit -qam other && \
        git switch -q main && echo again > a.txt && git commit -qam again
        """)
    let headBefore = shell("git -C \(q(work)) rev-parse HEAD")
    _ = try? await git.merge(projectPath: work, branch: "feat2")
    state = try await git.mergeState(projectPath: work)
    check(state.merging, "第二次合并应处于冲突中")
    try await git.mergeAbort(projectPath: work)
    state = try await git.mergeState(projectPath: work)
    check(!state.merging, "mergeAbort 后不应再处于合并中")
    check(shell("git -C \(q(work)) rev-parse HEAD") == headBefore, "mergeAbort 不应移动 HEAD")
    check(shell("git -C \(q(work)) status --porcelain").isEmpty, "mergeAbort 后工作区应干净")

    let reflog = try await git.reflog(projectPath: work, limit: 5)
    check(reflog.count == 5 && reflog[0].selector == "HEAD@{0}", "reflog 应返回最近 5 条")

    try? FileManager.default.removeItem(atPath: base)
} catch {
    failures += 1
    print("FAIL 合并冲突用例：\(error)")
}

// MARK: - 11. Worktree：创建前检查、创建、列出、移除

do {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("gitreg-worktree-\(UUID().uuidString)").path
    let q = shellQuote
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    let work = URL(fileURLWithPath: base).resolvingSymlinksInPath().path + "/work"
    _ = shell("""
        git init -q -b main \(q(work)) && cd \(q(work)) && \
        git config user.email t@t && git config user.name t && \
        echo a > a.txt && git add . && git commit -qm init
        """)

    check(GitService.worktreeSlug("feature/new task!") == "feature-new-task", "分支名应转成目录名")
    check(WorktreeLayout.owner(of: work + "/.worktrees/x") == work, ".worktrees/x 的会话应归到项目名下")
    check(WorktreeLayout.owner(of: work + "/.worktrees/x/sub") == work + "/.worktrees/x/sub",
          "worktree 的子目录不是 worktree 根")
    check(WorktreeLayout.owner(of: work) == work, "普通目录的归属是它自己")

    let created = try await git.createWorktree(CreateWorktreeInput(projectPath: work, branch: "feature/task"))
    check(created.path == work + "/.worktrees/feature-task", "默认路径应为 .worktrees/<slug>，实际 \(created.path)")
    check(FileManager.default.fileExists(atPath: created.path + "/a.txt"), "worktree 里应检出文件")
    check(shell("git -C \(q(created.path)) rev-parse --abbrev-ref HEAD").contains("feature/task"),
          "worktree 应在新分支上")
    check(shell("git -C \(q(work)) status --porcelain").isEmpty, ".worktrees 不应出现在主工作区的变更里")
    var list = try await git.worktrees(projectPath: work)
    check(list.count == 2, "worktrees 应列出两个，实际 \(list.count)")

    do {
        _ = try await git.createWorktree(CreateWorktreeInput(projectPath: work, branch: "feature/task"))
        failures += 1; print("FAIL 重名分支的 worktree 应抛 BRANCH_EXISTS")
    } catch let error as GitError {
        check(error.code == .branchExists, "重名分支错误码应为 BRANCH_EXISTS，实际 \(error.code.rawValue)")
    }
    do {
        // 分支名不同但目录名相同（/ 与 - 互换）→ 路径占用
        _ = try await git.createWorktree(CreateWorktreeInput(projectPath: work, branch: "feature-task"))
        failures += 1; print("FAIL 目录已存在时应抛 WORKTREE_PATH_EXISTS")
    } catch let error as GitError {
        check(error.code == .worktreePathExists, "路径占用错误码应为 WORKTREE_PATH_EXISTS，实际 \(error.code.rawValue)")
    }
    check(shell("git -C \(q(work)) branch --list feature-task").isEmpty, "创建失败不应留下分支")
    do {
        _ = try await git.createWorktree(CreateWorktreeInput(projectPath: base, branch: "x"))
        failures += 1; print("FAIL 非仓库建 worktree 应抛 NOT_A_REPOSITORY")
    } catch let error as GitError {
        check(error.code == .notARepository, "非仓库错误码应为 NOT_A_REPOSITORY，实际 \(error.code.rawValue)")
    }
    do {
        _ = try await git.createWorktree(
            CreateWorktreeInput(projectPath: work, branch: "escape", path: "../outside"))
        failures += 1; print("FAIL 项目目录之外的 worktree 路径应被拒绝")
    } catch let error as GitError {
        check(error.code == .permissionDenied, "越界路径错误码应为 PERMISSION_DENIED，实际 \(error.code.rawValue)")
    }
    do {
        _ = try await git.createWorktree(
            CreateWorktreeInput(projectPath: work, branch: "visible-tree", path: "visible-tree"))
        failures += 1; print("FAIL 项目内可跟踪的工作树目录应被拒绝")
    } catch let error as GitError {
        check(error.code == .permissionDenied, "可跟踪的目录应被拒绝")
        check(shell("git -C \(q(work)) branch --list visible-tree").isEmpty, "拒绝后不应创建分支")
    }

    // 主工作树不可移除；有未提交改动时不强删
    do {
        try await git.removeWorktree(RemoveWorktreeInput(projectPath: work, path: work))
        failures += 1; print("FAIL 主工作树不应能移除")
    } catch is GitError {}
    try "dirty\n".write(toFile: created.path + "/dirty.txt", atomically: true, encoding: .utf8)
    do {
        try await git.removeWorktree(RemoveWorktreeInput(projectPath: work, path: created.path))
        failures += 1; print("FAIL 有未提交改动的 worktree 不应被直接移除")
    } catch let error as GitError {
        check(error.code == .dirtyWorktree, "脏 worktree 错误码应为 DIRTY_WORKTREE，实际 \(error.code.rawValue)")
    }
    try FileManager.default.removeItem(atPath: created.path + "/dirty.txt")
    try await git.removeWorktree(RemoveWorktreeInput(projectPath: work, path: created.path))
    list = try await git.worktrees(projectPath: work)
    check(list.count == 1, "移除后应只剩主工作树")
    check(!shell("git -C \(q(work)) branch --list feature/task").isEmpty, "移除 worktree 应保留分支")

    try? FileManager.default.removeItem(atPath: base)
} catch {
    failures += 1
    print("FAIL Worktree 用例：\(error)")
}

// MARK: - 12. 富文件类型预览（DOCX / XLSX / PPTX / ZIP / 音视频 / 目录错误）

do {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("gitreg-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.resolvingSymlinksInPath().path
    try FileManager.default.createDirectory(atPath: root + "/subdir", withIntermediateDirectories: true)

    // 用系统 python3 zipfile 构造最小合规的 docx / xlsx / pptx / zip / wav / mp4
    _ = shell("""
    /usr/bin/python3 - \(shellQuote(root)) <<'PY'
    import os, sys, zipfile

    root = sys.argv[1]

    with zipfile.ZipFile(os.path.join(root, "doc.docx"), "w") as z:
        z.writestr("word/document.xml", '''<?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>设计评审</w:t></w:r></w:p>
            <w:p><w:r><w:t>正文内容支持第三栏预览。</w:t></w:r></w:p>
          </w:body>
        </w:document>''')

    with zipfile.ZipFile(os.path.join(root, "report.xlsx"), "w") as z:
        z.writestr("xl/workbook.xml", '''<?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="进度" sheetId="1" r:id="rId1"/>
            <sheet name="文件" sheetId="2" r:id="rId2"/>
          </sheets>
        </workbook>''')
        z.writestr("xl/_rels/workbook.xml.rels", '''<?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Target="worksheets/sheet2.xml"/>
        </Relationships>''')
        z.writestr("xl/sharedStrings.xml", '''<?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <si><t>功能</t></si><si><t>状态</t></si><si><t>文本预览</t></si><si><t>完成</t></si>
        </sst>''')
        z.writestr("xl/worksheets/sheet1.xml", '''<?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="s"><v>3</v></c></row>
          </sheetData>
        </worksheet>''')
        z.writestr("xl/worksheets/sheet2.xml", '''<?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="inlineStr"><is><t>样本</t></is></c><c r="B1"><v>42</v></c></row>
          </sheetData>
        </worksheet>''')

    with zipfile.ZipFile(os.path.join(root, "deck.pptx"), "w") as z:
        z.writestr("ppt/slides/slide1.xml", '''<?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld><p:spTree>
            <p:sp><p:nvSpPr><p:nvPr><p:ph type="ctrTitle"/></p:nvPr></p:nvSpPr>
              <p:txBody><a:p><a:r><a:t>第一页标题</a:t></a:r></a:p></p:txBody></p:sp>
            <p:sp><p:nvSpPr><p:nvPr/></p:nvSpPr>
              <p:txBody><a:p><a:r><a:t>第一页正文</a:t></a:r></a:p></p:txBody></p:sp>
          </p:spTree></p:cSld>
        </p:sld>''')
        z.writestr("ppt/slides/slide2.xml", '''<?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld><p:spTree>
            <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
              <p:txBody><a:p><a:r><a:t>第二页标题</a:t></a:r></a:p></p:txBody></p:sp>
          </p:spTree></p:cSld>
        </p:sld>''')

    with zipfile.ZipFile(os.path.join(root, "bundle.zip"), "w") as z:
        z.writestr("notes/readme.txt", "hello world")
        z.writestr("data.bin", b"0" * 2048)

    with open(os.path.join(root, "tone.wav"), "wb") as f:
        f.write(b"RIFF" + bytes.fromhex("24000000") + b"WAVEfmt ")
    with open(os.path.join(root, "clip.mp4"), "wb") as f:
        f.write(bytes.fromhex("00000018") + b"ftypmp42")
    PY
    """)

    let docx = try await files.read(projectPath: root, path: "doc.docx")
    check(docx.kind == .document && docx.isBinary, "docx 应识别为只读 document")
    check(docx.content?.contains("# 设计评审") == true && docx.content?.contains("正文内容支持第三栏预览。") == true,
          "docx 应解析出标题与正文，实际 \(docx.content ?? "nil")")

    let xlsx = try await files.read(projectPath: root, path: "report.xlsx")
    check(xlsx.kind == .spreadsheet && xlsx.sheets?.count == 2, "xlsx 应解析出 2 个工作表")
    check(xlsx.sheets?.first?.name == "进度" && xlsx.sheets?.first?.rows.last == ["文本预览", "完成"],
          "xlsx 首工作表应解析共享字符串，实际 \(String(describing: xlsx.sheets?.first))")
    check(xlsx.sheets?.last?.name == "文件" && xlsx.sheets?.last?.rows.first == ["样本", "42"],
          "xlsx 第二工作表应解析内联文本与数字，实际 \(String(describing: xlsx.sheets?.last))")

    let pptx = try await files.read(projectPath: root, path: "deck.pptx")
    check(pptx.kind == .presentation && pptx.slides?.count == 2, "pptx 应解析出 2 页幻灯片")
    check(pptx.slides?.first?.title == "第一页标题" && pptx.slides?.first?.body == "第一页正文",
          "pptx 第一页应区分标题与正文，实际 \(String(describing: pptx.slides?.first))")

    let zip = try await files.read(projectPath: root, path: "bundle.zip")
    check(zip.kind == .archive && zip.entries?.count == 2, "zip 应只读列出 2 个文件，实际 \(String(describing: zip.entries))")
    check(zip.entries?.contains(where: { $0.first == "notes/readme.txt" }) == true, "zip 清单应含 notes/readme.txt")
    check(!FileManager.default.fileExists(atPath: root + "/notes/readme.txt"), "读取 zip 清单不应解包到磁盘")

    let wav = try await files.read(projectPath: root, path: "tone.wav")
    check(wav.kind == .audio && wav.content?.hasPrefix("data:audio/wav;base64,") == true, "wav 应返回 audio data URL")

    let mp4 = try await files.read(projectPath: root, path: "clip.mp4")
    check(mp4.kind == .video && mp4.content?.hasPrefix("data:video/mp4;base64,") == true, "mp4 应返回 video data URL")

    do {
        _ = try await files.read(projectPath: root, path: "subdir")
        failures += 1; print("FAIL 读取目录应当返回可读错误")
    } catch let error as GitError {
        check(error.message.contains("目录"), "目录目标应给出明确目录提示，实际 \(error.message)")
    }
} catch {
    failures += 1
    print("FAIL 富文件类型预览用例：\(error)")
}

if failures > 0 {
    print("\(failures) 项失败")
    exit(1)
}
print("ALL PASS")
