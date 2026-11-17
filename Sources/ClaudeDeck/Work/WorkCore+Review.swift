import Foundation

// 审阅、证据、交付投递与导出。
// 三件事分开记录：接受审阅（绑定代码版本）≠ Work 之外的业务完成 ≠ 结果已送达来源。

extension WorkCore {
    // MARK: 审阅

    /// 当前执行目录的版本与相对基线的变更。git 计算在调用线程上做，不占领域队列。
    func reviewState(workId: String) throws -> JSONValue {
        let (work, evidence): (Work, [JSONValue]) = try read { store in
            guard let work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            return (work, store.evidence(workId: workId))
        }
        guard let path = work.workspacePath, WorkspaceService.isDirectory(path) else {
            return .obj(["prepared": .bool(false), "files": .array([]), "evidence": .array(evidence),
                         "reason": .string(work.workspacePath == nil ? "这个 Work 还没有执行过，没有执行目录。" : "执行目录已不存在：\(work.workspacePath ?? "")")])
        }
        let version = WorkspaceService.version(of: path)
        var files: [WorkspaceService.ChangedFile] = []
        if let base = work.baseCommit, let tree = version.tree {
            files = WorkspaceService.changes(in: path, base: base, tree: tree)
        }
        let accepted = evidence.last { $0["kind"]?.stringValue == "review" }
        return .obj([
            "prepared": .bool(true),
            "workspacePath": .string(path),
            "isRepository": .bool(version.isRepository),
            "base": .str(work.baseCommit),
            "head": .str(version.head),
            "tree": .str(version.tree),
            "headMoved": .bool(version.head != nil && version.head != work.baseCommit),
            "uncommitted": .bool(version.isRepository && WorkspaceService.hasUncommittedChanges(path)),
            "files": .array(files.map(\.json)),
            "added": .int(files.compactMap(\.added).reduce(0, +)),
            "deleted": .int(files.compactMap(\.deleted).reduce(0, +)),
            "evidence": .array(evidence),
            "acceptedTree": accepted?["tree"] ?? .null,
            // 已接受的审阅只对当时的代码版本有效：之后代码再变，旧批准不再代表当前代码。
            "acceptedStale": .bool(accepted != nil && accepted?["tree"]?.stringValue != version.tree),
        ])
    }

    func reviewDiff(workId: String, file: String) throws -> JSONValue {
        let work: Work = try read { store in
            guard let work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            return work
        }
        guard let path = work.workspacePath, let base = work.baseCommit else {
            throw WorkError.unavailable("这个 Work 没有可比较的基线（不是 Git 仓库或尚未执行）。")
        }
        guard !file.isEmpty, !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else {
            throw WorkError.invalid("文件路径不合法")
        }
        let version = WorkspaceService.version(of: path)
        guard let tree = version.tree else { throw WorkError.unavailable("无法读取当前代码版本") }
        return WorkspaceService.patch(in: path, base: base, tree: tree, file: file)
    }

