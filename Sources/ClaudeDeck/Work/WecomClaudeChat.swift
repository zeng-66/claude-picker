import Foundation

/// 每个机器人、对话、发送人各自持有一个 Claude 会话，状态只在 queue 上访问。
final class WecomClaudeChat: @unchecked Sendable {
    typealias Reply = @Sendable (String, Bool) -> Void

    private struct Message {
        let id: String
        let text: String
        let reply: Reply
    }

    private final class Conversation: @unchecked Sendable {
        let key: String
        let sessionId: String
        let cwd: String
        var resume: Bool
        var process: ClaudeProcess?
        var ready = false
        var pending: [Message] = []
        var active: Message?
        var text = ""
        var lastUpdate = Date.distantPast
        var attention: (id: String, tool: String, input: JSONValue)?
        var receipts: [String: String]
        var watchdog: DispatchWorkItem?

        init(key: String, saved: JSONValue?, cwd: String) {
            self.key = key
            sessionId = saved?["sessionId"]?.text ?? UUID().uuidString.lowercased()
            self.cwd = saved?["cwd"]?.text ?? cwd
            resume = saved?["resume"]?.boolValue ?? false
            receipts = (saved?["receipts"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        }
    }

    private let queue = DispatchQueue(label: "claude-picker.wecom-claude")
    private var conversations: [String: Conversation] = [:]

    func send(core: WorkCore, source: SourceGateway.Source, text: String, reply: @escaping Reply) {
        queue.async {
            guard (try? core.read { $0.isOwner }) == true else {
                reply("当前应用实例没有取得会话数据的管理权，请在主实例中连接机器人。", true)
                return
            }
            let key = "wecom.claude." + WorkText.sha256([source.accountId, source.conversationId, source.actorId].joined(separator: "\n"))
            let conversation: Conversation
            if let existing = self.conversations[key] {
                conversation = existing
            } else {
                let root = AppDataDir.url.appendingPathComponent("wecom-chats", isDirectory: true)
                do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
                catch { reply("无法准备 Claude 会话目录：\(error.localizedDescription)", true); return }
                conversation = Conversation(key: key, saved: core.getSetting(key), cwd: root.path)
                self.conversations[key] = conversation
            }
            if let receipt = conversation.receipts[source.messageId] { reply(receipt, true); return }
            if conversation.active?.id == source.messageId || conversation.pending.contains(where: { $0.id == source.messageId }) {
                reply("这条消息正在处理中，请等待 Claude 回复。", true)
                return
            }
            let message = Message(id: source.messageId, text: text, reply: reply)
            if let attention = conversation.attention {
                self.answer(attention, message: message, conversation: conversation, core: core)
                return
            }
            conversation.pending.append(message)
            self.advance(conversation, core: core)
        }
    }

    private func advance(_ conversation: Conversation, core: WorkCore) {
        guard conversation.active == nil, conversation.attention == nil, !conversation.pending.isEmpty else { return }
        if conversation.process == nil {
            guard !SessionOwnership.shared.heldByTerminal(conversation.sessionId) else {
                fail(conversation, core: core, text: "这个 Claude 会话正在应用中使用，请先关闭对应会话后重试。")
                return
            }
            guard let executable = ClaudeLocator.find() else {
                fail(conversation, core: core, text: "找不到 Claude CLI，请先在本机安装并登录 Claude。")
                return
            }
            let projects = (try? core.read { store in
                store.projects().filter(\.available).map { "\($0.name) → \($0.path)" }.joined(separator: "\n")
            }) ?? ""
            let config = ExecutorConfig(executable: executable, cwd: conversation.cwd,
                                        sessionId: conversation.sessionId, resume: conversation.resume,
                                        permissionMode: "default", model: nil, effort: nil,
                                        environment: LoginEnv.shared.environment,
                                        systemPrompt: """
                                        你通过企业微信与用户持续对话。用中文自然回复，保留上下文。
                                        用户要求操作项目时直接使用工具完成，按用户要求验证结果。
                                        已登记的项目及真实目录如下。目标不明确时先询问用户。
                                        \(projects)
                                        当前目录用于保存聊天，项目操作请使用上述真实目录。
                                        工具权限和 AskUserQuestion 会由宿主转发到当前对话等待本人回答。
                                        """)
            let process = ClaudeProcess(config: config) { [weak self, weak conversation] event in
                guard let self, let conversation else { return }
                self.queue.async { self.handle(event, conversation: conversation, core: core) }
            }
            conversation.process = process
            armWatchdog(conversation, core: core)
            do {
                try process.start()
                SessionOwnership.shared.setExecutor(conversation.sessionId, held: true)
            }
            catch { fail(conversation, core: core, text: "Claude 启动失败：\(error.localizedDescription)") }
            return
        }
        guard conversation.ready else { return }
        conversation.active = conversation.pending.removeFirst()
        conversation.text = ""
        armWatchdog(conversation, core: core)
        if conversation.process?.sendUserMessage(conversation.active!.text) != true {
            fail(conversation, core: core, text: "消息未能送达 Claude，请重试。")
        }
    }

    private func handle(_ event: ExecutorEvent, conversation: Conversation, core: WorkCore) {
        guard conversations[conversation.key] === conversation else { return }
        switch event {
        case .ready:
            conversation.ready = true
            advance(conversation, core: core)
        case .sessionInfo:
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
            conversation.attention = (id, tool, input)
            let prompt: String
            if tool == "AskUserQuestion" {
                prompt = (input["questions"]?.arrayValue ?? []).map { question in
                    let options = (question["options"]?.arrayValue ?? []).compactMap { $0["label"]?.text }
                    return (question["question"]?.text ?? "请补充说明") + (options.isEmpty ? "" : "\n可选：" + options.joined(separator: " / "))
                }.joined(separator: "\n\n") + "\n直接回复答案。多道问题可回复 JSON 对象，以问题原文为键。"
            } else {
                prompt = "Claude 请求执行 \(tool)：\n\(WorkText.redact(String(input.serialized(pretty: true).prefix(3000))))\n回复“允许”或“拒绝”。"
            }
            finish(conversation, core: core, text: prompt)
            conversation.watchdog?.cancel()
        case .turnResult(let result):
            let text = result["result"]?.text ?? conversation.text
            finish(conversation, core: core, text: text.isEmpty ? "Claude 本轮执行结束。" : text)
            advance(conversation, core: core)
        case .controlAck(_, let ok, let detail):
            if !ok { fail(conversation, core: core, text: "Claude 控制请求失败：\(detail.serialized())") }
        case .exited(let code, let stderr):
            fail(conversation, core: core, text: "Claude 会话已退出（\(code)）。\(WorkText.redact(String(stderr.suffix(400))))")
        default: break
        }
    }

    private func answer(_ attention: (id: String, tool: String, input: JSONValue), message: Message,
                        conversation: Conversation, core: WorkCore) {
        var input = attention.input.objectValue ?? [:]
        var allow = false
        if attention.tool == "AskUserQuestion" {
            let questions = input["questions"]?.arrayValue ?? []
            var answers = JSONValue.parse(message.text)?.objectValue ?? [:]
            if questions.count == 1, let question = questions.first?["question"]?.text {
                answers[question] = .string(message.text)
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
                message.reply("Claude 正在等待操作确认，请回复“允许”或“拒绝”。", true)
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
            fail(conversation, core: core, text: "回答未能送达 Claude，请重试。")
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
            "resume": .bool(conversation.resume),
            "receipts": .object(conversation.receipts.mapValues(JSONValue.string)),
        ]))
    }

    private func fail(_ conversation: Conversation, core: WorkCore, text: String) {
        conversations.removeValue(forKey: conversation.key)
        conversation.active?.reply(text, true)
        conversation.active = nil
        conversation.watchdog?.cancel()
        SessionOwnership.shared.setExecutor(conversation.sessionId, held: false)
        for message in conversation.pending { message.reply(text, true) }
        conversation.pending.removeAll()
        conversation.process?.shutdown(grace: 0)
    }

    private func armWatchdog(_ conversation: Conversation, core: WorkCore) {
        conversation.watchdog?.cancel()
        let item = DispatchWorkItem { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            self.fail(conversation, core: core, text: "Claude 处理超时，请重试。")
        }
        conversation.watchdog = item
        queue.asyncAfter(deadline: .now() + 240, execute: item)
    }

    func stop() {
        queue.sync {
            for conversation in conversations.values {
                conversation.watchdog?.cancel()
                conversation.active?.reply("应用正在退出，Claude 会话已中断。", true)
                for message in conversation.pending { message.reply("应用正在退出，请稍后重试。", true) }
                _ = conversation.process?.terminateAndWait()
                SessionOwnership.shared.setExecutor(conversation.sessionId, held: false)
            }
            conversations.removeAll()
        }
    }
}
