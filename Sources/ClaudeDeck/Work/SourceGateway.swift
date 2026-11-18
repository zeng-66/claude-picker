import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 来源网关：宿主提供给 WorkBuddy（企业微信对话侧）的接口。
///
/// 这里实现的是宿主这一侧的契约，不是 WorkBuddy 的 API：
/// - WorkBuddy 负责与人沟通、整理目标、判断项目；宿主只给它「已登记项目」的必要元数据（ID、名称、是否可用），
///   并校验它返回的项目 ID。没有群聊 → 项目的固定映射，也不接受模型给出的任意路径。
/// - 每条来源消息先落库并按（来源账号、会话、远端消息 ID）去重，重放只返回第一次的结果。
/// - 目标不唯一时只记录澄清，不创建 Work；澄清回复按意图身份关联，换了会话的回复不生效。
/// - 来源事件里没有可靠的发送人身份，所以远程的「确认」不能代替应用内的审批（见 AGENT_STARTER_INTEGRATION §3.4）。
/// 传输是本机 Unix 套接字（数据目录下，0600）+ 每次启动的新令牌；`--source-mcp` 把它包装成 MCP stdio 服务。
/// WorkBuddy 一侧如何调用尚未实测，设置页如实显示「宿主接口已就绪，对端未验证」。
enum SourceGateway {
    static let protocolVersion = 1

    static func settings(_ core: WorkCore) -> JSONValue {
        core.getSetting("robot") ?? .obj(["name": .string("开发协作助手"), "enabled": .bool(false),
                                          "autoStart": .bool(false), "remoteAnswers": .bool(false)])
    }

    // MARK: 请求分发

    static func handle(_ core: WorkCore, method: String, params: JSONValue) -> JSONValue {
        do {
            switch method {
            case "ping":
                core.setLastSeen()
                return ok(.obj(["protocol": .int(protocolVersion), "enabled": settings(core)["enabled"] ?? .bool(false)]))
            case "list_projects":
                core.setLastSeen()
                return ok(try listProjects(core))
            case "list_works":
                return ok(try listWorks(core, params: params))
            case "submit_intent":
                return ok(try submitIntent(core, params: params))
            case "get_work":
                return ok(try getWork(core, params: params))
            case "pending_notifications":
                return ok(try pendingNotifications(core, params: params))
            case "ack_notification":
                return ok(try ackNotification(core, params: params))
            case "answer_attention":
                return ok(try answerAttention(core, params: params))
            default:
                return .obj(["ok": .bool(false), "error": .obj(["code": .string("UNKNOWN_METHOD"), "message": .string("不支持的方法：\(method)")])])
            }
        } catch let error as WorkError {
            return .obj(["ok": .bool(false), "error": JSONValue(any: error.jsonObject)])
        } catch {
            return .obj(["ok": .bool(false), "error": .obj(["code": .string("COMMAND_FAILED"), "message": .string("\(error)")])])
        }
    }

    private static func ok(_ result: JSONValue) -> JSONValue { .obj(["ok": .bool(true), "result": result]) }

    // MARK: 项目索引

    /// 只给必要元数据：项目 ID、展示名、是否可用。不含路径之外的文件信息，更不含认证信息。
    static func listProjects(_ core: WorkCore) throws -> JSONValue {
        try core.read { store in
            let projects = store.projects()
            let version = WorkText.sha256(projects.map { "\($0.id)|\($0.name)|\($0.available)" }.joined(separator: "\n"))
            return .obj(["indexVersion": .string(String(version.prefix(16))),
                         "projects": .array(projects.map { .obj(["projectId": .string($0.id), "name": .string($0.name),
                                                                 "available": .bool($0.available)]) })])
        }
    }

    // MARK: 来源身份

    struct Source: Sendable {
        var accountId: String
        var conversationId: String
        var threadId: String
        var messageId: String
        var actorId: String
        var title: String
    }

    static func source(_ params: JSONValue, requireMessage: Bool = true) throws -> Source {
        let raw = params["source"] ?? .null
        guard let conversationId = raw["conversationId"]?.text else {
            throw WorkError.invalid("缺少来源会话 ID（source.conversationId）")
        }
        let messageId = raw["messageId"]?.text ?? ""
        if requireMessage, messageId.isEmpty {
            throw WorkError.invalid("缺少来源消息 ID（source.messageId）：没有稳定的事件身份就无法去重")
        }
        return Source(accountId: raw["accountId"]?.text ?? "default", conversationId: conversationId,
                      threadId: raw["threadId"]?.text ?? "", messageId: messageId,
                      actorId: raw["actorId"]?.text ?? "", title: raw["conversationTitle"]?.text ?? "")
    }