    /// 接受审阅：记录的是「对这一轮 Run、这一个代码版本的认可」，不是一个布尔值。
    /// 提交时重新计算版本，与用户看到的版本不一致就拒绝。
    func acceptReview(workId: String, runId: String, tree: String?, note: String?, requestId: String?) throws -> JSONValue {
        let work: Work = try read { store in
            guard let work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            return work
        }
        let version: WorkspaceVersion = work.workspacePath.map { WorkspaceService.version(of: $0) }
            ?? WorkspaceVersion(head: nil, tree: nil, isRepository: false)

        let result: JSONValue = try write { store in
            if let recorded = store.recordedResult(requestId: requestId) { return recorded }
            guard var work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            if work.status == .completed {
                return .obj(["accepted": .bool(true), "state": .string("already_completed")])
            }
            guard work.status == .waitingReview else {
                throw WorkError.rejected("只有待审阅的 Work 可以确认结果，当前是「\(work.status.label)」。")
            }
            guard work.currentRunId == runId, var run = store.run(id: runId) else {
                throw WorkError.conflict("你审阅的执行轮次已经不是当前轮次，请查看最新结果后再确认。")
            }
            if version.isRepository {
                guard let current = version.tree else { throw WorkError.unavailable("无法读取当前代码版本，未记录审阅。") }
                guard current == tree else {
                    throw WorkError.conflict("代码在你查看之后又发生了变化，之前看到的差异已不是当前版本。请重新查看后再确认。")
                }
            }
            try store.db.transaction {
                run.status = .completed
                run.reviewedTree = version.tree
                run.reviewedCommit = version.head
                run.endedAt = WorkClock.iso()
                try store.save(run)
                let versionText = version.isRepository
                    ? "tree \(String((version.tree ?? "").prefix(12))) · HEAD \(String((version.head ?? "—").prefix(12)))"
                    : "非 Git 目录，未绑定代码版本"
                try store.addEvidence(workId: workId, runId: runId, kind: "review", title: "审阅通过",
                                      detail: .obj(["note": .str(note), "isRepository": .bool(version.isRepository),
                                                    "headIsBase": .bool(version.head == work.baseCommit),
                                                    "actor": .string("本机用户")]),
                                      commit: version.head, tree: version.tree)
                try transition(&work, to: .completed, reason: "已确认结果（\(versionText)）", store: store,
                               activity: "确认变更并完成 Work")
            }
            let result: JSONValue = .obj(["accepted": .bool(true), "state": .string("completed"),
                                          "tree": .str(version.tree), "head": .str(version.head)])
            store.recordResult(requestId: requestId, method: "review.accept", result: result)
            // Work 完成后不再保留空闲的执行进程。
            processes[workId]?.shutdown(grace: 2)
            return result
        }
        queue.async { [self] in notify(.changed); tick() }
        return result
    }

    // MARK: 验证命令

