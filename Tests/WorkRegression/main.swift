import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

// Work 领域回归：真实 SQLite、真实 git 临时仓库、真实子进程（协议替身 fake-claude.py）。
// 由 scripts/test-work.sh 编译运行；不访问网络，不碰正式版数据目录，不调用真实 Claude。
// 括号里的编号对应 docs/agent-workspace-prototype/ACCEPTANCE.md 的场景。

setvbuf(stdout, nil, _IOLBF, 0)

let environment = ProcessInfo.processInfo.environment
guard let scratch = environment["WORK_TEST_DIR"], !scratch.isEmpty else {
    print("缺少 WORK_TEST_DIR")
    exit(2)
}
let scratchURL = URL(fileURLWithPath: scratch)

final class Counter: @unchecked Sendable {
    var passed = 0
    var failed: [String] = []
}
let counter = Counter()

func check(_ condition: @autoclosure () -> Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition() {
        counter.passed += 1
        print("  ✓ \(name)")
    } else {
        counter.failed.append(name)
        let extra = detail()
        print("  ✗ \(name)" + (extra.isEmpty ? "" : "\n      \(extra)"))
    }
}

@discardableResult
func sh(_ command: String, cwd: String) -> ProcResult {
    Proc.run("/bin/zsh", ["-c", command], cwd: cwd, timeout: 60)
}

func makeRepo(_ name: String) -> String {
    let url = scratchURL.appendingPathComponent("repos/\(name)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let path = WorkspaceService.canonical(url.path)
    sh("git init -q -b main . && git config user.email test@example.com && git config user.name tester && echo base > README.md && git add -A && git commit -q -m base", cwd: path)
    return path
}

func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(40_000)
    }
    return condition()
}

func work(_ core: WorkCore, _ id: String) -> JSONValue {
    (core.snapshot()["works"]?.arrayValue ?? []).first { $0["id"]?.stringValue == id } ?? .null
}

func status(_ core: WorkCore, _ id: String) -> String { work(core, id)["status"]?.stringValue ?? "" }

func events(_ core: WorkCore, _ id: String) -> [JSONValue] {
    (try? core.transcript(workId: id, after: 0))?["events"]?.arrayValue ?? []
}

func fakeLog() -> [JSONValue] {
    guard let path = environment["FAKE_CLAUDE_LOG"], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
}

func fakeAgyLog() -> [JSONValue] {
    guard let path = environment["FAKE_AGY_LOG"], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
}

func spawns(session: String?) -> Int {
    fakeLog().filter { $0["event"]?.stringValue == "spawn" && $0["session"]?.stringValue == session }.count
}

func create(_ core: WorkCore, project: WorkProject, title: String, objective: String, start: Bool = true,
            key: String? = nil, isolation: String = "worktree") throws -> String {
    var request = WorkCore.CreateRequest(projectId: project.id, title: title, objective: objective)
    request.start = start
    request.idempotencyKey = key
    request.isolation = isolation
    let result = try core.create(request)
    return result["work"]?["id"]?.stringValue ?? ""
}

// MARK: - 崩溃子进程模式（OP-02）

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--crash-child" {
    // 起一个核心、让一个 Work 进入执行中，然后不做任何清理直接退出，模拟应用崩溃。
    let core = WorkCore(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
    let projects = try core.syncProjects([(path: CommandLine.arguments[3], name: "crash-repo")])
    let id = try create(core, project: projects[0], title: "崩溃前在执行", objective: "SCENARIO:slow")
    guard waitUntil(15, { work(core, id)["busy"]?.boolValue == true }) else {
        print("child: work never became busy")
        exit(1)
    }
    print("CHILD-WORK \(id)")
    _exit(9)
}

// MARK: - MCP 包装模式（转给父进程里的来源网关）

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--source-mcp" {
    SourceMCPBridge.run(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
}

// MARK: - 用例

let dataA = scratchURL.appendingPathComponent("data-a")
let core = WorkCore(directory: dataA)
let repoA = makeRepo("alpha")
let repoB = makeRepo("beta")
let projects = try core.syncProjects([(path: repoA, name: "alpha"), (path: repoB, name: "beta")])
let alpha = projects.first { $0.name == "alpha" }!
let beta = projects.first { $0.name == "beta" }!

print("创建与启动授权")
do {
    let id = try create(core, project: alpha, title: "不自动启动", objective: "SCENARIO:edit", start: false)
    let w = work(core, id)
    check(w["displayId"]?.stringValue == "WORK-1001", "WK-01 分配持久编号 WORK-1001", w["displayId"]?.stringValue ?? "nil")
    check(w["origin"]?.stringValue == "local" && w["project"]?["path"]?.stringValue == repoA, "WK-01 记录来源与项目目录")
    usleep(500_000)
    check(status(core, id) == "queued" && w["startRequested"]?.boolValue == false, "WK-02 未请求启动的 Work 保持排队")
    check(fakeLog().isEmpty, "WK-02 调度器没有为它启动进程")

    // 重复启动同一个 Work：只应有一轮 Run、一个进程。
    _ = try core.start(workId: id, revision: nil, requestId: "start-1")
    _ = try core.start(workId: id, revision: nil, requestId: "start-1")
    _ = try core.start(workId: id, revision: nil, requestId: "start-2")
    check(waitUntil { status(core, id) == "waiting_review" }, "执行结束后进入待审阅", status(core, id))
    let transcript = try core.transcript(workId: id, after: 0)
    let runs = transcript["runs"]?.arrayValue ?? []
    let session = work(core, id)["sessionId"]?.stringValue
    check(runs.count == 1 && spawns(session: session) == 1, "WK-06 连点启动只产生一轮 Run 和一个进程",
          "runs=\(runs.count) spawns=\(spawns(session: session))")
    let path = work(core, id)["workspacePath"]?.stringValue ?? ""
    check(path.hasPrefix(repoA + "/.worktrees/") && FileManager.default.fileExists(atPath: path + "/work-output.txt"),
          "在项目的独立 worktree 里执行", path)
    check(!FileManager.default.fileExists(atPath: repoA + "/work-output.txt"), "GT-01 主工作区没有被改动")
    let kinds = events(core, id).compactMap { $0["kind"]?.stringValue }
    check(kinds.contains("tool_use") && kinds.contains("tool_result") && kinds.contains("assistant") && kinds.contains("turn_result"),
          "事件流记录了工具调用与结果", kinds.joined(separator: ","))
    let seqs = events(core, id).compactMap { $0["seq"]?.intValue }
    check(seqs == Array(1...max(seqs.count, 1)), "事件序号按 Work 连续，可用于发现缺口")
    check(waitUntil { ((try? core.transcript(workId: id, after: 0))?["evidence"]?.arrayValue ?? []).contains { $0["kind"]?.stringValue == "diff" } },
          "记录了本轮结束时的差异证据")

    // 审阅绑定代码版本。
    let state = try core.reviewState(workId: id)
    let runId = work(core, id)["currentRunId"]?.stringValue ?? ""
    check(state["files"]?.arrayValue?.count == 1 && state["files"]?.arrayValue?.first?["path"]?.stringValue == "work-output.txt",
          "审阅视图列出相对基线的实际变更")
    let patch = try core.reviewDiff(workId: id, file: "work-output.txt")
    check(patch["patch"]?.stringValue?.contains("+generated by fake claude") == true, "GT-05 文件差异来自真实仓库")
    do {
        _ = try core.deliveryConfirm(workId: id, target: "wecom", body: "x", requestId: nil)
        check(false, "独立本地 Work 不能向企业微信会话汇报")
    } catch let error as WorkError {
        check(error.code == .rejected, "独立本地 Work 不能向企业微信会话汇报")
    }
    try "changed after review\n".write(toFile: path + "/work-output.txt", atomically: true, encoding: .utf8)
    do {
        _ = try core.acceptReview(workId: id, runId: runId, tree: state["tree"]?.stringValue, note: nil, requestId: nil)
        check(false, "GT-03 代码变化后旧版本的审阅被拒绝")
    } catch let error as WorkError {
        check(error.code == .conflict && status(core, id) == "waiting_review", "GT-03 代码变化后旧版本的审阅被拒绝")
    }
    do {
        _ = try core.acceptReview(workId: id, runId: "another-run", tree: nil, note: nil, requestId: nil)
        check(false, "审阅不是当前轮次时被拒绝")
    } catch let error as WorkError {
        check(error.code == .conflict, "审阅不是当前轮次时被拒绝")
    }
    let fresh = try core.reviewState(workId: id)
    _ = try core.acceptReview(workId: id, runId: runId, tree: fresh["tree"]?.stringValue, note: "ok", requestId: "accept-1")
    let again = try core.acceptReview(workId: id, runId: runId, tree: fresh["tree"]?.stringValue, note: "ok", requestId: "accept-1")
    check(status(core, id) == "completed" && again["accepted"]?.boolValue == true, "确认当前版本后 Work 完成，重复确认幂等")
    let review = (try core.transcript(workId: id, after: 0))["evidence"]?.arrayValue?.last { $0["kind"]?.stringValue == "review" }
    check(review?["tree"]?.stringValue == fresh["tree"]?.stringValue, "审阅证据记录了具体的 tree，而不是布尔值")
    try "changed after accept\n".write(toFile: path + "/work-output.txt", atomically: true, encoding: .utf8)
    let afterAccept = try core.reviewState(workId: id)
    check(afterAccept["acceptedStale"]?.boolValue == true, "GT-03 完成后代码再变，已有批准标记为过期")
    do {
        _ = try core.send(workId: id, messageId: "after-done", text: "再改一下")
        check(false, "WK-12 已完成的 Work 不静默接收新范围")
    } catch let error as WorkError {
        check(error.code == .rejected, "WK-12 已完成的 Work 不静默接收新范围")
    }
    check(waitUntil(8) { work(core, id)["processAlive"]?.boolValue == false }, "完成后不保留空闲的执行进程")
}

