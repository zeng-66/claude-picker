import Foundation

/// 设置页「MCP 服务」的能力层。
///
/// 配置来源与 Claude Code 自己的一致：
/// - 用户级：`~/.claude.json` 顶层 `mcpServers`
/// - 本地级：`~/.claude.json` 的 `projects[<项目路径>].mcpServers`
/// - 项目级：`<项目>/.mcp.json`
///
/// 不调用 `claude mcp` 命令：增删改直接读写上面三处配置（与 Claude Code 同一把
/// `~/.claude.json.lock` 目录锁、原子写回）；连接状态与工具清单由应用自己与服务握手
/// （initialize → tools/list）得到。插件 / claude.ai 连接器提供的服务不在这些配置里，这里不显示。
struct McpServerInfo: Codable, Sendable, Equatable {
    /// `<scope>:<name>`，前端用它定位服务。
    let id: String
    let name: String
    /// user / local / project / external（插件或 claude.ai 连接器提供，不能在这里增删）
    let scope: String
    /// stdio / http / sse
    let transport: String
    /// 启动命令或服务地址。
    let endpoint: String
    let description: String
    let enabled: Bool
    let removable: Bool
}

struct McpProbeResult: Codable, Sendable, Equatable {
    /// connected / failed / auth / pending / disabled
    var status: String
    var connected: Bool
    var tools: [String]
    var error: String?
}

struct McpStatusReport: Codable, Sendable, Equatable {
    var statuses: [String: String]
    /// 预留：配置文件之外的服务。不调用 CLI 后始终为空。
    var extra: [McpServerInfo]
}

struct McpService: Sendable {
    /// `CLAUDE_PICKER_CLAUDE_CONFIG` 只给回归测试用：指到临时文件，绝不改用户真实的 `~/.claude.json`。
    static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_PICKER_CLAUDE_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    static let probeTimeout: TimeInterval = 25

    // MARK: - 列表

    private struct Entry {
        let name: String
        let scope: String
        let config: [String: Any]
    }

    private static func readJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// `~/.claude.json` 里这个项目的条目。键是 claude 启动时的 cwd，原样与 realpath 两种都试。
    private static func projectEntry(_ projectPath: String, in config: [String: Any]) -> (key: String, value: [String: Any]) {
        let projects = config["projects"] as? [String: Any] ?? [:]
        let resolved = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().path
        for key in [projectPath, resolved] {
            if let value = projects[key] as? [String: Any] { return (key, value) }
        }
        return (resolved, [:])
    }

    /// 同名服务按 local > project > user 取一份（与 Claude Code 的优先级一致）。
    private static func entries(projectPath: String) -> [Entry] {
        let config = readJSON(configURL)
        let project = projectEntry(projectPath, in: config).value
        let mcpJSON = readJSON(URL(fileURLWithPath: projectPath).appendingPathComponent(".mcp.json"))
        var seen = Set<String>()
        var result: [Entry] = []
        let sources: [(String, [String: Any])] = [
            ("local", project["mcpServers"] as? [String: Any] ?? [:]),
            ("project", mcpJSON["mcpServers"] as? [String: Any] ?? [:]),
            ("user", config["mcpServers"] as? [String: Any] ?? [:]),
        ]
        for (scope, servers) in sources {
            for name in servers.keys.sorted() where !seen.contains(name) {
                guard let server = servers[name] as? [String: Any] else { continue }
                seen.insert(name)
                result.append(Entry(name: name, scope: scope, config: server))
            }
        }
        return result
    }

    private static func disabledNames(projectPath: String) -> (plain: Set<String>, mcpJSON: Set<String>) {
        let project = projectEntry(projectPath, in: readJSON(configURL)).value
        return (Set(project["disabledMcpServers"] as? [String] ?? []),
                Set(project["disabledMcpjsonServers"] as? [String] ?? []))
    }