    private static func conversation(_ store: WorkStore, source: Source, create: Bool) throws -> String? {
        if let row = try store.db.first("""
            SELECT id FROM source_conversations WHERE origin = 'wecom' AND account_id = ? AND remote_conversation_id = ?
                AND remote_thread_id = ?
            """, [.text(source.accountId), .text(source.conversationId), .text(source.threadId)]) {
            if !source.title.isEmpty {
                try store.db.run("UPDATE source_conversations SET title = ?, updated_at = ? WHERE id = ?",
                                 [.text(source.title), .text(WorkClock.iso()), .text(row.text("id"))])
            }
            return row.text("id")
        }
        guard create else { return nil }
        let id = UUID().uuidString.lowercased()
        let now = WorkClock.iso()
        try store.db.run("""
            INSERT INTO source_conversations(id, origin, account_id, remote_conversation_id, remote_thread_id, actor_id,
                title, created_at, updated_at) VALUES(?, 'wecom', ?, ?, ?, ?, ?, ?, ?)
            """, [.text(id), .text(source.accountId), .text(source.conversationId), .text(source.threadId),
                  .text(source.actorId), .text(source.title), .text(now), .text(now)])
        return id
    }

    // MARK: 意图 → Work

    /// 宿主对来源侧给出的目录判定做校验：项目必须已登记、当前可访问；依据不能为空。
    static func validate(_ core: WorkCore, intent: JSONValue) throws -> (WorkIntent, WorkProject?, String?) {
        let objective = intent["objective"]?.text ?? ""
        guard !objective.isEmpty else { throw WorkError.invalid("意图缺少工作目标（intent.objective）") }
        var parsed = WorkIntent(objective: objective, title: intent["title"]?.text, projectId: intent["projectId"]?.text,
                                relatedWorkId: intent["relatedWorkId"]?.text,
                                resolution: intent["resolution"]?.stringValue ?? "needs_clarification",
                                evidence: (intent["evidence"]?.arrayValue ?? []).compactMap(\.text),
                                question: intent["question"]?.text)
        guard parsed.resolution == "resolved" else {
            parsed.resolution = "needs_clarification"
            return (parsed, nil, parsed.question ?? "这条需求要在哪个项目里处理？")
        }
        guard let projectId = parsed.projectId else {
            return (parsed, nil, "还不能确定这条需求对应的项目，请说明项目名称。")
        }
        guard !parsed.evidence.isEmpty else {
            // 只凭「最近活跃」之类的推测不够：没有可陈述的依据就回去问。
            return (parsed, nil, "需要先确认目标项目：请在对话里明确说明要处理的项目。")
        }
        let project = try core.read { $0.project(id: projectId) }
        guard let project else {
            return (parsed, nil, "没有找到对应的已登记项目。请说明项目名称；如果项目还没有添加到 Claude Picker，需要先在应用里添加该目录。")
        }
        guard project.available, WorkspaceService.isDirectory(project.path),
              WorkspaceService.canonical(project.path) == project.path else {
            return (parsed, nil, "项目「\(project.name)」的目录当前不可访问，暂时不能在其中创建 Work。")
        }
        return (parsed, project, nil)
    }

