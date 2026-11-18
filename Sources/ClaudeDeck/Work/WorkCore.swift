import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 同一个 CLI 会话只能有一个持有者：原生终端、图形聊天、或 Work 执行器。
/// 两侧都在各自的线程上登记 / 查询，所以用锁而不是队列。
final class SessionOwnership: @unchecked Sendable {
    static let shared = SessionOwnership()
    private let lock = NSLock()
    private var executor: Set<String> = []
    private var terminal: Set<String> = []

    func setExecutor(_ sessionId: String, held: Bool) {
        lock.lock(); defer { lock.unlock() }
        if held { executor.insert(sessionId) } else { executor.remove(sessionId) }
    }

    func setTerminal(_ sessionId: String, held: Bool) {
        guard !sessionId.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if held { terminal.insert(sessionId) } else { terminal.remove(sessionId) }
    }

    func clearTerminal() {
        lock.lock(); defer { lock.unlock() }
        terminal.removeAll()
    }

    func heldByExecutor(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return executor.contains(sessionId)
    }

    func heldByTerminal(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return terminal.contains(sessionId)
    }
}

enum WorkNotification: Sendable {
    /// Work 列表或某个 Work 的状态变了：前端重新取快照。
    case changed
    /// 某个 Work 的事件流追加了一条（带该 Work 自己的连续序号）。
    case event(JSONValue)
    /// 流式文本增量，不持久化。
    case delta(workId: String, runId: String, text: String)
}

/// Work 领域服务 + 调度器。所有状态改动都在 `queue` 这一条串行队列上，并写进 SQLite；
/// 界面只是这份状态的读者。命令返回「已接受 / 拒绝 / 冲突」，不把「已接受」说成「已完成」。
final class WorkCore: @unchecked Sendable {
    static let shared = WorkCore(directory: AppDataDir.url.appendingPathComponent("work", isDirectory: true))

    let queue = DispatchQueue(label: "claude-picker.work-core")
    let worker = DispatchQueue(label: "claude-picker.work-worker", attributes: .concurrent)
    let store: WorkStore?
    let initError: String?
    let instanceId = UUID().uuidString.lowercased()

    // 以下可变状态只在 queue 上读写。
    var processes: [String: any AgentExecutorProcess] = [:] // workId → 执行进程
    var processTokens: [String: String] = [:]               // workId → 当前进程的令牌（旧进程的迟到事件靠它识别）
    var currentTurnPreCheckpointId: [String: String] = [:]  // workId → 当前轮开始前的代码检查点 ID
    var ready: Set<String> = []                             // 已完成握手的 workId
    var busy: Set<String> = []                              // 正在一轮生成中的 workId
    var pendingInterrupts: [String: String] = [:]           // workId → 中断请求 ID
    var pendingAnswers: [String: [PendingAnswer]] = [:]     // 已记录、等拿到执行槽再交给执行器的答复
    var cancelling: Set<String> = []
    var settleTokens: [String: String] = [:]                // 一轮结束后的短暂观察期
    var observers: [@Sendable (WorkNotification) -> Void] = []
    var effectHandlers: [String: @Sendable (WorkCore, DBRow) -> Void] = [:]
    var effectTimerArmed = false
    var shuttingDown = false

    struct PendingAnswer: Sendable {
        let attentionId: String
        let requestId: String
        let allow: Bool
        let updatedInput: JSONValue?
        let message: String?
    }

    init(directory: URL) {
        signal(SIGPIPE, SIG_IGN)    // 执行进程退出后再写 stdin 不能把应用带走
        do {
            let opened = try WorkStore(directory: directory)
            store = opened
            initError = nil
        } catch {
            store = nil
            initError = (error as? WorkError)?.message ?? "\(error)"
        }
        queue.async { [self] in
            recover()
            tick()
            runEffects()
        }
    }

    // MARK: 订阅

    func observe(_ handler: @escaping @Sendable (WorkNotification) -> Void) {
        queue.async { self.observers.append(handler) }
    }

