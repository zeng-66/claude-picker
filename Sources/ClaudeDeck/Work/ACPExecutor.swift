import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 结构化执行器统一协议：Claude (`stream-json`)、Antigravity / 通用 ACP (`agy acp`) 与后续 Codex 均实现此接口，
/// 上层 `WorkCore` 只面向协议与 `ExecutorEvent` 调度。
protocol AgentExecutorProcess: AnyObject, Sendable {
    var config: ExecutorConfig { get }
    var pid: Int32 { get }
    var isRunning: Bool { get }
    var activeSessionId: String { get }
    func start() throws
    @discardableResult func sendUserMessage(_ text: String) -> Bool
    @discardableResult func respondPermission(requestId: String, allow: Bool, updatedInput: JSONValue?, message: String?) -> Bool
    @discardableResult func interrupt(requestId: String) -> Bool
    func shutdown(grace: TimeInterval)
    func terminateAndWait(timeout: TimeInterval) -> Bool
    /// 运行中修改权限模式（mode）、模型（model）或推理强度（effort）。返回 false 表示需要下一次启动才生效。
    @discardableResult func updateRuntime(key: String, value: String) -> Bool
}

extension AgentExecutorProcess {
    @discardableResult func updateRuntime(key: String, value: String) -> Bool { false }
}

/// 标准 Agent Client Protocol (ACP, JSON-RPC 2.0 NDJSON over stdio) 执行器。
/// 实测兼容 `agy acp`（Antigravity ACP Server 1.5+），并可直接复用于后续支持 `--acp` / `acp` 的智能体 CLI。
final class ACPProcess: AgentExecutorProcess, @unchecked Sendable {
    let config: ExecutorConfig
    private let onEvent: @Sendable (ExecutorEvent) -> Void
    private let queue = DispatchQueue(label: "claude-picker.acp-executor")
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var buffer = Data()
    private var stderrTail = Data()
    private var exited = false
    private var stdinClosed = false
    private var readySent = false
    private(set) var pid: Int32 = 0
    private var sessionIdValue: String

    private var nextRpcId: Int = 10
    private let initRpcId = 1
    private let sessionSetupRpcId = 2
    private var fallbackNewRpcId: Int? = nil
    private var activePromptRpcId: Int? = nil
    private var currentTurnText = ""
    private var turnStartedAt = Date()
    private var agentVersion = ""
    private var seenToolCalls = Set<String>()

    private struct PendingPermission {
        let rawId: JSONValue
        let options: [JSONValue]
    }
    private var pendingPermissions: [String: PendingPermission] = [:]

    init(config: ExecutorConfig, onEvent: @escaping @Sendable (ExecutorEvent) -> Void) {
        self.config = config
        self.sessionIdValue = config.sessionId
        self.onEvent = onEvent
    }

