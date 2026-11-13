import Foundation


struct GitFileChange: Identifiable, Sendable {
    var id: String { "\(status) \(path)" }
    /// porcelain v1 双字符状态，如 " M"、"??"、"A "
    let status: String
    let path: String
    var originalPath: String? = nil
    var paths: [String] { [originalPath, path].compactMap { $0 } }
    var conflicted: Bool { ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(status) }
    var unstaged: Bool { untracked || status.suffix(1) != " " }
    /// 是否已暂存（第一列非空且非 ?）
    var staged: Bool {
        guard !status.isEmpty, !conflicted else { return false }
        let first = status.prefix(1)
        return first != " " && first != "?"
    }
    var untracked: Bool { status == "??" }

    var statusLabel: String {
        if conflicted { return "冲突" }
        if untracked { return "未跟踪" }
        let first = String(status.prefix(1))
        let second = String(status.suffix(1))
        switch first {
        case "A": return "新增"
        case "M": return "已改"
        case "D": return "删除"
        case "R": return "重命名"
        case "?": return "未跟踪"
        default: break
        }
        switch second {
        case "M": return "已改"
        case "D": return "删除"
        case "A": return "新增"
        default: return "其他"
        }
    }
}

struct GitLogEntry: Identifiable, Sendable {
    let id: String
    let subject: String
    let author: String
    let relTime: String
}

struct GitStatus: Sendable {
    var isRepo = false
    var branch = ""
    var upstream = ""
    var remotes: [String] = []
    var hasHead = false
    var detached = false
    var ahead = 0
    var behind = 0
    var changes: [GitFileChange] = []
    var logs: [GitLogEntry] = []
    var repoRoot = ""
    var errorText: String?

    var dirtyCount: Int { changes.count }
    var stagedCount: Int { changes.filter { $0.staged }.count }
    var hasRemote: Bool { !upstream.isEmpty }
}

struct GitActionResult: Sendable {
    var ok: Bool
    var output: String
}

enum GitRunner {
    private static let gitPath = "/usr/bin/git"