    /// `verifiedActor`：发送人身份由平台认证过（企业微信机器人回调里的 from.userid）。
    /// 只有应用自己的机器人连接会传 true；本机套接字 / MCP 进来的请求一律视为未验证。
    static func submitIntent(_ core: WorkCore, params: JSONValue, verifiedActor: Bool = false,
                             via channel: String = "WorkBuddy") throws -> JSONValue {
        let config = settings(core)
        guard config["enabled"]?.boolValue == true else {
            throw WorkError.rejected("企业微信对话入口已关闭，不接收新的工作请求。已创建的 Work 不受影响。")
        }
        let src = try source(params)
        let text = params["text"]?.stringValue ?? ""
        let intentJSON = params["intent"] ?? .null
        let replyTo = params["intentId"]?.text
        core.setLastSeen()

        // 1. 事件先落库并去重：同一条消息重复投递，直接返回第一次的结果。
        let (conversationId, eventId, replay): (String, String, JSONValue?) = try core.write { store in
            try store.db.transaction {
                guard let conversationId = try conversation(store, source: src, create: true) else {
                    throw WorkError.failed("无法记录来源会话")
                }
                if let existing = try store.db.first(
                    "SELECT id, result_json FROM input_events WHERE conversation_id = ? AND remote_event_id = ?",
                    [.text(conversationId), .text(src.messageId)]) {
                    return (conversationId, existing.text("id"), existing.json("result_json") ?? .obj(["state": .string("processing")]))
                }
                let eventId = UUID().uuidString.lowercased()
                try store.db.run("""
                    INSERT INTO input_events(id, conversation_id, remote_event_id, kind, actor_id, actor_verified, text,
                        payload_json, created_at) VALUES(?,?,?,?,?,?,?,?,?)
                    """, [.text(eventId), .text(conversationId), .text(src.messageId),
                          .text(replyTo == nil ? "message" : "clarification_reply"), .text(src.actorId),
                          .of(verifiedActor && !src.actorId.isEmpty), .text(text),
                          .text(intentJSON.serialized()), .text(WorkClock.iso())])
                return (conversationId, eventId, nil)
            }
        }
        if let replay {
            guard case .object(var object) = replay else { return replay }
            object["duplicate"] = .bool(true)
            return .object(object)
        }

        func finish(_ result: JSONValue, workId: String? = nil, intentId: String? = nil) throws -> JSONValue {
            try core.write { store in
                _ = try store.db.run("UPDATE input_events SET result_json = ?, work_id = ?, intent_id = ? WHERE id = ?",
                                     [.text(result.serialized()), .of(workId), .of(intentId), .text(eventId)])
            }
            core.queue.async { core.notify(.changed) }
            return result
        }

        // 2. 澄清回复：必须来自发起该意图的同一个会话；有发起人身份时还要是同一个人。
        var openIntentId: String?
        if let replyTo {
            let row = try core.read { try $0.db.first("SELECT * FROM intents WHERE id = ?", [.text(replyTo)]) }
            guard let row, row.text("status") == "open" else {
                return try finish(.obj(["state": .string("rejected"), "reason": .string("intent_closed"),
                                        "message": .string("这个澄清问题已经结束，请作为新的需求重新发起。")]))
            }
            guard row.text("conversation_id") == conversationId else {
                return try finish(.obj(["state": .string("rejected"), "reason": .string("other_conversation"),
                                        "message": .string("这个回复不是来自提出该需求的会话，不能用来确定它的目标。")]))
            }
            let asker = try core.read { try $0.db.first("SELECT actor_id FROM input_events WHERE id = ?", [.text(row.text("event_id"))]) }?
                .text("actor_id") ?? ""
            if !asker.isEmpty, !src.actorId.isEmpty, asker != src.actorId {
                return try finish(.obj(["state": .string("rejected"), "reason": .string("other_actor"),
                                        "message": .string("澄清需要由提出该需求的人回复。")]))
            }
            openIntentId = replyTo
        }

        // 3. 已有 Work 的跟进：只认本会话创建的 Work。
        let (intent, project, question) = try validate(core, intent: intentJSON)
        if let related = intent.relatedWorkId {
            let work = try core.read { store in store.work(displayId: related) ?? store.work(id: related) }
            guard let work, work.sourceConversationId == conversationId else {
                return try finish(.obj(["state": .string("needs_clarification"),
                                        "question": .string("没有在这个会话里找到 \(related)。请确认 Work 编号，或说明这是一个新的需求。")]))
            }
            do {
                let sent = try core.send(workId: work.id, messageId: "source-\(eventId)", text: intent.objective)
                return try finish(.obj(["state": .string("follow_up"), "displayId": .string(work.displayId),
                                        "status": sent["status"] ?? .null]), workId: work.id)
            } catch let error as WorkError {
                return try finish(.obj(["state": .string("rejected"), "reason": .string("work_not_accepting"),
                                        "displayId": .string(work.displayId), "message": .string(error.message)]), workId: work.id)
            }
        }

        // 4. 目标还不唯一：记录（或更新）澄清，不创建 Work，也不启动任何进程。
        guard let project else {
            let intentId: String = try core.write { store in
                let now = WorkClock.iso()
                if let openIntentId {
                    try store.db.run("UPDATE intents SET question = ?, objective = ?, updated_at = ? WHERE id = ?",
                                     [.of(question), .text(intent.objective), .text(now), .text(openIntentId)])
                    return openIntentId
                }
                let id = UUID().uuidString.lowercased()
                try store.db.run("""
                    INSERT INTO intents(id, conversation_id, event_id, objective, title, project_id, related_work_id,
                        resolution, evidence_json, question, status, created_at, updated_at)
                    VALUES(?,?,?,?,?,NULL,NULL,'needs_clarification',?,?, 'open', ?, ?)
                    """, [.text(id), .text(conversationId), .text(eventId), .text(intent.objective), .of(intent.title),
                          .text(JSONValue.array(intent.evidence.map { .string($0) }).serialized()), .of(question),
                          .text(now), .text(now)])
                return id
            }
            return try finish(.obj(["state": .string("needs_clarification"), "intentId": .string(intentId),
                                    "question": .str(question)]), intentId: intentId)
        }

        // 5. 目标明确：创建独立 Work（不创建 TAPD 对象），记录来源与判定依据。
        var request = WorkCore.CreateRequest(projectId: project.id,
                                             title: intent.title ?? String(intent.objective.prefix(60)),
                                             objective: intent.objective)
        request.origin = .wecom
        request.sourceConversationId = conversationId
        request.sourceEventId = eventId
        // 来源事件没有可靠的发送人身份：默认只创建、不授权启动，由应用内的用户启动。
        request.start = config["autoStart"]?.boolValue == true
        request.idempotencyKey = "source:\(conversationId):\(openIntentId ?? src.messageId)"
        request.actor = channel + (src.actorId.isEmpty ? "" : (verifiedActor ? "（\(src.actorId)）" : "（\(src.actorId)，身份未验证）"))
        let created = try core.create(request)
        let workId = created["work"]?["id"]?.stringValue ?? ""
        let displayId = created["work"]?["displayId"]?.stringValue ?? ""
        let intentId: String = try core.write { store in
            let now = WorkClock.iso()
            let id = openIntentId ?? UUID().uuidString.lowercased()
            if openIntentId != nil {
                try store.db.run("""
                    UPDATE intents SET project_id = ?, resolution = 'resolved', evidence_json = ?, status = 'created',
                        work_id = ?, updated_at = ? WHERE id = ?
                    """, [.text(project.id), .text(JSONValue.array(intent.evidence.map { .string($0) }).serialized()),
                          .text(workId), .text(now), .text(id)])
            } else {
                try store.db.run("""
                    INSERT INTO intents(id, conversation_id, event_id, objective, title, project_id, resolution,
                        evidence_json, status, work_id, created_at, updated_at)
                    VALUES(?,?,?,?,?,?, 'resolved', ?, 'created', ?, ?, ?)
                    """, [.text(id), .text(conversationId), .text(eventId), .text(intent.objective), .of(intent.title),
                          .text(project.id), .text(JSONValue.array(intent.evidence.map { .string($0) }).serialized()),
                          .text(workId), .text(now), .text(now)])
            }
            store.addActivity(workId: workId, runId: nil, kind: "source", title: "项目判定依据",
                              detail: intent.evidence.joined(separator: "；"), actor: channel)
            return id
        }
        return try finish(.obj([
            "state": .string("created"), "displayId": .string(displayId), "project": .string(project.name),
            "status": created["work"]?["status"] ?? .null,
            "startAuthorized": .bool(request.start),
            "link": .string("claude-picker://work/\(displayId)"),
            "note": .string(request.start ? "已进入执行队列。" : "已创建，等待在 Claude Picker 应用内启动。"),
        ]), workId: workId, intentId: intentId)
    }

