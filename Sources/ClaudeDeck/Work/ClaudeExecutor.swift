import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Claude CLI 的结构化执行器：`claude -p --input-format stream-json --output-format stream-json`。
///
/// 协议形态在 CLI 2.1.325 上实测过（2026-11-16）：
/// - 每轮开始发 `system/init`；一轮结束发 `result`（成功 `subtype=success`，被中断是
///   `error_during_execution` + `terminal_reason=aborted_*`）。
/// - 工具权限与 AskUserQuestion 都以 `control_request{subtype: can_use_tool}` 到达，带独立 request_id；
///   答复是 `control_response`，`behavior: allow`（可带 updatedInput）或 `deny`（带 message）。
/// - 中断是 `control_request{subtype: interrupt}`，进程保持存活，可继续下一轮。
/// 这里不模拟按键，也不解析终端输出。
enum ExecutorEvent: Sendable {
    /// 握手完成：CLI 应答了 `initialize` 控制请求，可以开始发送消息。
    case ready
    /// 一轮开始时 CLI 报告的会话信息（模型、权限模式、CLI 版本、工作目录）。
    case sessionInfo(JSONValue)
    case turnStarted
    case assistantText(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, isError: Bool, content: JSONValue)
    /// 流式增量：只用于界面实时显示，不持久化。
    case delta(String)
    case permissionRequest(requestId: String, toolName: String, input: JSONValue, detail: JSONValue)
    case controlAck(requestId: String, ok: Bool, detail: JSONValue)
    case turnResult(JSONValue)
    case exited(code: Int32, stderrTail: String)
}

struct ExecutorConfig: Sendable {
    var executable: String
    var cwd: String
    var sessionId: String
    /// 会话已经存在（之前的 Run 跑过）时用 `--resume`，否则 `--session-id` 新建。
    var resume: Bool
    var permissionMode: String?
    var model: String?
    var effort: String?
    var environment: [String: String]
}

enum ClaudeLocator {
    /// 找 claude 可执行文件：显式指定 → 登录 shell 的 PATH → 常见安装位置。
    /// 从 Finder 启动时不能假定继承了终端 PATH。
    static func find() -> String? {
        let env = LoginEnv.shared
        if let override = env.environment["CLAUDE_PICKER_CLAUDE_BIN"], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let home = NSHomeDirectory()
        var extra = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            extra += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(nvm)/\($0)/bin/claude" }
        }
        return env.find("claude", extra: extra)
    }
}

final class ClaudeProcess: @unchecked Sendable {
    let config: ExecutorConfig
    private let onEvent: @Sendable (ExecutorEvent) -> Void
    private let queue = DispatchQueue(label: "claude-picker.executor")
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var buffer = Data()
    private var stderrTail = Data()
    private var readySent = false
    private var exited = false
    private var stdinClosed = false
    private(set) var pid: Int32 = 0

    init(config: ExecutorConfig, onEvent: @escaping @Sendable (ExecutorEvent) -> Void) {
        self.config = config
        self.onEvent = onEvent
    }

    var isRunning: Bool { queue.sync { !exited && pid > 0 } }