    private static func transport(of config: [String: Any]) -> String {
        if let type = (config["type"] as? String)?.lowercased(), !type.isEmpty {
            return type == "streamable-http" ? "http" : type
        }
        return config["url"] != nil ? "http" : "stdio"
    }

    private static func endpoint(of config: [String: Any]) -> String {
        if let url = config["url"] as? String { return url }
        let command = config["command"] as? String ?? ""
        let arguments = config["args"] as? [String] ?? []
        return ([command] + arguments).joined(separator: " ")
    }

    private static let scopeText = [
        "user": "用户级配置，所有项目可用",
        "local": "本地配置，只在当前项目可用",
        "project": "项目 .mcp.json 中定义，随仓库共享",
        "external": "由插件或 claude.ai 连接器提供",
    ]

    func list(projectPath: String) -> [McpServerInfo] {
        let disabled = Self.disabledNames(projectPath: projectPath)
        return Self.entries(projectPath: projectPath).map { entry in
            let off = entry.scope == "project"
                ? disabled.mcpJSON.contains(entry.name)
                : disabled.plain.contains(entry.name)
            return McpServerInfo(id: "\(entry.scope):\(entry.name)",
                                 name: entry.name,
                                 scope: entry.scope,
                                 transport: Self.transport(of: entry.config),
                                 endpoint: Self.endpoint(of: entry.config),
                                 description: Self.scopeText[entry.scope] ?? "",
                                 enabled: !off,
                                 removable: true)
        }
    }

    // MARK: - 连接状态（应用自己握手，不调用 CLI）

    /// 逐个（并行）与已启用的服务握手。停用的服务不启动。
    func status(projectPath: String) async throws -> McpStatusReport {
        let servers = list(projectPath: projectPath)
        var report = McpStatusReport(statuses: [:], extra: [])
        await withTaskGroup(of: (String, String).self) { group in
            for server in servers {
                guard server.enabled else {
                    report.statuses[server.id] = "disabled"
                    continue
                }
                group.addTask { (server.id, await self.tools(projectPath: projectPath, id: server.id).status) }
            }
            for await (id, status) in group { report.statuses[id] = status }
        }
        return report
    }

    /// 重新连接 = 再握手一次，带回状态与工具清单。
    func reconnect(projectPath: String, id: String) async throws -> McpProbeResult {
        await tools(projectPath: projectPath, id: id)
    }

    // MARK: - 增删改

    private static func name(fromID id: String) -> String {
        guard let colon = id.firstIndex(of: ":") else { return id }
        return String(id[id.index(after: colon)...])
    }

    private static func scope(fromID id: String) -> String {
        guard let colon = id.firstIndex(of: ":") else { return "user" }
        return String(id[..<colon])
    }

    /// 命令行按空白切开，支持单 / 双引号包住带空格的参数。
    static func splitCommandLine(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character == " " || character == "\t" || character == "\n" {
                if hasToken || !current.isEmpty { parts.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
            }
        }
        if hasToken || !current.isEmpty { parts.append(current) }
        return parts
    }