print("幂等创建与消息")
do {
    let first = try create(core, project: beta, title: "同一来源事件", objective: "SCENARIO:slow", start: false, key: "evt-42")
    let second = try create(core, project: beta, title: "同一来源事件（重放）", objective: "SCENARIO:slow", start: false, key: "evt-42")
    check(first == second, "相同幂等键只创建一个 Work（WB-09 / TP-04 的基础）")
    do {
        _ = try core.send(workId: first, messageId: "m0", text: "hi")
        check(false, "未启动的 Work 不接收消息")
    } catch { check(true, "未启动的 Work 不接收消息") }
    do {
        var bad = WorkCore.CreateRequest(projectId: "missing", title: "x", objective: "y")
        bad.start = true
        _ = try core.create(bad)
        check(false, "未登记的项目不能创建 Work")
    } catch let error as WorkError {
        check(error.code == .invalid, "未登记的项目不能创建 Work（WB-11）")
    }
    do {
        _ = try core.create(WorkCore.CreateRequest(projectId: beta.id, title: "  ", objective: "y"))
        check(false, "名称为空不创建")
    } catch { check(true, "名称为空不创建") }
    _ = try core.cancel(workId: first, revision: nil, requestId: nil)
    check(status(core, first) == "cancelled", "未执行的 Work 取消后立即结束")
}

print("并发上限与中断")
do {
    let a = try create(core, project: alpha, title: "慢任务 A", objective: "SCENARIO:slow")
    let b = try create(core, project: beta, title: "慢任务 B", objective: "SCENARIO:slow")
    check(waitUntil { work(core, a)["busy"]?.boolValue == true && work(core, b)["busy"]?.boolValue == true }, "两个 Work 同时在执行")
    let c = try create(core, project: alpha, title: "慢任务 C", objective: "SCENARIO:slow")
    usleep(700_000)
    let capacity = core.snapshot()["capacity"]
    check(status(core, c) == "queued" && capacity?["running"]?.intValue == 2 && capacity?["queued"]?.intValue == 1,
          "WK-03 第三个 Work 排队，不超出执行槽", "c=\(status(core, c)) capacity=\(capacity?.serialized() ?? "")")
    check(work(core, c)["sessionId"]?.stringValue == nil, "WK-03 排队的 Work 没有创建进程")

    _ = try core.interrupt(workId: a, requestId: "int-a")
    let repeatInterrupt = try core.interrupt(workId: a, requestId: "int-a")
    check(repeatInterrupt["accepted"]?.boolValue != nil, "连点停止不报错")
    check(waitUntil { status(core, a) == "interrupted" }, "WK-07 停止后状态为已中断", status(core, a))
    let interrupts = fakeLog().filter { $0["event"]?.stringValue == "control_request" && $0["subtype"]?.stringValue == "interrupt"
        && $0["session"]?.stringValue == work(core, a)["sessionId"]?.stringValue }
    check(interrupts.count == 1, "WK-07 中断请求只发了一次", "\(interrupts.count)")
    check(events(core, a).contains { $0["kind"]?.stringValue == "assistant" }, "WK-07 已收到的输出保留")
    check(status(core, b) == "running", "WK-07 其他 Work 不受影响")
    check(waitUntil { status(core, c) == "running" && work(core, c)["busy"]?.boolValue == true }, "释放执行槽后排队的 Work 启动")

    // 取消正在执行的 Work：执行器停下后才是 cancelled，迟到事件不改变结论。
    _ = try core.cancel(workId: b, revision: nil, requestId: "cancel-b")
    check(waitUntil(12) { status(core, b) == "cancelled" }, "取消执行中的 Work，进程停止后落为已取消", status(core, b))
    usleep(400_000)
    check(status(core, b) == "cancelled" && work(core, b)["processAlive"]?.boolValue == false, "WK-08 取消后不再被重新启动")
    let worktreeB = work(core, b)["workspacePath"]?.stringValue ?? ""
    check(FileManager.default.fileExists(atPath: worktreeB), "取消不自动删除 worktree")
    do {
        _ = try core.start(workId: b, revision: nil, requestId: nil)
        check(false, "已取消的 Work 不能启动")
    } catch { check(true, "已取消的 Work 不能启动") }

    // 中断后重试：新一轮 Run，旧轮次保留；复用会话而不是重放目标。
    _ = try core.retry(workId: a, revision: nil, requestId: "retry-a")
    check(waitUntil { status(core, a) == "waiting_review" }, "中断后重试能继续并进入待审阅", status(core, a))
    let runsA = (try core.transcript(workId: a, after: 0))["runs"]?.arrayValue ?? []
    check(runsA.count == 2 && runsA.first?["status"]?.stringValue == "interrupted", "WK-04 重试新建 Run，旧轮次的记录保留",
          runsA.map { $0["status"]?.stringValue ?? "" }.joined(separator: ","))
    let sessionA = work(core, a)["sessionId"]?.stringValue
    let slowTurns = fakeLog().filter { $0["event"]?.stringValue == "turn" && $0["session"]?.stringValue == sessionA
        && $0["scenario"]?.stringValue == "slow" }
    check(slowTurns.count == 1, "重试没有重放原来的目标消息", "\(slowTurns.count)")
    _ = try core.cancel(workId: c, revision: nil, requestId: nil)
    check(waitUntil(12) { status(core, c) == "cancelled" }, "清理：取消慢任务 C")
    _ = try core.cancel(workId: a, revision: nil, requestId: nil)
    check(waitUntil(12) { status(core, a) == "cancelled" }, "待审阅的 Work 可以取消")
}

