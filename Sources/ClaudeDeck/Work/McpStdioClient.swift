import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 最小的 MCP stdio 客户端：启动服务进程，`initialize` → `notifications/initialized` → `tools/list` / `tools/call`。
/// 按行收发 JSON-RPC 2.0。全部是同步调用（带超时），只能在后台线程使用。凭据只放在子进程环境里，不写日志。
final class McpStdioClient: @unchecked Sendable {
    struct Failure: Error, Sendable {
        var stage: String
        var message: String
        var detail: String?
    }

    struct Tool: Sendable {
        var name: String
        var required: [String]
    }

    static let protocolVersion = "2025-06-18"

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: JSONValue] = [:]
    private var stderrTail = Data()
    private var exited = false
    private var nextId = 1
    private(set) var serverInfo: JSONValue = .null

    init(command: String, arguments: [String], environment: [String: String], cwd: String = NSHomeDirectory()) {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    deinit { close() }

    var stderrText: String {
        condition.lock(); defer { condition.unlock() }
        return WorkText.redact(String(decoding: stderrTail, as: UTF8.self))
    }

    /// 启动并完成握手。`timeout` 覆盖首次启动时包管理器下载服务的耗时。
    func start(timeout: TimeInterval) throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.receive(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.condition.lock()
            self.stderrTail.append(data)
            if self.stderrTail.count > 8192 { self.stderrTail = self.stderrTail.suffix(8192) }
            self.condition.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.condition.lock()
            self.exited = true
            self.condition.broadcast()
            self.condition.unlock()
        }
        do {
            try process.run()
        } catch {
            throw Failure(stage: "launch", message: "无法启动 MCP 服务", detail: error.localizedDescription)
        }
        let response = try request("initialize", params: .obj([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .obj(["name": .string("claude-picker"), "version": .string("1.0")]),
        ]), timeout: timeout, stage: "handshake")
        serverInfo = response["serverInfo"] ?? .null
        try notify("notifications/initialized")
    }

    func listTools(timeout: TimeInterval = 30) throws -> [Tool] {
        let result = try request("tools/list", params: .object([:]), timeout: timeout, stage: "tools")
        return (result["tools"]?.arrayValue ?? []).compactMap { tool in
            guard let name = tool["name"]?.text else { return nil }
            let required = (tool["inputSchema"]?["required"]?.arrayValue ?? []).compactMap(\.stringValue)
            return Tool(name: name, required: required)
        }
    }

    /// 调用工具，返回 `result`（含 `content` / `isError`）。
    func callTool(_ name: String, arguments: JSONValue, timeout: TimeInterval = 45) throws -> JSONValue {
        try request("tools/call", params: .obj(["name": .string(name), "arguments": arguments]), timeout: timeout, stage: "call")
    }

    func close() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(30_000) }
        if process.isRunning, pid > 0 { kill(pid, SIGKILL) }
    }

    // MARK: 收发

    private func receive(_ data: Data) {
        condition.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = JSONValue.parse(Data(line)), let id = message["id"]?.intValue,
               message["method"] == nil {
                responses[id] = message
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    private func write(_ value: JSONValue) throws {
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data((value.serialized() + "\n").utf8))
        } catch {
            throw Failure(stage: "io", message: "MCP 服务已断开", detail: stderrText.suffix(400).description)
        }
    }

    private func notify(_ method: String) throws {
        try write(.obj(["jsonrpc": .string("2.0"), "method": .string(method)]))
    }

    private func request(_ method: String, params: JSONValue, timeout: TimeInterval, stage: String) throws -> JSONValue {
        condition.lock()
        let id = nextId
        nextId += 1
        condition.unlock()
        try write(.obj(["jsonrpc": .string("2.0"), "id": .int(id), "method": .string(method), "params": params]))
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil && !exited {
            if !condition.wait(until: deadline) { break }
        }
        guard let response = responses.removeValue(forKey: id) else {
            let tail = WorkText.redact(String(decoding: stderrTail.suffix(600), as: UTF8.self))
            throw Failure(stage: stage, message: exited ? "MCP 服务意外退出" : "MCP 服务响应超时",
                          detail: tail.isEmpty ? nil : tail)
        }
        if let error = response["error"], !error.isNull {
            throw Failure(stage: stage, message: error["message"]?.text ?? "MCP 请求失败", detail: error.serialized())
        }
        return response["result"] ?? .null
    }
}
