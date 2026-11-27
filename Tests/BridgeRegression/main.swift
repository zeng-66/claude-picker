import AppKit
import Foundation

// 桥分发层回归：用网页外壳（Web/src/shell）实际发送的方法名与参数，经 `Bridge.dispatch`
// 打到真实的处理函数上。只在临时目录里的 git 仓库上做写操作，绝不碰真实项目。
// 由 scripts/check-session-regressions.sh 把本文件替换进 main.swift 的启动段编译（Store / AppDelegate 可用，
// 终端进程换成假 shell，不会真的启动 claude）。

var bridgeFailures = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        bridgeFailures += 1
        print("FAIL \(message)")
    }
}

func sh(_ command: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 发一条桥请求。返回 (result, error code)。
@discardableResult
func call(_ method: String, _ params: [String: Any] = [:]) -> (Any?, String?) {
    do {
        switch try Bridge.dispatch(method: method, params: params) {
        case .handled(let value): return (value, nil)
        case .unknown: return (nil, "NOT_IMPLEMENTED")
        }
    } catch let error as GitError {
        return (nil, error.code.rawValue + (error.detail.map { ":" + $0 } ?? ""))
    } catch {
        return (nil, "\(error)")
    }
}

func ok(_ method: String, _ params: [String: Any] = [:]) -> Any? {
    let (value, error) = call(method, params)
    expect(error == nil, "\(method) 应成功，实际错误 \(error ?? "")")
    return value
}

let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    .appendingPathComponent("bridge-reg-\(UUID().uuidString)")
let repo = tempRoot.appendingPathComponent("repo").path
let remote = tempRoot.appendingPathComponent("remote.git").path
try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempRoot) }
// 终端进程换成一个只会 cat 的假 shell：session.create / session.open 不会真的启动 claude。
let fakeShell = tempRoot.appendingPathComponent("test-shell")
try "#!/bin/sh\nexec /bin/cat\n".write(to: fakeShell, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeShell.path)
setenv("CLAUDE_PICKER_TEST_SHELL", fakeShell.path, 1)
_ = sh("""
    git init -q --bare -b main '\(remote)' && git init -q -b main '\(repo)' && cd '\(repo)' && \
    git config user.email t@t && git config user.name t && \
    printf 'a\\n' > a.txt && printf 'b\\n' > b.txt && git add . && git commit -qm init && \
    git remote add origin '\(remote)' && git push -qu origin main 2>/dev/null
    """)

// MARK: - git.* / file.*（与 WorkspaceTab / GitPages / App 的调用逐一对应）

do {
    let p: [String: Any] = ["projectPath": repo]
    try "a2\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    try "new\n".write(toFile: repo + "/n.txt", atomically: true, encoding: .utf8)

    let status = ok("git.status", p) as? [String: Any]
    expect((status?["files"] as? [Any])?.count == 2, "git.status 应有 2 个变更")
    expect(status?["branch"] as? String == "main", "git.status 的 branch 应为 main")

    let diff = ok("git.diff", p.merging(["filePath": "a.txt", "staged": false]) { $1 }) as? [String: Any]
    expect((diff?["patch"] as? String)?.contains("+a2") == true, "git.diff 应带回 patch")

    _ = ok("git.stage", p.merging(["paths": ["a.txt", "n.txt"]]) { $1 })
    expect(sh("git -C '\(repo)' diff --cached --name-only").contains("n.txt"), "git.stage 应暂存")
    _ = ok("git.unstage", p.merging(["paths": ["n.txt"]]) { $1 })
    expect(!sh("git -C '\(repo)' diff --cached --name-only").contains("n.txt"), "git.unstage 应取消暂存")

    let commit = ok("git.commit", p.merging([
        "message": "bridge commit",
        "options": ["amend": false, "signOff": true, "noVerify": true, "allowEmpty": false],
    ]) { $1 }) as? [String: Any]
    expect((commit?["shortHash"] as? String)?.count == 7, "git.commit 应返回 shortHash")
    expect(sh("git -C '\(repo)' log -1 --format=%B").contains("Signed-off-by"), "signOff 选项应生效")

    let log = ok("git.log", p.merging(["limit": 50, "skip": 0]) { $1 }) as? [[String: Any]]
    expect(log?.count == 2, "git.log 应有 2 条")
    let hash = log?.first?["hash"] as? String ?? ""
    let show = ok("git.show", p.merging(["hash": hash]) { $1 }) as? [String: Any]
    expect((show?["files"] as? [Any])?.count == 1, "git.show 应列出 1 个文件")

    // 文件预览 / 编辑保存（WorkspaceTab：maxBytes、expectedModifiedAt）
    let read = ok("file.read", p.merging(["filePath": "b.txt", "maxBytes": 1_048_576]) { $1 }) as? [String: Any]
    expect(read?["content"] as? String == "b\n", "file.read 应读到内容")
    let modified = read?["modifiedAt"] as? String ?? ""
    let write = ok("file.write", p.merging(["filePath": "b.txt", "content": "b2\n",
                                           "expectedModifiedAt": modified]) { $1 }) as? [String: Any]
    expect(write?["modifiedAt"] is String, "file.write 应返回新的 modifiedAt")
    let (_, stale) = call("file.write", p.merging(["filePath": "b.txt", "content": "x",
                                                    "expectedModifiedAt": "2001-01-01T00:00:00Z"]) { $1 })
    expect(stale?.contains("STALE_FILE") == true, "外部修改应回 STALE_FILE，实际 \(stale ?? "nil")")
    _ = ok("file.write", p.merging(["filePath": "b.txt", "content": ""]) { $1 })
    expect(sh("wc -c < '\(repo)/b.txt'") == "0", "空内容也能保存")

    // Launch Services 打开方式：查询已安装应用与边界检查（不实际拉起外部窗口）
    let openWithApps = ok("file.openWithApps", p.merging(["filePath": "b.txt"]) { $1 }) as? [String: Any]
    let appItems = openWithApps?["apps"] as? [[String: Any]] ?? []
    expect(!appItems.isEmpty, "file.openWithApps 应为文本文件返回已安装 Mac 应用")
    expect(appItems.first?["isDefault"] as? Bool == true, "系统默认应用应置顶")
    let (_, escapeApps) = call("file.openWithApps", p.merging(["filePath": "../outside.txt"]) { $1 })
    expect(escapeApps?.contains("PERMISSION_DENIED") == true, "file.openWithApps 应拒绝越界路径")
    let (_, badApp) = call("file.openWith", p.merging(["filePath": "b.txt", "appPath": "/Applications/NoSuchAppXYZ.app"]) { $1 })
    expect(badApp != nil, "file.openWith 对不存在的应用应返回明确错误")

    // Stash（StashPage）
    _ = ok("git.stashSave", p.merging(["message": "wip", "includeUntracked": true]) { $1 })
    let stashes = ok("git.stashes", p) as? [[String: Any]]
    expect(stashes?.first?["message"] as? String == "On main: wip", "git.stashes 应列出 wip，实际 \(stashes?.first?["message"] ?? "")")
    _ = ok("git.stashApply", p.merging(["index": 0]) { $1 })
    _ = sh("cd '\(repo)' && git checkout -q -- . && git clean -fdq")
    _ = ok("git.stashPop", p.merging(["index": 0]) { $1 })
    _ = ok("git.stashSave", p.merging(["includeUntracked": true]) { $1 })
    _ = ok("git.stashDrop", p.merging(["index": 0]) { $1 })
    expect((ok("git.stashes", p) as? [Any])?.isEmpty == true, "stashDrop 后应为空")

    // 分支（App：switchBranch / fetch / pull / push / merge）
    _ = sh("git -C '\(repo)' branch side")
    _ = ok("git.switchBranch", p.merging(["branch": "side"]) { $1 })
    try "side\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    _ = sh("git -C '\(repo)' commit -qam side")
    _ = ok("git.push", p.merging(["branch": "side"]) { $1 })
    _ = ok("git.fetch", p.merging(["remote": "origin"]) { $1 })
    _ = ok("git.fetch", p)
    _ = ok("git.switchBranch", p.merging(["branch": "main"]) { $1 })
    _ = ok("git.pull", p)
    _ = ok("git.pull", p.merging(["branch": "side"]) { $1 })
    let branches = ok("git.branches", p) as? [[String: Any]]
    expect(branches?.contains { $0["name"] as? String == "origin/side" } == true, "git.branches 应含远程分支")

    // 合并冲突（ConflictPage）
    try "main\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    _ = sh("git -C '\(repo)' commit -qam main-change")
    let (_, conflict) = call("git.merge", p.merging(["branch": "side"]) { $1 })
    expect(conflict?.hasPrefix("MERGE_CONFLICT") == true, "冲突合并应回 MERGE_CONFLICT")
    let state = ok("git.mergeState", p) as? [String: Any]
    expect(state?["merging"] as? Bool == true && (state?["conflicts"] as? [String]) == ["a.txt"], "mergeState 应列出冲突")
    _ = ok("git.mergeAbort", p)
    _ = call("git.merge", p.merging(["branch": "side"]) { $1 })
    _ = ok("git.resolveConflict", p.merging(["filePath": "a.txt", "strategy": "theirs"]) { $1 })
    _ = ok("git.mergeContinue", p)
    expect(sh("cat '\(repo)/a.txt'") == "side", "采用传入分支后应为 side 的内容")
    expect(((ok("git.reflog", p.merging(["limit": 60]) { $1 }) as? [Any])?.count ?? 0) > 3, "git.reflog 应有记录")

    // 工作树（WorktreeTab）
    _ = sh("mkdir -p '\(repo)/.worktrees' && git -C '\(repo)' worktree add -q '\(repo)/.worktrees/wt' -b wt")
    let worktrees = ok("git.worktrees", p) as? [[String: Any]]
    expect(worktrees?.count == 2, "git.worktrees 应有 2 个")
    _ = ok("git.removeWorktree", ["input": ["projectPath": repo, "path": repo + "/.worktrees/wt", "force": false]])
    expect((ok("git.worktrees", p) as? [Any])?.count == 1, "removeWorktree 后应剩 1 个")


    // 参数缺失给结构化错误，而不是崩溃
    let (_, missing) = call("git.commit", p)
    expect(missing?.hasPrefix("COMMAND_FAILED") == true, "缺参数应回 COMMAND_FAILED")
    expect(call("nope.method").1 == "NOT_IMPLEMENTED", "未知方法应回 NOT_IMPLEMENTED")
}