print("业务问题与工具权限")
do {
    let q = try create(core, project: alpha, title: "需要确认口径", objective: "SCENARIO:question")
    let other = try create(core, project: beta, title: "另一个任务", objective: "SCENARIO:edit")
    check(waitUntil { status(core, q) == "waiting_user" }, "WK-09 收到业务问题后进入待回答", status(core, q))
    check(waitUntil { status(core, other) == "waiting_review" }, "WK-09 其他 Work 照常推进")
    let transcript = try core.transcript(workId: q, after: 0)
    let attention = transcript["attentions"]?.arrayValue?.first ?? .null
    let attentionId = attention["id"]?.stringValue ?? ""
    check(attention["kind"]?.stringValue == "question" && attention["body"]?["questions"]?.arrayValue?.count == 1
          && work(core, q)["attentionId"]?.stringValue == attentionId && work(core, q)["unread"]?.boolValue == true,
          "WK-09 问题有自己的身份、正文与未读标记")
    check(core.snapshot()["capacity"]?["running"]?.intValue == 0, "等待回答不占执行槽")
    do {
        _ = try core.answer(attentionId: attentionId, revision: nil, answer: .obj(["answers": .object([:])]))
        check(false, "没有显式答案时不接受")
    } catch let error as WorkError {
        check(error.code == .invalid && status(core, q) == "waiting_user", "没有显式答案时不接受，也不恢复执行")
    }
    do {
        _ = try core.send(workId: q, messageId: "mq", text: "随便说点什么")
        check(false, "待回答时普通消息不当作答案")
    } catch { check(true, "待回答时普通消息不当作答案") }
    core.markSeen(workId: q)
    check(work(core, q)["unread"]?.boolValue == false && status(core, q) == "waiting_user", "查看只消除未读，不清除待处理的问题")
    let answered = try core.answer(attentionId: attentionId, revision: nil,
                                   answer: .obj(["answers": .obj(["同步失败时如何处理本地状态？": .string("保留并重试")])]))
    check(answered["accepted"]?.boolValue == true, "回答被记录")
    let repeated = try core.answer(attentionId: attentionId, revision: nil,
                                   answer: .obj(["answers": .obj(["同步失败时如何处理本地状态？": .string("回滚本地操作")])]))
    check(repeated["accepted"]?.boolValue == false && repeated["state"]?.stringValue == "already_answered",
          "WK-10 已回答的问题再次作答被拒绝")
    check(waitUntil { status(core, q) == "waiting_review" }, "回答后恢复执行并进入待审阅", status(core, q))
    let answerFile = (work(core, q)["workspacePath"]?.stringValue ?? "") + "/answer.txt"
    let content = (try? String(contentsOfFile: answerFile, encoding: .utf8)) ?? ""
    check(content.contains("保留并重试") && !content.contains("回滚本地操作"), "CLI-04 执行器收到的是第一次的答案", content)
    let delivered = fakeLog().filter { $0["event"]?.stringValue == "control_response"
        && $0["session"]?.stringValue == work(core, q)["sessionId"]?.stringValue }
    check(delivered.count == 1, "WK-10 答复只投递了一次", "\(delivered.count)")
    check(status(core, other) == "waiting_review", "回答 A 的问题没有改变 B 的状态")

    let p = try create(core, project: alpha, title: "需要写权限", objective: "SCENARIO:permission")
    check(waitUntil { status(core, p) == "waiting_user" }, "工具权限请求进入待回答")
    let permission = (try core.transcript(workId: p, after: 0))["attentions"]?.arrayValue?.first ?? .null
    check(permission["kind"]?.stringValue == "permission" && permission["toolName"]?.stringValue == "Write"
          && permission["body"]?["risk"]?.stringValue == "写入工作目录内的文件", "权限请求带工具名、参数与风险范围",
          permission["body"]?["risk"]?.stringValue ?? "")
    _ = try core.answer(attentionId: permission["id"]?.stringValue ?? "", revision: nil,
                        answer: .obj(["behavior": .string("deny"), "message": .string("不要写这个文件")]))
    check(waitUntil { status(core, p) == "waiting_review" }, "拒绝后本轮正常结束")
    check(!FileManager.default.fileExists(atPath: (work(core, p)["workspacePath"]?.stringValue ?? "") + "/guarded.txt"),
          "CLI-04 拒绝后没有执行写入")

    // 请求修改：旧审阅结论失效，新一轮 Run；同一个 messageId 只接受一次。
    let runBefore = work(core, p)["currentRunId"]?.stringValue
    _ = try core.send(workId: p, messageId: "change-1", text: "请改成允许写入 SCENARIO:permission")
    let dup = try core.send(workId: p, messageId: "change-1", text: "请改成允许写入 SCENARIO:permission")
    check(dup["duplicate"]?.boolValue == true, "同一 messageId 重复发送不产生第二条消息")
    check(waitUntil { status(core, p) == "waiting_user" && work(core, p)["currentRunId"]?.stringValue != runBefore },
          "请求修改后开启新一轮 Run")
    let runsP = (try core.transcript(workId: p, after: 0))["runs"]?.arrayValue ?? []
    check(runsP.first?["status"]?.stringValue == "superseded", "旧轮次标记为已被取代，证据保留")
    let second = (try core.transcript(workId: p, after: 0))["attentions"]?.arrayValue?.last ?? .null
    let attentionCount = (try core.transcript(workId: p, after: 0))["attentions"]?.arrayValue?.count
    check(attentionCount == 2 && second["status"]?.stringValue == "open", "新一轮重新发起权限请求，旧批准不复用")
    _ = try core.answer(attentionId: second["id"]?.stringValue ?? "", revision: nil, answer: .obj(["behavior": .string("allow")]))
    check(waitUntil { status(core, p) == "waiting_review" }, "允许后进入待审阅")
    check(FileManager.default.fileExists(atPath: (work(core, p)["workspacePath"]?.stringValue ?? "") + "/guarded.txt"),
          "CLI-04 允许后执行了写入")
    let userTurns = fakeLog().filter { $0["event"]?.stringValue == "user" && $0["session"]?.stringValue == work(core, p)["sessionId"]?.stringValue }
    check(userTurns.count == 2, "修改意见只送达了一次", "\(userTurns.count)")

    // 等待回答时停止：未答请求作废。
    let s = try create(core, project: beta, title: "提问后被停止", objective: "SCENARIO:question")
    check(waitUntil { status(core, s) == "waiting_user" }, "再次进入待回答")
    let pending = (try core.transcript(workId: s, after: 0))["attentions"]?.arrayValue?.first?["id"]?.stringValue ?? ""
    _ = try core.interrupt(workId: s, requestId: nil)
    check(waitUntil { status(core, s) == "interrupted" }, "待回答时停止后为已中断", status(core, s))
    let late = try core.answer(attentionId: pending, revision: nil,
                               answer: .obj(["answers": .obj(["同步失败时如何处理本地状态？": .string("回滚本地操作")])]))
    check(late["accepted"]?.boolValue == false && late["state"]?.stringValue == "expired", "WK-10 过期的问题不能再回答")
    for id in [q, other, p, s] { _ = try? core.cancel(workId: id, revision: nil, requestId: nil) }
    check(waitUntil(12) { [q, other, p, s].allSatisfy { status(core, $0) == "cancelled" } }, "清理本组 Work")
}

print("失败、崩溃与多字节输出")
do {
    let f = try create(core, project: alpha, title: "执行出错", objective: "SCENARIO:fail")
    check(waitUntil { status(core, f) == "failed" }, "执行器报告出错时 Work 失败", status(core, f))
    check(work(core, f)["statusReason"]?.stringValue?.isEmpty == false, "失败原因可见")

    let c = try create(core, project: beta, title: "进程崩溃", objective: "SCENARIO:crash")
    check(waitUntil { status(core, c) == "interrupted" }, "CLI-09 进程中途退出后为已中断（结果未知）", status(core, c))
    let run = (try core.transcript(workId: c, after: 0))["runs"]?.arrayValue?.last
    check(run?["exitCode"]?.intValue == 3 && run?["error"]?.stringValue?.contains("boom") == true, "CLI-09 记录了退出码与错误输出",
          run?.serialized() ?? "")

    let m = try create(core, project: alpha, title: "多字节", objective: "SCENARIO:multibyte")
    check(waitUntil { status(core, m) == "waiting_review" }, "多字节场景结束")
    let text = events(core, m).first { $0["kind"]?.stringValue == "assistant" }?["payload"]?["text"]?.stringValue ?? ""
    check(text == "多字节字符切包测试：订单批量锁定与解锁 ✅", "CLI-03 多字节字符跨数据块不乱码", text)

    // 目录失效：不是静默换目录，而是失败并保留原因；重试保留旧轮次。
    let gonePath = scratchURL.appendingPathComponent("repos/gone").path
    try FileManager.default.createDirectory(atPath: gonePath, withIntermediateDirectories: true)
    let gone = try core.syncProjects([(path: repoA, name: "alpha"), (path: repoB, name: "beta"), (path: gonePath, name: "gone")])
        .first { $0.name == "gone" }!
    let g = try create(core, project: gone, title: "目录会被移走", objective: "SCENARIO:edit", start: false)
    try FileManager.default.removeItem(atPath: gonePath)
    _ = try core.start(workId: g, revision: nil, requestId: nil)
    check(waitUntil { status(core, g) == "failed" }, "WK-04 / WB-12 启动前目录失效则失败", status(core, g))
    check(work(core, g)["workspacePath"]?.stringValue == nil, "WB-12 没有降级到其他目录执行")
    _ = try core.retry(workId: g, revision: nil, requestId: nil)
    check(waitUntil { status(core, g) == "failed" }, "目录仍不可用时重试再次失败")
    let runsG = (try core.transcript(workId: g, after: 0))["runs"]?.arrayValue ?? []
    check(runsG.count == 2 && runsG.allSatisfy { $0["status"]?.stringValue == "failed" && $0["error"]?.stringValue?.isEmpty == false },
          "WK-04 每次失败的 Run 都保留了错误信息")

    // 没有提交的仓库：建不了 worktree。
    let emptyPath = scratchURL.appendingPathComponent("repos/empty").path
    try FileManager.default.createDirectory(atPath: emptyPath, withIntermediateDirectories: true)
    sh("git init -q .", cwd: emptyPath)
    let empty = try core.syncProjects([(path: repoA, name: "alpha"), (path: repoB, name: "beta"), (path: emptyPath, name: "empty")])
        .first { $0.name == "empty" }!
    let e = try create(core, project: empty, title: "空仓库", objective: "SCENARIO:edit")
    check(waitUntil { status(core, e) == "failed" }, "WK-04 worktree 准备失败记为失败而不是执行中")

    // 非 Git 目录：可以执行，但如实标记没有隔离、不能绑定版本。
    let plainPath = WorkspaceService.canonical(scratchURL.appendingPathComponent("repos/plain").path)
    try FileManager.default.createDirectory(atPath: plainPath, withIntermediateDirectories: true)
    let plain = try core.syncProjects([(path: repoA, name: "alpha"), (path: repoB, name: "beta"), (path: plainPath, name: "plain")])
        .first { $0.name == "plain" }!
    let n = try create(core, project: plain, title: "非仓库目录", objective: "SCENARIO:edit")
    check(waitUntil { status(core, n) == "waiting_review" }, "非 Git 目录可以执行")
    let stateN = try core.reviewState(workId: n)
    check(work(core, n)["isolation"]?.stringValue == "project" && stateN["isRepository"]?.boolValue == false,
          "非 Git 目录如实标记：未隔离、无法绑定代码版本")
    for id in [f, c, m, g, e, n] { _ = try? core.cancel(workId: id, revision: nil, requestId: nil) }
}

print("握手与启动失败")
do {
    setenv("CLAUDE_PICKER_CLAUDE_BIN", "/nonexistent/claude", 1)
    // LoginEnv 只读一次环境；找不到 CLI 的路径用专门的核心实例验证不了，这里直接验证定位函数的行为。
    unsetenv("CLAUDE_PICKER_CLAUDE_BIN")
    check(ClaudeLocator.find() == environment["CLAUDE_PICKER_CLAUDE_BIN"], "CLI-01 使用显式指定的 CLI 路径")
    let args = ClaudeProcess.arguments(for: ExecutorConfig(executable: "x", cwd: "/", sessionId: "sid", resume: true,
                                                           permissionMode: "acceptEdits", model: "sonnet", effort: nil, environment: [:]))
    check(args.contains("--resume") && !args.contains("--session-id") && args.contains("stdio")
          && args.firstIndex(of: "--permission-mode").map { args[$0 + 1] } == "acceptEdits",
          "已有会话用 --resume，权限走结构化请求而不是按键")
}