    /// 新服务写到用户级配置（`~/.claude.json` 顶层 `mcpServers`），所有项目可用。
    func add(projectPath: String, name: String, transport: String, endpoint: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw GitError.commandFailed("服务名称只能包含字母、数字、- 和 _", recoverable: true)
        }
        let server: [String: Any]
        if transport.lowercased() == "http" {
            let url = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", parsed.host != nil else {
                throw GitError.commandFailed("服务地址需要是 http(s):// 开头的完整地址", recoverable: true)
            }
            server = ["type": "http", "url": url]
        } else {
            let command = Self.splitCommandLine(endpoint)
            guard let executable = command.first else {
                throw GitError.commandFailed("启动命令不能为空", recoverable: true)
            }
            server = ["type": "stdio", "command": executable, "args": Array(command.dropFirst()), "env": [String: String]()]
        }
        try Self.updateClaudeConfig { config in
            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            guard servers[trimmed] == nil else {
                throw GitError.commandFailed("已存在同名服务：\(trimmed)", recoverable: true)
            }
            servers[trimmed] = server
            config["mcpServers"] = servers
        }
        return "user:\(trimmed)"
    }

    func remove(projectPath: String, id: String) async throws {
        let name = Self.name(fromID: id)
        switch Self.scope(fromID: id) {
        case "user":
            try Self.updateClaudeConfig { config in
                var servers = config["mcpServers"] as? [String: Any] ?? [:]
                servers.removeValue(forKey: name)
                config["mcpServers"] = servers
            }
        case "local":
            try Self.updateClaudeConfig { config in
                var projects = config["projects"] as? [String: Any] ?? [:]
                var (key, entry) = Self.projectEntry(projectPath, in: config)
                var servers = entry["mcpServers"] as? [String: Any] ?? [:]
                servers.removeValue(forKey: name)
                entry["mcpServers"] = servers
                projects[key] = entry
                config["projects"] = projects
            }
        case "project":
            // .mcp.json 在仓库里、随团队共享，只删这一项，其余内容与格式尽量保持
            let file = URL(fileURLWithPath: projectPath).appendingPathComponent(".mcp.json")
            var object = Self.readJSON(file)
            var servers = object["mcpServers"] as? [String: Any] ?? [:]
            servers.removeValue(forKey: name)
            object["mcpServers"] = servers
            guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
                throw GitError.commandFailed("写入 .mcp.json 失败", recoverable: true)
            }
            do { try data.write(to: file, options: .atomic) } catch {
                throw GitError.commandFailed("写入 .mcp.json 失败", detail: error.localizedDescription)
            }
        default:
            throw GitError.commandFailed("这个服务不能在这里移除", recoverable: false)
        }
    }

    /// 启停只对当前项目生效：写 `~/.claude.json` 里项目条目的禁用名单。
    func setEnabled(projectPath: String, id: String, enabled: Bool) throws {
        let name = Self.name(fromID: id)
        let scope = Self.scope(fromID: id)
        try Self.updateClaudeConfig { config in
            var projects = config["projects"] as? [String: Any] ?? [:]
            var (key, entry) = Self.projectEntry(projectPath, in: config)
            func update(_ field: String, insert: Bool) {
                var names = entry[field] as? [String] ?? []
                names.removeAll { $0 == name }
                if insert { names.append(name) }
                entry[field] = names
            }
            if scope == "project" {
                update("disabledMcpjsonServers", insert: !enabled)
                update("enabledMcpjsonServers", insert: enabled)
            } else {
                update("disabledMcpServers", insert: !enabled)
            }
            projects[key] = entry
            config["projects"] = projects
        }
    }

    /// 改 `~/.claude.json` 的唯一入口：按 Claude Code 自己的约定先拿 `~/.claude.json.lock` 目录锁，
    /// 读最新内容、只改需要的键、原子写回，把与正在运行的 claude 互相覆盖的窗口压到最小。
    private static func updateClaudeConfig(_ mutate: (inout [String: Any]) throws -> Void) throws {
        let lock = URL(fileURLWithPath: configURL.path + ".lock")
        let manager = FileManager.default
        var locked = false
        for _ in 0..<40 {
            if (try? manager.createDirectory(at: lock, withIntermediateDirectories: false)) != nil {
                locked = true
                break
            }
            // 持有方崩溃留下的旧锁：超过 10 秒没动就接管。
            if let modified = (try? manager.attributesOfItem(atPath: lock.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > 10 {
                try? manager.removeItem(at: lock)
                continue
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard locked else {
            throw GitError.commandFailed("Claude Code 的配置文件正被占用，请稍后再试", recoverable: true)
        }
        defer { try? manager.removeItem(at: lock) }

        guard let data = try? Data(contentsOf: configURL),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitError.commandFailed("读取 ~/.claude.json 失败", recoverable: true)
        }
        try mutate(&config)
        guard let output = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else {
            throw GitError.commandFailed("写入 ~/.claude.json 失败", recoverable: true)
        }
        do {
            try output.write(to: configURL, options: .atomic)
        } catch {
            throw GitError.commandFailed("写入 ~/.claude.json 失败", detail: "\(error.localizedDescription)")
        }
    }

    // MARK: - 工具发现（MCP 握手）

    func tools(projectPath: String, id: String) async -> McpProbeResult {
        let name = Self.name(fromID: id)
        guard let entry = Self.entries(projectPath: projectPath).first(where: { $0.name == name }) else {
            return McpProbeResult(status: "failed", connected: false, tools: [],
                                  error: "应用内无法读取这个服务的配置")
        }
        let config = McpEndpoint(entry.config)
        let transport = Self.transport(of: entry.config)
        let outcome: Result<[String], McpProbeError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<[String], McpProbeError>
                switch transport {
                case "stdio":
                    result = McpProbe.stdio(config, workingDirectory: projectPath, timeout: Self.probeTimeout)
                case "http":
                    result = McpProbe.http(config, timeout: Self.probeTimeout)
                default:
                    result = .failure(McpProbeError(status: "failed", message: "这种传输方式不支持应用内探测"))
                }
                continuation.resume(returning: result)
            }
        }
        switch outcome {
        case .success(let tools):
            return McpProbeResult(status: "connected", connected: true, tools: tools, error: nil)
        case .failure(let error):
            return McpProbeResult(status: error.status, connected: false, tools: [], error: error.message)
        }
    }
}

