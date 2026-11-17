import Foundation

/// TAPD 适配器：通过本机的 `tapd-cli`（TAPD OpenAPI CLI）读取待办与详情、受控地添加评论。
///
/// - 连接是独立配置：CLI 路径 + 登录 shell 里的 `TAPD_API_ENDPOINT` / `TAPD_TOKEN`。令牌只随子进程环境传递，
///   不写日志、不落盘、不进入返回值。
/// - 读取可以重试（限流退避、超时重试）；写入不自动重试，结果不明确时先回读核对。
/// - 只读写 TAPD 自己的字段；Work 的执行状态不会被写成业务状态。
/// 返回结构取自 2026-11-16 对 tapd-cli 的只读实测：`{"status":1,"data":[{"Story":{…}}],"info":"success"}`。
/// 全部是同步调用，只能在后台线程用。
enum TapdAdapter {
    struct Failure: Error, Sendable {
        var message: String
        var detail: String?
        var timedOut = false
        var workError: WorkError { .unavailable(message, detail: detail) }
    }

    // MARK: 配置

    static func settings(_ core: WorkCore) -> JSONValue {
        core.getSetting("tapd") ?? .obj(["enabled": .bool(false), "cliPath": .string(""), "workspaces": .array([]),
                                         "syncOnLaunch": .bool(true)])
    }

    static func locateCLI(custom: String?) -> String? {
        if let custom, !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return LoginEnv.shared.find("tapd-cli", extra: ["\(NSHomeDirectory())/.local/bin/tapd-cli"])
    }

    /// 连接所需条件是否齐备（只报告有 / 无，不回显任何凭据内容）。
    static func prerequisites(custom: String?) -> JSONValue {
        let env = LoginEnv.shared.environment
        return .obj([
            "cli": .str(locateCLI(custom: custom)),
            "endpointSet": .bool(!(env["TAPD_API_ENDPOINT"] ?? "").isEmpty),
            "tokenSet": .bool(!(env["TAPD_TOKEN"] ?? "").isEmpty),
        ])
    }

    // MARK: 调用

    private static func run(_ args: [String], cli: String, timeout: TimeInterval = 40, retry: Bool = true) throws -> JSONValue {
        var env = LoginEnv.shared.environment
        env["TAPD_CLI_LOG"] = "silent"
        var attempt = 0
        while true {
            attempt += 1
            let result = Proc.run(cli, args, env: env, timeout: timeout)
            if let launch = result.launchError { throw Failure(message: "无法运行 tapd-cli", detail: launch) }
            if result.timedOut {
                if retry, attempt < 2 { continue }
                throw Failure(message: "TAPD 请求超时", detail: nil, timedOut: true)
            }
            let text = WorkText.redact(result.stdout + result.stderr)
            let limited = text.contains("429") || text.lowercased().contains("rate limit") || text.contains("频率")
            if limited, retry, attempt < 4 {
                Thread.sleep(forTimeInterval: pow(2, Double(attempt - 1)))   // 限流：1s、2s、4s 退避
                continue
            }
            guard let json = JSONValue.parse(result.stdout) else {
                throw Failure(message: result.exitCode == 0 ? "TAPD 返回了无法解析的内容" : "TAPD 请求失败",
                              detail: String(text.suffix(600)))
            }
            guard json["status"]?.intValue == 1 else {
                throw Failure(message: "TAPD 拒绝了请求", detail: json["info"]?.stringValue ?? String(text.suffix(400)))
            }
            return json["data"] ?? .null
        }
    }

    private static func requireCLI(_ core: WorkCore) throws -> String {
        let config = settings(core)
        guard let cli = locateCLI(custom: config["cliPath"]?.text) else {
            throw Failure(message: "找不到 tapd-cli", detail: "请安装 tapd-cli，或在 TAPD 连接设置里填写它的路径。")
        }
        let env = LoginEnv.shared.environment
        guard !(env["TAPD_API_ENDPOINT"] ?? "").isEmpty, !(env["TAPD_TOKEN"] ?? "").isEmpty else {
            throw Failure(message: "登录 shell 里没有 TAPD 连接所需的环境变量",
                          detail: "需要 TAPD_API_ENDPOINT 与 TAPD_TOKEN（在 shell 配置中设置后重启应用）。")
        }
        return cli
    }