    // MARK: 查询

    private static func listWorks(_ core: WorkCore, params: JSONValue) throws -> JSONValue {
        let src = try source(params, requireMessage: false)
        return try core.read { store in
            guard let conversationId = try conversation(store, source: src, create: false) else {
                return .obj(["works": .array([])])
            }
            let works = store.works().filter { $0.sourceConversationId == conversationId }
            return .obj(["works": .array(works.map { work in
                .obj(["displayId": .string(work.displayId), "title": .string(work.title),
                      "project": .str(store.project(id: work.projectId)?.name),
                      "status": .string(work.status.rawValue), "statusLabel": .string(work.status.label)])
            })])
        }
    }

    /// 只能查到本会话发起的 Work：不跨会话、不跨账号暴露。
    private static func getWork(_ core: WorkCore, params: JSONValue) throws -> JSONValue {
        let src = try source(params, requireMessage: false)
        guard let displayId = params["displayId"]?.text else { throw WorkError.invalid("缺少 displayId") }
        return try core.read { store in
            guard let conversationId = try conversation(store, source: src, create: false),
                  let work = store.work(displayId: displayId), work.sourceConversationId == conversationId else {
                throw WorkError.notFound("这个会话里没有 \(displayId)")
            }
            let open = work.currentRunId.map { store.openAttentions(runId: $0) } ?? []
            return .obj(["displayId": .string(work.displayId), "title": .string(work.title),
                         "project": .str(store.project(id: work.projectId)?.name),
                         "status": .string(work.status.rawValue), "statusLabel": .string(work.status.label),
                         "reason": .str(work.statusReason),
                         "waitingFor": .array(open.map { .obj(["attentionId": .string($0.id), "kind": .string($0.kind.rawValue),
                                                               "title": .string($0.title)]) }),
                         "link": .string("claude-picker://work/\(work.displayId)")])
        }
    }

    // MARK: 回到原会话的通知

    /// 需要回到原会话的内容：状态通知（待回答 / 待审阅 / 失败 / 完成）与用户确认过的结果汇报。
    /// 领取之后、收到回执之前，发送结果是未知的。
    private static func pendingNotifications(_ core: WorkCore, params: JSONValue) throws -> JSONValue {
        let limit = min(max(params["limit"]?.intValue ?? 10, 1), 50)
        core.setLastSeen()
        // 由应用自己的机器人连接负责的会话不交给 WorkBuddy，避免同一条消息被两边各发一次。
        let rows = try claimNotifications(core, botOwned: false, limit: limit, note: "已交给 WorkBuddy，尚未收到发送回执")
        return .obj(["notifications": .array(rows.map { row in
            .obj(["id": .string(row.text("id")), "kind": .string(row.text("target") == "wecom" ? "report" : "notice"),
                  "displayId": .string(row.text("display_id")), "title": .string(row.text("work_title")),
                  "text": .string(row.text("body")),
                  "conversation": .obj(["accountId": .string(row.text("account_id")),
                                        "conversationId": .string(row.text("remote_conversation_id")),
                                        "threadId": .string(row.text("remote_thread_id"))]),
                  "link": .string("claude-picker://work/\(row.text("display_id"))")])
        })])
    }

    static let botAccountPrefix = "wecom-bot:"

