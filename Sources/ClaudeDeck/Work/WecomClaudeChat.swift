import Foundation

/// 企业微信直接对话：每个「企业 / Bot / 私聊或群聊 / 会话 / 发送人 / 项目」各自持有一个 CLI 会话（隔离续聊）。
///
/// - 首轮创建绑定并记下引擎、工作目录与原始会话 ID；之后按原引擎、原 ID 续接。机器人默认 CLI 只影响新绑定。
/// - 同一绑定串行处理，跨绑定互不影响；入站消息按消息 ID 去重，重放返回原回执。
/// - 工具权限与 AskUserQuestion 回到原会话等本人回答；单选问题同时推送决策卡，也可回复编号。
/// 状态只在 queue 上访问。
final class WecomClaudeChat: @unchecked Sendable {
    typealias Reply = @Sendable (String, Bool) -> Void
    typealias CardSender = @Sendable (JSONValue) -> Void

    struct Binding: Sendable {
        var key: String
        /// 旧版（企业/会话/发送人）记录：只在新键没有记录时读取，归属可核实才沿用。
        var legacyKey: String?
        var engine: AgentProvider
        var cwd: String
        var projectsPrompt: String
        var actorId: String
        /// 决策卡允许的操作者（发起人 + 拍板人）。
        var deciders: [String]
        var botLocalId: String
        var chatId: String
        var meta: JSONValue
    }

    private struct Message {
        let id: String
        let text: String
        let reply: Reply
    }

    private struct Attention {
        let id: String
        let tool: String
        let input: JSONValue
        var cardTaskId: String?
    }

    private final class Conversation: @unchecked Sendable {
        let binding: Binding
        var sessionId: String
        let cwd: String
        let engine: AgentProvider
        var resume: Bool
        var process: (any AgentExecutorProcess)?
        var ready = false
        var pending: [Message] = []
        var active: Message?
        var text = ""
        var lastUpdate = Date.distantPast
        var attention: Attention?
        var receipts: [String: String]
        var watchdog: DispatchWorkItem?
        var card: CardSender?

        var key: String { binding.key }