    func notify(_ notification: WorkNotification) {
        for observer in observers { observer(notification) }
    }

    // MARK: 进入队列

    /// 所有写命令的入口：确认数据库可用、本实例是状态目录的持有者。
    func write<T>(_ body: (WorkStore) throws -> T) throws -> T {
        try queue.sync {
            guard let store else { throw WorkError.unavailable("Work 数据库不可用", detail: initError) }
            guard store.isOwner else {
                throw WorkError(code: .notOwner, message: "另一个 Claude Picker 实例正在管理这份 Work 数据，本窗口只能查看。")
            }
            return try body(store)
        }
    }

    func read<T>(_ body: (WorkStore) throws -> T) throws -> T {
        try queue.sync {
            guard let store else { throw WorkError.unavailable("Work 数据库不可用", detail: initError) }
            return try body(store)
        }
    }

    // MARK: 设置

    static let defaultSlots = 2

    func slots(_ store: WorkStore) -> Int {
        min(max(store.setting("slots")?.intValue ?? Self.defaultSlots, 1), 8)
    }

    func setSlots(_ value: Int) throws {
        guard (1...8).contains(value) else { throw WorkError.invalid("执行槽数量需在 1–8 之间") }
        try write { store in
            try store.setSetting("slots", .int(value))
            notify(.changed)
            tick()
        }
    }

    func getSetting(_ key: String) -> JSONValue? {
        (try? read { $0.setting(key) }) ?? nil
    }

    func putSetting(_ key: String, _ value: JSONValue) throws {
        try write { store in
            try store.setSetting(key, value)
            notify(.changed)
        }
    }

    // MARK: 项目索引

    /// 宿主的项目登记（侧栏里的目录）同步到数据库：Work 只能指向这里面的项目。
    @discardableResult
    func syncProjects(_ list: [(path: String, name: String)]) throws -> [WorkProject] {
        try write { store in
            var paths = Set<String>()
            try store.db.transaction {
                for item in list {
                    let path = WorkspaceService.canonical(item.path)
                    paths.insert(path)
                    try store.upsertProject(path: path, name: item.name,
                                            available: WorkspaceService.isDirectory(path))
                }
                try store.markProjectsUnavailable(except: paths)
            }
            return store.projects()
        }
    }

    // MARK: 快照

    func snapshot() -> JSONValue {
        let result: JSONValue? = try? read { store in
            let projects = Dictionary(uniqueKeysWithValues: store.projects().map { ($0.id, $0) })
            let works = store.works().map { work -> JSONValue in
                workJSON(work, store: store, project: projects[work.projectId])
            }
            let running = store.works(status: .running).count
            let queued = store.works(status: .queued)
            return .obj([
                "available": .bool(true),
                "owner": .bool(store.isOwner),
                "works": .array(works),
                "projects": .array(store.projects().map(\.json)),
                "capacity": .obj([
                    "slots": .int(slots(store)),
                    "running": .int(running),
                    "queued": .int(queued.filter(\.startRequested).count),
                    "waitingStart": .int(queued.filter { !$0.startRequested }.count),
                ]),
                "workSessionIds": .array(store.workSessionIds().map { .string($0) }),
                "executor": .obj([
                    "claude": .str(ClaudeLocator.find()),
                    "antigravity": .str(CliBinaryLocator.findAgy()),
                ]),
            ])
        }
        return result ?? .obj(["available": .bool(false), "error": .str(initError ?? "Work 数据库不可用"),
                               "works": .array([]), "projects": .array([]),
                               "capacity": .obj(["slots": .int(Self.defaultSlots), "running": .int(0),
                                                 "queued": .int(0), "waitingStart": .int(0)]),
                               "workSessionIds": .array([])])
    }

