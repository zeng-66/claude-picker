import AppKit
import Foundation

/// Work 领域的桥方法（`work.*` / `attention.*` / `review.*` / `evidence.*` / `delivery.*` / `tapd.*` /
/// `source.*` / `agent.*` / `draft.*` / `project.*`）。全部在后台线程执行，领域状态由 `WorkCore` 串行管理。
///
/// 网页只是命令的发起方：路径、项目身份、状态机条件都在原生侧校验；命令的返回值只表达
/// 「已接受 / 拒绝 / 冲突」，执行进展通过 `claude-picker:work` 事件推回去。
enum WorkHandlers: BridgeModule {
    static let prefixes = ["work.", "attention.", "review.", "evidence.", "delivery.", "tapd.", "source.", "agent.", "draft.", "project.", "checkpoint."]

    static func handles(_ method: String) -> Bool { prefixes.contains { method.hasPrefix($0) } }

    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        guard handles(method) else { return .unknown }
        let p = JSONValue(any: params)
        guard let value = try run(method, p) else { return .unknown }
        return .handled(value.any)
    }

    private static func text(_ p: JSONValue, _ key: String) throws -> String {
        guard let value = p[key]?.text else { throw WorkError.invalid("缺少参数：\(key)") }
        return value
    }

    /// 侧栏里登记的目录就是可用的项目索引：每次取快照前同步进数据库。
    static func syncProjects(_ core: WorkCore) {
        let data: Data? = try? BridgeSupport.onMain {
            guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
            let list = delegate.store.projects.map { ["path": $0.path, "name": $0.isHome ? "~" : $0.title] }
            return try? JSONSerialization.data(withJSONObject: list)
        }
        guard let data, let list = JSONValue.parse(data)?.arrayValue else { return }
        _ = try? core.syncProjects(list.compactMap { item in
            guard let path = item["path"]?.text, let name = item["name"]?.text else { return nil }
            return (path: path, name: name)
        })
    }

    private static func cliMode(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw == "manual" ? "default" : raw
    }

    private static func run(_ method: String, _ p: JSONValue) throws -> JSONValue? {
        let core = WorkCore.shared
        switch method {
        // MARK: 快照与项目
        case "work.snapshot":
            syncProjects(core)
            return core.snapshot()

        case "project.list":
            syncProjects(core)
            return try SourceGateway.listProjects(core)

        // MARK: Work 命令
        case "work.create":
            syncProjects(core)
            let projectPath = WorkspaceService.canonical(try text(p, "projectPath"))
            guard let project = try core.read({ $0.project(path: projectPath) }) else {
                throw WorkError.invalid("这个目录还没有登记为项目，请先在侧栏添加目录。")
            }
            var request = WorkCore.CreateRequest(projectId: project.id, title: p["title"]?.stringValue ?? "",
                                                 objective: p["objective"]?.stringValue ?? "")
            request.scope = p["scope"]?.stringValue ?? ""
            request.start = p["start"]?.boolValue ?? false
            request.isolation = p["isolation"]?.text ?? "worktree"
            request.executor = p["executor"]?.text ?? "claude"
            request.permissionMode = cliMode(p["permissionMode"]?.text)
            request.model = p["model"]?.text
            request.idempotencyKey = p["requestId"]?.text.map { "local:\($0)" }
            if let sessionId = p["adoptSessionId"]?.text {
                request.adoptSession = WorkCore.AdoptedSession(
                    id: sessionId,
                    cwd: p["adoptCwd"]?.text ?? projectPath,
                    provider: p["adoptProvider"]?.text ?? request.executor
                )
            }
            return try core.create(request)

        case "work.switchExecutor":
            return try core.switchExecutor(
                workId: try text(p, "workId"),
                executor: try text(p, "executor"),
                model: p["model"]?.stringValue,
                permissionMode: cliMode(p["permissionMode"]?.stringValue)
            )

        case "work.start":
            return try core.start(workId: try text(p, "workId"), revision: p["revision"]?.intValue, requestId: p["requestId"]?.text)
        case "work.retry":
            return try core.retry(workId: try text(p, "workId"), revision: p["revision"]?.intValue, requestId: p["requestId"]?.text)
        case "work.interrupt":
            return try core.interrupt(workId: try text(p, "workId"), requestId: p["requestId"]?.text)
        case "work.cancel":
            return try core.cancel(workId: try text(p, "workId"), revision: p["revision"]?.intValue, requestId: p["requestId"]?.text)
        case "work.send":
            return try core.send(workId: try text(p, "workId"), messageId: try text(p, "messageId"),
                                 text: p["text"]?.stringValue ?? "")
        case "work.transcript":
            return try core.transcript(workId: try text(p, "workId"), after: p["after"]?.intValue ?? 0)
        case "work.seen":
            core.markSeen(workId: try text(p, "workId"))
            return .obj(["ok": .bool(true)])
        case "work.archive":
            try core.archive(workId: try text(p, "workId"), archived: p["archived"]?.boolValue ?? true)
            return .obj(["ok": .bool(true)])
        case "work.settings":
            if let slots = p["slots"]?.intValue { try core.setSlots(slots) }
            return core.snapshot()["capacity"] ?? .null

        case "work.export":
            return try core.exportMarkdown(workId: try text(p, "workId"), kind: p["kind"]?.text ?? "taskcard")

        case "work.saveExport":
            let exported = try core.exportMarkdown(workId: try text(p, "workId"), kind: p["kind"]?.text ?? "taskcard")
            let markdown = p["markdown"]?.text ?? exported["markdown"]?.stringValue ?? ""
            let name = exported["fileName"]?.stringValue ?? "work.md"
            let saved: String? = try BridgeSupport.onMain {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                panel.canCreateDirectories = true
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let url = panel.url else { return nil }
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                return url.path
            }
            return .obj(["saved": .bool(saved != nil), "path": .str(saved)])

        // MARK: 回答
        case "attention.answer":
            return try core.answer(attentionId: try text(p, "attentionId"), revision: p["revision"]?.intValue,
                                   answer: p["answer"] ?? .null)

        // MARK: 审阅与证据
        case "review.state":
            return try core.reviewState(workId: try text(p, "workId"))
        case "review.diff":
            return try core.reviewDiff(workId: try text(p, "workId"), file: try text(p, "path"))
        case "review.accept":
            return try core.acceptReview(workId: try text(p, "workId"), runId: try text(p, "runId"),
                                         tree: p["tree"]?.text, note: p["note"]?.text, requestId: p["requestId"]?.text)
        case "evidence.runCheck":
            return try core.runCheck(workId: try text(p, "workId"), command: p["command"]?.stringValue ?? "")

        case "checkpoint.list":
            return try core.checkpoints(workId: try text(p, "workId"))

        case "checkpoint.revert":
            return try core.revertCheckpoint(
                workId: try text(p, "workId"),
                checkpointId: try text(p, "checkpointId"),
                force: p["force"]?.boolValue ?? false,
                requestId: p["requestId"]?.text
            )

        // MARK: 交付
        case "delivery.preview":
            return try core.deliveryPreview(workId: try text(p, "workId"), target: try text(p, "target"))
        case "delivery.saveDraft":
            core.saveDeliveryDraft(workId: try text(p, "workId"), target: try text(p, "target"), body: p["body"]?.stringValue ?? "")
            return .obj(["ok": .bool(true)])
        case "delivery.confirm":
            return try core.deliveryConfirm(workId: try text(p, "workId"), target: try text(p, "target"),
                                            body: p["body"]?.stringValue ?? "", requestId: p["requestId"]?.text)
        case "delivery.retry":
            return try core.deliveryRetry(id: try text(p, "deliveryId"))
        case "delivery.verify":
            let id = try text(p, "deliveryId")
            guard let row = try core.read({ $0.delivery(id: id) }) else { throw WorkError.notFound("找不到这条投递记录") }
            if row.text("target") == "tapd" { return try TapdAdapter.verify(core, deliveryId: id) }
            // 企业微信侧没有可回读的接口：不能替用户判定是否送达。
            return .obj(["found": .null, "message": .string("企业微信消息无法由应用回读核对，请在原会话里确认是否已收到。")])
        case "delivery.markUndelivered":
            let id = try text(p, "deliveryId")
            try core.write { store in
                guard let row = store.delivery(id: id), row.text("status") == DeliveryStatus.unknown.rawValue else {
                    throw WorkError.rejected("只有结果未知的投递可以这样处理。")
                }
                core.updateDelivery(id: id, status: .failed, error: "用户确认原会话没有收到，可重新发送。")
            }
            return .obj(["ok": .bool(true)])
        case "delivery.requeue":
            // 企业微信投递的重试：重新排队，等 WorkBuddy 下次领取。
            let id = try text(p, "deliveryId")
            try core.write { store in
                guard let row = store.delivery(id: id), row.text("status") == DeliveryStatus.failed.rawValue,
                      row.text("target").hasPrefix("wecom") else {
                    throw WorkError.rejected("这条投递不能重新排队。")
                }
                try store.db.run("UPDATE deliveries SET status = 'pending', error = NULL, updated_at = ? WHERE id = ?",
                                 [.text(WorkClock.iso()), .text(id)])
                core.notify(.changed)
            }
            return .obj(["ok": .bool(true)])

        // MARK: 草稿
        case "draft.get":
            return .obj(["value": .string(core.draft(scope: try text(p, "scope"), key: try text(p, "key")))])
        case "draft.set":
            core.setDraft(scope: try text(p, "scope"), key: try text(p, "key"), value: p["value"]?.stringValue ?? "")
            return .obj(["ok": .bool(true)])

        // MARK: TAPD
        case "tapd.settings":
            if case .object(let patch)? = p["patch"] {
                var current = TapdAdapter.settings(core).objectValue ?? [:]
                for (key, value) in patch where ["enabled", "cliPath", "workspaces", "syncOnLaunch", "endpoint"].contains(key) {
                    current[key] = value
                }
                // 传输方式只能在 cli / mcp 之间切换；切到 MCP 需要先通过一键配置。
                if let transport = patch["transport"]?.stringValue, ["cli", "mcp"].contains(transport) {
                    if transport == "mcp", current["mcpCheckedAt"] == nil {
                        throw WorkError.rejected("请先用「一键配置」验证 TAPD MCP，再切换到 MCP。")
                    }
                    current["transport"] = .string(transport)
                }
                try core.putSetting("tapd", .object(current))
            }
            let config = TapdAdapter.settings(core)
            return .obj(["settings": config, "prerequisites": TapdAdapter.prerequisites(core)])
        case "tapd.setToken":
            try Keychain.set(.tapdToken, p["token"]?.stringValue ?? "")
            return .obj(["prerequisites": TapdAdapter.prerequisites(core)])
        case "tapd.clearToken":
            Keychain.delete(.tapdToken)
            return .obj(["prerequisites": TapdAdapter.prerequisites(core)])
        case "tapd.mcpSetup":
            return try TapdMcp.setup(core, idsText: p["workspaceIds"]?.stringValue ?? "",
                                     token: p["token"]?.stringValue, server: p["server"])
        case "tapd.test":
            if TapdMcp.isEnabled(core) { return TapdMcp.test(core) }
            do {
                let me = try TapdAdapter.whoami(core)
                return .obj(["connected": .bool(true), "user": .obj(["nick": .string(me.nick), "name": .string(me.name)]),
                             "checkedAt": .string(WorkClock.iso())])
            } catch let failure as TapdAdapter.Failure {
                return .obj(["connected": .bool(false), "message": .string(failure.message), "detail": .str(failure.detail),
                             "checkedAt": .string(WorkClock.iso())])
            }
        case "tapd.workspaces":
            do { return .obj(["workspaces": .array(try TapdAdapter.workspaces(core))]) }
            catch let failure as TapdAdapter.Failure { throw failure.workError }
        case "tapd.todos":
            let config = TapdAdapter.settings(core)
            guard config["enabled"]?.boolValue == true else {
                throw WorkError.unavailable("TAPD 连接未启用。请在设置的「TAPD 连接」里启用并选择项目。")
            }
            let enabled = (config["workspaces"]?.arrayValue ?? []).filter { $0["enabled"]?.boolValue != false }.compactMap { $0["id"]?.text }
            var targets = enabled
            if let only = p["workspaceId"]?.text { targets = enabled.filter { $0 == only } }
            guard !targets.isEmpty else {
                throw WorkError.unavailable("还没有选择要显示的 TAPD 项目。请在设置的「TAPD 连接」里勾选。")
            }
            do {
                return try TapdAdapter.todos(core, workspaceIds: targets, page: max(p["page"]?.intValue ?? 1, 1), query: p["query"]?.text,
                                             scope: p["scope"]?.text == "created" ? "created" : "todo")
            } catch let failure as TapdAdapter.Failure { throw failure.workError }
        case "tapd.fields":
            guard let ref = TapdRef(json: p["ref"]) else { throw WorkError.invalid("缺少完整的 TAPD 对象标识") }
            do {
                var out = try TapdAdapter.fields(core, workspaceId: ref.workspaceId, entityType: ref.entityType).objectValue ?? [:]
                out["members"] = .array(((try? TapdAdapter.members(core, workspaceId: ref.workspaceId)) ?? []).map { .string($0) })
                return .object(out)
            } catch let failure as TapdAdapter.Failure { throw failure.workError }
        case "tapd.related":
            guard let ref = TapdRef(json: p["ref"]) else { throw WorkError.invalid("缺少完整的 TAPD 对象标识") }
            do { return try TapdAdapter.related(core, ref: ref, kind: try text(p, "kind")) }
            catch let failure as TapdAdapter.Failure { throw failure.workError }
        case "tapd.comment":
            // 写入 TAPD：同一个 requestId 只执行一次（界面重发或重复点击不会多发一条评论）。
            guard let ref = TapdRef(json: p["ref"]) else { throw WorkError.invalid("缺少完整的 TAPD 对象标识") }
            let body = (p["body"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw WorkError.invalid("评论内容为空") }
            return try TapdWriteOnce.run(try text(p, "requestId")) {
                do {
                    let outcome = try TapdAdapter.postComment(core, ref: ref, body: body)
                    TapdAdapter.recordOnWorks(core, ref: ref, title: "已在 TAPD 评论",
                                              detail: WorkText.clip(body.replacingOccurrences(of: "\n", with: " "), limit: 80))
                    return .obj(["ok": .bool(true), "verified": .bool(outcome.verified), "commentId": .str(outcome.commentId)])
                } catch let failure as TapdAdapter.Failure { throw failure.workError }
            }
        case "tapd.transition":
            guard let ref = TapdRef(json: p["ref"]) else { throw WorkError.invalid("缺少完整的 TAPD 对象标识") }
            let target = try text(p, "to")
            let owner = p["owner"]?.text
            return try TapdWriteOnce.run(try text(p, "requestId")) {
                do {
                    let outcome = try TapdAdapter.transition(core, ref: ref, to: target, owner: owner, resolution: p["resolution"]?.text)
                    let from = p["fromLabel"]?.text ?? "—"
                    let toLabel = p["toLabel"]?.text ?? target
                    TapdAdapter.recordOnWorks(core, ref: ref, title: "已在 TAPD 流转",
                                              detail: "\(from) → \(toLabel)" + (owner.map { "（处理人 \($0)）" } ?? ""))
                    return .obj(["ok": .bool(true), "verified": .bool(outcome.verified)])
                } catch let failure as TapdAdapter.Failure { throw failure.workError }
            }
        case "tapd.detail":
            guard let ref = TapdRef(json: p["ref"]) else { throw WorkError.invalid("缺少完整的 TAPD 对象标识") }
            do { return try TapdAdapter.detail(core, ref: ref) }
            catch let failure as TapdAdapter.Failure { throw failure.workError }
        case "tapd.import":
            guard let ref = TapdRef(json: p["ref"]) else { throw WorkError.invalid("缺少完整的 TAPD 对象标识") }
            syncProjects(core)
            // 先查已有关联：同一个 TAPD 对象已经有 Work 时不静默再建一个。
            let existing = try core.read { $0.works(tapdRef: ref) }
            if !existing.isEmpty, p["newRound"]?.boolValue != true {
                return .obj(["created": .bool(false), "existing": .array(existing.map { work in
                    .obj(["id": .string(work.id), "displayId": .string(work.displayId), "title": .string(work.title),
                          "status": .string(work.status.rawValue), "statusLabel": .string(work.status.label)])
                })])
            }
            let projectPath = WorkspaceService.canonical(try text(p, "projectPath"))
            guard let project = try core.read({ $0.project(path: projectPath) }) else {
                throw WorkError.invalid("请选择一个已登记的本地项目。")
            }
            // 导入前重新读取一次需求：读不到就不创建，不用列表里的旧数据凑。
            let detail: JSONValue
            do { detail = try TapdAdapter.detail(core, ref: ref) }
            catch let failure as TapdAdapter.Failure { throw WorkError.unavailable("需求当前不可读，未创建 Work", detail: failure.message) }
            let title = p["title"]?.text ?? detail["title"]?.text ?? ""
            let description = detail["descriptionText"]?.stringValue ?? ""
            var request = WorkCore.CreateRequest(projectId: project.id, title: title,
                                                 objective: p["objective"]?.text ?? "实现 TAPD \(ref.entityType)「\(detail["title"]?.stringValue ?? "")」所描述的内容。")
            request.origin = .tapd
            request.scope = p["scope"]?.stringValue ?? ""
            request.start = p["start"]?.boolValue ?? false
            request.isolation = p["isolation"]?.text ?? "worktree"
            request.executor = p["executor"]?.text ?? "claude"
            request.permissionMode = cliMode(p["permissionMode"]?.text)
            request.model = p["model"]?.text
            request.idempotencyKey = "tapd:\(ref.workspaceId):\(ref.entityType):\(ref.entityId):\(existing.count)"
            request.tapd = WorkCore.TapdAttachment(ref: ref, title: detail["title"]?.stringValue ?? "",
                                                   businessStatus: detail["status"]?.text,
                                                   snapshotHash: detail["snapshotHash"]?.text,
                                                   snapshotModified: detail["modified"]?.text,
                                                   snapshot: .obj(["descriptionText": .string(description),
                                                                   "title": detail["title"], "status": detail["status"],
                                                                   "modified": detail["modified"]]))
            let created = try core.create(request)
            return .obj(["created": .bool(true), "work": created["work"] ?? .null])
        case "tapd.snapshotCheck":
            // 需求在导入后是否被改过：只报告差异，不覆盖正在执行的目标。
            let workId = try text(p, "workId")
            guard let row = try core.read({ $0.tapdRefs(workId: workId).first }),
                  let ref = TapdRef(json: .obj(["workspaceId": .string(row.text("workspace_id")),
                                                "entityType": .string(row.text("entity_type")),
                                                "entityId": .string(row.text("entity_id"))])) else {
                throw WorkError.rejected("这个 Work 没有关联 TAPD 对象。")
            }
            do {
                let detail = try TapdAdapter.detail(core, ref: ref)
                let old = row.json("snapshot_json")
                return .obj(["changed": .bool(detail["snapshotHash"]?.stringValue != row.string("snapshot_hash")),
                             "businessStatus": detail["status"] ?? .null,
                             "snapshotModified": .str(row.string("snapshot_modified")), "modified": detail["modified"] ?? .null,
                             "titleChanged": .bool(old?["title"]?.stringValue != detail["title"]?.stringValue),
                             "descriptionChanged": .bool(old?["descriptionText"]?.stringValue != detail["descriptionText"]?.stringValue),
                             "statusChanged": .bool(old?["status"]?.stringValue != detail["status"]?.stringValue),
                             "current": detail])
            } catch let failure as TapdAdapter.Failure { throw failure.workError }

        // MARK: 企业微信 / WorkBuddy
        case "source.overview":
            return SourceGateway.overview(core)

        // 多机器人：每个 Bot 独立的凭据、模式、默认 CLI 与生效范围（人员 / 场景 / 项目三项交集）。
        case "source.bots":
            return WecomBotAdmin.list(core)
        case "source.saveBot":
            let saved = try WecomBotAdmin.save(core, p["bot"] ?? .null)
            WecomBot.shared.refresh()
            return saved
        case "source.deleteBot":
            try WecomBotAdmin.delete(core, id: try text(p, "id"))
            WecomBot.shared.refresh()
            return WecomBotAdmin.list(core)
        case "source.setBotSecret":
            let id = try text(p, "id")
            try WecomBotConfig.setSecret(id, p["secret"]?.stringValue ?? "")
            WecomBot.shared.refresh(botLocalId: id, force: true)
            return .obj(["saved": .bool(true)])
        case "source.clearBotSecret":
            let id = try text(p, "id")
            WecomBotConfig.clearSecret(id)
            WecomBot.shared.refresh()
            return .obj(["saved": .bool(false)])
        case "source.reconnectBot":
            WecomBot.shared.refresh(botLocalId: try text(p, "id"), force: true)
            return .obj(["ok": .bool(true)])
        case "source.settings":
            guard case .object(let patch)? = p["patch"] else { return SourceGateway.settings(core) }
            var current = SourceGateway.settings(core).objectValue ?? [:]
            if let name = patch["name"]?.stringValue {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (1...50).contains(trimmed.count) else { throw WorkError.invalid("机器人名称需为 1–50 个字符") }
                current["name"] = .string(trimmed)
            }
            if let mode = patch["mode"]?.text {
                guard ["claude", "work"].contains(mode) else { throw WorkError.invalid("未知的机器人对话模式") }
                current["mode"] = .string(mode)
            }
            for key in ["enabled", "autoStart", "remoteAnswers"] {
                if let value = patch[key]?.boolValue { current[key] = .bool(value) }
            }
            if let botId = patch["botId"]?.stringValue {
                let trimmed = botId.trimmingCharacters(in: .whitespacesAndNewlines)
                current["botId"] = trimmed.isEmpty ? .null : .string(trimmed)
            }
            try core.putSetting("robot", .object(current))
            WecomBot.shared.refresh()
            return SourceGateway.settings(core)     // 回读保存后的值
        case "source.setSecret":
            try Keychain.set(.wecomBotSecret, p["secret"]?.stringValue ?? "")
            WecomBot.shared.refresh(force: true)
            return .obj(["saved": .bool(true)])
        case "source.clearSecret":
            Keychain.delete(.wecomBotSecret)
            WecomBot.shared.refresh()
            return .obj(["saved": .bool(false)])
        case "source.botStatus":
            return WecomBot.shared.status()
        case "source.reconnect":
            WecomBot.shared.refresh(force: true)
            return .obj(["ok": .bool(true)])
        case "source.mcpCommand":
            let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
            return .obj(["command": .string(executable), "args": .array([.string("--source-mcp")]),
                         "listening": .bool(SourceSocketServer.shared.isListening)])

        // MARK: 智能体能力（只读）
        case "agent.pack":
            if let path = p["path"]?.text {
                let index = AgentPack.index(path: path)
                if index["valid"]?.boolValue == true { try core.putSetting("agentPack", .obj(["path": .string(path)])) }
                return index
            }
            if p["clear"]?.boolValue == true {
                try core.putSetting("agentPack", .obj(["path": .null]))
                return .obj(["valid": .bool(false), "configured": .bool(false)])
            }
            guard let saved = core.getSetting("agentPack")?["path"]?.text else {
                return .obj(["valid": .bool(false), "configured": .bool(false)])
            }
            return AgentPack.index(path: saved)

        default:
            return nil
        }
    }
}