// MARK: - mcp.*（不调用 claude mcp：配置写临时文件，握手用一个假的 stdio 服务）

do {
    let config = tempRoot.appendingPathComponent("claude.json")
    try "{\"projects\":{}}".write(to: config, atomically: true, encoding: .utf8)
    setenv("CLAUDE_PICKER_CLAUDE_CONFIG", config.path, 1)
    // 假 MCP 服务：按行读 JSON-RPC，initialize 与 tools/list 各回一条
    let server = tempRoot.appendingPathComponent("fake-mcp.sh")
    try """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}' ;;
        *'"tools/list"'*) echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"alpha","inputSchema":{}},{"name":"beta","inputSchema":{}}]}}' ;;
      esac
    done
    """.write(to: server, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

    let p: [String: Any] = ["projectPath": repo]
    expect((ok("mcp.list", p) as? [Any])?.isEmpty == true, "空配置时 mcp.list 应为空")
    let added = ok("mcp.add", p.merging(["name": "fake", "transport": "stdio", "endpoint": "'\(server.path)'"]) { $1 }) as? [String: Any]
    expect(added?["id"] as? String == "user:fake", "mcp.add 应写入用户级配置")
    let (_, dup) = call("mcp.add", p.merging(["name": "fake", "transport": "stdio", "endpoint": "x"]) { $1 })
    expect(dup?.hasPrefix("COMMAND_FAILED") == true, "同名服务应被拒绝")
    _ = ok("mcp.add", p.merging(["name": "remote", "transport": "http", "endpoint": "http://127.0.0.1:9/mcp"]) { $1 })
    let list = ok("mcp.list", p) as? [[String: Any]]
    expect(list?.count == 2, "mcp.list 应列出两个服务")

    let tools = ok("mcp.tools", p.merging(["id": "user:fake"]) { $1 }) as? [String: Any]
    expect(tools?["tools"] as? [String] == ["alpha", "beta"], "握手应发现两个工具，实际 \(tools ?? [:])")
    let status = ok("mcp.status", p) as? [String: Any]
    let statuses = status?["statuses"] as? [String: String]
    expect(statuses?["user:fake"] == "connected", "能握手的服务应为 connected")
    expect(statuses?["user:remote"] == "failed", "连不上的服务应为 failed")

    _ = ok("mcp.setEnabled", p.merging(["id": "user:fake", "enabled": false]) { $1 })
    let disabled = (ok("mcp.list", p) as? [[String: Any]])?.first { $0["id"] as? String == "user:fake" }
    expect(disabled?["enabled"] as? Bool == false, "mcp.setEnabled 应停用")
    expect((ok("mcp.status", p) as? [String: Any]).flatMap { ($0["statuses"] as? [String: String])?["user:fake"] } == "disabled",
           "停用的服务不应启动")
    _ = ok("mcp.setEnabled", p.merging(["id": "user:fake", "enabled": true]) { $1 })
    _ = ok("mcp.remove", p.merging(["id": "user:remote"]) { $1 })
    expect((ok("mcp.list", p) as? [Any])?.count == 1, "mcp.remove 应删除服务")
    expect(!FileManager.default.fileExists(atPath: config.path + ".lock"), "写完配置应释放锁")
    expect(McpService.splitCommandLine("npx -y \"@a/b c\" --x 'd e'") == ["npx", "-y", "@a/b c", "--x", "d e"],
           "命令行按引号切分")
    let (_, bad) = call("mcp.add", p.merging(["name": "bad name", "transport": "stdio", "endpoint": "x"]) { $1 })
    expect(bad?.hasPrefix("COMMAND_FAILED") == true, "非法服务名应被拒绝")

    // Antigravity MCP 配置读写、SSE 拦截与从 Claude 导入
    let agyMcp = tempRoot.appendingPathComponent("agy-mcp.json")
    setenv("CLAUDE_PICKER_AGY_MCP_CONFIG", agyMcp.path, 1)
    _ = ok("mcp.add", p.merging(["name": "legacy-sse", "transport": "sse", "endpoint": "http://127.0.0.1:9/sse"]) { $1 })
    let (_, sseRejected) = call("mcp.add", p.merging(["provider": "antigravity", "name": "bad-sse", "transport": "sse", "endpoint": "http://127.0.0.1:9/sse"]) { $1 })
    expect(sseRejected?.hasPrefix("COMMAND_FAILED") == true, "Antigravity MCP 应拒绝旧版 SSE")
    let imported = ok("mcp.importFromClaude", p.merging(["provider": "antigravity"]) { $1 }) as? [String: Any]
    expect(imported?["imported"] as? Int == 1 && imported?["skippedSse"] as? Int == 1,
           "mcp.importFromClaude 应导入 stdio/http 并跳过 sse，实际 \(imported ?? [:])")
    let agyList = ok("mcp.list", p.merging(["provider": "antigravity"]) { $1 }) as? [[String: Any]]
    expect(agyList?.count == 1 && agyList?.first?["name"] as? String == "fake", "Antigravity mcp.list 应读出导入的服务")
    let agyTools = ok("mcp.tools", p.merging(["provider": "antigravity", "id": "agy:fake"]) { $1 }) as? [String: Any]
    expect(agyTools?["tools"] as? [String] == ["alpha", "beta"], "Antigravity MCP 握手应发现工具")
    unsetenv("CLAUDE_PICKER_AGY_MCP_CONFIG")
    unsetenv("CLAUDE_PICKER_CLAUDE_CONFIG")
}

// MARK: - app.* / session.*（Store + AppDelegate，终端用假 shell）

MainActor.assumeIsolated {
    // 第 0 位固定是家目录（Store 的约定：家目录不可移动、不可移除）
    let home = Project(id: -1, title: "~", path: tempRoot.path, isHome: true, sessions: [])
    let project = Project(id: 0, title: "repo", path: repo, isHome: false, sessions: [])
    let store = Store([home, project])
    let delegate = AppDelegate(store: store, outPath: "")
    NSApplication.shared.delegate = delegate
    defer { store.terminateAll() }

    let snapshot = ok("app.state") as? [String: Any]
    expect((snapshot?["projects"] as? [[String: Any]])?[1]["path"] as? String == repo, "app.state 应带回项目")
    expect((snapshot?["runtime"] as? [String: Any])?["models"] is [Any], "app.state 应带回可选模型")

    _ = ok("app.toggleProject", ["path": repo])
    expect(store.projects[1].expanded, "app.toggleProject 应展开")
    _ = ok("app.settings", ["density": "compact", "terminalWidth": 40, "sidebar": true])
    expect(store.settings.density == "compact" && store.settings.terminalWidthPercent == 40, "app.settings 应生效")
    _ = ok("app.settings", ["density": "comfortable", "terminalWidth": 30])

    // 统一工作树命令：设置校验、未填任务、假命令返回已登记的工作树 → reused / unified
    expect(call("app.setWorktreeCommand", ["path": "relative/ai-worktree"]).1?.hasPrefix("COMMAND_FAILED") == true,
           "相对路径的工作树命令应被拒绝")
    let unifiedTree = tempRoot.appendingPathComponent("shared/T9-demo").path
    _ = sh("git -C '\(repo)' worktree add -q '\(unifiedTree)' -b worktree/T9-demo")
    let fakeCommand = tempRoot.appendingPathComponent("fake-worktree")
    try? "#!/bin/sh\necho '{\"action\":\"reused\",\"repo_root\":\"\(repo)\",\"task\":\"T9\",\"path\":\"\(unifiedTree)\",\"branch\":\"worktree/T9-demo\"}'\n"
        .write(to: fakeCommand, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCommand.path)
    _ = ok("app.setWorktreeCommand", ["path": fakeCommand.path])
    expect(store.settings.worktreeCommand == fakeCommand.path, "工作树命令应写入设置")
    let (_, noTask) = call("git.createWorktree", ["input": ["projectPath": repo]])
    expect(noTask?.hasPrefix("COMMAND_FAILED") == true, "统一模式缺任务标识应回 COMMAND_FAILED，实际 \(noTask ?? "nil")")
    let unified = ok("git.createWorktree", ["input": ["projectPath": repo, "task": "T9", "name": "demo",
                                                      "command": "/bin/false"]]) as? [String: Any]
    expect(unified?["action"] as? String == "reused" && unified?["mode"] as? String == "unified"
           && (unified?["path"] as? String).map(WorktreeCommand.canonical) == WorktreeCommand.canonical(unifiedTree), "统一模式应返回复核过的复用结果，实际 \(String(describing: unified))")
    let checked = call("git.checkWorktreeCommand", ["projectPath": repo]).0 as? [String: Any]
    expect(checked == nil, "假命令不支持 repo-root，检测应报错而不是成功")
    _ = ok("app.setWorktreeCommand", ["path": ""])
    expect(store.settings.worktreeCommand.isEmpty, "清空后回到项目模式")
    _ = sh("git -C '\(repo)' worktree remove '\(unifiedTree)'")

    // 新建会话：当前分支
    let created = ok("session.create", ["projectPath": repo, "title": "桥测试会话", "mode": "current"]) as? [String: Any]
    let sid = created?["sessionId"] as? String ?? ""
    expect(!sid.isEmpty && store.projects[1].sessions.first?.id == sid, "session.create 应插入会话")
    expect(store.projects[1].sessions.first?.title == "桥测试会话", "新会话应使用用户起的名字")
    expect(store.activeSessionId == sid, "新会话应成为当前会话")

    // 新建会话：名称留空 → 先显示占位标题，之后由对话总结回填；可重命名 / 恢复自动标题
    let untitled = ok("session.create", ["projectPath": repo, "mode": "current"]) as? [String: Any]
    let untitledId = untitled?["sessionId"] as? String ?? ""
    expect(store.projects[1].sessions.first?.id == untitledId, "未命名会话也应插入")
    expect(store.projects[1].sessions.first?.title == "新建会话", "未命名会话应显示占位标题")
    _ = ok("app.renameSession", ["sessionId": untitledId, "title": "  改过的名字 "])
    expect(store.projects[1].sessions.first?.title == "改过的名字", "app.renameSession 应改名")
    let named = ((ok("app.state") as? [String: Any])?["projects"] as? [[String: Any]])?[1]["sessions"] as? [[String: Any]]
    expect(named?.first?["named"] as? Bool == true, "改名后快照应标记 named")
    _ = ok("app.renameSession", ["sessionId": untitledId, "title": ""])
    expect(store.projects[1].sessions.first?.title == "新建会话", "清空名称应恢复自动标题")
    let (_, missing) = call("app.renameSession", ["sessionId": "nope", "title": "x"])
    expect(missing?.hasPrefix("COMMAND_FAILED") == true, "不存在的会话应报错")
    _ = ok("app.remove", ["projectPath": repo, "sessionId": untitledId])

    // 新建会话：独立工作树（建在 .worktrees 下，归属到项目名下）
    let wt = ok("session.create", ["projectPath": repo, "title": "工作树会话", "mode": "worktree",
                                   "branch": "feature/bridge"]) as? [String: Any]
    expect(wt?["cwd"] as? String == repo + "/.worktrees/feature-bridge", "worktree 会话的 cwd 应在 .worktrees 下")
    expect(store.projects[1].sessions.count == 2, "worktree 会话应归到原项目名下")
    let (_, dup) = call("session.create", ["projectPath": repo, "title": "重复", "mode": "worktree",
                                           "branch": "feature/bridge"])
    expect(dup?.hasPrefix("BRANCH_EXISTS") == true, "重名分支不应建出会话")
    expect(store.projects[1].sessions.count == 2, "失败时不应插入会话")

    let target = wt?["cwd"] as? String ?? ""
    let existingTree = ok("session.create", ["projectPath": repo, "title": "在现有工作树新建",
        "workspace": ["branch": "feature/bridge", "worktreePath": target]]) as? [String: Any]
    let scopedId = existingTree?["sessionId"] as? String ?? ""
    let scopedPath = existingTree?["cwd"] as? String ?? ""
    expect(!scopedId.isEmpty && !scopedPath.isEmpty && resolvedPath(scopedPath) == resolvedPath(target),
           "分支入口应使用已有工作树目录")
    let (_, badPath) = call("session.create", ["projectPath": repo,
        "workspace": ["branch": "feature/bridge", "worktreePath": tempRoot.path]])
    expect(badPath?.hasPrefix("COMMAND_FAILED") == true, "未登记目录不得用作工作树")
    let scoped = ((ok("app.state") as? [String: Any])?["projects"] as? [[String: Any]])?[1]["sessions"] as? [[String: Any]]
    let scopedRow = scoped?.first { $0["id"] as? String == scopedId }
    expect(scopedRow?["branch"] as? String == "feature/bridge" && scopedRow?["originalSessionId"] as? String == scopedId,
           "快照应包含真实分支和 Claude 原始 ID")
    _ = ok("app.remove", ["projectPath": repo, "sessionId": scopedId])

    _ = ok("app.settings", ["cliPreferences": ["claude": ["enabled": false]]])
    let (_, disabled) = call("session.open", ["projectPath": repo, "sessionId": sid, "provider": "claude"])
    expect(disabled?.hasPrefix("COMMAND_FAILED") == true, "停用引擎不得重新打开旧会话")
    _ = ok("app.settings", ["cliPreferences": [String: Any]()])

    _ = ok("app.pin", ["projectPath": repo, "sessionId": sid])
    expect(store.projects[1].sessions.first?.id == sid, "app.pin 应置顶会话")
    _ = ok("session.open", ["projectPath": repo, "cwd": repo, "sessionId": sid])
    expect(store.activeSessionId == sid, "session.open 应切到该会话")
    let context = ok("app.context") as? [String: Any]
    expect(context?["total"] as? Int == 200_000, "app.context 应给出窗口容量")
    _ = ok("app.remove", ["projectPath": repo, "sessionId": sid])
    expect(!store.projects[1].sessions.contains { $0.id == sid }, "app.remove 应移除会话")
    _ = ok("app.command", ["name": "closeTerminal"])
    expect(store.active == nil, "closeTerminal 应关闭当前终端")

    let (_, missingDir) = call("app.addDirectory", ["path": tempRoot.appendingPathComponent("nope").path])
    expect(missingDir?.hasPrefix("COMMAND_FAILED") == true, "不存在的目录应被拒绝")
    let added = ok("app.addDirectory", ["path": remote]) as? [String: Any]
    expect(added?["path"] as? String == remote, "app.addDirectory 应返回规范化路径")
    _ = ok("app.moveProject", ["from": remote, "to": repo])
    expect(store.projects.map(\.path) == [tempRoot.path, repo, remote], "app.moveProject 应调整顺序")
    _ = ok("app.pin", ["projectPath": remote])
    expect(store.projects[1].path == remote, "app.pin 应把目录置顶到家目录之后")
    _ = ok("app.remove", ["projectPath": tempRoot.path])
    expect(store.projects.first?.isHome == true, "家目录不可移除")
    _ = ok("app.remove", ["projectPath": remote])
    expect(!store.projects.contains { $0.path == remote }, "app.remove 应移除目录")

    // 多引擎（Antigravity）会话创建、跨引擎接力与图形聊天自动降级
    setenv("CLAUDE_PICKER_AGY_BIN", fakeShell.path, 1)
    setenv("CLAUDE_PICKER_CLAUDE_BIN", fakeShell.path, 1)
    let agyCreated = ok("session.create", ["projectPath": repo, "title": "Agy 桥测试", "mode": "current", "provider": "antigravity"]) as? [String: Any]
    let agySid = agyCreated?["sessionId"] as? String ?? ""
    expect(agySid.hasPrefix("pending-agy-"), "Antigravity 新建终端会话应分配占位 ID 待落盘晋升")
    expect(store.projects[1].sessions.first?.provider == .antigravity, "新会话 provider 应为 antigravity")
    let agySnap = ok("app.state") as? [String: Any]
    let agyRt = agySnap?["runtime"] as? [String: Any]
    expect(agyRt?["provider"] as? String == "antigravity" && agyRt?["supportsFast"] as? Bool == false,
           "激活 Antigravity 会话时 runtime 应切到 antigravity 并关闭 supportsFast")

    // 跨引擎接力：Claude -> Antigravity
    let claudeTranscript = tempRoot.appendingPathComponent("claude-src.jsonl")
    try? "{\"type\":\"user\",\"cwd\":\"\(repo)\",\"message\":{\"content\":\"排查同步锁竞争\"}}\n{\"type\":\"assistant\",\"message\":{\"content\":\"已定位到队列重入问题。\"}}\n"
        .write(to: claudeTranscript, atomically: true, encoding: .utf8)
    store.projects[1].sessions.insert(
        Session(id: "claude-src-1", cwd: repo, title: "同步锁排查", summary: "同步锁排查", date: Date(), fileURL: claudeTranscript, provider: .claude),
        at: 0
    )
    let handoffRes = ok("session.handoff", [
        "sessionId": "claude-src-1",
        "sourceProvider": "claude",
        "targetProvider": "antigravity",
        "projectPath": repo,
        "cwd": repo,
    ]) as? [String: Any]
    let handoffSid = handoffRes?["sessionId"] as? String ?? ""
    expect(!handoffSid.isEmpty && handoffRes?["provider"] as? String == "antigravity", "session.handoff 应创建目标引擎会话")
    let afterHandoff = ((ok("app.state") as? [String: Any])?["projects"] as? [[String: Any]])?[1]["sessions"] as? [[String: Any]]
    let handoffRow = afterHandoff?.first { $0["id"] as? String == handoffSid }
    expect((handoffRow?["handoffFrom"] as? String)?.hasPrefix("Claude") == true, "接力会话应在快照里携带 handoffFrom 来源标记")

    // 图形聊天模式打开 Antigravity 会话时自动降级到原生终端
    store.settings.interactionMode = .chat
    _ = ok("session.open", ["projectPath": repo, "cwd": repo, "sessionId": handoffSid, "provider": "antigravity"])
    expect(!store.chatActive && store.activeSessionId == handoffSid, "chat 模式下打开 Antigravity 会话应自动回退原生终端")
    store.settings.interactionMode = .terminal
    unsetenv("CLAUDE_PICKER_AGY_BIN")
    unsetenv("CLAUDE_PICKER_CLAUDE_BIN")

    // MARK: - 逐会话打开方式与结构化聊天（Claude 协议替身 fake-claude.py）

    @MainActor func spin(_ timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }

    @MainActor func switchMode(_ sid: String, _ mode: InteractionMode) -> String? {
        var outcome: Result<Void, GitError>?
        store.switchOpenMode(sessionId: sid, to: mode) { outcome = $0 }
        guard spin(30, { outcome != nil }) else { return "timeout" }
        if case .failure(let error) = outcome! { return error.message }
        return nil
    }

        do {
        let fakeClaude = tempRoot.appendingPathComponent("fake-claude")
            try FileManager.default.copyItem(atPath: FileManager.default.currentDirectoryPath + "/Tests/WorkRegression/fake-claude.py",
                                             toPath: fakeClaude.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)
            let fakeState = tempRoot.appendingPathComponent("fake-claude-state")
            try FileManager.default.createDirectory(at: fakeState, withIntermediateDirectories: true)
            setenv("CLAUDE_PICKER_CLAUDE_BIN", fakeClaude.path, 1)
            setenv("FAKE_CLAUDE_STATE", fakeState.path, 1)
            setenv("FAKE_CLAUDE_SLOW_SECONDS", "30", 1)
            let fakeClaudeLog = tempRoot.appendingPathComponent("fake-claude.log").path
            setenv("FAKE_CLAUDE_LOG", fakeClaudeLog, 1)
            func claudeLog() -> String { (try? String(contentsOfFile: fakeClaudeLog, encoding: .utf8)) ?? "" }

            do {
                // Codex 历史：AGENTS.md 指令与 <environment_context> 作为 user 消息的独立段注入，不能显示成「你」的发言。
                let rows = [
                    ##"{"timestamp":"2026-11-18T05:06:44.259Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\n\n<INSTRUCTIONS>\nx\n</INSTRUCTIONS>"},{"type":"input_text","text":"<environment_context>\n  <cwd>/tmp</cwd>\n</environment_context>"}]}}"##,
                    ##"{"timestamp":"2026-11-18T05:06:45.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"分析一下 t3code"}]}}"##,
                    ##"{"timestamp":"2026-11-18T05:06:50.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"好的"}]}}"##,
                ]
                let url = tempRoot.appendingPathComponent("codex-history.jsonl")
                try? rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                let items = SessionChatHistory.load(provider: .codex, fileURL: url)
                let kinds: [String] = items.map { item -> String in item["kind"]?.stringValue ?? "" }
                let users: [String] = items.compactMap { item -> String? in
                    item["kind"]?.stringValue == "user" ? item["payload"]?["text"]?.stringValue : nil
                }
                expect(users == ["分析一下 t3code"] && kinds == ["user", "assistant"], "Codex 历史剔除注入的 AGENTS.md 与环境上下文：\(items)")
            }


            let hub = SessionChatHub.shared
            let created = ok("session.create", ["projectPath": repo, "title": "结构化会话", "mode": "current",
                                                "provider": "claude", "openMode": "structured"]) as? [String: Any]
            let sid = created?["sessionId"] as? String ?? ""
            expect(store.structuredTarget?.sid == sid && store.active == nil, "openMode=structured 新建会话应打开结构化聊天而非终端")
            let snap = ok("app.state") as? [String: Any]
            expect((snap?["active"] as? [String: Any])?["surface"] as? String == "structured", "快照 active.surface 应为 structured")
            let row = ((snap?["projects"] as? [[String: Any]])?[1]["sessions"] as? [[String: Any]])?.first { $0["id"] as? String == sid }
            expect(row?["openMode"] as? String == "structured", "会话行应带上已保存的打开方式")
            expect(spin { hub.run(sid)?.phase == .ready }, "结构化执行器握手就绪")
            expect(SessionOwnership.shared.heldByTerminal(sid), "结构化聊天持有该会话（单写者）")

            _ = ok("sessionChat.send", ["sessionId": sid, "text": "你好"])
            expect(spin { (hub.run(sid)?.events ?? []).contains { $0["kind"]?.stringValue == "turn_result" } }, "发送后收到回合结果")
            let chat = ok("sessionChat.snapshot", ["sessionId": sid]) as? [String: Any]
            let kinds = (chat?["events"] as? [[String: Any]])?.compactMap { $0["kind"] as? String } ?? []
            expect(kinds.contains("user") && kinds.contains("assistant"), "快照包含用户消息与助手回复：\(kinds.joined(separator: ","))")

            _ = ok("sessionChat.send", ["sessionId": sid, "text": "SCENARIO:permission"])
            expect(spin { !(hub.run(sid)?.pending.isEmpty ?? true) }, "工具权限请求进入待审批")
            let requestId = hub.run(sid)?.pending.keys.first ?? ""
            _ = ok("sessionChat.respond", ["sessionId": sid, "requestId": requestId, "allow": true])
            let (_, twice) = call("sessionChat.respond", ["sessionId": sid, "requestId": requestId, "allow": true])
            expect(twice != nil, "同一审批不能答复两次")
            expect(spin { hub.run(sid)?.phase == .ready }, "审批后回合结束")

            // 运行中切到终端：先中断回合、等执行器退出，再在终端按原始 ID 恢复。
            _ = ok("sessionChat.send", ["sessionId": sid, "text": "SCENARIO:slow"])
            expect(spin { hub.run(sid)?.phase == .running }, "慢回合进入运行中")
            let toTerminal = switchMode(sid, .terminal)
            expect(toTerminal == nil, "运行中切到终端应先中断再交接：\(toTerminal ?? "")")
            expect(!hub.isLive(sid) && store.structuredTarget == nil && store.active != nil && store.activeSessionId == sid,
                   "交接后结构化执行器已退出，终端接管同一原始 ID")
            expect((hub.run(sid)?.events ?? []).contains { $0["payload"]?["subtype"]?.stringValue == "aborted"
                                                           || $0["payload"]?["terminalReason"]?.stringValue?.hasPrefix("aborted") == true },
                   "被中断的回合记录为中断")
            expect(store.openMode(for: sid, provider: .claude) == .terminal, "打开方式改记为终端")

            // 再切回结构化聊天：终端先退出，聊天按原始 ID 接续并保留之前的记录。
            let toChat = switchMode(sid, .structured)
            expect(toChat == nil, "终端切回结构化聊天：\(toChat ?? "")")
            expect(store.active == nil && store.structuredTarget?.sid == sid && hub.isLive(sid), "终端已释放，聊天重新持有")
            expect(spin { hub.run(sid)?.phase == .ready }, "重新接续后就绪")

            // 已被结构化聊天持有时，按会话打开不得再起终端。
            _ = ok("session.open", ["projectPath": repo, "cwd": repo, "sessionId": sid])
            expect(store.active == nil && store.structuredTarget?.sid == sid, "持有中的会话重复打开仍回到聊天视图")

            // 关闭视图不结束执行器；App 退出时统一结束。
            _ = ok("app.command", ["name": "closeTerminal"])
            expect(store.structuredTarget == nil && hub.isLive(sid), "关闭视图保留执行器，可重新挂接")
            _ = ok("session.open", ["projectPath": repo, "cwd": repo, "sessionId": sid])
            expect(store.structuredTarget?.sid == sid, "重新打开挂回同一执行器")

            // 输入框快捷切换：模式与模型走 stream-json 控制请求即时生效；推理强度按原 ID 重启。
            _ = ok("sessionChat.runtime", ["sessionId": sid, "key": "mode", "value": "plan"])
            expect(spin { claudeLog().contains("set_permission_mode") } && hub.run(sid)?.runtime["mode"]?.stringValue == "plan",
                   "切换权限模式发出 set_permission_mode 并记录在会话上")
            _ = ok("sessionChat.runtime", ["sessionId": sid, "key": "model", "value": "sonnet"])
            expect(spin { claudeLog().contains("set_model") }, "切换模型发出 set_model")
            let (_, badValue) = call("sessionChat.runtime", ["sessionId": sid, "key": "model", "value": "no-such-model"])
            expect(badValue != nil, "不在可选项里的值被拒绝")
            let spawnsBefore = claudeLog().components(separatedBy: "\"spawn\"").count
            _ = ok("sessionChat.runtime", ["sessionId": sid, "key": "effort", "value": "low"])
            expect(spin(20) { claudeLog().components(separatedBy: "\"spawn\"").count > spawnsBefore && hub.run(sid)?.phase == .ready },
                   "切换推理强度后按原会话重新接续")
            let lastSpawn = claudeLog().split(separator: "\n").last { $0.contains("\"spawn\"") }.map(String.init) ?? ""
            expect(lastSpawn.contains("\"--effort\", \"low\"") || lastSpawn.contains("\"--effort\",\"low\""),
                   "重启参数带上新的推理强度与权限模式：\(lastSpawn.prefix(300))")
            expect(lastSpawn.contains("plan") && lastSpawn.contains("sonnet"), "重启沿用本会话改过的模式与模型")

            let (_, unsupported) = call("session.setOpenMode", ["sessionId": sid, "mode": "bogus"])
            expect(unsupported != nil, "未知打开方式应被拒绝")
            expect(InteractionMode.resolve(recorded: "structured", provider: .dsh, global: .terminal, overrides: [:]) == .terminal,
                   "DeepSeek 不支持结构化聊天时回到终端")

            // Antigravity 结构化历史载入：从 transcript.jsonl 解析用户消息、助手回复与工具调用。
            let agyHistFile = tempRoot.appendingPathComponent("agy-transcript.jsonl")
            let agyLines = [
                #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-11-26T08:00:00Z","content":"<USER_REQUEST>\n检查状态\n</USER_REQUEST>\n<ADDITIONAL_METADATA>ignored</ADDITIONAL_METADATA>"}"#,
                #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-11-26T08:00:05Z","content":"已完成检查。","tool_calls":[{"name":"read_file","args":{"Path":"/tmp/a.txt"}}]}"#,
            ].joined(separator: "\n")
            try agyLines.write(to: agyHistFile, atomically: true, encoding: .utf8)
            let agyHistory = SessionChatHistory.load(provider: .antigravity, fileURL: agyHistFile)
            expect(agyHistory.count == 3, "Antigravity 历史应解析出 1 条用户消息、1 条回复与 1 条工具记录，实际 \(agyHistory.count)")
            expect(agyHistory.first?["kind"]?.stringValue == "user"
                   && agyHistory.first?["payload"]?["text"]?.stringValue == "检查状态",
                   "Antigravity 历史应剥离 USER_REQUEST 包装")
            expect(agyHistory.contains { $0["kind"]?.stringValue == "assistant" && $0["payload"]?["text"]?.stringValue == "已完成检查。" },
                   "Antigravity 历史应保留助手回复")
            expect(agyHistory.contains { $0["kind"]?.stringValue == "tool_use" && $0["payload"]?["name"]?.stringValue == "read_file" },
                   "Antigravity 历史应保留工具调用记录")

            // 切换尺寸与挂载：先在无洞口时切到结构化聊天，再切回终端并回报洞口矩形，视图必须挂载且同步非零尺寸。
            let testShell = ShellView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
            store.onActiveChanged = {
                testShell.showTerminal(store.activeView, backgroundColor: store.activeTerminalBackground)
            }
            let switchToTermErr = switchMode(sid, .terminal)
            expect(switchToTermErr == nil, "带 ShellView 切到终端：\(switchToTermErr ?? "")")
            testShell.applyLayout(["terminal": NSNull(), "blocked": false])
            testShell.applyLayout(["terminal": ["x": 260, "y": 50, "w": 720, "h": 480], "blocked": false])
            expect(store.active != nil && store.active?.view.superview != nil, "切回终端后 active 视图已挂载")
            expect((store.active?.view.frame.width ?? 0) > 700 && (store.active?.view.frame.height ?? 0) > 460
                   && store.active?.view.superview?.isHidden == false,
                   "回报洞口矩形后终端视图应同步为非零尺寸且可见，实际：\(String(describing: store.active?.view.frame))")
            store.onActiveChanged = nil

            // Codex：CLI 分配线程 ID，占位 ID 换成原始 ID 后事件仍要送达同一个聊天。
            let fakeCodex = tempRoot.appendingPathComponent("fake-codex")
            try FileManager.default.copyItem(atPath: FileManager.default.currentDirectoryPath + "/Tests/WorkRegression/fake-codex-app-server.py",
                                             toPath: fakeCodex.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)
            let fakeCodexLog = tempRoot.appendingPathComponent("bridge-fake-codex.log")
            setenv("FAKE_CODEX_LOG", fakeCodexLog.path, 1)
            setenv("CLAUDE_PICKER_CODEX_BIN", fakeCodex.path, 1)

            // Codex 运行栏 + 快速模式：只读 config.toml 与 models_cache.json，修改写入 codex-runtime.json。
            let codexHome = tempRoot.appendingPathComponent("codex-home", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            let sampleToml = """
            # >>> aimami-relay codex-router top start (DO NOT EDIT MANUALLY)
            model_provider = "aimai1"
            # <<< aimami-relay codex-router top end
            service_tier = "default"
            model = "aimami_relay_test::gpt-6.2-sol"
            model_reasoning_effort = "high"

            [mcp_servers.tapd]
            command = "uvx"
            """
            let tomlURL = codexHome.appendingPathComponent("config.toml")
            try sampleToml.write(to: tomlURL, atomically: true, encoding: .utf8)
            let modelsCache = """
            {"models":[
              {"slug":"gpt-6.2-sol","display_name":"GPT-6.2-Sol","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"xhigh"}]},
              {"slug":"gpt-hidden","display_name":"Hidden","visibility":"hide","supported_reasoning_levels":[{"effort":"low"}]}
            ]}
            """
            try modelsCache.write(to: codexHome.appendingPathComponent("models_cache.json"), atomically: true, encoding: .utf8)
            setenv("CLAUDE_PICKER_CODEX_DIR", codexHome.path, 1)
            store.closeTerminal()
            store.reloadClaudeOptions()
            _ = ok("app.runtime", ["key": "provider", "value": "codex"])
            let codexSnapInit = (ok("app.state") as? [String: Any])?["runtime"] as? [String: Any]
            let codexModels = codexSnapInit?["models"] as? [[String: Any]] ?? []
            expect(codexSnapInit?["provider"] as? String == "codex"
                   && codexSnapInit?["supportsFast"] as? Bool == true
                   && codexSnapInit?["fast"] as? Bool == false
                   && codexSnapInit?["model"] as? String == "aimami_relay_test::gpt-6.2-sol"
                   && (codexSnapInit?["modes"] as? [[String: Any]])?.count == 3
                   && (codexSnapInit?["efforts"] as? [[String: Any]])?.isEmpty == false
                   && codexModels.contains { $0["id"] as? String == "aimami_relay_test::gpt-6.2-sol" }
                   && !codexModels.contains { $0["id"] as? String == "gpt-hidden" },
                   "Codex 运行栏应返回模式/模型/推理强度/快速模式并过滤隐藏模型：\(String(describing: codexSnapInit))")
            _ = ok("app.runtime", ["key": "mode", "value": "never"])
            _ = ok("app.runtime", ["key": "model", "value": "gpt-6.2-sol"])
            _ = ok("app.runtime", ["key": "effort", "value": "xhigh"])
            _ = ok("app.runtime", ["key": "fast", "value": true])
            let reloadedCodex = CodexConfig.loadOptions(in: codexHome)
            expect(reloadedCodex.mode == .never && reloadedCodex.model == "gpt-6.2-sol"
                   && reloadedCodex.effort == "xhigh" && reloadedCodex.fast == true,
                   "Codex 运行栏修改应写入 codex-runtime.json")
            expect((try? String(contentsOf: tomlURL, encoding: .utf8)) == sampleToml,
                   "不得修改用户 ~/.codex/config.toml")
            let codexCliFlags = CodexRenderOptions(mode: .onRequest, model: "gpt-6.2-sol", effort: "xhigh", fast: true).flags()
            expect(codexCliFlags.contains("service_tier=\"fast\"") && codexCliFlags.contains("model=\"gpt-6.2-sol\""),
                   "Codex 终端启动参数应包含 service_tier=fast 与 model：\(codexCliFlags)")

            let codexCreated = ok("session.create", ["projectPath": repo, "title": "Codex 结构化", "mode": "current",
                                                     "provider": "codex", "openMode": "structured"]) as? [String: Any]
            let placeholder = codexCreated?["sessionId"] as? String ?? ""
            expect(placeholder.hasPrefix("pending-codex-"), "Codex 新会话先用占位 ID")
            expect(spin { (store.structuredTarget?.sid ?? "").hasPrefix("fake-thread-") }, "取得 Codex 原始线程 ID 后改用原始 ID")
            let threadId = store.structuredTarget?.sid ?? ""
            expect(spin { hub.run(threadId)?.phase == .ready }, "回绑后仍收到就绪事件")
            _ = ok("sessionChat.runtime", ["sessionId": threadId, "key": "fast", "value": "true"])
            _ = ok("sessionChat.send", ["sessionId": threadId, "text": "你好 Codex"])
            expect(spin { (hub.run(threadId)?.events ?? []).contains { $0["kind"]?.stringValue == "assistant"
                                                                   && $0["payload"]?["text"]?.stringValue == "收到：你好 Codex" } },
                   "Codex 回复送达聊天")
            let codexReqLog = (try? String(contentsOfFile: fakeCodexLog.path, encoding: .utf8)) ?? ""
            expect(codexReqLog.contains("\"serviceTier\":\"fast\""), "Codex 结构化聊天 turn/start 应携带 serviceTier=fast")
            expect(store.openMode(for: threadId, provider: .codex) == .structured
                   && store.session(id: threadId)?.provider == .codex, "会话记录随原始 ID 迁移")
            unsetenv("CLAUDE_PICKER_CODEX_BIN")
            unsetenv("FAKE_CODEX_LOG")
            unsetenv("CLAUDE_PICKER_CODEX_DIR")

            // 额度刷新与 DeepSeek 金额解析 / 底部运行参数栏
            _ = ok("app.refreshUsage", ["onlyIfEmpty": true])
            let sampleYaml = """
            version: 1
            records:
              DEEPSEEK_API_KEY:
                value: "sk-test-deepseek-key"
            """
            expect(DeepSeekUsage.extractKeyFromCredentialsYAML(sampleYaml, keyName: "DEEPSEEK_API_KEY") == "sk-test-deepseek-key",
                   "应从 DSH .credentials.yaml 提取 DEEPSEEK_API_KEY")
            let sampleBalance = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"71.43","granted_balance":"0.00","topped_up_balance":"71.43"}]}"#.utf8)
            let parsedBalance = DeepSeekUsage.parsePayload(sampleBalance)
            expect(parsedBalance?.currency == "CNY" && parsedBalance?.total == 71.43 && parsedBalance?.toppedUp == 71.43 && parsedBalance?.isAvailable == true,
                   "应解析 DeepSeek /user/balance 金额响应")

            // Antigravity 配额与积分解析（官方 agy -p /usage 与 /credits 输出形态）
            let agyUsageJSON = Data(#"""
            {
              "command": {
                "name": "usage",
                "data": {
                  "groups": [
                    {
                      "name": "Gemini Models",
                      "buckets": [
                        {"id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.64, "reset_time": "2099-12-03T07:56:21Z"},
                        {"id": "gemini-5h", "window": "5h", "remaining_fraction": 0.55, "reset_time": "2099-11-27T06:06:11Z"}
                      ]
                    },
                    {
                      "name": "Claude and GPT models",
                      "buckets": [
                        {"id": "3p-weekly", "window": "weekly", "remaining_fraction": 0, "reset_time": "2099-12-03T11:35:56Z"},
                        {"id": "3p-5h", "window": "5h", "disabled": true, "remaining_fraction": 0}
                      ]
                    }
                  ]
                }
              }
            }
            """#.utf8)
            let agyBuckets = AntigravityUsage.parseUsageOutput(agyUsageJSON)
            expect(agyBuckets.count == 3
                   && agyBuckets[0].label == "Gemini 每周" && agyBuckets[0].usedPercent == 36
                   && agyBuckets[1].label == "Gemini 5 小时" && agyBuckets[1].usedPercent == 45
                   && agyBuckets[2].label == "Claude/GPT 每周" && agyBuckets[2].usedPercent == 100,
                   "应解析 Antigravity 模型组配额并跳过 disabled 项：\(agyBuckets)")
            let agyCreditsJSON = Data(#"{"command":{"name":"credits","data":{"remaining_credits":42}}}"#.utf8)
            expect(AntigravityUsage.parseCreditsOutput(agyCreditsJSON) == 42, "应解析 Antigravity 积分余额")
            let agyUsageTSV = Data("Gemini Models\tWeekly Limit Remaining\t64%\t2099-12-03T07:56:21Z\nClaude and GPT models\tFive Hour Limit Remaining\tdisabled\t\n".utf8)
            let agyTsvBuckets = AntigravityUsage.parseUsageOutput(agyUsageTSV)
            expect(agyTsvBuckets.count == 1 && agyTsvBuckets[0].usedPercent == 36, "TSV 回退解析应跳过 disabled 行")

            let dshDir = tempRoot.appendingPathComponent("dsh-tui-prefs", isDirectory: true)
            setenv("CLAUDE_PICKER_DSH_TUI_DIR", dshDir.path, 1)
            store.closeTerminal()
            hub.terminateAll()
            _ = ok("app.runtime", ["key": "provider", "value": "dsh"])
            _ = ok("app.runtime", ["key": "mode", "value": "read-only"])
            _ = ok("app.runtime", ["key": "model", "value": "deepseek-account/deepseek-flash"])
            _ = ok("app.runtime", ["key": "effort", "value": "max"])
            let dshSnap = (ok("app.state") as? [String: Any])?["runtime"] as? [String: Any]
            expect(dshSnap?["provider"] as? String == "dsh"
                   && dshSnap?["mode"] as? String == "read-only"
                   && dshSnap?["model"] as? String == "deepseek-account/deepseek-flash"
                   && dshSnap?["effort"] as? String == "max",
                   "DeepSeek 底部运行栏应返回当前模式、模型与推理强度：\(String(describing: dshSnap))")
            expect((dshSnap?["modes"] as? [[String: Any]])?.isEmpty == false
                   && (dshSnap?["models"] as? [[String: Any]])?.isEmpty == false
                   && (dshSnap?["efforts"] as? [[String: Any]])?.isEmpty == false,
                   "DeepSeek 底部运行栏应提供可选列表")
            let reloadedDsh = DeepSeekConfig.loadOptions(in: dshDir)
            expect(reloadedDsh.mode == .readOnly
                   && reloadedDsh.model == "deepseek-account/deepseek-flash"
                   && reloadedDsh.effort == .max,
                   "DeepSeek 底部运行栏修改应持久化到 dsh-tui 偏好目录")
            unsetenv("CLAUDE_PICKER_DSH_TUI_DIR")

            // 四引擎（Claude / Antigravity / Codex / DeepSeek）4 × 3 = 12 种会话接力全组合回归
            do {
                store.closeTerminal()
                hub.terminateAll()
                let handoffDir = tempRoot.appendingPathComponent("handoff-matrix", isDirectory: true)
                let dshHome = handoffDir.appendingPathComponent("dsh-home", isDirectory: true)
                let dshProjDir = dshHome.appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
                let dshTuiDir = handoffDir.appendingPathComponent("dsh-tui", isDirectory: true)
                try FileManager.default.createDirectory(at: dshProjDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: dshTuiDir, withIntermediateDirectories: true)
                setenv("DSH_HOME", dshHome.path, 1)
                setenv("CLAUDE_PICKER_DSH_TUI_DIR", dshTuiDir.path, 1)
                setenv("CLAUDE_PICKER_CLAUDE_BIN", fakeShell.path, 1)
                setenv("CLAUDE_PICKER_AGY_BIN", fakeShell.path, 1)
                setenv("CLAUDE_PICKER_CODEX_BIN", fakeShell.path, 1)
                setenv("CLAUDE_PICKER_DSH_TUI_BIN", fakeShell.path, 1)
                defer {
                    unsetenv("DSH_HOME")
                    unsetenv("CLAUDE_PICKER_DSH_TUI_DIR")
                    unsetenv("CLAUDE_PICKER_CLAUDE_BIN")
                    unsetenv("CLAUDE_PICKER_AGY_BIN")
                    unsetenv("CLAUDE_PICKER_CODEX_BIN")
                    unsetenv("CLAUDE_PICKER_DSH_TUI_BIN")
                }

                let claudeFile = handoffDir.appendingPathComponent("src-claude.jsonl")
                try "{\"type\":\"user\",\"cwd\":\"\(repo)\",\"message\":{\"content\":\"Claude源问题\"}}\n{\"type\":\"assistant\",\"message\":{\"content\":\"Claude源回答\"}}\n"
                    .write(to: claudeFile, atomically: true, encoding: .utf8)

                let agyFile = handoffDir.appendingPathComponent("src-agy.jsonl")
                try "{\"type\":\"USER_INPUT\",\"source\":\"USER_EXPLICIT\",\"content\":\"<USER_REQUEST>Agy源问题</USER_REQUEST>\"}\n{\"type\":\"PLANNER_RESPONSE\",\"content\":\"Agy源回答\"}\n"
                    .write(to: agyFile, atomically: true, encoding: .utf8)

                let codexFile = handoffDir.appendingPathComponent("src-codex.jsonl")
                try [
                    ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\nignored"},{"type":"input_text","text":"Codex源问题"}]}}"##,
                    ##"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Codex源回答"}]}}"##,
                ].joined(separator: "\n").write(to: codexFile, atomically: true, encoding: .utf8)

                let dshUuid = UUID().uuidString.lowercased()
                let dshSid = "session-\(dshUuid)"
                let dshFile = dshProjDir.appendingPathComponent("\(dshSid).json")
                let dshPayload: [String: Any] = [
                    "version": 1,
                    "record": [
                        "identity": ["cwd": repo, "createdAt": Date().timeIntervalSince1970 * 1000],
                        "rows": [
                            "turnOutline": [
                                "ver": 1,
                                "seq": 1,
                                "val": [
                                    "turns": [
                                        ["turn": 1, "seq": 2, "prompt": "DeepSeek源问题", "response": "DeepSeek源回答"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]
                try JSONSerialization.data(withJSONObject: dshPayload).write(to: dshFile)
                let dshIndex: [String: Any] = [
                    "entries": [
                        dshSid: [
                            "derived": ["modifiedAt": Date().timeIntervalSince1970 * 1000, "title": "DeepSeek测试会话"],
                        ],
                    ],
                ]
                try JSONSerialization.data(withJSONObject: dshIndex).write(to: dshTuiDir.appendingPathComponent("session-index.json"))

                let sources: [(provider: AgentProvider, sid: String, marker: String, file: URL)] = [
                    (.claude, "handoff-src-claude", "Claude源回答", claudeFile),
                    (.antigravity, "handoff-src-agy", "Agy源回答", agyFile),
                    (.codex, "handoff-src-codex", "Codex源回答", codexFile),
                    (.dsh, dshSid, "DeepSeek源回答", dshFile),
                ]
                for item in sources {
                    store.projects[1].sessions.insert(
                        Session(id: item.sid, cwd: repo, title: "\(item.provider.shortLabel)源会话",
                                summary: nil, date: Date(), fileURL: item.file, provider: item.provider),
                        at: 0
                    )
                }

                var matrixCount = 0
                for src in sources {
                    for dst in AgentProvider.allCases where dst != src.provider {
                        let envelope = HandoffBuilder.fromSessionFile(
                            sourceProvider: src.provider,
                            targetProvider: dst,
                            title: "\(src.provider.shortLabel)源会话",
                            cwd: repo,
                            fileURL: src.file
                        )
                        expect(envelope.contains(src.marker), "\(src.provider.rawValue) → \(dst.rawValue) 信封应含源对话内容")
                        let res = ok("session.handoff", [
                            "sessionId": src.sid,
                            "sourceProvider": src.provider.rawValue,
                            "targetProvider": dst.rawValue,
                            "projectPath": repo,
                            "cwd": repo,
                        ]) as? [String: Any]
                        let newSid = res?["sessionId"] as? String ?? ""
                        expect(!newSid.isEmpty && res?["provider"] as? String == dst.rawValue,
                               "session.handoff 应支持 \(src.provider.rawValue) → \(dst.rawValue)")
                        let rows = ((ok("app.state") as? [String: Any])?["projects"] as? [[String: Any]])?[1]["sessions"] as? [[String: Any]]
                        let newRow = rows?.first { $0["id"] as? String == newSid }
                        expect(newRow?["provider"] as? String == dst.rawValue
                               && (newRow?["handoffFrom"] as? String)?.hasPrefix(src.provider.shortLabel) == true,
                               "接力新会话快照应标记 \(src.provider.shortLabel) 来源与目标 \(dst.rawValue)")
                        store.closeTerminal()
                        matrixCount += 1
                    }
                }
                expect(matrixCount == 12, "应覆盖全部 12 种引擎接力组合，实际 \(matrixCount)")

                // 单会话连续接力合并验证：Claude → Antigravity → Codex → DeepSeek → Claude 始终保持 1 条侧栏会话。
                let chainRootId = "unified-chain-root"
                let countBeforeChain = store.projects[1].sessions.count
                store.projects[1].sessions.insert(
                    Session(id: chainRootId, cwd: repo, title: "统一接力话题", summary: nil, date: Date(), fileURL: claudeFile, provider: .claude),
                    at: 0
                )
                let expectedCount = countBeforeChain + 1
                let h1 = ok("session.handoff", ["sessionId": chainRootId, "sourceProvider": "claude", "targetProvider": "antigravity", "projectPath": repo, "cwd": repo]) as? [String: Any]
                let h1Id = h1?["sessionId"] as? String ?? ""
                expect(store.projects[1].sessions.count == expectedCount, "第 1 次接力后侧栏会话数应保持不变，实际 \(store.projects[1].sessions.count) vs \(expectedCount)")

                // 模拟 Agy 接力段后继续接力到 Codex → DeepSeek → Claude
                let h2 = ok("session.handoff", ["sessionId": h1Id, "sourceProvider": "antigravity", "targetProvider": "codex", "projectPath": repo, "cwd": repo]) as? [String: Any]
                let h2Id = h2?["sessionId"] as? String ?? ""
                expect(store.projects[1].sessions.count == expectedCount, "第 2 次接力后侧栏会话数应保持不变")

                // 在同一会话内切回历史段（Claude），不应新增侧栏行，且 threadId 保持指向当前主会话。
                _ = ok("session.open", ["projectPath": repo, "cwd": repo, "sessionId": chainRootId, "provider": "claude"])
                let peekState = ok("app.state") as? [String: Any]
                let peekActive = peekState?["active"] as? [String: Any]
                expect(peekActive?["sessionId"] as? String == chainRootId && peekActive?["threadId"] as? String == h2Id,
                       "切回历史段查看时 sessionId 应为历史段且 threadId 保持为主会话：\(String(describing: peekActive))")
                expect(((peekActive?["handoffChain"] as? [[String: Any]])?.count ?? 0) >= 3,
                       "接力链应至少包含 3 段：\(String(describing: peekActive?["handoffChain"]))")

                // 切回仍在运行（或刚退出但面板仍在）的 pending Codex 段，不应报「会话尚未取得原始 ID，无法恢复」。
                _ = ok("session.open", ["projectPath": repo, "cwd": repo, "sessionId": h2Id, "provider": "codex"])
                expect(store.activeSessionId == h2Id, "应能切回 pending 接力段查看终端")

                // 继续从 Codex 接力到 DeepSeek 再接力回 Claude
                let h3 = ok("session.handoff", ["sessionId": h2Id, "sourceProvider": "codex", "targetProvider": "dsh", "projectPath": repo, "cwd": repo]) as? [String: Any]
                let h3Id = h3?["sessionId"] as? String ?? ""
                let h4 = ok("session.handoff", ["sessionId": h3Id, "sourceProvider": "dsh", "targetProvider": "claude", "projectPath": repo, "cwd": repo]) as? [String: Any]
                let h4Id = h4?["sessionId"] as? String ?? ""
                expect(store.projects[1].sessions.count == expectedCount, "连续 4 次跨引擎接力后侧栏仍只应有 1 条会话")
                let finalRows = ((ok("app.state") as? [String: Any])?["projects"] as? [[String: Any]])?[1]["sessions"] as? [[String: Any]]
                let finalRow = finalRows?.first { $0["id"] as? String == h4Id }
                expect(((finalRow?["handoffChain"] as? [[String: Any]])?.count ?? 0) >= 4, "主会话快照应携带完整接力链")

                // Codex 连续接力不丢失 <thread-handoff> 上下文且不产生嵌套标签；DeepSeek v4 JSONL 正常抽取轮次。
                let chainedCodex = tempRoot.appendingPathComponent("chained-codex.jsonl")
                let firstEnvelope = HandoffBuilder.fromSessionFile(sourceProvider: .claude, targetProvider: .codex, title: "链式测试", cwd: repo, fileURL: claudeFile)
                let chainedCodexRow: [String: Any] = [
                    "type": "response_item",
                    "payload": [
                        "type": "message",
                        "role": "user",
                        "content": [["type": "input_text", "text": firstEnvelope]],
                    ],
                ]
                let chainedCodexReply: [String: Any] = [
                    "type": "response_item",
                    "payload": [
                        "type": "message",
                        "role": "assistant",
                        "content": [["type": "output_text", "text": "Codex接力后确认完成"]],
                    ],
                ]
                let codexChainedLines = [chainedCodexRow, chainedCodexReply].compactMap { obj -> String? in
                    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
                    return String(data: d, encoding: .utf8)
                }.joined(separator: "\n")
                try codexChainedLines.write(to: chainedCodex, atomically: true, encoding: .utf8)
                let secondEnvelope = HandoffBuilder.fromSessionFile(sourceProvider: .codex, targetProvider: .antigravity, title: "链式测试", cwd: repo, fileURL: chainedCodex)
                expect(secondEnvelope.contains("Claude源回答") && secondEnvelope.contains("Codex接力后确认完成"),
                       "Codex 连续接力应保留更早轮次与 Codex 回复")
                expect(secondEnvelope.components(separatedBy: "<thread-handoff>").count == 2,
                       "连续接力信封不得嵌套多层 <thread-handoff> 标签")

                // DeepSeek v4 session.v4.jsonl 抽取测试
                let encodedRepo = "--" + repo.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "-") + "--"
                let dshV4Sid = "session-\(UUID().uuidString.lowercased())"
                let dshV4Dir = dshHome.appendingPathComponent("sessions/\(encodedRepo)/\(dshV4Sid)", isDirectory: true)
                try FileManager.default.createDirectory(at: dshV4Dir, withIntermediateDirectories: true)
                let dshV4Lines = [
                    #"{"type":"user/message","seq":1,"data":{"source":{"kind":"user"},"content":[{"type":"text","text":"DeepSeek v4 用户提问"}]}}"#,
                    #"{"type":"user/message","seq":2,"data":{"source":{"kind":"system"},"content":[{"type":"text","text":"<system-reminder>ignored</system-reminder>"}]}}"#,
                    #"{"type":"assistant/message","seq":3,"data":{"message":{"role":"assistant","content":[{"type":"reasoning","text":"思考过程"},{"type":"text","text":"DeepSeek v4 助手回答"}]}}}"#,
                ].joined(separator: "\n")
                try dshV4Lines.write(to: dshV4Dir.appendingPathComponent("session.v4.jsonl"), atomically: true, encoding: .utf8)
                let dshV4Envelope = HandoffBuilder.fromSessionFile(sourceProvider: .dsh, targetProvider: .codex, title: "v4测试", cwd: repo, fileURL: nil, sessionId: dshV4Sid)
                expect(dshV4Envelope.contains("DeepSeek v4 用户提问") && dshV4Envelope.contains("DeepSeek v4 助手回答") && !dshV4Envelope.contains("<system-reminder>"),
                       "DeepSeek v4 会话应提取真实用户/助手轮次并过滤系统提醒")

                // 删除统一接力会话应同步移除
                _ = ok("app.remove", ["projectPath": repo, "sessionId": h4Id])
                expect(store.projects[1].sessions.count == countBeforeChain, "移除统一接力会话后应恢复原会话数")
            }

            hub.terminateAll()
            expect(!hub.isLive(sid) && !SessionOwnership.shared.heldByTerminal(sid), "退出时结束执行器并释放会话")
            store.closeTerminal()
            unsetenv("CLAUDE_PICKER_CLAUDE_BIN")
    } catch {
        expect(false, "结构化聊天回归准备失败：\(error)")
    }
}

// 回归测试会改 tree.json / settings.json：只允许发生在调试数据目录或临时 HOME 里（脚本负责设置）。
if bridgeFailures > 0 {
    print("\(bridgeFailures) 项失败")
    exit(1)
}
print("Bridge regression checks passed")