    /// 领取待发送的通知 / 汇报：在同一个事务里把它们标为「结果未知」，收到回执后再改为已发送或失败。
    /// 谁领取谁负责发送；`botOwned` 区分应用自己的机器人连接与 WorkBuddy 两条通道，互不重叠。
    static func claimNotifications(_ core: WorkCore, botOwned: Bool, limit: Int, note: String) throws -> [DBRow] {
        let rows: [DBRow] = try core.write { store in
            try store.db.transaction {
                let rows = try store.db.query("""
                    SELECT d.*, w.display_id, w.title AS work_title, c.remote_conversation_id, c.remote_thread_id, c.account_id
                    FROM deliveries d JOIN works w ON w.id = d.work_id
                    JOIN source_conversations c ON c.id = w.source_conversation_id
                    WHERE d.target IN ('wecom', 'wecom-notice') AND d.status = 'pending'
                      AND (c.account_id LIKE ?) = ? ORDER BY d.created_at LIMIT ?
                    """, [.text(botAccountPrefix + "%"), .of(botOwned), .of(limit)])
                for row in rows {
                    try store.db.run("""
                        UPDATE deliveries SET status = 'unknown', attempts = attempts + 1, error = ?, updated_at = ? WHERE id = ?
                        """, [.text(note), .text(WorkClock.iso()), .text(row.text("id"))])
                }
                return rows
            }
        }
        if !rows.isEmpty { core.queue.async { core.notify(.changed) } }
        return rows
    }

    /// 同一条来源消息之前处理过：返回当时的结果（重连后平台重发、或用户重复发送都不会再处理一次）。
    static func previousResult(_ core: WorkCore, source src: Source) -> JSONValue? {
        (try? core.read { store -> JSONValue? in
            guard let conversationId = try conversation(store, source: src, create: false),
                  let row = try store.db.first("SELECT result_json FROM input_events WHERE conversation_id = ? AND remote_event_id = ?",
                                               [.text(conversationId), .text(src.messageId)]) else { return nil }
            return row.json("result_json") ?? .obj(["state": .string("processing")])
        }) ?? nil
    }

    /// 普通问答也记一笔（不创建 Work）：便于在来源对话里回看，也用于去重。
    static func recordChat(_ core: WorkCore, source src: Source, text: String, reply: String, verifiedActor: Bool) {
        _ = try? core.write { store in
            try store.db.transaction {
                guard let conversationId = try conversation(store, source: src, create: true) else { return }
                try store.db.run("""
                    INSERT OR IGNORE INTO input_events(id, conversation_id, remote_event_id, kind, actor_id, actor_verified, text,
                        result_json, created_at) VALUES(?,?,?,'chat',?,?,?,?,?)
                    """, [.text(UUID().uuidString.lowercased()), .text(conversationId), .text(src.messageId), .text(src.actorId),
                          .of(verifiedActor && !src.actorId.isEmpty), .text(text),
                          .text(JSONValue.obj(["state": .string("chat"), "reply": .string(reply)]).serialized()),
                          .text(WorkClock.iso())])
            }
        }
        core.queue.async { core.notify(.changed) }
    }

    /// 给意图判断用的上下文：这个会话已有的 Work（含待回答的问题）与待澄清的意图。
    static func conversationContext(_ core: WorkCore, source src: Source) -> JSONValue {
        (try? core.read { store -> JSONValue in
            guard let conversationId = try conversation(store, source: src, create: false) else {
                return .obj(["works": .array([]), "openIntents": .array([])])
            }
            let works = store.works().filter { $0.sourceConversationId == conversationId && !$0.archived }.prefix(20)
            let intents = try store.db.query("""
                SELECT i.id, i.objective, i.question, e.actor_id FROM intents i JOIN input_events e ON e.id = i.event_id
                WHERE i.conversation_id = ? AND i.status = 'open' ORDER BY i.updated_at DESC LIMIT 5
                """, [.text(conversationId)])
            return .obj([
                "works": .array(works.map { work in
                    let open = work.currentRunId.map { store.openAttentions(runId: $0) } ?? []
                    return .obj(["displayId": .string(work.displayId), "title": .string(work.title),
                                 "project": .str(store.project(id: work.projectId)?.name),
                                 "status": .string(work.status.label), "reason": .str(work.statusReason),
                                 "openQuestions": .array(open.filter { $0.kind == .question }.map { attention in
                                     .obj(["attentionId": .string(attention.id),
                                           "questions": attention.body["questions"] ?? .array([])])
                                 })])
                }),
                "openIntents": .array(intents.map { row in
                    .obj(["intentId": .string(row.text("id")), "objective": .string(row.text("objective")),
                          "question": .str(row.string("question")), "askedBy": .string(row.text("actor_id"))])
                }),
            ])
        }) ?? .obj(["works": .array([]), "openIntents": .array([])])
    }

    private static func ackNotification(_ core: WorkCore, params: JSONValue) throws -> JSONValue {
        guard let id = params["id"]?.text else { throw WorkError.invalid("缺少通知 ID") }
        let sent = params["sent"]?.boolValue ?? false
        let receipt = params["receipt"]?.text
        try core.write { store in
            guard let row = store.delivery(id: id), row.text("target").hasPrefix("wecom") else {
                throw WorkError.notFound("找不到这条通知")
            }
            guard row.text("status") != DeliveryStatus.sent.rawValue else { return }     // 重复回执
            if sent {
                // 没有回执标识就不算「已发送」：只说发了却给不出凭据的，保持未知。
                guard let receipt else { throw WorkError.invalid("确认已发送需要提供发送回执（receipt）") }
                core.updateDelivery(id: id, status: .sent, remoteId: receipt)
            } else {
                core.updateDelivery(id: id, status: .failed, error: params["error"]?.text ?? "WorkBuddy 报告发送失败")
            }
        }
        return .obj(["recorded": .bool(true)])
    }