    var isRunning: Bool { queue.sync { !exited && pid > 0 } }
    var activeSessionId: String { queue.sync { sessionIdValue } }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: config.executable)
        process.arguments = config.acpArguments
        process.currentDirectoryURL = URL(fileURLWithPath: config.cwd)
        process.environment = config.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.consume(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async {
                self.stderrTail.append(data)
                if self.stderrTail.count > 8192 { self.stderrTail = self.stderrTail.suffix(8192) }
            }
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let code = proc.terminationStatus
            self.queue.asyncAfter(deadline: .now() + 0.15) { self.finish(code: code) }
        }
        try process.run()
        queue.sync {
            pid = process.processIdentifier
            _ = sendRpc(id: initRpcId, method: "initialize", params: .obj([
                "protocolVersion": .int(1),
                "clientCapabilities": .object([:]),
                "clientInfo": .obj([
                    "name": .string("claude-picker"),
                    "version": .string("1.0"),
                ]),
            ]))
        }
    }

    private func finish(code: Int32) {
        guard !exited else { return }
        exited = true
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty { consume(rest) }
        if !buffer.isEmpty { handleLine(buffer); buffer.removeAll() }
        let tail = String(decoding: stderrTail, as: UTF8.self)
        onEvent(.exited(code: code, stderrTail: WorkText.redact(tail)))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { handleLine(Data(line)) }
        }
    }

    private func handleLine(_ line: Data) {
        guard let msg = JSONValue.parse(line) else { return }

        // 1. 服务端发来的双向请求（带 method 且带 id）：主要是 `session/request_permission`
        if let method = msg["method"]?.stringValue, let rawId = msg["id"], !rawId.isNull {
            handleServerRequest(id: rawId, method: method, params: msg["params"] ?? .object([:]))
            return
        }

        // 2. 服务端发来的单向流式通知（带 method，无 id）：主要是 `session/update`
        if let method = msg["method"]?.stringValue {
            if method == "session/update", let update = msg["params"]?["update"] {
                handleSessionUpdate(update)
            }
            return
        }

        // 3. 客户端发起 RPC 的响应（带 id）
        guard let rpcId = msg["id"]?.intValue else { return }
        let errorObj = msg["error"]
        let resultObj = msg["result"]

        if rpcId == initRpcId {
            if let errorObj, !errorObj.isNull {
                onEvent(.controlAck(requestId: ClaudeProcess.initializeRequestId, ok: false, detail: errorObj))
                return
            }
            agentVersion = resultObj?["agentInfo"]?["version"]?.stringValue ?? ""
            if config.resume, !sessionIdValue.isEmpty {
                _ = sendRpc(id: sessionSetupRpcId, method: "session/load", params: .obj([
                    "sessionId": .string(sessionIdValue),
                    "cwd": .string(config.cwd),
                    "mcpServers": .array([]),
                ]))
            } else {
                _ = sendRpc(id: sessionSetupRpcId, method: "session/new", params: .obj([
                    "cwd": .string(config.cwd),
                    "mcpServers": .array([]),
                ]))
            }
            return
        }

        if rpcId == sessionSetupRpcId || rpcId == fallbackNewRpcId {
            if let errorObj, !errorObj.isNull {
                // `session/load` 若因远端/本地未找到旧 ID 失败，自动降级 `session/new` 新建
                if rpcId == sessionSetupRpcId && config.resume && fallbackNewRpcId == nil {
                    nextRpcId += 1
                    fallbackNewRpcId = nextRpcId
                    _ = sendRpc(id: nextRpcId, method: "session/new", params: .obj([
                        "cwd": .string(config.cwd),
                        "mcpServers": .array([]),
                    ]))
                    return
                }
                onEvent(.controlAck(requestId: ClaudeProcess.initializeRequestId, ok: false, detail: errorObj))
                return
            }
            if let sid = resultObj?["sessionId"]?.text {
                sessionIdValue = sid
            }
            let currentModel = resultObj?["models"]?["currentModelId"]?.text ?? config.model
            let currentMode = resultObj?["modes"]?["currentModeId"]?.text ?? config.permissionMode

            // 按需设置会话模式与模型（异步通知服务端，不阻塞握手完成）
            if let wantedMode = config.permissionMode, !wantedMode.isEmpty, wantedMode != currentMode {
                nextRpcId += 1
                _ = sendRpc(id: nextRpcId, method: "session/set_mode", params: .obj([
                    "sessionId": .string(sessionIdValue),
                    "modeId": .string(wantedMode),
                ]))
            }
            if let wantedModel = config.model, !wantedModel.isEmpty, wantedModel != "default", wantedModel != currentModel {
                nextRpcId += 1
                _ = sendRpc(id: nextRpcId, method: "session/set_model", params: .obj([
                    "sessionId": .string(sessionIdValue),
                    "modelId": .string(wantedModel),
                ]))
            }

            onEvent(.sessionInfo(.obj([
                "sessionId": .string(sessionIdValue),
                "executor": .string(config.provider.rawValue),
                "model": .str(config.model ?? currentModel),
                "permissionMode": .str(config.permissionMode ?? currentMode),
                "cwd": .string(config.cwd),
                "cliVersion": .str(agentVersion),
                // 可选模式与模型以 ACP 会话自己报告的为准，供界面快捷切换。
                "availableModes": resultObj?["modes"]?["availableModes"] ?? .null,
                "availableModels": resultObj?["models"]?["availableModels"] ?? .null,
            ])))
            if !readySent {
                currentTurnText = ""
                seenToolCalls.removeAll()
                readySent = true
                onEvent(.ready)
            }
            return
        }

        if rpcId == activePromptRpcId {
            activePromptRpcId = nil
            let finalText = currentTurnText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty {
                onEvent(.assistantText(currentTurnText))
            }
            currentTurnText = ""
            let durationMs = Int(Date().timeIntervalSince(turnStartedAt) * 1000)
            if let errorObj, !errorObj.isNull {
                let errMsg = errorObj["message"]?.stringValue ?? errorObj.serialized()
                let cancelled = errMsg.lowercased().contains("cancel") || errMsg.lowercased().contains("abort")
                onEvent(.turnResult(.obj([
                    "subtype": .string(cancelled ? "aborted" : "error_during_execution"),
                    "isError": .bool(!cancelled),
                    "terminalReason": .string(cancelled ? "aborted_by_user" : "acp_error"),
                    "result": .string(cancelled ? finalText : errMsg),
                    "durationMs": .int(durationMs),
                ])))
            } else {
                let stopReason = resultObj?["stopReason"]?.stringValue ?? "end_turn"
                let cancelled = stopReason == "cancelled" || stopReason.hasPrefix("abort")
                onEvent(.turnResult(.obj([
                    "subtype": .string(cancelled ? "aborted" : "success"),
                    "isError": .bool(false),
                    "terminalReason": .string(cancelled ? "aborted_by_user" : stopReason),
                    "stopReason": .string(stopReason),
                    "result": .string(finalText),
                    "durationMs": .int(durationMs),
                ])))
            }
        }
    }

    private func handleSessionUpdate(_ update: JSONValue) {
        // `session/load` 响应到达前的重放通知不包含完整 user/assistant 配对：
        // 本地历史已由 `SessionChatHistory` 完整载入，重放期直接跳过，避免拼出残缺卡片或污染下一回合文本。
        guard readySent else { return }
        guard let kind = update["sessionUpdate"]?.stringValue else { return }
        switch kind {
        case "agent_message_chunk":
            if let chunk = update["content"]?["text"]?.stringValue, !chunk.isEmpty {
                currentTurnText += chunk
                onEvent(.delta(chunk))
            }

        case "tool_call":
            let callId = update["toolCallId"]?.stringValue ?? UUID().uuidString.lowercased()
            let title = update["title"]?.text ?? update["kind"]?.text ?? "tool"
            let rawInput = update["rawInput"] ?? .obj(["title": .string(title)])
            seenToolCalls.insert(callId)
            onEvent(.toolUse(id: callId, name: title, input: rawInput))
            if let status = update["status"]?.stringValue, status == "completed" || status == "failed" {
                let content = update["content"] ?? update["rawOutput"] ?? .string(status)
                onEvent(.toolResult(id: callId, isError: status == "failed", content: content))
            }

        case "tool_call_update":
            let callId = update["toolCallId"]?.stringValue ?? ""
            guard !callId.isEmpty else { return }
            if !seenToolCalls.contains(callId) {
                let title = update["title"]?.text ?? update["kind"]?.text ?? "tool"
                seenToolCalls.insert(callId)
                onEvent(.toolUse(id: callId, name: title, input: update["rawInput"] ?? .object([:])))
            }
            if let status = update["status"]?.stringValue, status == "completed" || status == "failed" {
                let content = update["content"] ?? update["rawOutput"] ?? .string(status)
                onEvent(.toolResult(id: callId, isError: status == "failed", content: content))
            }

        default:
            break
        }
    }

    private func handleServerRequest(id rawId: JSONValue, method: String, params: JSONValue) {
        guard method == "session/request_permission" else {
            _ = write(.obj([
                "jsonrpc": .string("2.0"),
                "id": rawId,
                "error": .obj(["code": .int(-32601), "message": .string("Method not supported: \(method)")]),
            ]))
            return
        }
        let idKey: String
        if let i = rawId.intValue { idKey = "acp-\(i)" }
        else if let s = rawId.stringValue { idKey = "acp-\(s)" }
        else { idKey = "acp-\(UUID().uuidString)" }

        let options = params["options"]?.arrayValue ?? []
        pendingPermissions[idKey] = PendingPermission(rawId: rawId, options: options)

        let toolCall = params["toolCall"] ?? .object([:])
        let toolName = toolCall["title"]?.text ?? toolCall["kind"]?.text ?? "Antigravity 工具操作"
        let rawInput = toolCall["rawInput"] ?? toolCall
        onEvent(.permissionRequest(
            requestId: idKey,
            toolName: toolName,
            input: rawInput,
            detail: .obj([
                "description": toolCall["title"] ?? params["description"],
                "toolUseId": toolCall["toolCallId"],
            ])
        ))
    }

    // MARK: 发送与控制

    @discardableResult
    private func write(_ value: JSONValue) -> Bool {
        guard !exited, !stdinClosed else { return false }
        let line = value.serialized() + "\n"
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func sendRpc(id: Int, method: String, params: JSONValue) -> Bool {
        write(.obj([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": params,
        ]))
    }

    @discardableResult
    func sendUserMessage(_ text: String) -> Bool {
        queue.sync {
            guard !sessionIdValue.isEmpty else { return false }
            nextRpcId += 1
            let rpcId = nextRpcId
            activePromptRpcId = rpcId
            currentTurnText = ""
            turnStartedAt = Date()
            let fullText: String
            if let sys = config.systemPrompt, !sys.isEmpty, rpcId <= 15 {
                fullText = "<system-instructions>\n\(sys)\n</system-instructions>\n\n\(text)"
            } else {
                fullText = text
            }
            let sent = sendRpc(id: rpcId, method: "session/prompt", params: .obj([
                "sessionId": .string(sessionIdValue),
                "prompt": .array([.obj(["type": .string("text"), "text": .string(fullText)])]),
            ]))
            if sent { onEvent(.turnStarted) }
            return sent
        }
    }

    @discardableResult
    func respondPermission(requestId: String, allow: Bool, updatedInput: JSONValue?, message: String?) -> Bool {
        queue.sync {
            guard let pending = pendingPermissions.removeValue(forKey: requestId) else { return false }
            let chosenId = Self.pickOptionId(from: pending.options, allow: allow)
            let outcome: JSONValue
            if let chosenId {
                outcome = .obj(["outcome": .string("selected"), "optionId": .string(chosenId)])
            } else {
                outcome = .obj(["outcome": .string("cancelled")])
            }
            return write(.obj([
                "jsonrpc": .string("2.0"),
                "id": pending.rawId,
                "result": .obj(["outcome": outcome]),
            ]))
        }
    }

    private static func pickOptionId(from options: [JSONValue], allow: Bool) -> String? {
        if allow {
            if let hit = options.first(where: { ($0["kind"]?.stringValue ?? "").contains("allow_once") })?["optionId"]?.text {
                return hit
            }
            if let hit = options.first(where: {
                let k = ($0["kind"]?.stringValue ?? $0["optionId"]?.stringValue ?? "").lowercased()
                return k.contains("allow") || k.contains("approve")
            })?["optionId"]?.text {
                return hit
            }
            return options.first?["optionId"]?.text ?? "allow_once"
        } else {
            if let hit = options.first(where: {
                let k = ($0["kind"]?.stringValue ?? $0["optionId"]?.stringValue ?? "").lowercased()
                return k.contains("reject") || k.contains("deny")
            })?["optionId"]?.text {
                return hit
            }
            return nil
        }
    }

    @discardableResult
    func updateRuntime(key: String, value: String) -> Bool {
        queue.sync {
            guard !sessionIdValue.isEmpty, key == "mode" || key == "model" else { return false }
            nextRpcId += 1
            return sendRpc(id: nextRpcId, method: key == "mode" ? "session/set_mode" : "session/set_model", params: .obj([
                "sessionId": .string(sessionIdValue),
                key == "mode" ? "modeId" : "modelId": .string(value),
            ]))
        }
    }

    @discardableResult
    func interrupt(requestId: String) -> Bool {
        let ok = queue.sync {
            guard !sessionIdValue.isEmpty else { return false }
            return write(.obj([
                "jsonrpc": .string("2.0"),
                "method": .string("session/cancel"),
                "params": .obj(["sessionId": .string(sessionIdValue)]),
            ]))
        }
        if ok {
            onEvent(.controlAck(requestId: requestId, ok: true, detail: .null))
        }
        return ok
    }

    func shutdown(grace: TimeInterval = 4) {
        let alreadyGone: Bool = queue.sync {
            if exited { return true }
            if !stdinClosed {
                stdinClosed = true
                try? stdinPipe.fileHandleForWriting.close()
            }
            return false
        }
        guard !alreadyGone else { return }
        let process = self.process
        let pid = self.pid
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning, pid > 0 { kill(pid, SIGKILL) }
            }
        }
    }

    func terminateAndWait(timeout: TimeInterval = 4) -> Bool {
        queue.sync {
            if !stdinClosed {
                stdinClosed = true
                try? stdinPipe.fileHandleForWriting.close()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        if process.isRunning { process.terminate() }
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning, pid > 0 {
            kill(pid, SIGKILL)
            let hard = Date().addingTimeInterval(1.5)
            while process.isRunning, Date() < hard { usleep(50_000) }
        }
        return !process.isRunning
    }
}