    static func arguments(for config: ExecutorConfig) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--input-format", "stream-json",
                    "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        args += [config.resume ? "--resume" : "--session-id", config.sessionId]
        if let mode = config.permissionMode, !mode.isEmpty { args += ["--permission-mode", mode] }
        if let model = config.model, !model.isEmpty, model != "default" { args += ["--model", model] }
        if let effort = config.effort, !effort.isEmpty { args += ["--effort", effort] }
        return args
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: config.executable)
        process.arguments = Self.arguments(for: config)
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
            // 等管道里剩下的输出读完再报告退出，否则最后一条 result 可能排在 exited 后面。
            self.queue.asyncAfter(deadline: .now() + 0.15) { self.finish(code: code) }
        }
        try process.run()
        queue.sync {
            pid = process.processIdentifier
            // 握手：收到这条请求的应答才算就绪（见 handleLine 的 control_response 分支）。
            write(.obj(["type": .string("control_request"), "request_id": .string(Self.initializeRequestId),
                        "request": .obj(["subtype": .string("initialize")])]))
        }
    }

    static let initializeRequestId = "picker-initialize"

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

    /// 按换行字节切行后再解码：多字节字符被切在两个数据块之间也不会乱码。
    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { handleLine(Data(line)) }
        }
    }

    private func handleLine(_ line: Data) {
        guard let event = JSONValue.parse(line), let type = event["type"]?.stringValue else { return }
        switch type {
        case "system":
            guard event["subtype"]?.stringValue == "init" else { return }
            onEvent(.sessionInfo(.obj([
                "sessionId": event["session_id"],
                "model": event["model"],
                "permissionMode": event["permissionMode"],
                "cwd": event["cwd"],
                "cliVersion": event["claude_code_version"],
            ])))
            onEvent(.turnStarted)

        case "stream_event":
            guard event["parent_tool_use_id"]?.stringValue == nil,
                  let inner = event["event"], inner["type"]?.stringValue == "content_block_delta",
                  let delta = inner["delta"], delta["type"]?.stringValue == "text_delta",
                  let text = delta["text"]?.stringValue, !text.isEmpty else { return }
            onEvent(.delta(text))

        case "assistant":
            // 子代理的消息带 parent_tool_use_id，不进主对话。
            guard event["parent_tool_use_id"]?.stringValue == nil else { return }
            for block in event["message"]?["content"]?.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue, !text.isEmpty { onEvent(.assistantText(text)) }
                case "tool_use":
                    onEvent(.toolUse(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "",
                                     input: block["input"] ?? .null))
                default: break
                }
            }

        case "user":
            guard event["parent_tool_use_id"]?.stringValue == nil else { return }
            for block in event["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result" {
                onEvent(.toolResult(id: block["tool_use_id"]?.stringValue ?? "",
                                    isError: block["is_error"]?.boolValue ?? false,
                                    content: block["content"] ?? .null))
            }

        case "control_request":
            guard let requestId = event["request_id"]?.stringValue, let request = event["request"] else { return }
            if request["subtype"]?.stringValue == "can_use_tool" {
                onEvent(.permissionRequest(
                    requestId: requestId,
                    toolName: request["tool_name"]?.stringValue ?? "",
                    input: request["input"] ?? .null,
                    detail: .obj(["description": request["description"],
                                  "toolUseId": request["tool_use_id"],
                                  "suggestions": request["permission_suggestions"],
                                  "requiresUserInteraction": request["requires_user_interaction"]])))
            } else {
                // 不认识的控制请求明确回错误，不能让 CLI 一直等。
                write(.obj(["type": .string("control_response"),
                            "response": .obj(["subtype": .string("error"), "request_id": .string(requestId),
                                              "error": .string("unsupported control request")])]))
            }

        case "control_response":
            guard let response = event["response"], let requestId = response["request_id"]?.stringValue else { return }
            let ok = response["subtype"]?.stringValue == "success"
            if requestId == Self.initializeRequestId {
                // 握手应答是「可以发送」的确定信号；握手失败按启动失败处理（进程随后会被结束）。
                if ok, !readySent {
                    readySent = true
                    onEvent(.ready)
                } else if !ok {
                    onEvent(.controlAck(requestId: requestId, ok: false, detail: response["error"] ?? .null))
                }
                return
            }
            // 只取布尔结果与简短说明：initialize 之外的应答体也可能很大。
            onEvent(.controlAck(requestId: requestId, ok: ok, detail: ok ? .null : (response["error"] ?? .null)))

        case "result":
            onEvent(.turnResult(.obj([
                "subtype": event["subtype"],
                "isError": event["is_error"],
                "terminalReason": event["terminal_reason"],
                "stopReason": event["stop_reason"],
                "result": event["result"],
                "numTurns": event["num_turns"],
                "durationMs": event["duration_ms"],
                "costUsd": event["total_cost_usd"],
                "permissionDenials": .int(event["permission_denials"]?.arrayValue?.count ?? 0),
            ])))

        default:
            break
        }
    }

    // MARK: 写入

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
    func sendUserMessage(_ text: String) -> Bool {
        queue.sync {
            write(.obj(["type": .string("user"),
                        "message": .obj(["role": .string("user"),
                                         "content": .array([.obj(["type": .string("text"), "text": .string(text)])])])]))
        }
    }

    /// 只把答复写回给发起请求的那一条 request_id。
    @discardableResult
    func respondPermission(requestId: String, allow: Bool, updatedInput: JSONValue?, message: String?) -> Bool {
        let body: JSONValue = allow
            ? .obj(["behavior": .string("allow"), "updatedInput": updatedInput ?? .object([:])])
            : .obj(["behavior": .string("deny"), "message": .string(message ?? "用户拒绝了这次操作")])
        return queue.sync {
            write(.obj(["type": .string("control_response"),
                        "response": .obj(["subtype": .string("success"), "request_id": .string(requestId),
                                          "response": body])]))
        }
    }

    @discardableResult
    func control(subtype: String, requestId: String, extra: [String: JSONValue] = [:]) -> Bool {
        var request = extra
        request["subtype"] = .string(subtype)
        return queue.sync {
            write(.obj(["type": .string("control_request"), "request_id": .string(requestId),
                        "request": .object(request)]))
        }
    }

    @discardableResult
    func interrupt(requestId: String) -> Bool { control(subtype: "interrupt", requestId: requestId) }

    /// 结束进程：先关 stdin 让 CLI 自己收尾，超时后 SIGTERM，再超时 SIGKILL。只动自己启动的这一个进程。
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

    /// 同步结束（退出应用时用）：返回进程是否确实已经退出。
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
