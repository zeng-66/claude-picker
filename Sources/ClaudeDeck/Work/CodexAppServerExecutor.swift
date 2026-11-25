import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Codex CLI 的结构化执行器：`codex app-server --listen stdio://`（JSON-RPC，按行分隔，不带 `jsonrpc` 头）。
///
/// 协议依据 codex-cli 0.170 `app-server generate-ts` 的 v2 定义：
/// - `initialize` → `initialized` 通知；`thread/start` 新建线程或 `thread/resume` 按原始线程 ID 接续。
///   线程 ID 即 rollout 会话 ID，与 `codex resume <id>` 共用。
/// - `turn/start` 发起回合；`item/agentMessage/delta` 流式文本；`item/started|completed` 报告命令、补丁和 MCP 工具；
///   `turn/completed` 的 `turn.status` 为 completed / interrupted / failed。
/// - 审批是服务端请求 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval`
///   （答 `{decision: accept|decline}`），旧版 `execCommandApproval`、`applyPatchApproval`（答 `approved|denied`）。
/// - 中断用 `turn/interrupt {threadId, turnId}`，进程保持存活，可继续下一轮。
final class CodexAppServerProcess: AgentExecutorProcess, @unchecked Sendable {
    let config: ExecutorConfig
    private let onEvent: @Sendable (ExecutorEvent) -> Void
    private let queue = DispatchQueue(label: "claude-picker.codex-executor")
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
    private var threadId: String
    private var activeTurnId: String?
    private var pendingTurnStart = false
    private var currentTurnText = ""
    private var turnStartedAt = Date()
    private var nextRpcId = 10
    private var turnStartRpcIds = Set<Int>()
    private var cliVersion = ""
    private var seenItems = Set<String>()

    static let initializeRpcId = 1
    static let threadRpcId = 2
    static let modelListRpcId = 3
    private var threadResult: JSONValue = .null
    /// 界面切换的模型、推理强度与审批预设：从下一回合起随 turn/start 覆盖。
    private var overrides: [String: String] = [:]
    /// 最近一次 `thread/tokenUsage/updated`：上一回合实际占用的上下文与模型窗口。
    private var contextUsage: JSONValue = .null

    private struct PendingApproval {
        let rawId: JSONValue
        let legacy: Bool
    }
    private var pendingApprovals: [String: PendingApproval] = [:]

    init(config: ExecutorConfig, onEvent: @escaping @Sendable (ExecutorEvent) -> Void) {
        self.config = config
        self.threadId = config.resume ? config.sessionId : ""
        self.onEvent = onEvent
    }

    var isRunning: Bool { queue.sync { !exited && pid > 0 } }
    var activeSessionId: String { queue.sync { threadId } }

    /// 权限预设 → Codex 的审批策略与沙箱。未知或缺省时按需审批、工作区可写。
    static func policy(for permissionMode: String?) -> (approval: String, sandbox: String) {
        switch permissionMode {
        case "bypassPermissions", "never": return ("never", "danger-full-access")
        case "plan", "read-only": return ("on-request", "read-only")
        case "auto-review": return ("on-request", "workspace-write")
        case "untrusted": return ("untrusted", "workspace-write")
        default: return ("on-request", "workspace-write")
        }
    }

    /// 权限预设，与 Codex 桌面端输入框下方的权限选择器一致：
    /// 请求批准（按需审批、工作区可写）、替我批准（按需审批交给自动审查）、完全访问（不审批、不设沙箱）。
    static let presets: [(id: String, label: String)] = [("on-request", "请求批准"), ("auto-review", "替我批准"), ("never", "完全访问")]

    static func preset(approval: String?, sandbox: String?, reviewer: String? = nil) -> String {
        if approval == "never" || sandbox == "dangerFullAccess" { return "never" }
        if reviewer == "auto_review" { return "auto-review" }
        return "on-request"
    }