    private static func unwrap(_ items: JSONValue, _ key: String) -> [JSONValue] {
        (items.arrayValue ?? []).compactMap { $0[key] }
    }

    // MARK: 身份与项目

    struct Identity: Sendable {
        var nick: String
        var name: String
        var companyId: String
    }

    static func whoami(_ core: WorkCore) throws -> Identity {
        let data = try run(["user", "info"], cli: try requireCLI(core))
        guard let nick = data["nick"]?.text else { throw Failure(message: "TAPD 没有返回当前用户") }
        let company = data["current_company_id"].map { $0.stringValue ?? String($0.intValue ?? 0) } ?? ""
        return Identity(nick: nick, name: data["name"]?.text ?? nick, companyId: company)
    }

    /// 当前用户参与的 TAPD 项目（workspace）。
    static func workspaces(_ core: WorkCore) throws -> [JSONValue] {
        let me = try whoami(core)
        let data = try run(["user", "participant-projects", "nick=\(me.nick)", "company_id=\(me.companyId)"],
                           cli: try requireCLI(core))
        return unwrap(data, "Workspace").compactMap { item in
            guard let id = item["id"]?.text else { return nil }
            return .obj(["id": .string(id), "name": .string(item["name"]?.text ?? id),
                         "closed": .bool(item["status"]?.stringValue == "closed")])
        }
    }

    // MARK: 待办

    private static func summary(_ item: JSONValue, type: String, workspaceName: String?) -> JSONValue? {
        guard let id = item["id"]?.text else { return nil }
        let workspaceId = item["workspace_id"]?.text ?? ""
        let short = id.count > 7 ? String(Int(id.suffix(7)) ?? 0) : id
        let isBug = type == "bug"
        let iteration = item["iteration_id"]?.text
        var out: [String: JSONValue] = [:]
        out["ref"] = TapdRef(workspaceId: workspaceId, entityType: type, entityId: id).json
        out["shortId"] = .string(short)
        out["type"] = .string(type)
        out["title"] = .string(item[isBug ? "title" : "name"]?.text ?? "（无标题）")
        out["status"] = .str(item["v_status"]?.text ?? item["status"]?.text)
        out["rawStatus"] = .str(item["status"]?.text)
        out["priority"] = .str(item["priority_label"]?.text ?? item["priority"]?.text)
        out["severity"] = .str(item["severity"]?.text)
        out["owner"] = .str(item[isBug ? "current_owner" : "owner"]?.text)
        out["iterationId"] = .str(iteration == "0" ? nil : iteration)
        out["begin"] = .str(item["begin"]?.text)
        out["due"] = .str(item["due"]?.text ?? item["deadline"]?.text)
        out["modified"] = .str(item["modified"]?.text)
        out["workspaceName"] = .str(workspaceName)
        return .object(out)
    }

    static let pageSize = 50