        init(binding: Binding, saved: JSONValue?) {
            self.binding = binding
            engine = saved?["engine"]?.text.flatMap(AgentProvider.init(rawValue:)) ?? binding.engine
            sessionId = saved?["sessionId"]?.text ?? (engine == .claude ? UUID().uuidString.lowercased() : "")
            cwd = saved?["cwd"]?.text ?? binding.cwd
            resume = saved?["resume"]?.boolValue ?? false
            receipts = (saved?["receipts"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        }
    }

    private let queue = DispatchQueue(label: "claude-picker.wecom-claude")
    private var conversations: [String: Conversation] = [:]

    func send(core: WorkCore, binding: Binding, messageId: String, text: String,
              reply: @escaping Reply, card: CardSender? = nil) {
        queue.async {
            guard (try? core.read { $0.isOwner }) == true else {
                reply("当前应用实例没有取得会话数据的管理权，请在主实例中连接机器人。", true)
                return
            }
            let conversation: Conversation
            if let existing = self.conversations[binding.key] {
                conversation = existing
            } else {
                do { try FileManager.default.createDirectory(atPath: binding.cwd, withIntermediateDirectories: true) }
                catch { reply("无法准备会话目录：\(error.localizedDescription)", true); return }
                let saved = core.getSetting(binding.key) ?? binding.legacyKey.flatMap { core.getSetting($0) }
                conversation = Conversation(binding: binding, saved: saved)
                self.conversations[binding.key] = conversation
            }
            conversation.card = card ?? conversation.card
            if let receipt = conversation.receipts[messageId] { reply(receipt, true); return }
            if conversation.active?.id == messageId || conversation.pending.contains(where: { $0.id == messageId }) {
                reply("这条消息正在处理中，请等待回复。", true)
                return
            }
            let message = Message(id: messageId, text: text, reply: reply)
            if let attention = conversation.attention {
                self.answer(attention, message: message, conversation: conversation, core: core, preResolved: nil)
                return
            }
            conversation.pending.append(message)
            self.advance(conversation, core: core)
        }
    }

    /// 决策卡回调已原子记下选择：把答案交回原绑定等待中的问题。
    func answerCard(core: WorkCore, record: JSONValue, choice: String, reply: @escaping Reply) {
        queue.async {
            guard let key = record["bindingKey"]?.text, let conversation = self.conversations[key],
                  let attention = conversation.attention, attention.cardTaskId == record["taskId"]?.text else {
                reply("这个问题已经结束，选择已记录。", true)
                return
            }
            let label = WecomCards.label(record, key: choice)
            let message = Message(id: "card-\(record["taskId"]?.text ?? choice)", text: label, reply: reply)
            self.answer(attention, message: message, conversation: conversation, core: core, preResolved: label)
        }
    }

    private func advance(_ conversation: Conversation, core: WorkCore) {
        guard conversation.active == nil, conversation.attention == nil, !conversation.pending.isEmpty else { return }
        let engine = conversation.engine
        if conversation.process == nil {
            if !conversation.sessionId.isEmpty, SessionOwnership.shared.heldByTerminal(conversation.sessionId) {
                fail(conversation, core: core, text: "这个会话正在 Claude Picker 中打开，请先关闭对应会话后重试。")
                return
            }
            guard let executable = AgentExecutorFactory.executable(for: engine) else {
                fail(conversation, core: core, text: "找不到 \(engine.label)，请先在本机安装并登录。")
                return
            }
            let config = ExecutorConfig(provider: engine, executable: executable, cwd: conversation.cwd,
                                        sessionId: conversation.sessionId, resume: conversation.resume && !conversation.sessionId.isEmpty,
                                        permissionMode: engine == .claude ? "default" : nil, model: nil, effort: nil,
                                        environment: LoginEnv.shared.environment,
                                        systemPrompt: """
                                        你通过企业微信与用户持续对话。用中文自然回复，保留上下文。
                                        用户要求操作项目时直接使用工具完成，按用户要求验证结果。
                                        你只能操作以下已授权的项目及其真实目录。目标不明确时先询问用户。
                                        \(conversation.binding.projectsPrompt)
                                        工具权限和提问会由宿主转发到当前对话等待本人回答。
                                        """)
            guard let process = AgentExecutorFactory.make(config, onEvent: { [weak self, weak conversation] event in
                guard let self, let conversation else { return }
                self.queue.async { self.handle(event, conversation: conversation, core: core) }
            }) else {
                fail(conversation, core: core, text: "\(engine.label) 暂不支持企业微信直接对话。")
                return
            }
            conversation.process = process
            armWatchdog(conversation, core: core)
            do {
                try process.start()
                if !conversation.sessionId.isEmpty { SessionOwnership.shared.setExecutor(conversation.sessionId, held: true) }
            }
            catch { fail(conversation, core: core, text: "\(engine.label) 启动失败：\(error.localizedDescription)") }
            return
        }
        guard conversation.ready else { return }
        conversation.active = conversation.pending.removeFirst()
        conversation.text = ""
        armWatchdog(conversation, core: core)
        if conversation.process?.sendUserMessage(conversation.active!.text) != true {
            fail(conversation, core: core, text: "消息未能送达 \(engine.label)，请重试。")
        }
    }

    private func handle(_ event: ExecutorEvent, conversation: Conversation, core: WorkCore) {
        guard conversations[conversation.key] === conversation else { return }
        switch event {
        case .ready:
            conversation.ready = true
            advance(conversation, core: core)
        case .sessionInfo(let info):
            if let id = info["sessionId"]?.text, id != conversation.sessionId {
                // Codex / Antigravity 由 CLI 分配原始 ID：记下来，之后按原 ID 续接。
                conversation.sessionId = id
                SessionOwnership.shared.setExecutor(id, held: true)
            }
            conversation.resume = true
            save(conversation, core: core)
        case .delta(let text):
            conversation.text += text
            if Date().timeIntervalSince(conversation.lastUpdate) >= 2, !conversation.text.isEmpty {
                conversation.lastUpdate = Date()
                conversation.active?.reply(conversation.text, false)
            }
        case .assistantText(let text):
            // 完整文本与增量描述同一段输出，最终以 result 为准。
            if conversation.text.isEmpty { conversation.text = text }
        case let .permissionRequest(id, tool, input, _):
            var attention = Attention(id: id, tool: tool, input: input, cardTaskId: nil)
            let prompt: String
            if tool == "AskUserQuestion" {
                let questions = input["questions"]?.arrayValue ?? []
                prompt = questions.map { question in
                    let options = (question["options"]?.arrayValue ?? []).compactMap { $0["label"]?.text }
                    return (question["question"]?.text ?? "请补充说明")
                        + (options.isEmpty ? "" : "\n" + options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                }.joined(separator: "\n\n") + "\n直接回复答案或编号。多道问题可回复 JSON 对象，以问题原文为键。"
                // 单个单选问题：同时推送待拍板卡片，点击结果与文字回答走同一套校验。
                if questions.count == 1, let question = questions.first, question["multiSelect"]?.boolValue != true,
                   let send = conversation.card {
                    let options = (question["options"]?.arrayValue ?? []).compactMap { $0["label"]?.text }
                    if (2...6).contains(options.count), let record = try? WecomCards.create(
                        core, kind: "decision", botLocalId: conversation.binding.botLocalId,
                        chatId: conversation.binding.chatId, bindingKey: conversation.key,
                        title: question["header"]?.text ?? "待拍板", detail: question["question"]?.text ?? "",
                        options: options.enumerated().map { WecomCards.Option(key: "o\($0.offset + 1)", label: $0.element) },
                        allowed: conversation.binding.deciders) {
                        attention.cardTaskId = record["taskId"]?.text
                        send(record)
                    }
                }
            } else {
                prompt = "\(conversation.engine.label) 请求执行 \(tool)：\n\(WorkText.redact(String(input.serialized(pretty: true).prefix(3000))))\n回复“允许”或“拒绝”。"
            }
            conversation.attention = attention
            finish(conversation, core: core, text: prompt)
            conversation.watchdog?.cancel()
        case .turnResult(let result):
            let text = result["result"]?.text ?? conversation.text
            finish(conversation, core: core, text: text.isEmpty ? "\(conversation.engine.label) 本轮执行结束。" : text)
            advance(conversation, core: core)
        case .controlAck(_, let ok, let detail):
            if !ok { fail(conversation, core: core, text: "\(conversation.engine.label) 控制请求失败：\(detail.serialized())") }
        case .exited(let code, let stderr):
            fail(conversation, core: core, text: "\(conversation.engine.label) 会话已退出（\(code)）。\(WorkText.redact(String(stderr.suffix(400))))")
        default: break
        }
    }

    private func answer(_ attention: Attention, message: Message, conversation: Conversation, core: WorkCore,
                        preResolved: String?) {
        var input = attention.input.objectValue ?? [:]
        var allow = false
        if attention.tool == "AskUserQuestion" {
            let questions = input["questions"]?.arrayValue ?? []
            var answers = JSONValue.parse(message.text)?.objectValue ?? [:]
            if questions.count == 1, let question = questions.first?["question"]?.text {
                var value = preResolved ?? message.text
                if preResolved == nil, let taskId = attention.cardTaskId, let record = WecomCards.record(core, taskId: taskId),
                   let key = WecomCards.optionKey(forReply: message.text, record: record) {
                    // 文字回复编号或选项原文：与卡片点击共用同一条记录，先到先得。
                    switch WecomCards.resolve(core, taskId: taskId, key: key, actor: conversation.binding.actorId) {
                    case .accepted(let record, let choice): value = WecomCards.label(record, key: choice)
                    case .duplicate(let record): value = WecomCards.label(record, key: record["choice"]?.text ?? key)
                    case .rejected(let reason): message.reply(reason, true); return
                    }
                } else if preResolved == nil, let options = questions.first?["options"]?.arrayValue,
                          let index = Int(message.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                          index >= 1, index <= options.count, let label = options[index - 1]["label"]?.text {
                    value = label
                }
                answers[question] = .string(value)
            }
            guard !questions.isEmpty, questions.allSatisfy({ answers[$0["question"]?.text ?? ""]?.text != nil }) else {
                message.reply("请用 JSON 对象逐一回答，例如 {\"问题原文\":\"答案\"}。", true)
                return
            }
            input["answers"] = .object(answers)
            allow = true
        } else {
            let answer = message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["允许", "同意", "allow", "拒绝", "deny"].contains(answer) else {
                message.reply("\(conversation.engine.label) 正在等待操作确认，请回复“允许”或“拒绝”。", true)
                return
            }
            allow = ["允许", "同意", "allow"].contains(answer)
        }
        conversation.attention = nil
        conversation.active = message
        conversation.text = ""
        armWatchdog(conversation, core: core)
        if conversation.process?.respondPermission(requestId: attention.id, allow: allow,
                                                   updatedInput: .object(input), message: allow ? nil : "用户拒绝") != true {
            fail(conversation, core: core, text: "回答未能送达 \(conversation.engine.label)，请重试。")
        }
    }

    private func finish(_ conversation: Conversation, core: WorkCore, text: String) {
        conversation.watchdog?.cancel()
        guard let active = conversation.active else { return }
        conversation.receipts[active.id] = text
        if conversation.receipts.count > 100 { conversation.receipts = [active.id: text] }
        conversation.active = nil
        save(conversation, core: core)
        active.reply(text, true)
    }

    private func save(_ conversation: Conversation, core: WorkCore) {
        try? core.putSetting(conversation.key, .obj([
            "sessionId": .string(conversation.sessionId), "cwd": .string(conversation.cwd),
            "engine": .string(conversation.engine.rawValue), "resume": .bool(conversation.resume),
            "binding": conversation.binding.meta, "updatedAt": .string(WorkClock.iso()),
            "receipts": .object(conversation.receipts.mapValues(JSONValue.string)),
        ]))
    }

    private func fail(_ conversation: Conversation, core: WorkCore, text: String) {
        conversations.removeValue(forKey: conversation.key)
        conversation.active?.reply(text, true)
        conversation.active = nil
        conversation.watchdog?.cancel()
        if !conversation.sessionId.isEmpty { SessionOwnership.shared.setExecutor(conversation.sessionId, held: false) }
        for message in conversation.pending { message.reply(text, true) }
        conversation.pending.removeAll()
        conversation.process?.shutdown(grace: 0)
    }

    private func armWatchdog(_ conversation: Conversation, core: WorkCore) {
        conversation.watchdog?.cancel()
        let item = DispatchWorkItem { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            self.fail(conversation, core: core, text: "\(conversation.engine.label) 处理超时，请重试。")
        }
        conversation.watchdog = item
        queue.asyncAfter(deadline: .now() + 240, execute: item)
    }

    func stop() {
        queue.sync {
            for conversation in conversations.values {
                conversation.watchdog?.cancel()
                conversation.active?.reply("应用正在退出，会话已中断。", true)
                for message in conversation.pending { message.reply("应用正在退出，请稍后重试。", true) }
                _ = conversation.process?.terminateAndWait(timeout: 4)
                if !conversation.sessionId.isEmpty { SessionOwnership.shared.setExecutor(conversation.sessionId, held: false) }
            }
            conversations.removeAll()
        }
    }
}