    /// 从原会话回答 Work 的问题。来源事件没有可靠的发送人身份：工具权限一律回应用内处理；
    /// 业务问题只有在设置里明确允许、且来自发起该 Work 的会话时才接收。
    static func answerAttention(_ core: WorkCore, params: JSONValue, verifiedActor: Bool = false,
                                via channel: String = "WorkBuddy") throws -> JSONValue {
        let src = try source(params)
        guard let attentionId = params["attentionId"]?.text else { throw WorkError.invalid("缺少 attentionId") }
        let config = settings(core)
        let (attention, work): (WorkAttention, Work) = try core.read { store in
            guard let attention = store.attention(id: attentionId), let work = store.work(id: attention.workId),
                  let conversationId = try conversation(store, source: src, create: false),
                  work.sourceConversationId == conversationId else {
                throw WorkError.notFound("这个会话里没有这个待回答的问题")
            }
            return (attention, work)
        }
        guard attention.kind == .question, config["remoteAnswers"]?.boolValue == true else {
            return .obj(["state": .string("requires_app"),
                         "message": .string(attention.kind == .question
                            ? "在原会话回答问题的功能没有开启，请在 Claude Picker 应用内作答。"
                            : "工具权限只能在 Claude Picker 应用内由本人确认。"),
                         "link": .string("claude-picker://work/\(work.displayId)")])
        }
        let result = try core.answer(attentionId: attentionId, revision: nil, answer: params["answer"] ?? .null,
                                     actor: channel + (src.actorId.isEmpty ? "（身份未验证）"
                                        : (verifiedActor ? "（\(src.actorId)）" : "（\(src.actorId)，身份未验证）")))
        return .obj(["state": .string(result["accepted"]?.boolValue == true ? "recorded" : (result["state"]?.stringValue ?? "rejected")),
                     "message": result["message"] ?? .null])
    }

    // MARK: 界面用的只读视图

    static func overview(_ core: WorkCore) -> JSONValue {
        let conversations: [JSONValue] = (try? core.read { store in
            try store.db.query("SELECT * FROM source_conversations ORDER BY updated_at DESC LIMIT 100").map { row in
                let id = row.text("id")
                let events = try store.db.query("SELECT * FROM input_events WHERE conversation_id = ? ORDER BY created_at DESC LIMIT 40",
                                                [.text(id)])
                let works = store.works().filter { $0.sourceConversationId == id }
                let intents = try store.db.query("SELECT * FROM intents WHERE conversation_id = ? AND status = 'open'", [.text(id)])
                return .obj(["id": .string(id), "title": .string(row.text("title")),
                             "remoteConversationId": .string(row.text("remote_conversation_id")),
                             "accountId": .string(row.text("account_id")), "updatedAt": .string(row.text("updated_at")),
                             "events": .array(events.map { event in
                                 .obj(["id": .string(event.text("id")), "kind": .string(event.text("kind")),
                                       "actorId": .string(event.text("actor_id")), "actorVerified": .bool(event.bool("actor_verified")),
                                       "text": .string(event.text("text")), "result": event.json("result_json") ?? .null,
                                       "workId": .str(event.string("work_id")), "at": .string(event.text("created_at"))])
                             }),
                             "works": .array(works.map { .obj(["id": .string($0.id), "displayId": .string($0.displayId),
                                                               "title": .string($0.title), "status": .string($0.status.rawValue)]) }),
                             "openIntents": .array(intents.map { .obj(["id": .string($0.text("id")), "objective": .string($0.text("objective")),
                                                                      "question": .str($0.string("question"))]) })])
            }
        }) ?? []
        return .obj(["settings": settings(core), "bot": WecomBot.shared.status(),
                     "socket": .str(SourceSocketServer.shared.path),
                     "listening": .bool(SourceSocketServer.shared.isListening),
                     "lastSeen": core.getSetting("robot.lastSeen") ?? .null,
                     "conversations": .array(conversations)])
    }
}

extension WorkCore {
    /// 来源侧最近一次调用宿主接口的时间：设置页据此显示「对端是否真的连上过」。
    func setLastSeen() {
        queue.async { _ = try? self.store?.setSetting("robot.lastSeen", .string(WorkClock.iso())) }
    }

    /// 企业微信发起的 Work 到了需要人知道的节点：生成一条回到原会话的通知（由 WorkBuddy 领取发送）。
    /// 同一状态不重复生成；发不出去不影响 Work 本身的状态。
    func enqueueSourceNotice(work: Work, store: WorkStore) {
        guard work.origin == .wecom, work.sourceConversationId != nil else { return }
        let text: String
        switch work.status {
        case .waitingUser: text = "【\(work.displayId)】\(work.title)：需要你回答一个问题后才能继续，请在 Claude Picker 中查看。"
        case .waitingReview: text = "【\(work.displayId)】\(work.title)：本轮执行已结束，等待审阅。"
        case .failed: text = "【\(work.displayId)】\(work.title)：执行失败。\(work.statusReason ?? "")"
        case .interrupted: text = "【\(work.displayId)】\(work.title)：执行被中断，结果未知，需要在应用中确认后重试。"
        case .completed: text = "【\(work.displayId)】\(work.title)：结果已确认。详细汇报由负责人确认后另行发送。"
        default: return
        }
        let hash = WorkText.sha256("\(work.status.rawValue)|\(work.currentRunId ?? "")|\(text)")
        let now = WorkClock.iso()
        _ = try? store.db.run("""
            INSERT OR IGNORE INTO deliveries(id, work_id, target, target_json, body, body_hash, status, created_at, updated_at)
            VALUES(?, ?, 'wecom-notice', NULL, ?, ?, 'pending', ?, ?)
            """, [.text(UUID().uuidString.lowercased()), .text(work.id), .text(text), .text(hash), .text(now), .text(now)])
    }
}

