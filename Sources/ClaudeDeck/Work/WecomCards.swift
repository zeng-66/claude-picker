import Foundation

/// 企业微信决策卡（`button_interaction` 模板卡片）：任务确认与待拍板。
///
/// 协议取自官方 @wecom/aibot-node-sdk 1.0.7：卡片随 `aibot_send_msg`（msgtype `template_card`）推送；
/// 点击回调是 `aibot_event_callback`，`event.eventtype = template_card_event`，带 `event_key`、`task_id` 与 `from.userid`；
/// 5 秒内用该事件的 req_id 发 `aibot_respond_update_msg`（`response_type: update_template_card`）更新卡片。
///
/// 每张卡记录唯一 task_id、归属、允许操作者、选项、版本与有效期。回调重新校验身份、有效期与状态；
/// 首次有效选择原子写入，重复点击返回已处理回执，过期或无权时保留原状态并说明原因。
enum WecomCards {
    /// 有效期按类型区分：拍板卡 30 分钟（CLI 正在等答复），Work 确认卡 24 小时（Work 本身在等待启动）。
    static let ttl: TimeInterval = 30 * 60
    static let taskTTL: TimeInterval = 24 * 60 * 60
    static func ttl(kind: String) -> TimeInterval { kind == "task" ? taskTTL : ttl }
    private static let lock = NSLock()

    struct Option: Sendable, Equatable {
        var key: String
        var label: String
    }

    static func settingKey(_ taskId: String) -> String { "wecom.card.\(taskId)" }

    /// 新建卡片记录。`kind`：decision（待拍板，答案回到原会话）或 task（Work 确认）。
    static func create(_ core: WorkCore, kind: String, botLocalId: String, chatId: String, bindingKey: String,
                       title: String, detail: String, options: [Option], allowed: [String],
                       subject: JSONValue = .null, now: Date = Date()) throws -> JSONValue {
        let taskId = "cp\(Int(now.timeIntervalSince1970))\(UUID().uuidString.prefix(8).lowercased())"
        let record: JSONValue = .obj([
            "taskId": .string(taskId), "kind": .string(kind), "botLocalId": .string(botLocalId),
            "chatId": .string(chatId), "bindingKey": .string(bindingKey),
            "title": .string(title), "detail": .string(detail),
            "options": .array(options.map { .obj(["key": .string($0.key), "label": .string($0.label)]) }),
            "allowed": .array(allowed.map { .string($0) }),
            "subject": subject, "version": .int(1), "status": .string("open"),
            "createdAt": .number(now.timeIntervalSince1970),
            "expiresAt": .number(now.addingTimeInterval(ttl(kind: kind)).timeIntervalSince1970),
        ])
        try core.putSetting(settingKey(taskId), record)
        return record
    }

    static func record(_ core: WorkCore, taskId: String) -> JSONValue? { core.getSetting(settingKey(taskId)) }

    /// 卡片内容（按钮最多 6 个；已决定的卡片不再带按钮）。
    static func template(_ record: JSONValue) -> JSONValue {
        let open = record["status"]?.stringValue == "open"
        let options = record["options"]?.arrayValue ?? []
        var card: [String: JSONValue] = [
            "card_type": .string("button_interaction"),
            "main_title": .obj(["title": .string(String((record["title"]?.text ?? "需要你确认").prefix(26))),
                                "desc": .string(String((record["detail"]?.text ?? "").prefix(30)))]),
            "task_id": record["taskId"] ?? .null,
        ]
        if open {
            card["button_list"] = .array(options.prefix(6).enumerated().map { index, option in
                .obj(["text": .string(String((option["label"]?.text ?? "选项").prefix(10))),
                      "style": .int(index == 0 ? 1 : 2), "key": option["key"] ?? .string("opt\(index)")])
            })
        } else {
            let choice = options.first { $0["key"] == record["choice"] }?["label"]?.text ?? record["choice"]?.text ?? ""
            let text: String
            switch record["status"]?.stringValue {
            case "decided": text = "已选择：\(choice)"
            case "expired": text = "已过期，未作选择"
            default: text = "已关闭"
            }
            card["sub_title_text"] = .string(text)
            card["button_list"] = .array([.obj(["text": .string(String(text.prefix(10))), "style": .int(4),
                                                "key": .string("noop")])])
        }
        return .object(card)
    }

    /// 不支持卡片时的回退：带有效期的编号选项，同一套权限与去重。
    static func fallbackText(_ record: JSONValue) -> String {
        let options = (record["options"]?.arrayValue ?? []).enumerated().map { "\($0.offset + 1). \($0.element["label"]?.text ?? "")" }
        let seconds = ttl(kind: record["kind"]?.stringValue ?? "decision")
        let window = seconds >= 3600 ? "\(Int(seconds / 3600)) 小时" : "\(Int(seconds / 60)) 分钟"
        return "\(record["title"]?.text ?? "请选择")\n" + options.joined(separator: "\n") + "\n回复编号即可（\(window)内有效）。"
    }

    enum Outcome: Equatable {
        case accepted(record: JSONValue, choice: String)
        case duplicate(record: JSONValue)
        case rejected(String)
    }

    /// 处理一次点击或编号回复。只有首次有效选择生效；记录不存在、过期、无权、选项不对都不改状态。
    static func resolve(_ core: WorkCore, taskId: String, key: String, actor: String, now: Date = Date()) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        guard var record = record(core, taskId: taskId)?.objectValue else { return .rejected("这张卡片已失效") }
        let status = record["status"]?.stringValue ?? "open"
        if status == "decided" {
            return .duplicate(record: .object(record))
        }
        guard status == "open" else { return .rejected("这张卡片已关闭") }
        let allowed = (record["allowed"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !actor.isEmpty, allowed.isEmpty || allowed.contains(actor) else {
            return .rejected("只有发起人或拍板人可以在这张卡片上做决定")
        }
        if let expires = record["expiresAt"]?.doubleValue, now.timeIntervalSince1970 > expires {
            record["status"] = .string("expired")
            try? core.putSetting(settingKey(taskId), .object(record))
            return .rejected("这张卡片已过期，请在原会话重新发起")
        }
        let options = record["options"]?.arrayValue ?? []
        guard options.contains(where: { $0["key"]?.stringValue == key }) else { return .rejected("无效的选项") }
        record["status"] = .string("decided")
        record["choice"] = .string(key)
        record["decidedBy"] = .string(actor)
        record["decidedAt"] = .number(now.timeIntervalSince1970)
        record["version"] = .int((record["version"]?.intValue ?? 1) + 1)
        do { try core.putSetting(settingKey(taskId), .object(record)) } catch { return .rejected("记录决定失败，请重试") }
        return .accepted(record: .object(record), choice: key)
    }

    /// 编号回复 → 选项 key（1 起）。
    static func optionKey(forReply text: String, record: JSONValue) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = record["options"]?.arrayValue ?? []
        if let index = Int(trimmed), index >= 1, index <= options.count { return options[index - 1]["key"]?.stringValue }
        return options.first { $0["label"]?.stringValue == trimmed }?["key"]?.stringValue
    }

    static func label(_ record: JSONValue, key: String) -> String {
        (record["options"]?.arrayValue ?? []).first { $0["key"]?.stringValue == key }?["label"]?.text ?? key
    }
}