// MARK: - 握手

struct McpProbeError: Error, Sendable {
    let status: String
    let message: String
}

/// 从 `[String: Any]` 配置里取出握手要用的字段（Sendable，可以带到后台线程）。
struct McpEndpoint: Sendable {
    let command: String
    let arguments: [String]
    let environment: [String: String]
    let url: String
    let headers: [String: String]

    init(_ config: [String: Any]) {
        command = config["command"] as? String ?? ""
        arguments = config["args"] as? [String] ?? []
        environment = config["env"] as? [String: String] ?? [:]
        url = config["url"] as? String ?? ""
        headers = config["headers"] as? [String: String] ?? [:]
    }
}

enum McpProbe {
    private static let protocolVersion = "2025-06-18"

    private static func message(_ id: Int?, _ method: String, _ params: [String: Any]? = nil) -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    }

    private static var initializeParams: [String: Any] {
        ["protocolVersion": protocolVersion,
         "capabilities": [String: Any](),
         "clientInfo": ["name": "claude-picker", "version": "1.0"]]
    }

    private static func toolNames(_ response: [String: Any]) -> [String]? {
        guard let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return nil }
        return tools.compactMap { $0["name"] as? String }
    }

    private static func errorText(_ response: [String: Any]) -> String? {
        (response["error"] as? [String: Any])?["message"] as? String
    }

    // MARK: stdio

    static func stdio(_ endpoint: McpEndpoint, workingDirectory: String,
                      timeout: TimeInterval) -> Result<[String], McpProbeError> {
        guard !endpoint.command.isEmpty else {
            return .failure(McpProbeError(status: "failed", message: "没有配置启动命令"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShellPath)
        process.arguments = ["-lc", ProcessRunner.shellCommand(executable: endpoint.command,
                                                                arguments: endpoint.arguments)]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
           isDirectory.boolValue {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in endpoint.environment { environment[key] = value }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let collector = JSONLineCollector()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { collector.finish() } else { collector.append(data) }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return .failure(McpProbeError(status: "failed", message: "启动失败：\(error.localizedDescription)"))
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        func send(_ data: Data) {
            try? input.fileHandleForWriting.write(contentsOf: data + Data([0x0a]))
        }

        send(message(1, "initialize", initializeParams))
        guard let initialized = collector.wait(forID: 1, until: deadline) else {
            return .failure(McpProbeError(status: "failed", message: "服务没有响应初始化请求"))
        }
        if let text = errorText(initialized) {
            return .failure(McpProbeError(status: "failed", message: text))
        }
        send(message(nil, "notifications/initialized"))
        send(message(2, "tools/list"))
        guard let listed = collector.wait(forID: 2, until: deadline) else {
            return .failure(McpProbeError(status: "failed", message: "服务没有返回工具清单"))
        }
        if let names = toolNames(listed) { return .success(names) }
        // 有的服务不提供 tools 能力：连接是通的，只是没有工具。
        return .success([])
    }

    // MARK: http

    static func http(_ endpoint: McpEndpoint, timeout: TimeInterval) -> Result<[String], McpProbeError> {
        guard let url = URL(string: endpoint.url) else {
            return .failure(McpProbeError(status: "failed", message: "服务地址不合法"))
        }
        var sessionID: String?

        func post(_ body: Data) -> Result<[String: Any]?, McpProbeError> {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            for (key, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: key) }
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

            let box = HTTPResultBox()
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, response, error in
                box.set(data: data, response: response as? HTTPURLResponse, error: error)
                done.signal()
            }.resume()
            guard done.wait(timeout: .now() + timeout + 2) == .success else {
                return .failure(McpProbeError(status: "failed", message: "连接超时"))
            }
            let (data, response, error) = box.get()
            if let error {
                return .failure(McpProbeError(status: "failed", message: error.localizedDescription))
            }
            guard let response else {
                return .failure(McpProbeError(status: "failed", message: "没有收到响应"))
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                return .failure(McpProbeError(status: "auth", message: "需要认证（HTTP \(response.statusCode)）"))
            }
            guard (200..<300).contains(response.statusCode) else {
                return .failure(McpProbeError(status: "failed", message: "HTTP \(response.statusCode)"))
            }
            if let id = response.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
            guard let data, !data.isEmpty else { return .success(nil) }
            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if contentType.contains("text/event-stream") {
                // SSE：逐个 `data:` 行解析，取最后一个带 result / error 的 JSON-RPC 响应。
                var found: [String: Any]?
                for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                where line.hasPrefix("data:") {
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                       object["result"] != nil || object["error"] != nil {
                        found = object
                    }
                }
                return .success(found)
            }
            return .success(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        switch post(message(1, "initialize", initializeParams)) {
        case .failure(let error): return .failure(error)
        case .success(let response):
            guard let response else {
                return .failure(McpProbeError(status: "failed", message: "服务没有响应初始化请求"))
            }
            if let text = errorText(response) {
                return .failure(McpProbeError(status: "failed", message: text))
            }
        }
        _ = post(message(nil, "notifications/initialized"))
        switch post(message(2, "tools/list")) {
        case .failure(let error): return .failure(error)
        case .success(let response):
            guard let response else { return .success([]) }
            return .success(toolNames(response) ?? [])
        }
    }
}

/// stdout 上的换行分隔 JSON-RPC 消息收集器：读线程写入，握手线程带超时等待指定 id 的响应。
private final class JSONLineCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var finished = false

    func append(_ data: Data) {
        condition.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue,
                  object["result"] != nil || object["error"] != nil else { continue }
            responses[id] = object
        }
        condition.broadcast()
        condition.unlock()
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(forID id: Int, until deadline: Date) -> [String: Any]? {
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil, !finished {
            if !condition.wait(until: deadline) { break }
        }
        return responses[id]
    }
}

private final class HTTPResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var response: HTTPURLResponse?
    private var error: Error?

    func set(data: Data?, response: HTTPURLResponse?, error: Error?) {
        lock.lock()
        self.data = data
        self.response = response
        self.error = error
        lock.unlock()
    }

    func get() -> (Data?, HTTPURLResponse?, Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, response, error)
    }
}