// MARK: - 本机套接字服务

/// 数据目录下的 Unix 套接字。同一用户的进程才能连接（0600），请求还要带本次启动生成的令牌。
final class SourceSocketServer: @unchecked Sendable {
    static let shared = SourceSocketServer()
    private let lock = NSLock()
    private var fd: Int32 = -1
    private(set) var path: String?
    private var token = ""

    var isListening: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }

    /// 套接字位置。`sun_path` 只有 104 字节：数据目录路径太长时改放到 `/tmp` 下按用户与目录区分的私有目录（0700）。
    /// 两端用同一个函数推导，不需要额外的发现文件。
    static func socketURL(directory: URL) -> URL {
        let direct = directory.appendingPathComponent("source.sock")
        if direct.path.utf8.count < 100 { return direct }
        let tag = String(WorkText.sha256(directory.standardizedFileURL.path).prefix(12))
        return URL(fileURLWithPath: "/tmp/claude-picker-\(getuid())-\(tag)", isDirectory: true)
            .appendingPathComponent("source.sock")
    }

    static func tokenURL(directory: URL) -> URL { directory.appendingPathComponent("source.token") }

    func start(core: WorkCore, directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return }
        let url = Self.socketURL(directory: directory)
        guard url.path.utf8.count < 100 else { return }
        let parent = url.deletingLastPathComponent()
        if parent.path != directory.path {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            // 目录必须是自己的、且别人进不来，否则不在里面放套接字。
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path),
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  chmod(parent.path, 0o700) == 0 else { return }
        }
        unlink(url.path)
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            url.path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(sock, 8) == 0 else {
            close(sock)
            return
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        arc4random_buf(&bytes, bytes.count)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        let tokenURL = Self.tokenURL(directory: directory)
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        fd = sock
        path = url.path
        let expected = token
        Thread.detachNewThread {
            while true {
                let client = accept(sock, nil, nil)
                if client < 0 { break }
                Thread.detachNewThread { Self.serve(client: client, core: core, token: expected) }
            }
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { close(fd) }
        fd = -1
        if let path { unlink(path) }
    }

    /// 一行一个 JSON 请求：`{id, token, method, params}` → `{id, ok, result | error}`。
    private static func serve(client: Int32, core: WorkCore, token: String) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > 4_000_000 { return }
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = JSONValue.parse(line) else { continue }
                var response: JSONValue
                if request["token"]?.stringValue != token {
                    response = .obj(["ok": .bool(false), "error": .obj(["code": .string("UNAUTHORIZED"), "message": .string("令牌无效")])])
                } else {
                    response = SourceGateway.handle(core, method: request["method"]?.stringValue ?? "", params: request["params"] ?? .null)
                }
                if case .object(var object) = response {
                    object["id"] = request["id"] ?? .null
                    response = .object(object)
                }
                let data = Data((response.serialized() + "\n").utf8)
                let written = data.withUnsafeBytes { write(client, $0.baseAddress, data.count) }
                if written < 0 { return }
            }
        }
    }
}

// MARK: - MCP stdio 包装（`ClaudePicker --source-mcp`）