print("投递与导出")
do {
    let d = try create(core, project: alpha, title: "交付流程", objective: "SCENARIO:edit")
    check(waitUntil { status(core, d) == "waiting_review" }, "交付用例进入待审阅")
    do {
        _ = try core.deliveryPreview(workId: d, target: "tapd")
        check(false, "TP-11 无 TapdRef 的 Work 没有 TAPD 回填")
    } catch let error as WorkError {
        check(error.code == .rejected, "TP-11 无 TapdRef 的 Work 没有 TAPD 回填")
    }
    let card = try core.exportMarkdown(workId: d, kind: "taskcard")
    check(card["markdown"]?.stringValue?.contains("任务卡状态：active") == true
          && card["markdown"]?.stringValue?.contains("blocked（等待审阅）") == true, "AS-04 任务卡导出保留等待事实",
          card["markdown"]?.stringValue ?? "")
    let record = try core.exportMarkdown(workId: d, kind: "record")
    check(record["markdown"]?.stringValue?.contains("未运行") == true, "执行记录里没跑过的验证写「未运行」")
    check(status(core, d) == "waiting_review", "导出不改变 Work 状态")

    _ = try core.runCheck(workId: d, command: "test -f work-output.txt && echo token=abcdef123456")
    check(waitUntil { ((try? core.transcript(workId: d, after: 0))?["evidence"]?.arrayValue ?? [])
        .contains { $0["kind"]?.stringValue == "check" && $0["detail"]?["state"]?.stringValue == "passed" } }, "验证命令的结果记为证据")
    let checkEvidence = (try core.transcript(workId: d, after: 0))["evidence"]?.arrayValue?.last { $0["kind"]?.stringValue == "check" }
    check(checkEvidence?["detail"]?["exitCode"]?.intValue == 0 && checkEvidence?["tree"]?.stringValue?.isEmpty == false
          && checkEvidence?["detail"]?["startedAt"]?.stringValue != nil, "验证证据带命令、退出码、起止时间与代码版本")
    check(checkEvidence?["detail"]?["output"]?.stringValue?.contains("abcdef123456") == false, "OP-09 输出里的凭据形态被脱敏",
          checkEvidence?["detail"]?["output"]?.stringValue ?? "")
    _ = try? core.cancel(workId: d, revision: nil, requestId: nil)
}