    /// 在执行目录里运行一条由用户输入的验证命令，并把命令、起止时间、退出码、对应代码版本记为证据。
    /// 立即返回；结果随后更新到同一条证据上。
    func runCheck(workId: String, command: String) throws -> JSONValue {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { throw WorkError.invalid("请输入要运行的验证命令") }
        let (work, evidenceId): (Work, String) = try write { store in
            guard let work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            guard let path = work.workspacePath, WorkspaceService.isDirectory(path) else {
                throw WorkError.unavailable("这个 Work 还没有可用的执行目录。")
            }
            let id = try store.addEvidence(workId: workId, runId: work.currentRunId, kind: "check", title: line,
                                           detail: .obj(["command": .string(line), "state": .string("running"),
                                                         "cwd": .string(path), "startedAt": .string(WorkClock.iso())]))
            notify(.changed)
            return (work, id)
        }
        let path = work.workspacePath ?? ""
        worker.async { [self] in
            let version = WorkspaceService.version(of: path)
            let started = Date()
            let result = Proc.run("/bin/zsh", ["-lc", line], cwd: path, timeout: 1200)
            let ended = Date()
            let output = WorkText.redact(String((result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)).suffix(8000)))
            let state = result.timedOut ? "timeout" : (result.launchError != nil ? "error" : (result.exitCode == 0 ? "passed" : "failed"))
            queue.async {
                guard let store = self.store else { return }
                _ = try? store.db.run("UPDATE evidence SET detail_json = ?, commit_sha = ?, tree_hash = ? WHERE id = ?", [
                    .text(JSONValue.obj(["command": .string(line), "state": .string(state), "cwd": .string(path),
                                         "exitCode": result.timedOut || result.launchError != nil ? .null : .int(Int(result.exitCode)),
                                         "startedAt": .string(WorkClock.iso(started)), "endedAt": .string(WorkClock.iso(ended)),
                                         "output": .string(output), "launchError": .str(result.launchError)]).serialized()),
                    .of(version.head), .of(version.tree), .text(evidenceId),
                ])
                store.addActivity(workId: workId, runId: work.currentRunId, kind: "check", title: "运行验证命令",
                                  detail: "\(line) → \(state)", actor: "本机用户")
                self.notify(.changed)
            }
        }
        return .obj(["accepted": .bool(true), "evidenceId": .string(evidenceId)])
    }

    // MARK: 交付草稿

    /// 生成（或取回已保存的）交付草稿。只读，不产生任何外部副作用。
    func deliveryPreview(workId: String, target: String) throws -> JSONValue {
        guard target == "tapd" || target == "wecom" else { throw WorkError.invalid("未知的投递目标") }
        let state = try reviewState(workId: workId)
        return try read { store in
            guard let work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            let project = store.project(id: work.projectId)
            var targetInfo: JSONValue = .null
            var blockers: [String] = []
            if target == "tapd" {
                guard let ref = store.tapdRefs(workId: workId).first else {
                    throw WorkError.rejected("这个 Work 没有关联 TAPD 对象，不能回填。")
                }
                targetInfo = .obj(["workspaceId": .string(ref.text("workspace_id")), "entityType": .string(ref.text("entity_type")),
                                   "entityId": .string(ref.text("entity_id")), "title": .string(ref.text("title")),
                                   "businessStatus": .str(ref.string("business_status")),
                                   "action": .string("添加评论（不修改状态、工时、排期与上线字段）")])
            } else {
                guard work.origin == .wecom, let conversationId = work.sourceConversationId,
                      let row = try store.db.first("SELECT * FROM source_conversations WHERE id = ?", [.text(conversationId)]) else {
                    throw WorkError.rejected("这个 Work 不是从企业微信对话发起的，没有可回复的原会话。")
                }
                targetInfo = .obj(["conversationId": .string(conversationId), "title": .string(row.text("title")),
                                   "remoteConversationId": .string(row.text("remote_conversation_id")),
                                   "action": .string("交给 WorkBuddy 在原会话回复")])
            }
            if work.status != .completed { blockers.append("尚未确认变更：请先完成审阅并确认结果。") }
            if state["acceptedStale"]?.boolValue == true { blockers.append("审阅通过后代码又发生了变化，汇报依据已失效，需要重新审阅。") }

            let saved = store.draft(scope: "delivery:\(target)", key: workId)
            let generated = Self.composeDelivery(work: work, project: project, state: state, evidence: store.evidence(workId: workId))
            let body = saved ?? generated
            return .obj([
                "workId": .string(workId), "target": .string(target), "targetInfo": targetInfo,
                "body": .string(body), "generated": .string(generated), "edited": .bool(saved != nil && saved != generated),
                "evidenceVersion": state["acceptedTree"] ?? .null,
                "blockers": .array(blockers.map { .string($0) }),
                "deliveries": .array(store.deliveries(workId: workId).filter { $0.text("target") == target }
                    .map(WorkStore.deliveryJSON)),
            ])
        }
    }

    static func composeDelivery(work: Work, project: WorkProject?, state: JSONValue, evidence: [JSONValue]) -> String {
        var lines: [String] = []
        lines.append("【\(work.displayId)】\(work.title)")
        lines.append("项目：\(project?.name ?? "—")")
        if let summary = evidence.last(where: { $0["kind"]?.stringValue == "result" })?["detail"]?["text"]?.text {
            lines.append("")
            lines.append("结果摘要：")
            lines.append(WorkText.clip(summary, limit: 1200))
        }
        lines.append("")
        let files = state["files"]?.arrayValue ?? []
        if state["isRepository"]?.boolValue == true {
            lines.append("变更范围：\(files.count) 个文件，+\(state["added"]?.intValue ?? 0) / −\(state["deleted"]?.intValue ?? 0)。")
            let head = state["head"]?.text.map { String($0.prefix(10)) }
            if state["headMoved"]?.boolValue == true, let head {
                lines.append(state["uncommitted"]?.boolValue == true
                    ? "代码状态：已有提交 \(head)，另有未提交的变更。"
                    : "代码状态：已提交 \(head)（未推送、未合并）。")
            } else {
                lines.append("代码状态：变更尚未提交，保留在工作树中。")
            }
        } else {
            lines.append("变更范围：执行目录不是 Git 仓库，没有可核对的差异。")
        }
        let checks = evidence.filter { $0["kind"]?.stringValue == "check" }
        if checks.isEmpty {
            lines.append("验证：应用内没有记录到验证命令的执行结果。")
        } else {
            lines.append("验证：")
            for check in checks.suffix(6) {
                let detail = check["detail"]
                let stateText: String
                switch detail?["state"]?.stringValue {
                case "passed": stateText = "通过"
                case "failed": stateText = "失败（退出码 \(detail?["exitCode"]?.intValue ?? -1)）"
                case "timeout": stateText = "超时"
                case "running": stateText = "运行中"
                default: stateText = "未能运行"
                }
                let stale = check["tree"]?.stringValue != state["tree"]?.stringValue ? "，针对较早的代码版本" : ""
                lines.append("- `\(detail?["command"]?.stringValue ?? "")`：\(stateText)\(stale)")
            }
        }
        lines.append("")
        lines.append("说明：以上为本地执行与审阅结果，不代表业务验收、发布或上线。")
        return lines.joined(separator: "\n")
    }

    func saveDeliveryDraft(workId: String, target: String, body: String) {
        setDraft(scope: "delivery:\(target)", key: workId, value: body)
    }

    // MARK: 确认投递

    /// 确认投递：只是「投递已排队」。发送结果由 outbox 的执行情况决定，不在这里宣称已送达。
    /// 同一个 Work、同一目标、同一正文只排队一次。
    func deliveryConfirm(workId: String, target: String, body: String, requestId: String?) throws -> JSONValue {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WorkError.invalid("投递内容不能为空") }
        let preview = try deliveryPreview(workId: workId, target: target)
        if let blocker = preview["blockers"]?.arrayValue?.first?.stringValue {
            throw WorkError.rejected(blocker)
        }
        let hash = WorkText.sha256(text)
        let result: JSONValue = try write { store in
            if let recorded = store.recordedResult(requestId: requestId) { return recorded }
            if let existing = try store.db.first(
                "SELECT * FROM deliveries WHERE work_id = ? AND target = ? AND body_hash = ?",
                [.text(workId), .text(target), .text(hash)]) {
                return .obj(["accepted": .bool(true), "duplicate": .bool(true),
                             "delivery": WorkStore.deliveryJSON(existing)])
            }
            let id = UUID().uuidString.lowercased()
            let now = WorkClock.iso()
            try store.db.transaction {
                try store.db.run("""
                    INSERT INTO deliveries(id, work_id, target, target_json, body, body_hash, status, evidence_version,
                        created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)
                    """, [.text(id), .text(workId), .text(target), .text((preview["targetInfo"] ?? .null).serialized()),
                          .text(text), .text(hash), .text(DeliveryStatus.pending.rawValue),
                          .of(preview["evidenceVersion"]?.stringValue), .text(now), .text(now)])
                if target == "tapd" {
                    _ = try store.enqueueEffect(kind: "delivery.tapd", refId: id)
                }
                store.addActivity(workId: workId, runId: nil, kind: "delivery",
                                  title: target == "tapd" ? "确认 TAPD 回填（评论）" : "确认向原会话汇报",
                                  detail: "投递已排队", actor: "本机用户")
                store.setDraft(scope: "delivery:\(target)", key: workId, value: "")
            }
            guard let row = store.delivery(id: id) else { throw WorkError.failed("投递记录创建失败") }
            let result: JSONValue = .obj(["accepted": .bool(true), "delivery": WorkStore.deliveryJSON(row)])
            store.recordResult(requestId: requestId, method: "delivery.confirm", result: result)
            return result
        }
        queue.async { [self] in notify(.changed); runEffects() }
        return result
    }

    func updateDelivery(id: String, status: DeliveryStatus, remoteId: String? = nil, error: String? = nil) {
        guard let store else { return }
        _ = try? store.db.run("""
            UPDATE deliveries SET status = ?, remote_id = COALESCE(?, remote_id), error = ?,
                attempts = attempts + 1, updated_at = ? WHERE id = ?
            """, [.text(status.rawValue), .of(remoteId), .of(error), .text(WorkClock.iso()), .text(id)])
        if let row = store.delivery(id: id) {
            let label: String
            switch status {
            case .sent: label = "投递成功"
            case .failed: label = "投递失败"
            case .unknown: label = "投递结果未知，需核对"
            default: label = "投递状态更新"
            }
            store.addActivity(workId: row.text("work_id"), runId: nil, kind: "delivery", title: label,
                              detail: error ?? (remoteId.map { "远端记录 \($0)" } ?? ""))
        }
        notify(.changed)
    }

    /// 失败的投递由用户明确重试；结果未知的必须先核对（由适配器回读），不能直接重发。
    func deliveryRetry(id: String) throws -> JSONValue {
        let result: JSONValue = try write { store in
            guard let row = store.delivery(id: id) else { throw WorkError.notFound("找不到这条投递记录") }
            switch row.text("status") {
            case DeliveryStatus.failed.rawValue:
                try store.db.run("UPDATE deliveries SET status = 'pending', error = NULL, updated_at = ? WHERE id = ?",
                                 [.text(WorkClock.iso()), .text(id)])
                if row.text("target") == "tapd" { _ = try store.enqueueEffect(kind: "delivery.tapd", refId: id) }
                return .obj(["accepted": .bool(true)])
            case DeliveryStatus.unknown.rawValue:
                throw WorkError.rejected("上次发送的结果未知，直接重发可能造成重复。请先点「核对」确认远端是否已有这条内容。")
            default:
                return .obj(["accepted": .bool(false), "message": .string("这条投递不需要重试。")])
            }
        }
        queue.async { [self] in notify(.changed); runEffects() }
        return result
    }

    // MARK: 副作用执行（outbox）

    func registerEffect(_ kind: String, handler: @escaping @Sendable (WorkCore, DBRow) -> Void) {
        queue.async {
            self.effectHandlers[kind] = handler
            self.runEffects()
        }
    }

    /// 领取并执行到期的副作用。处理函数自己负责在完成后调 `finishEffect`。
    func runEffects() {
        guard let store, store.isOwner, !shuttingDown else { return }
        while let effect = store.leaseEffect(owner: instanceId) {
            guard let handler = effectHandlers[effect.text("kind")] else {
                // 处理方还没注册（适配器未就绪）：放回队列稍后再试。
                store.finishEffect(id: effect.text("id"), status: "pending", error: "handler not ready", retryAfter: 15)
                continue
            }
            handler(self, effect)
        }
        if !effectTimerArmed {
            effectTimerArmed = true
            queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self else { return }
                self.effectTimerArmed = false
                self.runEffects()
            }
        }
    }

    func finishEffect(id: String, status: String, error: String? = nil, retryAfter: TimeInterval? = nil) {
        queue.async {
            self.store?.finishEffect(id: id, status: status, error: error, retryAfter: retryAfter)
        }
    }

    // MARK: 导出

    /// 导出任务卡 / 执行记录（Markdown 草稿）。数据库仍是状态正本，导出不改变 Work。
    func exportMarkdown(workId: String, kind: String) throws -> JSONValue {
        let state = (try? reviewState(workId: workId)) ?? .null
        return try read { store in
            guard let work = store.work(id: workId) else { throw WorkError.notFound("找不到这个 Work") }
            let project = store.project(id: work.projectId)
            let runs = store.runs(workId: workId)
            let evidence = store.evidence(workId: workId)
            let attentions = store.attentions(workId: workId)
            let deliveries = store.deliveries(workId: workId)

            // 任务卡状态只有 active / paused / done：等待类状态仍是 active，由卡内任务标 blocked 并写明等待对象。
            let cardStatus: String
            switch work.status {
            case .completed: cardStatus = "done"
            case .cancelled: cardStatus = "paused"
            default: cardStatus = "active"
            }
            let taskState: String
            switch work.status {
            case .queued: taskState = "todo"
            case .running: taskState = "doing"
            case .waitingUser: taskState = "blocked（等待用户回答）"
            case .waitingReview: taskState = "blocked（等待审阅）"
            case .failed: taskState = "blocked（上一轮失败）"
            case .interrupted: taskState = "blocked（上一轮中断，结果未知）"
            case .completed: taskState = "done"
            case .cancelled: taskState = "blocked（已取消）"
            }

            var md: [String] = []
            md.append("# \(work.displayId) \(work.title)")
            md.append("")
            md.append("- 任务卡状态：\(cardStatus)")
            md.append("- 应用内状态：\(work.status.rawValue)（\(work.status.label)）" + (work.statusReason.map { " — \($0)" } ?? ""))
            md.append("- 项目：\(project?.name ?? "—")（\(project?.path ?? "—")）")
            md.append("- 来源：\(work.origin.rawValue)")
            for ref in store.tapdRefs(workId: workId) {
                md.append("- TAPD：\(ref.text("entity_type")) #\(ref.text("entity_id"))（workspace \(ref.text("workspace_id"))）\(ref.text("title"))")
            }
            md.append("- 执行目录：\(work.workspacePath ?? "尚未准备")" + (work.branch.map { "（分支 \($0)）" } ?? ""))
            md.append("- 基线提交：\(work.baseCommit ?? "—")")
            md.append("- Work ID：\(work.id)")
            md.append("- 导出时间：\(WorkClock.iso())")
            md.append("")
            md.append("## 目标")
            md.append(work.objective)
            if !work.scope.isEmpty { md.append(""); md.append("## 范围"); md.append(work.scope) }
            md.append("")
            md.append("## 任务")
            md.append("- [\(work.status == .completed ? "x" : " ")] \(work.title) — \(taskState)")

            if kind == "record" {
                md.append("")
                md.append("## 执行轮次")
                for run in runs {
                    md.append("- 第 \(run.attempt) 轮：\(run.status.rawValue)"
                        + (run.startedAt.map { "，开始 \($0)" } ?? "") + (run.endedAt.map { "，结束 \($0)" } ?? "")
                        + (run.exitCode.map { "，退出码 \($0)" } ?? "")
                        + (run.reviewedTree.map { "，审阅版本 tree \($0.prefix(12))" } ?? ""))
                    if let error = run.error { md.append("  - \(error.replacingOccurrences(of: "\n", with: " "))") }
                }
                md.append("")
                md.append("## 已定决策")
                let answered = attentions.filter { $0.status == .answered && $0.kind == .question }
                if answered.isEmpty { md.append("- 无") }
                for attention in answered {
                    let answers = attention.answer?["answers"]?.objectValue ?? [:]
                    for (question, value) in answers.sorted(by: { $0.key < $1.key }) {
                        md.append("- \(question) → \(value.stringValue ?? "")")
                    }
                }
                md.append("")
                md.append("## 变更范围")
                if state["isRepository"]?.boolValue == true {
                    md.append("当前 tree \(state["tree"]?.stringValue ?? "—")，HEAD \(state["head"]?.stringValue ?? "—")；\(state["files"]?.arrayValue?.count ?? 0) 个文件，+\(state["added"]?.intValue ?? 0) / −\(state["deleted"]?.intValue ?? 0)。")
                    for file in (state["files"]?.arrayValue ?? []).prefix(200) {
                        md.append("- \(file["status"]?.stringValue ?? "M") \(file["path"]?.stringValue ?? "")")
                    }
                } else {
                    md.append("执行目录不是 Git 仓库或尚未准备，未记录差异。")
                }
                md.append("")
                md.append("## 实际验证")
                let checks = evidence.filter { $0["kind"]?.stringValue == "check" }
                if checks.isEmpty { md.append("- 未运行（应用内没有验证命令的执行记录）") }
                for check in checks {
                    let detail = check["detail"]
                    md.append("- `\(detail?["command"]?.stringValue ?? "")`：\(detail?["state"]?.stringValue ?? "unknown")"
                        + (detail?["exitCode"]?.intValue.map { "，退出码 \($0)" } ?? "")
                        + "，代码版本 tree \((check["tree"]?.stringValue ?? "—").prefix(12))"
                        + "，\(detail?["startedAt"]?.stringValue ?? "") → \(detail?["endedAt"]?.stringValue ?? "")")
                }
                md.append("")
                md.append("## 交付状态")
                md.append("- 审阅：" + (evidence.contains { $0["kind"]?.stringValue == "review" } ? "已通过" : "未通过 / 未进行"))
                md.append("- 业务验收、发布、上线：不由本记录推断")
                if deliveries.isEmpty { md.append("- 来源投递：未请求") }
                for delivery in deliveries {
                    md.append("- 投递到 \(delivery.text("target"))：\(delivery.text("status"))"
                        + (delivery.string("error").map { "（\($0)）" } ?? ""))
                }
                if let summary = evidence.last(where: { $0["kind"]?.stringValue == "result" })?["detail"]?["text"]?.text {
                    md.append("")
                    md.append("## 执行结果摘要")
                    md.append(summary)
                }
            }
            let text = WorkText.redact(md.joined(separator: "\n")) + "\n"
            let name = "\(work.displayId)-\(kind == "record" ? "执行记录" : "任务卡").md"
            return .obj(["markdown": .string(text), "fileName": .string(name)])
        }
    }
}