    /// 分配给当前用户的需求与缺陷（「我的待办」，不是项目的全部需求）。按 workspace 分页读取。
    /// `query` 全是数字时按编号精确查；否则由界面在已读取的条目里按标题筛选。
    static func todos(_ core: WorkCore, workspaceIds: [String], page: Int, query: String?) throws -> JSONValue {
        let cli = try requireCLI(core)
        let me = try whoami(core)
        let names = Dictionary(uniqueKeysWithValues: (settings(core)["workspaces"]?.arrayValue ?? []).compactMap { item -> (String, String)? in
            guard let id = item["id"]?.text else { return nil }
            return (id, item["name"]?.text ?? id)
        })
        var items: [JSONValue] = []
        var hasMore = false
        var errors: [JSONValue] = []
        let idQuery = query.flatMap { q -> String? in
            let trimmed = q.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber) ? trimmed : nil
        }
        for workspace in workspaceIds {
            do {
                var storyArgs = ["story", "list", "workspaceid=\(workspace)", "with_v_status=1",
                                 "limit=\(pageSize)", "page=\(page)", "order=modified desc"]
                var bugArgs = ["bug", "list", "workspaceid=\(workspace)", "limit=\(pageSize)", "page=\(page)",
                               "order=modified desc"]
                if let idQuery {
                    storyArgs.append("id=\(idQuery)")
                    bugArgs.append("id=\(idQuery)")
                } else {
                    storyArgs.append("owner=\(me.nick)")
                    bugArgs.append("current_owner=\(me.nick)")
                }
                let stories = unwrap(try run(storyArgs, cli: cli), "Story")
                let bugs = unwrap(try run(bugArgs, cli: cli), "Bug")
                if stories.count == pageSize || bugs.count == pageSize { hasMore = true }
                items += stories.compactMap { summary($0, type: "story", workspaceName: names[workspace]) }
                items += bugs.compactMap { summary($0, type: "bug", workspaceName: names[workspace]) }
            } catch let failure as Failure {
                errors.append(.obj(["workspaceId": .string(workspace), "message": .string(failure.message),
                                    "detail": .str(failure.detail)]))
            }
        }
        // 按完整身份去重：分页边界上的重复不会出现两次。
        var seen = Set<String>()
        items = items.filter { item in
            let key = item["ref"]?.serialized() ?? UUID().uuidString
            return seen.insert(key).inserted
        }
        items.sort { ($0["modified"]?.stringValue ?? "") > ($1["modified"]?.stringValue ?? "") }
        return .obj(["items": .array(items), "page": .int(page), "hasMore": .bool(hasMore),
                     "user": .obj(["nick": .string(me.nick), "name": .string(me.name)]),
                     "errors": .array(errors), "fetchedAt": .string(WorkClock.iso()),
                     "byId": .bool(idQuery != nil)])
    }

    // MARK: 详情

    static func htmlToText(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [("(?i)<br\\s*/?>", "\n"), ("(?i)</(p|div|li|tr|h[1-6])>", "\n"),
                                       ("(?i)<li[^>]*>", "- "), ("(?is)<(script|style)[^>]*>.*?</\\1>", ""),
                                       ("(?i)<img[^>]*>", "［图片］"), ("<[^>]+>", "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func entryType(_ entityType: String) -> String {
        switch entityType {
        case "bug": return "bug"
        case "task": return "tasks"
        default: return "stories"
        }
    }

    /// 读取一个 TAPD 对象的完整详情。附件与评论各自带读取状态：读不到就标明原因，不假装已读。
    static func detail(_ core: WorkCore, ref: TapdRef) throws -> JSONValue {
        let cli = try requireCLI(core)
        let entity: String, wrapper: String
        switch ref.entityType {
        case "bug": entity = "bug"; wrapper = "Bug"
        case "task": entity = "task"; wrapper = "Task"
        default: entity = "story"; wrapper = "Story"
        }
        var args = [entity, "list", "workspaceid=\(ref.workspaceId)", "id=\(ref.entityId)", "limit=1"]
        if entity == "story" { args.append("with_v_status=1") }
        guard let item = unwrap(try run(args, cli: cli), wrapper).first, item["id"]?.text == ref.entityId else {
            throw Failure(message: "TAPD 里找不到这个对象，或当前账号没有权限读取")
        }
        let descriptionHTML = item["description"]?.stringValue ?? ""
        let descriptionText = htmlToText(descriptionHTML)
        let title = item[entity == "bug" ? "title" : "name"]?.text ?? ""
        let modified = item["modified"]?.text
        let status = item["v_status"]?.text ?? item["status"]?.text
        let imageCount = descriptionHTML.components(separatedBy: "<img").count - 1

        var iteration: JSONValue = .null
        if let iterationId = item["iteration_id"]?.text, iterationId != "0" {
            if let found = try? unwrap(run(["iteration", "list", "workspaceid=\(ref.workspaceId)", "id=\(iterationId)"], cli: cli),
                                       "Iteration").first {
                iteration = .obj(["id": .string(iterationId), "name": .str(found["name"]?.text),
                                  "begin": .str(found["startdate"]?.text), "end": .str(found["enddate"]?.text)])
            } else {
                iteration = .obj(["id": .string(iterationId), "name": .null])
            }
        }

        var attachments: JSONValue
        do {
            let list = unwrap(try run(["attachment", "list", "workspaceid=\(ref.workspaceId)", "entry-id=\(ref.entityId)", "limit=50"],
                                      cli: cli), "Attachment")
            attachments = .obj(["state": .string("listed"), "items": .array(list.map { file in
                .obj(["id": .str(file["id"]?.text), "name": .str(file["filename"]?.text),
                      "type": .str(file["content_type"]?.text), "owner": .str(file["owner"]?.text),
                      "created": .str(file["created"]?.text),
                      // 只读到了附件清单；内容没有下载，也没有交给执行器。
                      "content": .string("not_read")])
            })])
        } catch let failure as Failure {
            attachments = .obj(["state": .string("failed"), "message": .string(failure.message), "detail": .str(failure.detail),
                                "items": .array([])])
        }

        var comments: JSONValue
        do {
            let list = unwrap(try run(["comment", "list", "workspaceid=\(ref.workspaceId)",
                                       "entry-type=\(entryType(ref.entityType))", "entry-id=\(ref.entityId)", "limit=30"],
                                      cli: cli), "Comment")
            comments = .obj(["state": .string("listed"), "items": .array(list.map { comment in
                .obj(["id": .str(comment["id"]?.text), "author": .str(comment["author"]?.text),
                      "created": .str(comment["created"]?.text),
                      "text": .string(WorkText.clip(htmlToText(comment["description"]?.stringValue ?? ""), limit: 4000))])
            })])
        } catch let failure as Failure {
            comments = .obj(["state": .string("failed"), "message": .string(failure.message), "items": .array([])])
        }

        let hash = WorkText.sha256([title, descriptionHTML, status ?? "", modified ?? ""].joined(separator: "\u{1f}"))
        let existing = (try? core.read { store in store.works(tapdRef: ref).map { work in
            JSONValue.obj(["id": .string(work.id), "displayId": .string(work.displayId), "title": .string(work.title),
                           "status": .string(work.status.rawValue), "statusLabel": .string(work.status.label)])
        } }) ?? []
        let isBug = entity == "bug"
        var out: [String: JSONValue] = [:]
        out["ref"] = ref.json
        out["type"] = .string(ref.entityType)
        out["title"] = .string(title)
        out["status"] = .str(status)
        out["rawStatus"] = .str(item["status"]?.text)
        out["priority"] = .str(item["priority_label"]?.text ?? item["priority"]?.text)
        out["severity"] = .str(item["severity"]?.text)
        out["owner"] = .str(item[isBug ? "current_owner" : "owner"]?.text)
        out["creator"] = .str(item[isBug ? "reporter" : "creator"]?.text)
        out["begin"] = .str(item["begin"]?.text)
        out["due"] = .str(item["due"]?.text ?? item["deadline"]?.text)
        out["created"] = .str(item["created"]?.text)
        out["modified"] = .str(modified)
        out["iteration"] = iteration
        out["descriptionText"] = .string(descriptionText)
        out["imageCount"] = .int(max(imageCount, 0))
        out["attachments"] = attachments
        out["comments"] = comments
        out["snapshotHash"] = .string(hash)
        out["existingWorks"] = .array(existing)
        out["fetchedAt"] = .string(WorkClock.iso())
        return .object(out)
    }

    // MARK: 评论写入（只在用户确认后由 outbox 调用）

    /// 添加一条评论。不重试：失败或超时都交回调用方，由调用方决定核对还是重发。
    static func addComment(_ core: WorkCore, ref: TapdRef, body: String) throws -> String? {
        let data = try run(["comment", "add", "workspaceid=\(ref.workspaceId)", "entry-type=\(entryType(ref.entityType))",
                            "entry-id=\(ref.entityId)", "description=\(body)"],
                           cli: try requireCLI(core), timeout: 45, retry: false)
        return data["Comment"]?["id"]?.text ?? data["id"]?.text
    }

    /// 回读：这条正文是否已经在目标对象的评论里（用于写入后的确认，以及结果未知时的核对）。
    static func findComment(_ core: WorkCore, ref: TapdRef, body: String) throws -> String? {
        let list = unwrap(try run(["comment", "list", "workspaceid=\(ref.workspaceId)",
                                   "entry-type=\(entryType(ref.entityType))", "entry-id=\(ref.entityId)", "limit=50"],
                                  cli: try requireCLI(core)), "Comment")
        func normalize(_ text: String) -> String {
            String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) })
        }
        let needle = String(normalize(body).prefix(80))
        guard needle.count >= 8 else { return nil }
        return list.first { normalize(htmlToText($0["description"]?.stringValue ?? "")).contains(needle) }?["id"]?.text
    }

    // MARK: outbox 处理

    /// 注册 TAPD 评论投递。成功必须有回读确认；超时记为 unknown，等用户核对，不自动重发。
    static func registerEffects(_ core: WorkCore) {
        core.registerEffect("delivery.tapd") { core, effect in
            let effectId = effect.text("id")
            let deliveryId = effect.text("ref_id")
            core.worker.async {
                guard let row = (try? core.read { $0.delivery(id: deliveryId) }) ?? nil,
                      let ref = TapdRef(json: row.json("target_json")) else {
                    core.finishEffect(id: effectId, status: "failed", error: "投递记录或目标不完整")
                    return
                }
                guard row.text("status") == DeliveryStatus.pending.rawValue else {
                    core.finishEffect(id: effectId, status: "done")
                    return
                }
                let body = row.text("body")
                do {
                    let remote = try addComment(core, ref: ref, body: body)
                    // 写入后回读一次；回读失败不改写入结论，只是没有确认到。
                    let confirmed = (try? findComment(core, ref: ref, body: body)) ?? nil
                    core.queue.async {
                        if confirmed != nil || remote != nil {
                            core.updateDelivery(id: deliveryId, status: .sent, remoteId: confirmed ?? remote)
                        } else {
                            core.updateDelivery(id: deliveryId, status: .unknown, error: "TAPD 接受了请求，但回读没有找到这条评论，请核对。")
                        }
                    }
                    core.finishEffect(id: effectId, status: "done")
                } catch let failure as Failure {
                    core.queue.async {
                        core.updateDelivery(id: deliveryId, status: failure.timedOut ? .unknown : .failed,
                                            error: failure.timedOut ? "发送超时，TAPD 端是否已写入未知。请先核对，不要直接重发。"
                                                : [failure.message, failure.detail].compactMap { $0 }.joined(separator: "："))
                    }
                    core.finishEffect(id: effectId, status: failure.timedOut ? "done" : "failed", error: failure.message)
                } catch {
                    core.queue.async { core.updateDelivery(id: deliveryId, status: .failed, error: "\(error)") }
                    core.finishEffect(id: effectId, status: "failed", error: "\(error)")
                }
            }
        }
    }

    /// 结果未知的投递：回读目标对象的评论来判定。找到 → 已发送；没找到 → 未写入，允许重试。
    static func verify(_ core: WorkCore, deliveryId: String) throws -> JSONValue {
        guard let row = try core.read({ $0.delivery(id: deliveryId) }), row.text("target") == "tapd",
              let ref = TapdRef(json: row.json("target_json")) else {
            throw WorkError.notFound("找不到这条 TAPD 投递记录")
        }
        do {
            let found = try findComment(core, ref: ref, body: row.text("body"))
            core.queue.sync {
                if let found {
                    core.updateDelivery(id: deliveryId, status: .sent, remoteId: found)
                } else {
                    core.updateDelivery(id: deliveryId, status: .failed, error: "已核对：TAPD 上没有这条评论，可以重试。")
                }
            }
            return .obj(["found": .bool(found != nil), "remoteId": .str(found)])
        } catch let failure as Failure {
            throw failure.workError
        }
    }
}