    func workJSON(_ work: Work, store: WorkStore, project: WorkProject?) -> JSONValue {
        guard case .object(var object) = work.json else { return work.json }
        object["project"] = project?.json ?? .null
        object["tapdRefs"] = .array(store.tapdRefs(workId: work.id).map { row in
            .obj(["workspaceId": .string(row.text("workspace_id")), "entityType": .string(row.text("entity_type")),
                  "entityId": .string(row.text("entity_id")), "title": .string(row.text("title")),
                  "businessStatus": .str(row.string("business_status")),
                  "snapshotModified": .str(row.string("snapshot_modified")),
                  "snapshotHash": .str(row.string("snapshot_hash"))])
        })
        object["cancelling"] = .bool(cancelling.contains(work.id))
        object["processAlive"] = .bool(processes[work.id] != nil)
        object["busy"] = .bool(busy.contains(work.id))
        let deliveries = store.deliveries(workId: work.id)
        object["deliveries"] = .array(deliveries.map(WorkStore.deliveryJSON))
        if let runId = work.currentRunId, let run = store.run(id: runId) {
            object["run"] = run.json
        }
        object["checkpoints"] = .array(store.checkpoints(workId: work.id).prefix(20).map(\.json))
        object["segments"] = .array(store.threadSegments(workId: work.id))
        return .object(object)
    }

    // MARK: 创建

    struct CreateRequest: Sendable {
        var projectId: String
        var title: String
        var objective: String
        var scope: String = ""
        var origin: WorkOrigin = .local
        var start: Bool = false
        var isolation: String = "worktree"
        var executor: String = "claude"
        var permissionMode: String?
        var model: String?
        var idempotencyKey: String?
        var sourceConversationId: String?
        var sourceEventId: String?
        var tapd: TapdAttachment?
        var actor: String = "本机用户"
        /// 「作为 Work 继续」：接管一个已有的 CLI 会话，在它原来的目录里继续（不新建 worktree）。
        var adoptSession: AdoptedSession?
    }

    struct AdoptedSession: Sendable {
        var id: String
        var cwd: String
        var provider: String = "claude"
    }

    struct TapdAttachment: Sendable {
        var ref: TapdRef
        var title: String
        var businessStatus: String?
        var snapshotHash: String?
        var snapshotModified: String?
        var snapshot: JSONValue?
    }

    /// 创建 Work。Work、编号、来源关联、创建记录在同一个事务里落库；失败则什么都不留。
    /// 相同幂等键的重复请求返回已有 Work，不会创建第二个。
    func create(_ request: CreateRequest) throws -> JSONValue {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let objective = request.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkError.invalid("Work 名称不能为空") }
        guard title.count <= 200 else { throw WorkError.invalid("Work 名称不能超过 200 个字符") }
        guard !objective.isEmpty else { throw WorkError.invalid("工作目标不能为空") }
        guard ["worktree", "project"].contains(request.isolation) else { throw WorkError.invalid("未知的隔离方式") }