// MARK: - 运行时接线

/// 应用启动时把领域层接到宿主：事件推给网页、注册外部副作用的处理方、打开来源接口。
@MainActor
enum WorkRuntime {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        let core = WorkCore.shared
        core.observe { notification in
            let payload: JSONValue
            switch notification {
            case .changed: payload = .obj(["type": .string("changed")])
            case .event(let event): payload = .obj(["type": .string("event"), "event": event])
            case .delta(let workId, let runId, let text):
                payload = .obj(["type": .string("delta"), "workId": .string(workId), "runId": .string(runId), "text": .string(text)])
            }
            let json = Data(payload.serialized().utf8)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = Bridge.emit("claude-picker:work", json: json) }
            }
        }
        TapdAdapter.registerEffects(core)
        WecomBot.shared.start(core: core)
        SourceSocketServer.shared.start(core: core, directory: AppDataDir.url.appendingPathComponent("work", isDirectory: true))
    }

    static func stop() {
        WecomBot.shared.stop()
        SourceSocketServer.shared.stop()
    }
}

/// TAPD 写操作的幂等：同一个 requestId 只真正执行一次，之后直接返回第一次的结果（进程内记忆）。
enum TapdWriteOnce {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var results: [String: JSONValue] = [:]
    nonisolated(unsafe) private static var running: Set<String> = []

    static func run(_ requestId: String, _ body: () throws -> JSONValue) throws -> JSONValue {
        lock.lock()
        if let done = results[requestId] { lock.unlock(); return done }
        guard running.insert(requestId).inserted else {
            lock.unlock()
            throw WorkError.rejected("这次写入正在进行，请稍候。")
        }
        lock.unlock()
        defer { lock.lock(); running.remove(requestId); lock.unlock() }
        let result = try body()
        lock.lock(); results[requestId] = result; lock.unlock()
        return result
    }
}