    static func turnOverrides(_ overrides: [String: String]) -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let model = overrides["model"] { params["model"] = .string(model) }
        if let effort = overrides["effort"] { params["effort"] = .string(effort) }
        switch overrides["mode"] {
        case "never":
            params["approvalPolicy"] = .string("never")
            params["approvalsReviewer"] = .string("user")
            params["sandboxPolicy"] = .obj(["type": .string("dangerFullAccess")])
        case "read-only":
            params["approvalPolicy"] = .string("on-request")
            params["sandboxPolicy"] = .obj(["type": .string("readOnly"), "networkAccess": .bool(false)])
        case "on-request", "auto-review":
            params["approvalPolicy"] = .string("on-request")
            params["approvalsReviewer"] = .string(overrides["mode"] == "auto-review" ? "auto_review" : "user")
            params["sandboxPolicy"] = .obj(["type": .string("workspaceWrite"), "writableRoots": .array([]),
                                            "networkAccess": .bool(false), "excludeTmpdirEnvVar": .bool(false),
                                            "excludeSlashTmp": .bool(false)])
        default: break
        }
        return params
    }

    static func threadParams(for config: ExecutorConfig, threadId: String?) -> JSONValue {
        let policy = policy(for: config.permissionMode)
        var params: [String: JSONValue] = [
            "cwd": .string(config.cwd),
            "approvalPolicy": .string(policy.approval),
            "sandbox": .string(policy.sandbox),
        ]
        if let model = config.model, !model.isEmpty, model != "default" { params["model"] = .string(model) }
        if let prompt = config.systemPrompt, !prompt.isEmpty { params["developerInstructions"] = .string(prompt) }
        if config.permissionMode == "auto-review" { params["approvalsReviewer"] = .string("auto_review") }
        if let threadId {
            params["threadId"] = .string(threadId)
            // 只要线程元数据；界面历史由宿主从本地记录读取，避免一次灌入整段线程。
            params["excludeTurns"] = .bool(true)
        }
        return .object(params)
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: config.executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
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
            _ = sendRpc(id: Self.initializeRpcId, method: "initialize", params: .obj([
                "clientInfo": .obj([
                    "name": .string("claude-picker"),
                    "title": .string("ClaudePicker"),
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
        if let method = msg["method"]?.stringValue {
            if let rawId = msg["id"], !rawId.isNull {
                handleServerRequest(id: rawId, method: method, params: msg["params"] ?? .object([:]))
            } else {
                handleNotification(method: method, params: msg["params"] ?? .object([:]))
            }
            return
        }
        guard let rpcId = msg["id"]?.intValue else { return }
        let error = msg["error"].flatMap { $0.isNull ? nil : $0 }
        let result = msg["result"] ?? .null

        switch rpcId {
        case Self.initializeRpcId:
            if let error {
                onEvent(.controlAck(requestId: ClaudeProcess.initializeRequestId, ok: false, detail: error))
                return
            }
            cliVersion = result["userAgent"]?.text ?? ""
            _ = write(.obj(["method": .string("initialized")]))
            if config.resume, !threadId.isEmpty {
                _ = sendRpc(id: Self.threadRpcId, method: "thread/resume",
                            params: Self.threadParams(for: config, threadId: threadId))
            } else {
                _ = sendRpc(id: Self.threadRpcId, method: "thread/start",
                            params: Self.threadParams(for: config, threadId: nil))
            }
        case Self.threadRpcId:
            if let error {
                onEvent(.controlAck(requestId: ClaudeProcess.initializeRequestId, ok: false, detail: error))
                return
            }
            if let id = result["thread"]?["id"]?.text { threadId = id }
            threadResult = result
            // 先取可选模型（含各自支持的推理强度），再报告就绪；不支持时照常就绪。
            _ = sendRpc(id: Self.modelListRpcId, method: "model/list", params: .obj(["limit": .int(50)]))
        case Self.modelListRpcId:
            let models = (result["data"]?.arrayValue ?? []).filter { $0["hidden"]?.boolValue != true }.map { model -> JSONValue in
                .obj([
                    "id": model["model"] ?? model["id"] ?? .null,
                    "label": model["displayName"] ?? model["model"] ?? .null,
                    "efforts": .array((model["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap {
                        $0["reasoningEffort"] ?? ($0.stringValue.map(JSONValue.string))
                    }),
                    "defaultEffort": model["defaultReasoningEffort"] ?? .null,
                ])
            }
            let info = threadResult
            onEvent(.sessionInfo(.obj([
                "sessionId": .string(threadId),
                "executor": .string(AgentProvider.codex.rawValue),
                "model": .str(info["model"]?.text ?? config.model),
                "effort": info["reasoningEffort"] ?? .null,
                "permissionMode": .str(Self.preset(approval: info["approvalPolicy"]?.text, sandbox: info["sandbox"]?["type"]?.text,
                                                   reviewer: info["approvalsReviewer"]?.text)),
                "cwd": .string(info["cwd"]?.text ?? config.cwd),
                "cliVersion": .str(cliVersion),
                "availableModels": error == nil ? .array(models) : .null,
            ])))
            if !readySent {
                readySent = true
                onEvent(.ready)
            }
        default:
            guard turnStartRpcIds.remove(rpcId) != nil else { return }
            if let error {
                pendingTurnStart = false
                let message = error["message"]?.text ?? error.serialized()
                onEvent(.turnResult(.obj([
                    "subtype": .string("error_during_execution"),
                    "isError": .bool(true),
                    "terminalReason": .string("codex_error"),
                    "result": .string(message),
                    "durationMs": .int(0),
                ])))
            } else if let id = result["turn"]?["id"]?.text, activeTurnId == nil {
                activeTurnId = id
            }
        }
    }

    private func handleNotification(method: String, params: JSONValue) {
        if let thread = params["threadId"]?.text, !threadId.isEmpty, thread != threadId { return }
        switch method {
        case "turn/started":
            activeTurnId = params["turn"]?["id"]?.text ?? activeTurnId
        case "item/agentMessage/delta":
            if let delta = params["delta"]?.stringValue, !delta.isEmpty {
                currentTurnText += delta
                onEvent(.delta(delta))
            }
        case "item/started":
            if let item = params["item"] { emitToolStart(item) }
        case "item/completed":
            guard let item = params["item"] else { return }
            if item["type"]?.stringValue == "agentMessage" {
                let text = item["text"]?.stringValue ?? ""
                if !text.isEmpty { onEvent(.assistantText(text)) }
                currentTurnText = ""
            } else {
                emitToolStart(item)
                if let id = item["id"]?.text, Self.isTool(item) {
                    onEvent(.toolResult(id: id, isError: Self.isFailure(item), content: Self.toolOutput(item)))
                }
            }
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"] ?? .null
            if let used = usage["last"]?["totalTokens"]?.intValue {
                contextUsage = .obj(["used": .int(used), "total": usage["modelContextWindow"] ?? .null])
            }
        case "turn/completed":
            let turn = params["turn"] ?? .object([:])
            finishTurn(status: turn["status"]?.stringValue ?? "completed", error: turn["error"],
                       durationMs: turn["durationMs"]?.intValue)
        case "error":
            if params["willRetry"]?.boolValue == true { return }
            if activeTurnId == nil && !pendingTurnStart { return }
            finishTurn(status: "failed", error: params["error"] ?? params, durationMs: nil)
        default:
            break
        }
    }

    private func finishTurn(status: String, error: JSONValue?, durationMs: Int?) {
        guard activeTurnId != nil || pendingTurnStart else { return }
        activeTurnId = nil
        pendingTurnStart = false
        let leftover = currentTurnText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty { onEvent(.assistantText(currentTurnText)) }
        currentTurnText = ""
        let elapsed = durationMs ?? Int(Date().timeIntervalSince(turnStartedAt) * 1000)
        let interrupted = status == "interrupted"
        let failed = status == "failed"
        let message = error.flatMap { $0.isNull ? nil : ($0["message"]?.text ?? $0.serialized()) }
        onEvent(.turnResult(.obj([
            "subtype": .string(interrupted ? "aborted" : failed ? "error_during_execution" : "success"),
            "isError": .bool(failed),
            "terminalReason": .string(interrupted ? "aborted_by_user" : status),
            "result": .string(failed ? (message ?? "Codex 回合失败") : leftover),
            "durationMs": .int(elapsed),
            "context": contextUsage,
        ])))
    }

    static func isTool(_ item: JSONValue) -> Bool {
        let type = item["type"]?.stringValue ?? ""
        return ["commandExecution", "fileChange", "mcpToolCall", "webSearch", "dynamicToolCall", "imageView"].contains(type)
    }

    static func toolName(_ item: JSONValue) -> String {
        switch item["type"]?.stringValue {
        case "commandExecution": return "Bash"
        case "fileChange": return "Edit"
        case "mcpToolCall":
            let server = item["server"]?.text ?? "mcp"
            return "mcp__\(server)__\(item["tool"]?.text ?? "tool")"
        case "webSearch": return "WebSearch"
        case let other?: return other
        case nil: return "tool"
        }
    }

    static func toolInput(_ item: JSONValue) -> JSONValue {
        switch item["type"]?.stringValue {
        case "commandExecution":
            return .obj(["command": item["command"] ?? .null, "cwd": item["cwd"] ?? .null])
        case "fileChange":
            let paths = (item["changes"]?.arrayValue ?? []).compactMap { $0["path"] }
            return .obj(["file_path": paths.first ?? .null, "changes": item["changes"] ?? .array([])])
        case "mcpToolCall":
            return item["arguments"] ?? .object([:])
        case "webSearch":
            return .obj(["query": item["query"] ?? .null])
        default:
            return item
        }
    }

    static func toolOutput(_ item: JSONValue) -> JSONValue {
        if let output = item["aggregatedOutput"], !output.isNull { return output }
        if let result = item["result"], !result.isNull { return result }
        if let error = item["error"], !error.isNull { return error }
        return item["status"] ?? .string("completed")
    }

    static func isFailure(_ item: JSONValue) -> Bool {
        let status = item["status"]?.stringValue ?? ""
        if ["failed", "declined", "error"].contains(status) { return true }
        if let code = item["exitCode"]?.intValue, code != 0 { return true }
        return false
    }

    private func emitToolStart(_ item: JSONValue) {
        guard Self.isTool(item), let id = item["id"]?.text, !seenItems.contains(id) else { return }
        seenItems.insert(id)
        onEvent(.toolUse(id: id, name: Self.toolName(item), input: Self.toolInput(item)))
    }

    private func handleServerRequest(id rawId: JSONValue, method: String, params: JSONValue) {
        let legacy = method == "execCommandApproval" || method == "applyPatchApproval"
        let isApproval = method == "item/commandExecution/requestApproval"
            || method == "item/fileChange/requestApproval" || legacy
        guard isApproval else {
            _ = write(.obj([
                "id": rawId,
                "error": .obj(["code": .int(-32601), "message": .string("ClaudePicker 暂不支持 \(method)")]),
            ]))
            return
        }
        let key: String
        if let i = rawId.intValue { key = "codex-\(i)" }
        else { key = "codex-\(rawId.text ?? UUID().uuidString)" }
        pendingApprovals[key] = PendingApproval(rawId: rawId, legacy: legacy)
        let isPatch = method.contains("fileChange") || method == "applyPatchApproval"
        var input: [String: JSONValue] = [:]
        if let command = params["command"], !command.isNull { input["command"] = command }
        if let cwd = params["cwd"], !cwd.isNull { input["cwd"] = cwd }
        if let changes = params["fileChanges"] ?? params["changes"], !changes.isNull { input["changes"] = changes }
        if let root = params["grantRoot"], !root.isNull { input["grantRoot"] = root }
        onEvent(.permissionRequest(
            requestId: key,
            toolName: isPatch ? "Edit" : "Bash",
            input: .object(input),
            detail: .obj([
                "description": params["reason"] ?? .null,
                "toolUseId": params["itemId"] ?? params["callId"] ?? .null,
            ])
        ))
    }

    // MARK: 发送与控制

    @discardableResult
    private func write(_ value: JSONValue) -> Bool {
        guard !exited, !stdinClosed else { return false }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data((value.serialized() + "\n").utf8))
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func sendRpc(id: Int, method: String, params: JSONValue) -> Bool {
        write(.obj(["id": .int(id), "method": .string(method), "params": params]))
    }

    @discardableResult
    func sendUserMessage(_ text: String) -> Bool {
        queue.sync {
            guard !threadId.isEmpty, activeTurnId == nil, !pendingTurnStart else { return false }
            nextRpcId += 1
            let rpcId = nextRpcId
            turnStartRpcIds.insert(rpcId)
            currentTurnText = ""
            turnStartedAt = Date()
            var params: [String: JSONValue] = [
                "threadId": .string(threadId),
                "input": .array([.obj(["type": .string("text"), "text": .string(text), "text_elements": .array([])])]),
            ]
            params.merge(Self.turnOverrides(overrides)) { _, new in new }
            let sent = sendRpc(id: rpcId, method: "turn/start", params: .object(params))
            if sent {
                pendingTurnStart = true
                onEvent(.turnStarted)
            } else {
                turnStartRpcIds.remove(rpcId)
            }
            return sent
        }
    }

    @discardableResult
    func updateRuntime(key: String, value: String) -> Bool {
        guard ["mode", "model", "effort"].contains(key) else { return false }
        queue.sync { overrides[key] = value }
        return true
    }

    @discardableResult
    func respondPermission(requestId: String, allow: Bool, updatedInput: JSONValue?, message: String?) -> Bool {
        queue.sync {
            guard let pending = pendingApprovals.removeValue(forKey: requestId) else { return false }
            let decision = pending.legacy ? (allow ? "approved" : "denied") : (allow ? "accept" : "decline")
            return write(.obj(["id": pending.rawId, "result": .obj(["decision": .string(decision)])]))
        }
    }

    @discardableResult
    func interrupt(requestId: String) -> Bool {
        let ok: Bool = queue.sync {
            guard !threadId.isEmpty, let turn = activeTurnId else { return false }
            // 先拒掉悬而未决的审批，避免服务端一直等答复。
            for (_, pending) in pendingApprovals {
                let decision = pending.legacy ? "abort" : "cancel"
                _ = write(.obj(["id": pending.rawId, "result": .obj(["decision": .string(decision)])]))
            }
            pendingApprovals.removeAll()
            nextRpcId += 1
            return sendRpc(id: nextRpcId, method: "turn/interrupt", params: .obj([
                "threadId": .string(threadId), "turnId": .string(turn),
            ]))
        }
        onEvent(.controlAck(requestId: requestId, ok: ok, detail: .null))
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

/// 结构化执行器的统一入口：Work、会话聊天与企微续聊共用同一套引擎选择。
enum AgentExecutorFactory {
    static func supportsStructured(_ provider: AgentProvider) -> Bool {
        provider.supportsStructuredChat
    }

    static func executable(for provider: AgentProvider) -> String? {
        switch provider {
        case .claude: return ClaudeLocator.find()
        case .antigravity: return CliBinaryLocator.findAgy()
        case .codex: return CliBinaryLocator.find(.codex)
        case .dsh: return nil
        }
    }

    static func make(_ config: ExecutorConfig,
                     onEvent: @escaping @Sendable (ExecutorEvent) -> Void) -> (any AgentExecutorProcess)? {
        switch config.provider {
        case .claude: return ClaudeProcess(config: config, onEvent: onEvent)
        case .antigravity: return ACPProcess(config: config, onEvent: onEvent)
        case .codex: return CodexAppServerProcess(config: config, onEvent: onEvent)
        case .dsh: return nil
        }
    }
}