        let created: (Work, Bool) = try write { store in
            if let key = request.idempotencyKey, let existing = store.work(idempotencyKey: key) {
                return (existing, false)
            }
            guard let project = store.project(id: request.projectId) else {
                throw WorkError.invalid("项目未登记，无法创建 Work。请先通过「添加目录」登记项目。")
            }
            guard project.available, WorkspaceService.isDirectory(project.path) else {
                throw WorkError.unavailable("项目目录当前不可访问：\(project.path)")
            }
            var adopted: AdoptedSession?
            if let adopt = request.adoptSession {
                let cwd = WorkspaceService.canonical(adopt.cwd)
                guard cwd == project.path || cwd.hasPrefix(project.path + "/"), WorkspaceService.isDirectory(cwd) else {
                    throw WorkError.invalid("要接管的会话不在这个项目的目录里。")
                }
                guard !store.workSessionIds().contains(adopt.id) else {
                    throw WorkError.rejected("这个会话已经属于另一个 Work。")
                }
                guard !SessionOwnership.shared.heldByTerminal(adopt.id) else {
                    throw WorkError.rejected("这个会话还在终端或图形聊天里打开着。请先关闭它，再作为 Work 继续（同一个会话不能被两个后端同时驱动）。")
                }
                adopted = AdoptedSession(id: adopt.id, cwd: cwd, provider: adopt.provider)
            }
            let chosenExecutor = AgentProvider.parse(adopted?.provider ?? request.executor).rawValue
            let id = UUID().uuidString.lowercased()
            try store.db.transaction {
                let displayId = try store.nextDisplayId()
                try store.insertWork(id: id, displayId: displayId, projectId: project.id, title: title,
                                     objective: objective, scope: request.scope, origin: request.origin,
                                     sourceConversationId: request.sourceConversationId,
                                     sourceEventId: request.sourceEventId, startRequested: request.start,
                                     isolation: request.isolation, executor: chosenExecutor,
                                     permissionMode: request.permissionMode,
                                     model: request.model, idempotencyKey: request.idempotencyKey)
                if let adopted {
                    try store.db.run("UPDATE works SET session_id = ?, workspace_path = ?, isolation = 'project' WHERE id = ?",
                                     [.text(adopted.id), .text(adopted.cwd), .text(id)])
                    try store.upsertSession(id: adopted.id, projectId: project.id, workId: id, cwd: adopted.cwd, backend: "adopted")
                    try store.appendThreadSegment(workId: id, provider: chosenExecutor, sessionId: adopted.id, cwd: adopted.cwd)
                    let brief = "从现在起，这个会话作为 Claude Picker 的工作项 \(displayId)「\(title)」继续。\n\n目标：\n\(objective)"
                        + (request.scope.isEmpty ? "" : "\n\n执行范围：\n\(request.scope)")
                        + "\n\n约定：不要 push、合并、部署；涉及业务口径时用 AskUserQuestion 提问；完成后说明改动与实际运行过的验证。"
                    _ = try store.addPendingInput(id: "adopt-\(id)", workId: id, text: brief)
                    try store.appendEvent(workId: id, runId: nil, kind: "user",
                                          payload: .obj(["messageId": .string("adopt-\(id)"), "origin": .string("system"),
                                                         "text": .string(brief), "state": .string("accepted")]))
                    store.addActivity(workId: id, runId: nil, kind: "session", title: "接管已有会话",
                                      detail: adopted.id, actor: request.actor)
                }
                if let tapd = request.tapd {
                    try store.addTapdRef(workId: id, ref: tapd.ref, title: tapd.title,
                                         businessStatus: tapd.businessStatus, snapshotHash: tapd.snapshotHash,
                                         snapshotModified: tapd.snapshotModified, snapshot: tapd.snapshot)
                }
                let originText: String
                switch request.origin {
                case .local: originText = "本地创建"
                case .tapd: originText = "从 TAPD 导入"
                case .wecom: originText = "企业微信 / WorkBuddy 发起"
                }
                store.addActivity(workId: id, runId: nil, kind: "created", title: "创建 Work",
                                  detail: "\(displayId) · \(project.name) · \(originText)", actor: request.actor)
                if let tapd = request.tapd {
                    store.addActivity(workId: id, runId: nil, kind: "tapd", title: "关联 TAPD \(tapd.ref.entityType)",
                                      detail: "#\(tapd.ref.entityId) \(tapd.title)", actor: request.actor)
                }
                try store.appendEvent(workId: id, runId: nil, kind: "status",
                                      payload: .obj(["to": .string(WorkStatus.queued.rawValue),
                                                     "reason": .string(request.start ? "已请求启动，等待执行槽" : "已创建，等待启动授权")]))
            }
            guard let work = store.work(id: id) else { throw WorkError.failed("Work 创建后无法读取") }
            return (work, true)
        }
        queue.async { [self] in
            notify(.changed)
            tick()
        }
        return try read { store in
            .obj(["work": workJSON(created.0, store: store, project: store.project(id: created.0.projectId)),
                  "created": .bool(created.1)])
        }
    }

    // MARK: 状态迁移（在 queue 上调用）

    /// 统一的状态迁移：写库、追加状态事件、记活动。`from == to` 时只更新原因。
    func transition(_ work: inout Work, to status: WorkStatus, reason: String?, store: WorkStore,
                    runId: String? = nil, markUnread: Bool = false, activity: String? = nil) throws {
        let previous = work.status
        work.status = status
        work.statusReason = reason
        if status == .queued { work.queuedAt = WorkClock.iso() }
        if markUnread { work.unread = true }
        try store.save(&work)
        guard previous != status else { return }
        let event = try store.appendEvent(workId: work.id, runId: runId ?? work.currentRunId, kind: "status",
                                          payload: .obj(["from": .string(previous.rawValue),
                                                         "to": .string(status.rawValue), "reason": .str(reason)]))
        notify(.event(event))
        if let activity {
            store.addActivity(workId: work.id, runId: runId ?? work.currentRunId, kind: "status",
                              title: activity, detail: reason ?? "")
        }
        enqueueSourceNotice(work: work, store: store)
    }

    func checkRevision(_ work: Work, expected: Int?) throws {
        guard let expected, expected != work.revision else { return }
        throw WorkError.conflict("这个 Work 已被更新（当前版本 \(work.revision)），请按最新状态重试。")
    }

    // MARK: 启动 / 重试

    /// 请求启动：只表示「启动请求已入队」，是否立刻执行由执行槽决定。重复请求不会双启动。
    func start(workId: String, revision: Int?, requestId: String?) throws -> JSONValue {
        let result: JSONValue = try write { store in
            if let recorded = store.recordedResult(requestId: requestId) { return recorded }
            guard var work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            switch work.status {
            case .queued:
                if !work.startRequested {
                    try checkRevision(work, expected: revision)
                    work.startRequested = true
                    work.queuedAt = WorkClock.iso()
                    work.statusReason = "已请求启动，等待执行槽"
                    try store.save(&work)
                    store.addActivity(workId: work.id, runId: nil, kind: "start", title: "请求启动", actor: "本机用户")
                }
            case .running, .waitingUser, .waitingReview:
                break   // 已经在执行链路里：幂等返回当前状态
            case .failed, .interrupted:
                throw WorkError.rejected("这个 Work 上一轮\(work.status.label)，请使用「重试」明确开启新一轮。")
            case .completed, .cancelled:
                throw WorkError.rejected("\(work.status.label)的 Work 不能启动。")
            }
            let result: JSONValue = .obj(["accepted": .bool(true), "status": .string(work.status.rawValue),
                                          "revision": .int(work.revision)])
            store.recordResult(requestId: requestId, method: "work.start", result: result)
            return result
        }
        queue.async { [self] in notify(.changed); tick() }
        return result
    }

    /// 失败 / 中断后的重试：新建一轮 Run，保留前一轮的证据。
    func retry(workId: String, revision: Int?, requestId: String?) throws -> JSONValue {
        let result: JSONValue = try write { store in
            if let recorded = store.recordedResult(requestId: requestId) { return recorded }
            guard var work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            guard work.status == .failed || work.status == .interrupted else {
                if work.status == .queued || work.status == .running {
                    return .obj(["accepted": .bool(true), "status": .string(work.status.rawValue)])
                }
                throw WorkError.rejected("只有失败或已中断的 Work 可以重试，当前是「\(work.status.label)」。")
            }
            try checkRevision(work, expected: revision)
            try store.db.transaction {
                if store.pendingInputs(workId: work.id).isEmpty, work.sessionId != nil {
                    // 会话已经存在：续上被打断的工作，而不是重放之前的用户消息。
                    let id = UUID().uuidString.lowercased()
                    _ = try store.addPendingInput(id: id, workId: work.id,
                                                  text: "上一轮执行被中断或失败。请先检查当前工作目录的实际状态，再继续完成这个 Work 的目标；不要假设之前的操作已经完成。")
                    let event = try store.appendEvent(workId: work.id, runId: nil, kind: "user",
                                                      payload: .obj(["messageId": .string(id), "origin": .string("system"),
                                                                     "text": .string("重试：检查当前状态并继续完成 Work 目标。"),
                                                                     "state": .string("accepted")]))
                    notify(.event(event))
                }
                work.startRequested = true
                try transition(&work, to: .queued, reason: "已批准重试，等待执行槽", store: store,
                               activity: "批准重试")
            }
            let result: JSONValue = .obj(["accepted": .bool(true), "status": .string(work.status.rawValue)])
            store.recordResult(requestId: requestId, method: "work.retry", result: result)
            return result
        }
        queue.async { [self] in notify(.changed); tick() }
        return result
    }

    // MARK: 发送消息

    /// 向 Work 的会话发送一条用户消息。返回的是「已接受」，送达与处理状态由事件流继续报告。
    /// 同一个 messageId 只接受一次；超时或断线后前端重发同一 ID 不会变成两条。
    func send(workId: String, messageId: String, text: String) throws -> JSONValue {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw WorkError.invalid("消息内容不能为空") }
        guard !messageId.isEmpty else { throw WorkError.invalid("缺少 messageId") }
        let result: JSONValue = try write { store in
            guard var work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            if store.inputExists(id: messageId) {
                return .obj(["accepted": .bool(true), "duplicate": .bool(true), "status": .string(work.status.rawValue)])
            }
            switch work.status {
            case .completed, .cancelled:
                throw WorkError.rejected("\(work.status.label)的 Work 不再接收消息。需要继续请新建 Work 或明确开启新一轮。")
            case .waitingUser:
                throw WorkError.rejected("这个 Work 正在等待你回答问题，请先在问题卡片里作答。")
            case .queued where !work.startRequested && work.sessionId == nil:
                throw WorkError.rejected("这个 Work 还没有启动。启动后才能继续对话。")
            default:
                break
            }
            try store.db.transaction {
                _ = try store.addPendingInput(id: messageId, workId: work.id, text: body)
                let event = try store.appendEvent(workId: work.id, runId: work.currentRunId, kind: "user",
                                                  payload: .obj(["messageId": .string(messageId), "origin": .string("local"),
                                                                 "text": .string(body), "state": .string("accepted")]))
                notify(.event(event))
                switch work.status {
                case .running:
                    break   // 当前轮还在进行：直接写给执行器，由 CLI 排到本轮之后
                case .waitingReview:
                    // 请求修改：旧的审阅结论随之失效，新一轮 Run 重新产出证据。
                    work.startRequested = true
                    try transition(&work, to: .queued, reason: "收到修改意见，等待执行槽", store: store,
                                   activity: "请求修改")
                case .failed, .interrupted:
                    work.startRequested = true
                    try transition(&work, to: .queued, reason: "收到新消息，等待执行槽", store: store,
                                   activity: "继续执行")
                case .queued:
                    break
                default:
                    break
                }
            }
            if work.status == .running { deliverPendingInputs(work: work, store: store) }
            return .obj(["accepted": .bool(true), "status": .string(work.status.rawValue)])
        }
        queue.async { [self] in notify(.changed); tick() }
        return result
    }

    // MARK: 已读 / 归档

    /// 查看 Work 只消除未读标记，不清除仍待处理的 Attention。
    func markSeen(workId: String) {
        _ = try? write { store in
            guard var work = store.work(id: workId), work.unread else { return }
            work.unread = false
            work.revision -= 1      // 未读标记不是领域变更，不占用版本号
            try store.save(&work)
            notify(.changed)
        }
    }

    func archive(workId: String, archived: Bool) throws {
        try write { store in
            guard var work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            if archived, !(work.status.isTerminal || work.status == .failed || work.status == .interrupted) {
                throw WorkError.rejected("执行链路中的 Work 不能归档。归档不等于取消，请先结束或取消它。")
            }
            work.archived = archived
            try store.save(&work)
            notify(.changed)
        }
    }

    /// 在非运行态切换同一条 Work 的执行引擎（共用 Thread 跨引擎接力）：
    /// 关闭旧执行器常驻进程、清空当前单引擎 sessionId，下一轮启动新引擎时自动从 `run_events` 拼装 `<thread-handoff>` 前情上下文。
    func switchExecutor(workId: String, executor raw: String, model: String? = nil, permissionMode: String? = nil) throws -> JSONValue {
        let target = AgentProvider.parse(raw)
        let executable = target == .claude ? ClaudeLocator.find() : CliBinaryLocator.findAgy()
        guard executable != nil else {
            throw WorkError.unavailable("本机未检测到 \(target.label)（\(target.commandName)），请先安装并登录后再切换。")
        }
        let result: JSONValue = try write { store in
            guard var work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            guard !work.status.isTerminal else {
                throw WorkError.rejected("\(work.status.label)的 Work 不能切换执行引擎。")
            }
            guard work.status != .running && work.status != .waitingUser else {
                throw WorkError.rejected("当前轮次正在执行中，请先停止或等待本轮结束后再切换引擎。")
            }
            let previous = AgentProvider.parse(work.executor)
            if previous == target && model == nil && permissionMode == nil {
                return .obj(["accepted": .bool(true), "executor": .string(work.executor), "changed": .bool(false)])
            }
            if let oldProcess = processes.removeValue(forKey: workId) {
                SessionOwnership.shared.setExecutor(oldProcess.activeSessionId, held: false)
                oldProcess.shutdown(grace: 1)
            }
            processTokens.removeValue(forKey: workId)
            ready.remove(workId)

            try store.db.transaction {
                work.executor = target.rawValue
                if previous != target {
                    // 清空单引擎 sessionId，使下一轮在新引擎分配新底层会话并自动走 Handoff 前情注入
                    work.sessionId = nil
                    work.model = model
                    work.permissionMode = permissionMode
                } else {
                    if let model { work.model = model.isEmpty ? nil : model }
                    if let permissionMode { work.permissionMode = permissionMode.isEmpty ? nil : permissionMode }
                }
                try store.save(&work)
                if previous != target {
                    let msg = "已切换执行引擎：\(previous.label) → \(target.label)（下一轮将自动同步前情上下文）"
                    let event = try store.appendEvent(
                        workId: workId,
                        runId: work.currentRunId,
                        kind: "status",
                        payload: .obj([
                            "from": .string(work.status.rawValue),
                            "to": .string(work.status.rawValue),
                            "reason": .string(msg),
                            "executorSwitch": .bool(true),
                            "fromExecutor": .string(previous.rawValue),
                            "toExecutor": .string(target.rawValue),
                        ])
                    )
                    notify(.event(event))
                    store.addActivity(workId: workId, runId: work.currentRunId, kind: "executor",
                                      title: "切换执行引擎", detail: "\(previous.label) → \(target.label)")
                }
            }
            return .obj(["accepted": .bool(true), "executor": .string(work.executor), "changed": .bool(previous != target)])
        }
        queue.async { [self] in notify(.changed) }
        return result
    }

    // MARK: 事件流

    func transcript(workId: String, after: Int) throws -> JSONValue {
        try read { store in
            guard let work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            return .obj([
                "work": workJSON(work, store: store, project: store.project(id: work.projectId)),
                "events": .array(store.events(workId: workId, after: after)),
                "lastSeq": .int(store.lastEventSeq(workId: workId)),
                "attentions": .array(store.attentions(workId: workId).map(\.json)),
                "runs": .array(store.runs(workId: workId).map(\.json)),
                "activity": .array(store.activity(workId: workId)),
                "evidence": .array(store.evidence(workId: workId)),
                "checkpoints": .array(store.checkpoints(workId: workId).map(\.json)),
                "segments": .array(store.threadSegments(workId: workId)),
            ])
        }
    }

    // MARK: 草稿

    func draft(scope: String, key: String) -> String {
        ((try? read { $0.draft(scope: scope, key: key) }) ?? nil) ?? ""
    }

    func setDraft(scope: String, key: String, value: String) {
        _ = try? write { $0.setDraft(scope: scope, key: key, value: value) }
    }
}