    private static func env() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["GIT_LITERAL_PATHSPECS"] = "1"
        e["LC_ALL"] = "C"
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        if let path = e["PATH"], !path.contains("/opt/homebrew/bin") {
            e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        }
        return e
    }

    /// 同步跑一条 git 命令（后台队列专用，勿在主线程调）。返回 (exitCode, stdout+stderr 合并文本)。
    static func runSync(_ args: [String], cwd: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = ["--no-pager", "-c", "color.ui=false"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        p.environment = env()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // Drain while the child is running; waiting first deadlocks on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return (p.terminationStatus, text)
    }

    /// 采集完整状态（后台）。
    static func fetchStatus(cwd: String, _ done: @escaping @Sendable @MainActor (GitStatus) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var st = GitStatus()
            guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else {
                st.errorText = "路径不存在"
                DispatchQueue.main.async { MainActor.assumeIsolated { done(st) } }
                return
            }
            let (rootCode, rootOut) = runSync(["rev-parse", "--show-toplevel"], cwd: cwd)
            guard rootCode == 0 else {
                DispatchQueue.main.async { MainActor.assumeIsolated { done(st) } }
                return
            }
            st.isRepo = true
            st.repoRoot = rootOut.trimmingCharacters(in: .whitespacesAndNewlines)

            let (statusCode, statusOut) = runSync(["status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd: st.repoRoot)
            guard statusCode == 0 else {
                st.errorText = statusOut
                DispatchQueue.main.async { MainActor.assumeIsolated { done(st) } }
                return
            }
            st.changes = parseChanges(statusOut)
            let (branchCode, branchOut) = runSync(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: st.repoRoot)
            let (headCode, headOut) = runSync(["rev-parse", "--verify", "--short", "HEAD"], cwd: st.repoRoot)
            st.hasHead = headCode == 0
            st.detached = branchCode != 0
            st.branch = branchCode == 0 ? branchOut.trimmingCharacters(in: .newlines) : "detached \(headOut.trimmingCharacters(in: .newlines))"
            let (upCode, upOut) = runSync(["rev-parse", "--symbolic-full-name", "@{upstream}"], cwd: st.repoRoot)
            if upCode == 0 {
                st.upstream = displayRef(upOut.trimmingCharacters(in: .newlines))
                let (countCode, counts) = runSync(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], cwd: st.repoRoot)
                let numbers = counts.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
                if countCode == 0, numbers.count == 2 { st.ahead = numbers[0]; st.behind = numbers[1] }
            }
            let (remoteCode, remoteOut) = runSync(["remote"], cwd: st.repoRoot)
            if remoteCode == 0 { st.remotes = remoteOut.split(separator: "\n").map(String.init) }

            // 最近提交
            let logFmt = "%h\u{1f}%s\u{1f}%an\u{1f}%cr"
            let (lc, lo) = runSync(["log", "--oneline", "--format=\(logFmt)", "-15"], cwd: st.repoRoot)
            if lc == 0 {
                for line in lo.split(separator: "\n") {
                    let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                    guard parts.count >= 4 else { continue }
                    st.logs.append(GitLogEntry(id: String(parts[0]), subject: String(parts[1]), author: String(parts[2]), relTime: String(parts[3])))
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(st) } }
        }
    }

    static func parseChanges(_ output: String) -> [GitFileChange] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: false)
        var result: [GitFileChange] = []
        var i = 0
        while i < records.count {
            let record = String(records[i])
            i += 1
            guard record.count >= 4 else { continue }
            let status = String(record.prefix(2))
            var change = GitFileChange(status: status, path: String(record.dropFirst(3)))
            if status.contains("R") || status.contains("C"), i < records.count {
                change.originalPath = String(records[i])
                i += 1
            }
            result.append(change)
        }
        return result
    }

    /// 执行一组 git 动作命令（后台），全部完成后回主线程。用于 pull/push/stage/commit 等。
    static func perform(_ cmdGroups: [[String]], cwd: String, _ done: @escaping @Sendable @MainActor (GitActionResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var allOk = true
            var out: [String] = []
            for args in cmdGroups where !args.isEmpty {
                let (code, text) = runSync(args, cwd: cwd)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                if code != 0 { allOk = false; break }
            }
            let result = GitActionResult(ok: allOk, output: out.joined(separator: "\n"))
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    // MARK: - v2：分支 / diff / worktree

    private static func displayRef(_ ref: String) -> String {
        for prefix in ["refs/remotes/", "refs/heads/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    static func fetchBranches(cwd: String, _ done: @escaping @Sendable @MainActor ([GitBranch], String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var branches: [GitBranch] = []
            // Full refs distinguish local and remote names; symref excludes remote HEAD.
            let (code, out) = runSync(["branch", "-a", "--format=%(refname)|%(HEAD)|%(upstream)|%(objectname:short)|%(symref)"], cwd: cwd)
            if code == 0 {
                for line in out.split(separator: "\n") {
                    let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 2, !parts[0].isEmpty else { continue }
                    let name = parts[0]
                    if parts.count > 4, !parts[4].isEmpty { continue } // 远程 HEAD 指针行
                    let current = parts.count >= 2 && parts[1] == "*"
                    let upstream = parts.count >= 3 ? displayRef(parts[2]) : ""
                    let sha = parts.count >= 4 ? parts[3] : ""
                    let remote = name.hasPrefix("refs/remotes/")
                    let display = remote ? String(name.dropFirst("refs/remotes/".count)) : String(name.dropFirst("refs/heads/".count))
                    branches.append(GitBranch(name: display, remote: remote, current: current, upstream: upstream, sha: sha))
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(branches, code == 0 ? nil : out) } }
        }
    }

    /// 后台采集 worktree 列表，回主线程。
    static func fetchWorktrees(cwd: String, _ done: @escaping @Sendable @MainActor ([GitWorktree], String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var trees: [GitWorktree] = []
            let (code, out) = runSync(["worktree", "list", "--porcelain", "-z"], cwd: cwd)
            if code == 0 {
                var path = "", head = "", branch = "", isBare = false
                func flush() {
                    if !path.isEmpty {
                        trees.append(GitWorktree(path: path, branch: isBare ? "(bare)" : branch, head: String(head.prefix(7))))
                    }
                    path = ""; head = ""; branch = ""; isBare = false
                }
                for line in out.split(separator: "\0", omittingEmptySubsequences: false) {
                    let l = String(line)
                    if l.isEmpty { flush(); continue }
                    if l.hasPrefix("worktree ") { path = String(l.dropFirst("worktree ".count)) }
                    else if l.hasPrefix("HEAD ") { head = String(l.dropFirst("HEAD ".count)) }
                    else if l.hasPrefix("branch ") { branch = String(l.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "") }
                    else if l == "bare" { isBare = true }
                    else if l == "detached" { branch = "(detached)" }
                }
                flush()
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(trees, code == 0 ? nil : out) } }
        }
    }

    /// 后台生成 diff 文本，回主线程。args 为 git diff/show 的完整参数组。
    static func fetchDiff(_ args: [String], cwd: String, _ done: @escaping @Sendable @MainActor (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let (code, out) = runSync(args, cwd: cwd)
            let text: String
            if code != 0 && !(args.contains("--no-index") && code == 1) {
                text = "diff 执行失败（exit \(code)）\n" + out
            } else {
                text = out
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text) } }
        }
    }
}

// MARK: - Git v2 模型

struct GitBranch: Identifiable, Sendable, Hashable {
    var id: String { (remote ? "remote:" : "local:") + name }
    let name: String
    let remote: Bool
    var ref: String { (remote ? "refs/remotes/" : "refs/heads/") + name }
    let current: Bool
    let upstream: String
    let sha: String
}

struct GitWorktree: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let branch: String
    let head: String
}