print("企业微信 / WorkBuddy 来源网关")
do {
    func call(_ method: String, _ params: JSONValue) -> JSONValue { SourceGateway.handle(core, method: method, params: params) }
    func src(_ conversation: String, _ message: String, actor: String = "zhang") -> JSONValue {
        .obj(["accountId": .string("corp"), "conversationId": .string(conversation), "messageId": .string(message),
              "actorId": .string(actor), "conversationTitle": .string("研发协作群")])
    }
    func intent(_ objective: String, project: String?, evidence: [String] = ["消息里写明了项目名"], resolved: Bool = true) -> JSONValue {
        .obj(["objective": .string(objective), "projectId": .str(project),
              "resolution": .string(resolved ? "resolved" : "needs_clarification"),
              "evidence": .array(evidence.map { .string($0) }), "question": resolved ? .null : .string("要在哪个项目里处理？")])
    }
    let wecomWorks = { (core.snapshot()["works"]?.arrayValue ?? []).filter { $0["origin"]?.stringValue == "wecom" } }

    let index = call("list_projects", .object([:]))["result"]
    let listed = index?["projects"]?.arrayValue ?? []
    check(listed.contains { $0["projectId"]?.stringValue == alpha.id && $0["name"]?.stringValue == "alpha" }
          && listed.allSatisfy { $0["path"] == nil }, "项目索引只给 ID / 名称 / 可用状态，不含路径")

    let closed = call("submit_intent", .obj(["source": src("room-1", "m-0"), "text": .string("x"), "intent": intent("优化搜索", project: alpha.id)]))
    check(closed["ok"]?.boolValue == false && wecomWorks().isEmpty, "WB-17 接收关闭时不创建来源 Work")

    try core.putSetting("robot", .obj(["name": .string("开发协作助手"), "enabled": .bool(true),
                                       "autoStart": .bool(false), "remoteAnswers": .bool(false)]))
    let first = call("submit_intent", .obj(["source": src("room-1", "m-1"), "text": .string("帮我在 alpha 项目里优化会话搜索"),
                                            "intent": intent("优化会话搜索 SCENARIO:edit", project: alpha.id)]))["result"] ?? .null
    let firstId = first["displayId"]?.stringValue ?? ""
    let firstWork = wecomWorks().first { $0["displayId"]?.stringValue == firstId } ?? .null
    check(first["state"]?.stringValue == "created" && firstWork["project"]?["id"]?.stringValue == alpha.id,
          "WB-02 明确指向已知项目时自动归到该项目", first.serialized())
    check(firstWork["origin"]?.stringValue == "wecom" && (firstWork["tapdRefs"]?.arrayValue ?? []).isEmpty
          && firstWork["sourceConversationId"]?.stringValue != nil, "WB-13 来源 Work 记录原会话，且没有 TAPD 关联")
    check(firstWork["startRequested"]?.boolValue == false && first["startAuthorized"]?.boolValue == false,
          "来源身份未验证：默认只创建，不授权启动")

    let replay = call("submit_intent", .obj(["source": src("room-1", "m-1"), "text": .string("帮我在 alpha 项目里优化会话搜索"),
                                             "intent": intent("优化会话搜索 SCENARIO:edit", project: alpha.id)]))["result"] ?? .null
    check(replay["duplicate"]?.boolValue == true && replay["displayId"]?.stringValue == firstId && wecomWorks().count == 1,
          "WB-09 同一消息重放只有一个 Work，回执相同")

    let second = call("submit_intent", .obj(["source": src("room-1", "m-2"), "text": .string("beta 项目里修一下导出"),
                                             "intent": intent("修复导出", project: beta.id)]))["result"] ?? .null
    let secondWork = wecomWorks().first { $0["displayId"]?.stringValue == second["displayId"]?.stringValue } ?? .null
    check(second["state"]?.stringValue == "created" && secondWork["project"]?["id"]?.stringValue == beta.id && wecomWorks().count == 2,
          "WB-03 同一个群里的另一个项目，新 Work 归到新项目")

    let vague = call("submit_intent", .obj(["source": src("room-1", "m-3"), "text": .string("帮我优化搜索"),
                                            "intent": intent("优化搜索", project: nil, resolved: false)]))["result"] ?? .null
    let intentId = vague["intentId"]?.stringValue ?? ""
    check(vague["state"]?.stringValue == "needs_clarification" && !intentId.isEmpty && wecomWorks().count == 2,
          "WB-04 目标不明确时只记录澄清，不创建 Work")
    let spawnsBefore = fakeLog().filter { $0["event"]?.stringValue == "spawn" }.count
    let stranger = call("submit_intent", .obj(["source": src("room-2", "m-4", actor: "li"), "text": .string("在 alpha 里"),
                                               "intentId": .string(intentId), "intent": intent("优化搜索", project: alpha.id)]))["result"] ?? .null
    check(stranger["state"]?.stringValue == "rejected" && stranger["reason"]?.stringValue == "other_conversation" && wecomWorks().count == 2,
          "WB-07 另一个会话的回复不能确定原意图的目标")
    let otherActor = call("submit_intent", .obj(["source": src("room-1", "m-5", actor: "li"), "text": .string("在 alpha 里"),
                                                 "intentId": .string(intentId), "intent": intent("优化搜索", project: alpha.id)]))["result"] ?? .null
    check(otherActor["state"]?.stringValue == "rejected" && otherActor["reason"]?.stringValue == "other_actor",
          "WB-07 同群其他成员的回复不当作发起人的确认")
    let stillVague = call("submit_intent", .obj(["source": src("room-1", "m-6"), "text": .string("就那个项目"),
                                                 "intentId": .string(intentId), "intent": intent("优化搜索", project: nil, resolved: false)]))["result"] ?? .null
    check(stillVague["state"]?.stringValue == "needs_clarification" && stillVague["intentId"]?.stringValue == intentId,
          "回复仍不明确时继续追问，沿用同一个意图")
    let clarified = call("submit_intent", .obj(["source": src("room-1", "m-7"), "text": .string("在 alpha 项目里处理"),
                                                "intentId": .string(intentId), "intent": intent("优化搜索", project: alpha.id)]))["result"] ?? .null
    check(clarified["state"]?.stringValue == "created" && wecomWorks().count == 3, "WB-06 发起人补充后创建 Work", clarified.serialized())
    check(fakeLog().filter { $0["event"]?.stringValue == "spawn" }.count == spawnsBefore, "E2E-B 澄清过程没有启动任何执行进程")
    let mappings = (try core.read { try $0.db.query("SELECT key FROM settings") }).map { $0.text("key") }
    check(!mappings.contains { $0.contains("mapping") || $0.contains("room") }, "WB-06 没有生成任何群聊 → 项目的固定映射", mappings.joined(separator: ","))
    let next = call("submit_intent", .obj(["source": src("room-1", "m-8"), "text": .string("再帮我看个问题"),
                                           "intent": intent("看个问题", project: nil, resolved: false)]))["result"] ?? .null
    check(next["state"]?.stringValue == "needs_clarification" && next["intentId"]?.stringValue != intentId,
          "WB-18 新的需求不沿用上一轮澄清出来的项目")

    let unknown = call("submit_intent", .obj(["source": src("room-1", "m-9"), "text": .string("去 /etc 里改配置"),
                                              "intent": intent("改配置", project: "/etc")]))["result"] ?? .null
    check(unknown["state"]?.stringValue == "needs_clarification" && wecomWorks().count == 3,
          "WB-11 未登记的项目 / 任意路径不被接受")
    let guess = call("submit_intent", .obj(["source": src("room-1", "m-10"), "text": .string("继续"),
                                            "intent": intent("继续", project: alpha.id, evidence: [])]))["result"] ?? .null
    check(guess["state"]?.stringValue == "needs_clarification", "WB-04 没有依据的项目判定（仅凭最近活跃）不被接受")
    check(call("submit_intent", .obj(["source": .obj(["conversationId": .string("room-1")]), "text": .string("x"),
                                      "intent": intent("x", project: alpha.id)]))["ok"]?.boolValue == false,
          "没有稳定消息 ID 的事件被拒绝（无法去重）")

    let foreign = call("get_work", .obj(["source": src("room-2", "q-1"), "displayId": .string(firstId)]))
    let own = call("get_work", .obj(["source": src("room-1", "q-2"), "displayId": .string(firstId)]))["result"] ?? .null
    check(foreign["ok"]?.boolValue == false && own["displayId"]?.stringValue == firstId, "不跨会话暴露 Work 状态")

    // 在应用内启动后，状态通知回到原会话；发送结果以回执为准。
    let firstWorkId = firstWork["id"]?.stringValue ?? ""
    _ = try core.start(workId: firstWorkId, revision: nil, requestId: nil)
    check(waitUntil { status(core, firstWorkId) == "waiting_review" }, "来源 Work 由应用内启动后执行到待审阅")
    let pending = call("pending_notifications", .obj(["limit": .int(10)]))["result"]?["notifications"]?.arrayValue ?? []
    let notice = pending.first { $0["displayId"]?.stringValue == firstId } ?? .null
    check(notice["conversation"]?["conversationId"]?.stringValue == "room-1" && notice["text"]?.stringValue?.contains("等待审阅") == true,
          "WB-14 通知指向发起该 Work 的原会话", notice.serialized())
    let noticeId = notice["id"]?.stringValue ?? ""
    func deliveryStatus(_ id: String) -> String {
        ((try? core.read { $0.delivery(id: id) }) ?? nil)?.text("status") ?? ""
    }
    check(deliveryStatus(noticeId) == "unknown", "WB-16 交给 WorkBuddy 后、收到回执前，结果是未知而不是已发送")
    check((call("pending_notifications", .obj(["limit": .int(10)]))["result"]?["notifications"]?.arrayValue ?? [])
        .contains { $0["id"]?.stringValue == noticeId } == false, "WB-16 未知结果的通知不会被自动重复领取（不刷群）")
    check(call("ack_notification", .obj(["id": .string(noticeId), "sent": .bool(true)]))["ok"]?.boolValue == false
          && deliveryStatus(noticeId) == "unknown", "没有回执不能标记为已发送")
    _ = call("ack_notification", .obj(["id": .string(noticeId), "sent": .bool(true), "receipt": .string("msg-9001")]))
    check(deliveryStatus(noticeId) == "sent", "WB-15 有实际回执后才是已发送")

    // 审阅通过后汇报：Work 完成与投递结果各自记录。
    let state = try core.reviewState(workId: firstWorkId)
    do {
        _ = try core.deliveryConfirm(workId: firstWorkId, target: "wecom", body: "结果汇报", requestId: nil)
        check(false, "未审阅时不能汇报")
    } catch let error as WorkError { check(error.code == .rejected, "未审阅时不能汇报") }
    _ = try core.acceptReview(workId: firstWorkId, runId: work(core, firstWorkId)["currentRunId"]?.stringValue ?? "",
                              tree: state["tree"]?.stringValue, note: nil, requestId: nil)
    let preview = try core.deliveryPreview(workId: firstWorkId, target: "wecom")
    check(preview["blockers"]?.arrayValue?.isEmpty == true && preview["body"]?.stringValue?.contains(firstId) == true
          && preview["body"]?.stringValue?.contains("未记录") == false, "汇报草稿由真实证据生成")
    check(preview["body"]?.stringValue?.contains("应用内没有记录到验证命令") == true, "缺少验证证据时草稿如实写明")
    let confirmed = try core.deliveryConfirm(workId: firstWorkId, target: "wecom", body: "结果汇报：已完成", requestId: "deliver-1")
    let again = try core.deliveryConfirm(workId: firstWorkId, target: "wecom", body: "结果汇报：已完成", requestId: "deliver-2")
    let reportId = confirmed["delivery"]?["id"]?.stringValue ?? ""
    check(again["duplicate"]?.boolValue == true && confirmed["delivery"]?["status"]?.stringValue == "pending",
          "确认汇报只是排队；相同内容不重复排队")
    let reports = call("pending_notifications", .obj(["limit": .int(10)]))["result"]?["notifications"]?.arrayValue ?? []
    check(reports.contains { $0["id"]?.stringValue == reportId && $0["kind"]?.stringValue == "report" }, "结果汇报等待 WorkBuddy 领取")
    _ = call("ack_notification", .obj(["id": .string(reportId), "sent": .bool(false), "error": .string("群已解散")]))
    check(status(core, firstWorkId) == "completed" && deliveryStatus(reportId) == "failed",
          "WK-11 汇报发送失败时 Work 仍是已完成，投递单独显示失败")

    // 远程回答：默认必须回到应用内。
    let ask = call("submit_intent", .obj(["source": src("room-1", "m-11"), "text": .string("alpha 里确认口径"),
                                          "intent": intent("确认口径 SCENARIO:question", project: alpha.id)]))["result"] ?? .null
    let askWork = wecomWorks().first { $0["displayId"]?.stringValue == ask["displayId"]?.stringValue }?["id"]?.stringValue ?? ""
    _ = try core.start(workId: askWork, revision: nil, requestId: nil)
    check(waitUntil { status(core, askWork) == "waiting_user" }, "来源 Work 进入待回答")
    let attentionId = work(core, askWork)["attentionId"]?.stringValue ?? ""
    let remote = call("answer_attention", .obj(["source": src("room-1", "m-12"), "attentionId": .string(attentionId),
                                                "answer": .obj(["answers": .obj(["同步失败时如何处理本地状态？": .string("回滚本地操作")])])]))["result"] ?? .null
    check(remote["state"]?.stringValue == "requires_app" && status(core, askWork) == "waiting_user",
          "AS-07 身份未验证的群内「确认」不被当作批准")
    let foreignAnswer = call("answer_attention", .obj(["source": src("room-2", "m-13"), "attentionId": .string(attentionId),
                                                       "answer": .object([:])]))
    check(foreignAnswer["ok"]?.boolValue == false, "WB-07 其他会话不能回答这个 Work 的问题")

    // 套接字与 MCP 包装：令牌校验 + 真实的 stdio 往返。
    let socketDir = scratchURL.appendingPathComponent("sock")
    try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
    SourceSocketServer.shared.start(core: core, directory: socketDir)
    check(SourceSocketServer.shared.isListening, "来源接口在数据目录下监听", socketDir.path)
    let perms = (try FileManager.default.attributesOfItem(atPath: SourceSocketServer.socketURL(directory: socketDir).path)[.posixPermissions] as? NSNumber)?.intValue
    let tokenPerms = (try FileManager.default.attributesOfItem(atPath: SourceSocketServer.tokenURL(directory: socketDir).path)[.posixPermissions] as? NSNumber)?.intValue
    check(perms == 0o600 && tokenPerms == 0o600, "OP-08 套接字与令牌文件仅当前用户可访问", "\(String(perms ?? 0, radix: 8)) \(String(tokenPerms ?? 0, radix: 8))")
    let requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#,
    ].joined(separator: "\n") + "\n"
    let mcp = Proc.run(CommandLine.arguments[0], ["--source-mcp", socketDir.path], env: environment, timeout: 20, stdin: Data(requests.utf8))
    let replies = mcp.stdout.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
    let toolNames = replies.first { $0["id"]?.intValue == 2 }?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    let listReply = replies.first { $0["id"]?.intValue == 3 }?["result"]
    check(replies.count == 4 && toolNames.contains("submit_intent") && toolNames.contains("list_projects"),
          "MCP 包装应答 initialize / tools/list", String(mcp.stdout.prefix(300)) + String(mcp.stderr.prefix(300)))
    check(listReply?["isError"]?.boolValue == false && listReply?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains(alpha.id) == true,
          "MCP 工具调用经套接字到达正在运行的核心")
    check(replies.first { $0["id"]?.intValue == 4 }?["error"] != nil, "未知工具返回错误")
    try "wrong-token".write(to: SourceSocketServer.tokenURL(directory: socketDir), atomically: true, encoding: .utf8)
    let denied = Proc.run(CommandLine.arguments[0], ["--source-mcp", socketDir.path], env: environment, timeout: 20,
                          stdin: Data((#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}"# + "\n").utf8))
    let deniedReply = JSONValue.parse(String(denied.stdout.split(separator: "\n").first ?? ""))?["result"]
    check(deniedReply?["isError"]?.boolValue == true && deniedReply?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("令牌") == true,
          "OP-08 令牌不对的调用被拒绝")
    SourceSocketServer.shared.stop()
    check(!FileManager.default.fileExists(atPath: SourceSocketServer.socketURL(directory: socketDir).path), "停止后移除套接字")

    for item in wecomWorks() { _ = try? core.cancel(workId: item["id"]?.stringValue ?? "", revision: nil, requestId: nil) }
}

print("企业微信智能机器人长连接")
do {
    // 本机假服务端：按官方 SDK 的帧格式应答认证、心跳、回复与主动推送。
    final class FakeWecom: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "fake-wecom")
        let lock = NSLock()
        var frames: [JSONValue] = []
        var connections: [NWConnection] = []
        var authCode = 0
        var sendCode = 0
        var port: UInt16 = 0

        init() throws {
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.lock(); self.connections.append(connection); self.lock.unlock()
                connection.start(queue: self.queue)
                self.receive(connection)
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
            port = listener.port?.rawValue ?? 0
        }

        func receive(_ connection: NWConnection) {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self, error == nil else { return }
                if let data, let frame = JSONValue.parse(data) { self.handle(frame, connection) }
                self.receive(connection)
            }
        }

        func handle(_ frame: JSONValue, _ connection: NWConnection) {
            lock.lock(); frames.append(frame); lock.unlock()
            let reqId = frame["headers"]?["req_id"] ?? .null
            switch frame["cmd"]?.stringValue {
            case "aibot_subscribe":
                send(.obj(["headers": .obj(["req_id": reqId]), "errcode": .int(authCode), "errmsg": .string(authCode == 0 ? "ok" : "invalid secret")]), connection)
            case "ping", "aibot_respond_msg":
                send(.obj(["headers": .obj(["req_id": reqId]), "errcode": .int(0), "errmsg": .string("ok")]), connection)
            case "aibot_send_msg":
                send(.obj(["headers": .obj(["req_id": reqId]), "errcode": .int(sendCode), "errmsg": .string(sendCode == 0 ? "ok" : "no permission")]), connection)
            default: break
            }
        }

        func send(_ frame: JSONValue, _ connection: NWConnection? = nil) {
            lock.lock(); let target = connection ?? connections.last; lock.unlock()
            guard let target else { return }
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
            target.send(content: Data(frame.serialized().utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }

        func sent(_ cmd: String) -> [JSONValue] {
            lock.lock(); defer { lock.unlock() }
            return frames.filter { $0["cmd"]?.stringValue == cmd }
        }

        var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }

        func push(msgid: String, text: String, user: String = "zhangsan", chat: String? = "group-1") -> String {
            let reqId = "callback_\(msgid)"
            var body: [String: JSONValue] = ["msgid": .string(msgid), "aibotid": .string("test-bot"), "msgtype": .string("text"),
                                             "chattype": .string(chat == nil ? "single" : "group"),
                                             "from": .obj(["userid": .string(user)]), "text": .obj(["content": .string(text)])]
            if let chat { body["chatid"] = .string(chat) }
            send(.obj(["cmd": .string("aibot_msg_callback"), "headers": .obj(["req_id": .string(reqId)]), "body": .object(body)]))
            return reqId
        }

        /// 某次回调最终（finish=true）的回复内容。
        func finalReply(_ reqId: String) -> String? {
            sent("aibot_respond_msg").last {
                $0["headers"]?["req_id"]?.stringValue == reqId && $0["body"]?["stream"]?["finish"]?.boolValue == true
            }?["body"]?["stream"]?["content"]?.stringValue
        }
    }

    let fake = try FakeWecom()
    setenv("CLAUDE_PICKER_WECOM_WS_URL", "ws://127.0.0.1:\(fake.port)", 1)
    let bot = WecomBot.shared
    try core.putSetting("robot", .obj(["name": .string("开发协作助手"), "enabled": .bool(true), "botId": .string("test-bot"), "mode": .string("work"),
                                       "autoStart": .bool(false), "remoteAnswers": .bool(false)]))
    bot.start(core: core)
    check(waitUntil(3) { bot.status()["state"]?.stringValue == "disabled" }, "没有 Secret 时不连接", bot.status().serialized())
    try Keychain.set(.wecomBotSecret, "test-secret")
    bot.refresh(force: true)
    check(waitUntil(8) { bot.status()["state"]?.stringValue == "connected" }, "保存 Secret 后连接并认证成功", bot.status().serialized())
    let subscribe = fake.sent("aibot_subscribe").last
    check(subscribe?["body"]?["bot_id"]?.stringValue == "test-bot" && subscribe?["body"]?["secret"]?.stringValue == "test-secret",
          "认证帧带 bot_id 与 secret")
    check(core.getSetting("robot.status")?["state"]?.stringValue == "connected"
          && core.getSetting("robot.status")?.serialized().contains("test-secret") == false, "连接状态落库，且不含 Secret")
    check(Keychain.get(.wecomBotSecret) == "test-secret" && core.getSetting("robot")?.serialized().contains("test-secret") == false,
          "Secret 只在钥匙串，不进设置")

    let worksBefore = (core.snapshot()["works"]?.arrayValue ?? []).count
    let idsBefore = Set((core.snapshot()["works"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
    let first = fake.push(msgid: "bot-m1", text: "@开发协作助手 帮我在 alpha 项目里优化搜索 SCENARIO:edit")
    check(waitUntil(10) { fake.finalReply(first) != nil }, "收到消息后回复最终结果")
    let placeholder = fake.sent("aibot_respond_msg").first { $0["headers"]?["req_id"]?.stringValue == first }
    check(placeholder?["body"]?["stream"]?["finish"]?.boolValue == false, "先回复「正在处理」占位，再给最终结果（同一个 stream）")
    let created = fake.finalReply(first) ?? ""
    check(created.contains("已创建 WORK-") && created.contains("alpha"), "明确项目的工作请求创建 Work 并回执", created)
    let botWork = (core.snapshot()["works"]?.arrayValue ?? []).first { !idsBefore.contains($0["id"]?.stringValue ?? "") }
    check(botWork?["project"]?["name"]?.stringValue == "alpha" && botWork?["startRequested"]?.boolValue == false,
          "Work 归到 alpha，默认等待应用内启动")
    let intentCall = fakeLog().last { $0["event"]?.stringValue == "intent" }
    check(intentCall?["tools"]?.stringValue == "" && intentCall?["message"]?.stringValue?.hasPrefix("@") == false,
          "理解消息的调用不带任何工具，且去掉了 @机器人")
    let verified = try core.read { try $0.db.first("SELECT actor_id, actor_verified FROM input_events WHERE remote_event_id = 'bot-m1'") }
    check(verified?.text("actor_id") == "zhangsan" && verified?.bool("actor_verified") == true, "机器人回调里的发送人记为已验证")

    let replay = fake.push(msgid: "bot-m1", text: "@开发协作助手 帮我在 alpha 项目里优化搜索 SCENARIO:edit")
    check(waitUntil(6) { fake.finalReply(replay) != nil }, "重复投递的消息也有回复")
    check((core.snapshot()["works"]?.arrayValue ?? []).count == worksBefore + 1, "WB-09 同一条消息重放不会再建 Work")

    let chat = fake.push(msgid: "bot-m2", text: "现在进度怎么样")
    check(waitUntil(10) { fake.finalReply(chat) != nil } && fake.finalReply(chat)?.contains("目前有 1 个 Work") == true,
          "WB-08 普通问答直接回答，带上本会话 Work 的情况", fake.finalReply(chat) ?? "")
    check((core.snapshot()["works"]?.arrayValue ?? []).count == worksBefore + 1, "WB-08 问答不产生 Work")

    let vague = fake.push(msgid: "bot-m3", text: "帮我修一下导出", user: "lisi")
    check(waitUntil(10) { fake.finalReply(vague) != nil } && fake.finalReply(vague)?.contains("哪个项目") == true,
          "WB-04 项目不明确时在原会话追问", fake.finalReply(vague) ?? "")
    let wrongPerson = fake.push(msgid: "bot-m4", text: "在 beta 里", user: "wangwu")
    check(waitUntil(10) { fake.finalReply(wrongPerson) != nil } && fake.finalReply(wrongPerson)?.contains("提出该需求的人") == true,
          "WB-07 别人的回复不能确定 lisi 的需求", fake.finalReply(wrongPerson) ?? "")
    let clarified = fake.push(msgid: "bot-m5", text: "在 beta 里", user: "lisi")
    check(waitUntil(10) { fake.finalReply(clarified)?.contains("已创建") == true }, "WB-06 发起人补充后创建 Work", fake.finalReply(clarified) ?? "")

    // 应用内启动后，状态变化通过 aibot_send_msg 推回原群。
    let botWorkId = botWork?["id"]?.stringValue ?? ""
    _ = try core.start(workId: botWorkId, revision: nil, requestId: nil)
    check(waitUntil(15) { status(core, botWorkId) == "waiting_review" }, "机器人发起的 Work 执行到待审阅")
    check(waitUntil(10) { fake.sent("aibot_send_msg").contains { $0["body"]?["markdown"]?["content"]?.stringValue?.contains("等待审阅") == true } },
          "WB-14 状态通知主动推送到原会话")
    let push = fake.sent("aibot_send_msg").first { $0["body"]?["markdown"]?["content"]?.stringValue?.contains("等待审阅") == true }
    check(push?["body"]?["chatid"]?.stringValue == "group-1" && push?["body"]?["msgtype"]?.stringValue == "markdown", "推送目标是发起的群")
    let notice = { () -> DBRow? in
        (try? core.read { try $0.db.first("SELECT d.status FROM deliveries d WHERE d.work_id = ? AND d.target = 'wecom-notice' AND d.body LIKE '%等待审阅%'",
                                          [.text(botWorkId)]) }) ?? nil
    }
    check(waitUntil(6) { notice()?.text("status") == "sent" }, "WB-15 收到回执后标记已发送", notice()?.text("status") ?? "nil")
    let mcpClaim = SourceGateway.handle(core, method: "pending_notifications", params: .obj(["limit": .int(50)]))
    check((mcpClaim["result"]?["notifications"]?.arrayValue ?? []).allSatisfy { !($0["conversation"]?["accountId"]?.stringValue ?? "").hasPrefix("wecom-bot:") },
          "机器人负责的会话不会再被 WorkBuddy 通道领取（不重复发送）")

    _ = try core.cancel(workId: botWorkId, revision: nil, requestId: nil)
    check(waitUntil(12) { status(core, botWorkId) == "cancelled" }, "取消机器人发起的 Work")

    // 直接 Claude 对话使用真实双向执行器和模拟企微长连接。
    try core.putSetting("robot", .obj(["enabled": .bool(true), "botId": .string("test-bot"), "mode": .string("claude")]))
    let directWorkCount = core.snapshot()["works"]?.arrayValue?.count
    let spawnsBefore = fakeLog().filter { $0["event"]?.text == "spawn" }.count
    let hello = fake.push(msgid: "direct-1", text: "你好 Claude")
    check(waitUntil(10) { fake.finalReply(hello)?.contains("你好 Claude") == true }, "企微直接收到 Claude 回复", fake.finalReply(hello) ?? "")
    let follow = fake.push(msgid: "direct-2", text: "继续聊")
    check(waitUntil(10) { fake.finalReply(follow)?.contains("继续聊") == true }, "同一企微会话可以继续对话")
    check(fakeLog().filter { $0["event"]?.text == "spawn" }.count == spawnsBefore + 1, "连续消息复用同一个 Claude 进程和会话")
    let replayDirect = fake.push(msgid: "direct-1", text: "你好 Claude")
    check(waitUntil(6) { fake.finalReply(replayDirect) == fake.finalReply(hello) }, "直接对话重放返回原回复")
    check(core.snapshot()["works"]?.arrayValue?.count == directWorkCount, "直接聊天和执行不创建 Work")
    let permission = fake.push(msgid: "direct-3", text: "SCENARIO:permission")
    check(waitUntil(10) { fake.finalReply(permission)?.contains("回复“允许”或“拒绝”") == true }, "工具权限在原企微会话询问")
    let deny = fake.push(msgid: "direct-4", text: "拒绝")
    check(waitUntil(10) { fake.finalReply(deny)?.contains("拒绝") == true }, "企微拒绝准确传回 Claude 工具请求")
    let question = fake.push(msgid: "direct-5", text: "SCENARIO:question")
    check(waitUntil(10) { fake.finalReply(question)?.contains("直接回复答案") == true }, "Claude 的问题转发到企微")
    let answer = fake.push(msgid: "direct-6", text: "方案一")
    check(waitUntil(10) { fake.finalReply(answer)?.contains("方案一") == true }, "企微回答后 Claude 继续执行", fake.finalReply(answer) ?? "")
    let other = fake.push(msgid: "direct-7", text: "你好", user: "lisi")
    check(waitUntil(10) { fake.finalReply(other)?.contains("你好") == true }, "同群其他发送人可独立对话")
    check(fakeLog().filter { $0["event"]?.text == "spawn" }.count == spawnsBefore + 2, "不同发送人的 Claude 上下文隔离")

    // 被别处的新连接顶替：断开且不自动重连。
    let connectionsBefore = fake.connectionCount
    fake.send(.obj(["cmd": .string("aibot_event_callback"), "headers": .obj(["req_id": .string("evt-1")]),
                    "body": .obj(["msgtype": .string("event"), "event": .obj(["eventtype": .string("disconnected_event")])])]))
    check(waitUntil(5) { bot.status()["state"]?.stringValue == "kicked" }, "收到 disconnected_event 后标记为被顶替")
    usleep(2_500_000)
    check(fake.connectionCount == connectionsBefore && bot.status()["state"]?.stringValue == "kicked", "被顶替后不自动重连")

    // 认证失败：停下来等用户改，不反复重试。
    fake.authCode = 40001
    bot.refresh(force: true)
    check(waitUntil(6) { bot.status()["state"]?.stringValue == "auth_failed" }, "认证失败如实显示", bot.status().serialized())
    let attempts = fake.sent("aibot_subscribe").count
    usleep(2_500_000)
    check(fake.sent("aibot_subscribe").count == attempts, "认证失败后不自动重试")

    // 关闭入口：断开。
    fake.authCode = 0
    try core.putSetting("robot", .obj(["name": .string("开发协作助手"), "enabled": .bool(false), "botId": .string("test-bot")]))
    bot.refresh()
    check(waitUntil(4) { bot.status()["state"]?.stringValue == "disabled" }, "WB-17 关闭对话入口后断开长连接")
    bot.stop()
    fake.listener.cancel()

    // TAPD 令牌：钥匙串优先，且不出现在任何返回值里。
    try Keychain.set(.tapdToken, "tapd-secret-token")
    let pre = TapdAdapter.prerequisites(core)
    check(pre["tokenSource"]?.stringValue == "keychain" && pre.serialized().contains("tapd-secret-token") == false,
          "TAPD 令牌来自钥匙串，前提检查不回显令牌")
    Keychain.delete(.tapdToken)
    check(TapdAdapter.prerequisites(core)["tokenSource"]?.stringValue != "keychain", "清除后不再使用钥匙串里的令牌")
}

print("Antigravity ACP 执行、跨引擎接力与 Turn Checkpoint 回退")
do {
    // 1. 直接由 Antigravity ACP 执行 Work（含工具调用与权限审批）
    var agyReq = WorkCore.CreateRequest(projectId: alpha.id, title: "Antigravity ACP 写入与审批", objective: "SCENARIO:permission")
    agyReq.executor = "antigravity"
    agyReq.start = true
    let agyWorkId = (try core.create(agyReq))["work"]?["id"]?.stringValue ?? ""
    check(work(core, agyWorkId)["executor"]?.stringValue == "antigravity", "AGY-01 Work 记录 executor 为 antigravity")
    check(waitUntil(15) { status(core, agyWorkId) == "waiting_user" }, "AGY-02 ACP session/request_permission 进入待回答", status(core, agyWorkId))
    let agyPerm = (try core.transcript(workId: agyWorkId, after: 0))["attentions"]?.arrayValue?.first ?? .null
    check(agyPerm["kind"]?.stringValue == "permission" && agyPerm["toolName"]?.stringValue == "Write",
          "AGY-02 ACP 权限卡片识别工具名与参数")
    _ = try core.answer(attentionId: agyPerm["id"]?.stringValue ?? "", revision: nil,
                        answer: .obj(["behavior": .string("allow")]))
    check(waitUntil(15) { status(core, agyWorkId) == "waiting_review" }, "AGY-02 批准后 ACP 继续完成轮次并进入待审阅", status(core, agyWorkId))
    let agyPath = work(core, agyWorkId)["workspacePath"]?.stringValue ?? ""
    check(FileManager.default.fileExists(atPath: agyPath + "/agy-guarded.txt"), "AGY-02 批准后实际写入 agy-guarded.txt")
    _ = try core.cancel(workId: agyWorkId, revision: nil, requestId: nil)
    check(waitUntil(10) { status(core, agyWorkId) == "cancelled" }, "清理 Antigravity 权限测试 Work")

    // 2. 共用 Thread 跨引擎无缝切换（Claude -> Antigravity）+ Turn Checkpoint 外科回退
    let relayRepo = makeRepo("relay")
    let sharedRepo = makeRepo("shared-cp")
    let extraProjects = try core.syncProjects([
        (path: repoA, name: "alpha"),
        (path: repoB, name: "beta"),
        (path: relayRepo, name: "relay"),
        (path: sharedRepo, name: "shared-cp"),
    ])
    let relayProject = extraProjects.first { $0.name == "relay" }!
    let sharedProject = extraProjects.first { $0.name == "shared-cp" }!
    let relayId = try create(core, project: relayProject, title: "跨引擎接力与检查点回退", objective: "SCENARIO:edit")
    check(waitUntil(15) { status(core, relayId) == "waiting_review" }, "RL-01 第 1 轮在 Claude 执行完成", status(core, relayId))
    let relayPath = work(core, relayId)["workspacePath"]?.stringValue ?? ""
    check(FileManager.default.fileExists(atPath: relayPath + "/work-output.txt"), "RL-01 Claude 产出 work-output.txt")

    // 在待审阅态将执行器切换为 Antigravity
    let switched = try core.switchExecutor(workId: relayId, executor: "antigravity")
    check(switched["accepted"]?.boolValue == true && switched["changed"]?.boolValue == true
          && work(core, relayId)["executor"]?.stringValue == "antigravity",
          "RL-02 非运行态可切换执行器至 Antigravity")

    // 第 2 轮发送消息：应启动 fake-agy-acp 并自动注入 <thread-handoff>，在同一 worktree 产出 agy-output.txt
    _ = try core.send(workId: relayId, messageId: "relay-r2", text: "继续第二轮修改 SCENARIO:edit")
    check(waitUntil(15) { status(core, relayId) == "waiting_review" && FileManager.default.fileExists(atPath: relayPath + "/agy-output.txt") },
          "RL-03 第 2 轮由 Antigravity 在同一工作树接力完成", status(core, relayId))
    let agyPrompts = fakeAgyLog().filter { $0["event"]?.stringValue == "prompt" }.compactMap { $0["text"]?.stringValue }
    check(agyPrompts.contains { $0.contains("<thread-handoff>") && $0.contains("Claude Code") && $0.contains("work-output.txt") },
          "RL-03 切换引擎后的首轮自动注入包含第 1 轮摘要的 <thread-handoff>")

    let relayTranscript = try core.transcript(workId: relayId, after: 0)
    let segments = relayTranscript["segments"]?.arrayValue ?? []
    check(segments.count == 2 && segments[0]["provider"]?.stringValue == "claude" && segments[1]["provider"]?.stringValue == "antigravity",
          "RL-04 thread_segments 记录两段跨引擎轨迹")

    // 检查 Turn Checkpoints：每轮均有隐藏 Git Ref 锚定，回退第 2 轮 preCheckpointId 应精确删掉 agy-output.txt 而保留 work-output.txt
    _ = waitUntil(8) {
        ((try? core.transcript(workId: relayId, after: 0))?["checkpoints"]?.arrayValue?.count ?? 0) >= 4
    }
    let cps = (try core.transcript(workId: relayId, after: 0))["checkpoints"]?.arrayValue ?? []
    let turnEvents = (relayTranscript["events"]?.arrayValue ?? []).filter { $0["kind"]?.stringValue == "turn_result" }
    let r2PreId = turnEvents.last?["payload"]?["preCheckpointId"]?.stringValue ?? ""
    let refsOut = sh("git for-each-ref refs/claude-picker/checkpoints/\(relayId)", cwd: relayPath)
    check(cps.count >= 4 && !r2PreId.isEmpty && refsOut.stdout.contains("refs/claude-picker/checkpoints/\(relayId)/"),
          "CP-01 每轮前后自动生成锚定在隐藏 Git Ref 下的检查点", "cps=\(cps.count)")

    let rev = try core.revertCheckpoint(workId: relayId, checkpointId: r2PreId, requestId: "rev-r2")
    check(rev["reverted"]?.boolValue == true
          && !FileManager.default.fileExists(atPath: relayPath + "/agy-output.txt")
          && FileManager.default.fileExists(atPath: relayPath + "/work-output.txt"),
          "CP-02 回退到第 2 轮前：第 2 轮新增文件被移除，第 1 轮成果完好保留")
    let undoId = rev["undoCheckpointId"]?.stringValue ?? ""
    check(!undoId.isEmpty, "CP-03 回退前自动生成 undo 备份检查点")

    // 第 3 轮发送普通消息：验证自动向智能体注入 <workspace-reverted-notice> 防止上下文幻觉
    let promptCountBefore = fakeAgyLog().filter { $0["event"]?.stringValue == "prompt" }.count
    _ = try core.send(workId: relayId, messageId: "relay-r3", text: "确认回退后的目录状态 SCENARIO:plain")
    check(waitUntil(15) {
        fakeAgyLog().filter { $0["event"]?.stringValue == "prompt" }.count > promptCountBefore
            && status(core, relayId) == "waiting_review"
    }, "CP-04 回退后继续对话正常完成")
    let latestAgyPrompt = fakeAgyLog().filter { $0["event"]?.stringValue == "prompt" }.last?["text"]?.stringValue ?? ""
    check(latestAgyPrompt.contains("<workspace-reverted-notice>"), "CP-04 回退后的下一轮自动注入 <workspace-reverted-notice> 同步通知")
    _ = try core.cancel(workId: relayId, revision: nil, requestId: nil)
    check(waitUntil(10) { status(core, relayId) == "cancelled" }, "清理跨引擎接力 Work")

    // 3. 未隔离共享目录（isolation: project）外部未保存改动冲突保护与强制回退
    let sharedId = try create(core, project: sharedProject, title: "共享目录检查点保护", objective: "SCENARIO:edit", isolation: "project")
    check(waitUntil(15) { status(core, sharedId) == "waiting_review" }, "CP-05 共享目录第 1 轮完成")
    _ = waitUntil(8) {
        ((try? core.transcript(workId: sharedId, after: 0))?["checkpoints"]?.arrayValue ?? [])
            .contains { $0["phase"]?.stringValue == "post" }
    }
    let sharedTurnPre = (events(core, sharedId).last { $0["kind"]?.stringValue == "turn_result" })?["payload"]?["preCheckpointId"]?.stringValue ?? ""
    try "external manual edit\n".write(toFile: sharedRepo + "/external.txt", atomically: true, encoding: .utf8)
    do {
        _ = try core.revertCheckpoint(workId: sharedId, checkpointId: sharedTurnPre, force: false)
        check(false, "CP-05 共享目录存在外部改动时默认拦截回退")
    } catch let error as WorkError {
        check(error.code == .conflict, "CP-05 共享目录存在外部改动时返回 conflict 保护用户修改")
    }
    let forced = try core.revertCheckpoint(workId: sharedId, checkpointId: sharedTurnPre, force: true)
    check(forced["reverted"]?.boolValue == true && !FileManager.default.fileExists(atPath: sharedRepo + "/work-output.txt"),
          "CP-05 用户确认 force=true 后可执行强制回退")
    _ = try core.cancel(workId: sharedId, revision: nil, requestId: nil)
    check(waitUntil(10) { status(core, sharedId) == "cancelled" }, "清理共享目录 Work")
}

print("状态目录独占与重启恢复")
do {
    let second = WorkCore(directory: dataA)
    usleep(200_000)
    do {
        _ = try second.create(WorkCore.CreateRequest(projectId: alpha.id, title: "第二实例", objective: "x"))
        check(false, "OP-03 第二个实例不能写同一个状态目录")
    } catch let error as WorkError {
        check(error.code == .notOwner, "OP-03 第二个实例不能写同一个状态目录")
    }
    check(second.snapshot()["owner"]?.boolValue == false && (second.snapshot()["works"]?.arrayValue?.count ?? 0) > 0,
          "OP-03 第二个实例只读可见")

    // 另起一个进程模拟崩溃：它让一个 Work 进入执行中后直接 _exit，留下孤儿执行进程。
    let dataB = scratchURL.appendingPathComponent("data-b")
    let repoC = makeRepo("gamma")
    let child = Proc.run(CommandLine.arguments[0], ["--crash-child", dataB.path, repoC], env: environment, timeout: 40)
    let childWork = child.stdout.split(separator: "\n").first { $0.hasPrefix("CHILD-WORK ") }.map { String($0.dropFirst(11)) } ?? ""
    check(child.exitCode == 9 && !childWork.isEmpty, "崩溃子进程已让 Work 进入执行中后异常退出", "exit=\(child.exitCode) out=\(child.stdout) err=\(child.stderr.suffix(300))")

    let raw = try SQLiteDB(path: dataB.appendingPathComponent("work.sqlite3").path)
    let liveRun = try raw.first("SELECT pid, session_id, status FROM runs WHERE work_id = ?", [.text(childWork)])
    let orphanPid = Int32(liveRun?.int("pid") ?? 0)
    check(liveRun?.text("status") == "running" && orphanPid > 0 && kill(orphanPid, 0) == 0, "崩溃后数据库里留着 running 的 Run 和孤儿进程")
    raw.close()

    let recovered = WorkCore(directory: dataB)
    check(waitUntil { status(recovered, childWork) == "interrupted" }, "OP-02 重启后未结束的 Run 标记为已中断", status(recovered, childWork))
    check(waitUntil(6) { kill(orphanPid, 0) != 0 }, "OP-02 自己留下的孤儿执行进程被结束")
    let turns = fakeLog().filter { $0["event"]?.stringValue == "turn" && $0["session"]?.stringValue == work(recovered, childWork)["sessionId"]?.stringValue }
    usleep(600_000)
    check(turns.count == 1 && status(recovered, childWork) == "interrupted", "OP-02 恢复时没有重发上一条消息，也没有自动改回执行中")
    let recoveredRuns = (try recovered.transcript(workId: childWork, after: 0))["runs"]?.arrayValue ?? []
    check(recoveredRuns.count == 1 && recoveredRuns[0]["error"]?.stringValue?.contains("结果未知") == true, "中断的 Run 保留并注明结果未知")
    _ = try recovered.retry(workId: childWork, revision: nil, requestId: nil)
    check(waitUntil { status(recovered, childWork) == "waiting_review" }, "恢复后由用户批准重试才继续", status(recovered, childWork))

    // 退出：只结束自己启动的进程，执行中的轮次落为 interrupted。
    let bystander = Process()
    bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
    bystander.arguments = ["30"]
    try bystander.run()
    let projectsB = try recovered.syncProjects([(path: repoC, name: "gamma")])
    let live = try create(recovered, project: projectsB[0], title: "退出时在执行", objective: "SCENARIO:slow")
    check(waitUntil { work(recovered, live)["busy"]?.boolValue == true }, "退出前有 Work 在执行")
    check(recovered.activeExecutionCount() == 1, "退出前能数出仍在执行的 Work")
    let stuck = recovered.shutdown(timeout: 5)
    check(stuck.isEmpty && status(recovered, live) == "interrupted", "OP-04 退出时结束自有执行并标记为已中断", "stuck=\(stuck) status=\(status(recovered, live))")
    check(bystander.isRunning, "OP-04 没有误杀无关进程")
    bystander.terminate()
}

core.shutdown(timeout: 3)
print("")
print("通过 \(counter.passed) 项，失败 \(counter.failed.count) 项")
if !counter.failed.isEmpty {
    for name in counter.failed { print("  - \(name)") }
    exit(1)
}
exit(0)
