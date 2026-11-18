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
}

// 回归测试会改 tree.json / settings.json：只允许发生在调试数据目录或临时 HOME 里（脚本负责设置）。
if bridgeFailures > 0 {
    print("\(bridgeFailures) 项失败")
    exit(1)
}
print("Bridge regression checks passed")