/// 把来源网关包装成 MCP stdio 服务，供 WorkBuddy 作为工具服务加载。
/// 这个进程不打开数据库，只把工具调用转给正在运行的应用；应用没开时工具调用返回明确错误。
enum SourceMCPBridge {
    static let tools: [(name: String, description: String, schema: String)] = [
        ("list_projects", "列出 Claude Picker 已登记、可执行 Work 的本地项目（projectId、名称、是否可用）。判断一条需求属于哪个项目时先调用它。",
         #"{"type":"object","properties":{}}"#),
        ("list_works", "列出当前对话已经发起的 Work（编号、标题、项目、状态），用于判断新消息是不是对已有 Work 的跟进。",
         #"{"type":"object","properties":{"source":{"type":"object"}},"required":["source"]}"#),
        ("submit_intent", "把一条已整理好的工作请求交给 Claude Picker。intent.resolution 为 resolved 时必须给出 list_projects 返回的 projectId 和判定依据 evidence；不能唯一确定项目时用 needs_clarification 并在原对话追问。普通问答不要调用。",
         #"{"type":"object","properties":{"source":{"type":"object","properties":{"accountId":{"type":"string"},"conversationId":{"type":"string"},"threadId":{"type":"string"},"messageId":{"type":"string"},"actorId":{"type":"string"},"conversationTitle":{"type":"string"}},"required":["conversationId","messageId"]},"text":{"type":"string"},"intentId":{"type":"string"},"intent":{"type":"object","properties":{"objective":{"type":"string"},"title":{"type":"string"},"projectId":{"type":"string"},"relatedWorkId":{"type":"string"},"resolution":{"type":"string","enum":["resolved","needs_clarification"]},"evidence":{"type":"array","items":{"type":"string"}},"question":{"type":"string"}},"required":["objective","resolution"]}},"required":["source","text","intent"]}"#),
        ("get_work", "查询当前对话发起的某个 Work 的状态。",
         #"{"type":"object","properties":{"source":{"type":"object"},"displayId":{"type":"string"}},"required":["source","displayId"]}"#),
        ("pending_notifications", "领取需要回到原对话的通知与结果汇报。领取后必须用 ack_notification 报告是否发送成功。",
         #"{"type":"object","properties":{"limit":{"type":"integer"}}}"#),
        ("ack_notification", "报告一条通知的发送结果。sent=true 时必须提供发送回执 receipt。",
         #"{"type":"object","properties":{"id":{"type":"string"},"sent":{"type":"boolean"},"receipt":{"type":"string"},"error":{"type":"string"}},"required":["id","sent"]}"#),
        ("answer_attention", "把原对话里对 Work 问题的回答交给 Claude Picker。工具权限类请求只能在应用内确认。",
         #"{"type":"object","properties":{"source":{"type":"object"},"attentionId":{"type":"string"},"answer":{"type":"object"}},"required":["source","attentionId","answer"]}"#),
    ]

    private static func call(directory: URL, method: String, params: JSONValue) -> JSONValue {
        let socketPath = SourceSocketServer.socketURL(directory: directory).path
        guard let token = try? String(contentsOf: SourceSocketServer.tokenURL(directory: directory), encoding: .utf8) else {
            return .obj(["ok": .bool(false), "error": .obj(["message": .string("Claude Picker 没有在运行（找不到宿主接口）。请先打开应用。")])])
        }
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return .obj(["ok": .bool(false), "error": .obj(["message": .string("无法创建套接字")])]) }
        defer { close(sock) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            socketPath.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            return .obj(["ok": .bool(false), "error": .obj(["message": .string("Claude Picker 没有在运行（宿主接口未监听）。请先打开应用。")])])
        }
        let request = JSONValue.obj(["id": .string(UUID().uuidString), "token": .string(token.trimmingCharacters(in: .whitespacesAndNewlines)),
                                     "method": .string(method), "params": params]).serialized() + "\n"
        let payload = Data(request.utf8)
        guard payload.withUnsafeBytes({ write(sock, $0.baseAddress, payload.count) }) == payload.count else {
            return .obj(["ok": .bool(false), "error": .obj(["message": .string("写入宿主接口失败")])])
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while buffer.firstIndex(of: 0x0a) == nil {
            let count = read(sock, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
        }
        return JSONValue.parse(buffer) ?? .obj(["ok": .bool(false), "error": .obj(["message": .string("宿主接口没有返回结果")])])
    }

    /// 阻塞运行：标准输入读 JSON-RPC，标准输出写应答。
    static func run(directory: URL) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        func reply(_ id: JSONValue, result: JSONValue? = nil, error: JSONValue? = nil) {
            var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
            if let error { object["error"] = error } else { object["result"] = result ?? .object([:]) }
            print(JSONValue.object(object).serialized())
        }
        while let line = readLine(strippingNewline: true) {
            guard let message = JSONValue.parse(line), let method = message["method"]?.stringValue else { continue }
            guard let id = message["id"], !id.isNull else { continue }     // 通知类消息不需要应答
            switch method {
            case "initialize":
                reply(id, result: .obj(["protocolVersion": message["params"]?["protocolVersion"] ?? .string("2024-11-05"),
                                        "capabilities": .obj(["tools": .object([:])]),
                                        "serverInfo": .obj(["name": .string("claude-picker-work"), "version": .string("2.0.0")])]))
            case "ping":
                reply(id)
            case "tools/list":
                reply(id, result: .obj(["tools": .array(tools.map { tool in
                    .obj(["name": .string(tool.name), "description": .string(tool.description),
                          "inputSchema": JSONValue.parse(tool.schema) ?? .object([:])])
                })]))
            case "tools/call":
                let name = message["params"]?["name"]?.stringValue ?? ""
                guard tools.contains(where: { $0.name == name }) else {
                    reply(id, error: .obj(["code": .int(-32602), "message": .string("未知工具：\(name)")]))
                    continue
                }
                let response = call(directory: directory, method: name, params: message["params"]?["arguments"] ?? .object([:]))
                let failed = response["ok"]?.boolValue != true
                let body = failed ? (response["error"] ?? .null) : (response["result"] ?? .null)
                reply(id, result: .obj(["content": .array([.obj(["type": .string("text"), "text": .string(body.serialized(pretty: true))])]),
                                        "isError": .bool(failed)]))
            default:
                reply(id, error: .obj(["code": .int(-32601), "message": .string("Method not found")]))
            }
        }
        exit(0)
    }
}
