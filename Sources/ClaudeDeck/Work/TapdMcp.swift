import Foundation

/// TAPD MCP 接入：官方 `mcp-server-tapd`（stdio，经 `uvx` 启动），令牌通过 `TAPD_ACCESS_TOKEN` 只传给子进程。
///
/// 依据 2026-11-19 对 `mcp-server-tapd==8.0.81`（serverInfo `mcp-tapd 1.30.0`）的只读实测：
/// - `get_workspace_info(workspace_id)` → `data.Workspace`；
/// - `get_todo(workspace_id, entity_type, limit, page)` → `data` 数组，需求行包装在 `Story` 下、缺陷在 `Bug` 下；
/// - 工具结果的 `content[0].text` 是 TAPD OpenAPI 的 `{status, data, info}`。
/// 一键配置只做握手、工具发现与逐项目只读试读；全部成功后才一次性保存，失败时保留原配置。
enum TapdMcp {
    static let package = "mcp-server-tapd==8.0.81"
    static let defaultWebBase = "https://www.tapd.cn"

    /// 已接入场景 → 所需工具。`write` 场景只校验工具是否存在，配置阶段从不调用。
    struct Scenario: Sendable {
        var id: String
        var label: String
        var tools: [String]
        var write: Bool
    }

    static let scenarios: [Scenario] = [
        Scenario(id: "workspace", label: "项目信息", tools: ["get_workspace_info"], write: false),
        Scenario(id: "todo", label: "我的待办", tools: ["get_todo"], write: false),
        Scenario(id: "detail", label: "需求与缺陷详情", tools: ["get_stories_or_tasks", "get_bug"], write: false),
        Scenario(id: "comments", label: "读取评论", tools: ["get_comments"], write: false),
        Scenario(id: "members", label: "项目成员", tools: ["get_workspace_users"], write: false),
        Scenario(id: "commentWrite", label: "回填评论", tools: ["create_comments"], write: true),
        Scenario(id: "transition", label: "状态流转", tools: ["get_workflows_status_map", "update_story_or_task", "update_bug"], write: true),
    ]
    static let requiredTools = ["get_workspace_info", "get_todo"]

    // MARK: 输入

    /// 多个项目 ID：按换行、空格、中英文逗号、顿号、分号拆分，去重并保持顺序；非数字的单独列出。
    static func parseWorkspaceIds(_ text: String) -> (ids: [String], invalid: [String]) {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，、;；"))
        var seen = Set<String>()
        var ids: [String] = []
        var invalid: [String] = []
        for raw in text.components(separatedBy: separators) where !raw.isEmpty {
            if raw.allSatisfy(\.isASCII) && raw.allSatisfy(\.isNumber) {
                if seen.insert(raw).inserted { ids.append(raw) }
            } else if !invalid.contains(raw) {
                invalid.append(raw)
            }
        }
        return (ids, invalid)
    }

    // MARK: 服务

    struct Server: Sendable {
        var command: String
        var arguments: [String]
        var environment: [String: String]
    }

    static func defaultServerConfig() -> JSONValue {
        .obj(["command": .string("uvx"), "args": .array(["--from", package, "mcp-server-tapd"].map { .string($0) }),
              "webBase": .string(defaultWebBase)])
    }

    static func mcpConfig(_ core: WorkCore) -> JSONValue {
        TapdAdapter.settings(core)["mcp"] ?? defaultServerConfig()
    }

    static func isEnabled(_ core: WorkCore) -> Bool {
        TapdAdapter.settings(core)["transport"]?.stringValue == "mcp"
    }

    static func token(_ core: WorkCore) -> (value: String?, source: String) {
        if let token = Keychain.get(.tapdToken) { return (token, "keychain") }
        let env = LoginEnv.shared.environment
        if let token = env["TAPD_ACCESS_TOKEN"], !token.isEmpty { return (token, "env") }
        if let token = env["TAPD_TOKEN"], !token.isEmpty { return (token, "env") }
        return (nil, "none")
    }

    static func resolveCommand(_ command: String) -> String? {
        if command.hasPrefix("/") || command.hasPrefix("~") {
            let path = (command as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return LoginEnv.shared.find(command, extra: ["\(NSHomeDirectory())/.local/bin/\(command)",
                                                     "/opt/homebrew/bin/\(command)", "/usr/local/bin/\(command)"])
    }

    static func server(config: JSONValue, token: String, apiBase: String) throws -> Server {
        let command = config["command"]?.text ?? "uvx"
        guard let path = resolveCommand(command) else {
            throw McpStdioClient.Failure(stage: "launch", message: "找不到 \(command)",
                                         detail: "TAPD MCP 通过 uvx 运行官方 mcp-server-tapd。请先安装 uv（https://docs.astral.sh/uv/），或填写可执行文件路径。")
        }
        let args = (config["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        var env = LoginEnv.shared.environment.merging(ProcessInfo.processInfo.environment) { login, _ in login }
        env["TAPD_ACCESS_TOKEN"] = token
        env["TAPD_API_BASE_URL"] = apiBase
        env["TAPD_BASE_URL"] = config["webBase"]?.text ?? defaultWebBase
        return Server(command: path, arguments: args.isEmpty ? ["--from", package, "mcp-server-tapd"] : args, environment: env)
    }

    static func connect(_ server: Server, timeout: TimeInterval = 120) throws -> McpStdioClient {
        let client = McpStdioClient(command: server.command, arguments: server.arguments, environment: server.environment)
        try client.start(timeout: timeout)
        return client
    }

    /// 工具结果 → TAPD `data`。服务端报错、TAPD 拒绝或无法解析时抛出。
    static func decode(_ result: JSONValue, tool: String) throws -> JSONValue {
        let text = (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
        if result["isError"]?.boolValue == true {
            throw McpStdioClient.Failure(stage: "call", message: "\(tool) 调用失败", detail: WorkText.redact(String(text.prefix(400))))
        }
        if let structured = result["structuredContent"], !structured.isNull, structured["status"] != nil {
            return try unwrap(structured, tool: tool, raw: text)
        }
        guard let json = JSONValue.parse(text) else {
            throw McpStdioClient.Failure(stage: "call", message: "\(tool) 返回了无法解析的内容",
                                         detail: WorkText.redact(String(text.prefix(400))))
        }
        return try unwrap(json, tool: tool, raw: text)
    }

    private static func unwrap(_ json: JSONValue, tool: String, raw: String) throws -> JSONValue {
        if let status = json["status"] {
            guard status.intValue == 1 || status.stringValue == "1" else {
                throw McpStdioClient.Failure(stage: "call", message: "TAPD 拒绝了 \(tool)",
                                             detail: json["info"]?.text ?? WorkText.redact(String(raw.prefix(300))))
            }
            return json["data"] ?? .null
        }
        return json["data"] ?? json
    }

    // MARK: 一键配置

    /// 只读试查：握手 → 工具发现 → 逐项目 `get_workspace_info` 与 `get_todo(limit=1)`。
    /// 全部通过才写入设置：新项目默认启用，已有项目保留启停与仓库映射；`token` 非空时存进钥匙串。
    static func setup(_ core: WorkCore, idsText: String, token newToken: String?, server overrides: JSONValue?) throws -> JSONValue {
        func report(_ stage: String, ok: Bool, message: String, detail: String? = nil,
                    projects: [JSONValue] = [], tools: [String] = []) -> JSONValue {
            .obj([
                "ok": .bool(ok), "stage": .string(stage), "message": .string(message), "detail": .str(detail),
                "projects": .array(projects),
                "scenarios": .array(scenarioReport(tools: Set(tools))),
                "checkedAt": .string(WorkClock.iso()),
            ])
        }
        let parsed = parseWorkspaceIds(idsText)
        guard parsed.invalid.isEmpty else {
            return report("input", ok: false, message: "项目 ID 只能是数字", detail: parsed.invalid.joined(separator: "、"))
        }
        guard !parsed.ids.isEmpty else { return report("input", ok: false, message: "请填写至少一个 TAPD 项目 ID") }

        let trimmedToken = newToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = (trimmedToken?.isEmpty == false ? trimmedToken : nil) ?? self.token(core).value else {
            return report("credential", ok: false, message: "还没有 TAPD 个人令牌", detail: "在 TAPD「个人设置 → 个人令牌」生成后填入，保存在钥匙串。")
        }
        var config = mcpConfig(core).objectValue ?? [:]
        if case .object(let patch)? = overrides {
            for (key, value) in patch where ["command", "args", "webBase"].contains(key) { config[key] = value }
        }
        let apiBase = TapdAdapter.credentials(core).endpoint
        let client: McpStdioClient
        do {
            client = try connect(try server(config: .object(config), token: token, apiBase: apiBase))
        } catch let failure as McpStdioClient.Failure {
            return report(failure.stage, ok: false, message: failure.message, detail: failure.detail)
        }
        defer { client.close() }

        let tools: [McpStdioClient.Tool]
        do { tools = try client.listTools() } catch let failure as McpStdioClient.Failure {
            return report("tools", ok: false, message: failure.message, detail: failure.detail)
        }
        let names = tools.map(\.name)
        let missing = requiredTools.filter { !names.contains($0) }
        guard missing.isEmpty else {
            return report("tools", ok: false, message: "MCP 服务缺少必需工具", detail: missing.joined(separator: "、"), tools: names)
        }

        var results: [JSONValue] = []
        var allOk = true
        for id in parsed.ids {
            var name: String?
            do {
                let info = try decode(try client.callTool("get_workspace_info", arguments: .obj(["workspace_id": .string(id)])),
                                      tool: "get_workspace_info")
                let workspace = info["Workspace"] ?? info
                guard workspace["id"]?.text == id || workspace["id"]?.intValue.map(String.init) == id else {
                    throw McpStdioClient.Failure(stage: "project", message: "没有读到项目 \(id) 的信息", detail: nil)
                }
                name = workspace["name"]?.text
                let todo = try decode(try client.callTool("get_todo", arguments: .obj([
                    "workspace_id": .string(id), "entity_type": .string("story"), "limit": .int(1), "page": .int(1),
                ])), tool: "get_todo")
                guard todo.arrayValue != nil || todo.isNull else {
                    throw McpStdioClient.Failure(stage: "project", message: "待办返回格式不符合预期", detail: nil)
                }
                results.append(.obj(["id": .string(id), "name": .str(name), "ok": .bool(true)]))
            } catch let failure as McpStdioClient.Failure {
                allOk = false
                results.append(.obj(["id": .string(id), "name": .str(name), "ok": .bool(false),
                                     "message": .string(failure.message), "detail": .str(failure.detail)]))
            }
        }
        guard allOk else {
            let failed = results.filter { $0["ok"]?.boolValue != true }.compactMap { $0["id"]?.text }
            return report("project", ok: false, message: "\(failed.count) 个项目试读失败，配置未保存",
                          detail: failed.joined(separator: "、"), projects: results, tools: names)
        }

        // 一次保存：凭据进钥匙串，设置里只留服务启动方式与项目列表。
        if let trimmedToken, !trimmedToken.isEmpty { try Keychain.set(.tapdToken, trimmedToken) }
        var settings = TapdAdapter.settings(core).objectValue ?? [:]
        var workspaces = settings["workspaces"]?.arrayValue ?? []
        for result in results {
            guard let id = result["id"]?.text else { continue }
            if let index = workspaces.firstIndex(where: { $0["id"]?.text == id }) {
                if case .object(var existing) = workspaces[index], let name = result["name"]?.text {
                    existing["name"] = .string(name)
                    workspaces[index] = .object(existing)
                }
            } else {
                workspaces.append(.obj(["id": .string(id), "name": .string(result["name"]?.text ?? id),
                                        "enabled": .bool(true), "projects": .array([])]))
            }
        }
        settings["workspaces"] = .array(workspaces)
        settings["transport"] = .string("mcp")
        settings["enabled"] = .bool(true)
        settings["mcp"] = .object(config)
        settings["mcpTools"] = .array(names.map { .string($0) })
        settings["mcpCheckedAt"] = .string(WorkClock.iso())
        try core.putSetting("tapd", .object(settings))
        return report("saved", ok: true, message: "已验证 \(results.count) 个项目并保存", projects: results, tools: names)
    }

    static func scenarioReport(tools: Set<String>) -> [JSONValue] {
        scenarios.map { scenario in
            let missing = scenario.tools.filter { !tools.contains($0) }
            return .obj(["id": .string(scenario.id), "label": .string(scenario.label), "write": .bool(scenario.write),
                         "available": .bool(!tools.isEmpty && missing.isEmpty),
                         "missing": .array(missing.map { .string($0) })])
        }
    }

    // MARK: 运行时读取

    /// 「我的待办」：每个项目读需求与缺陷。MCP 的 get_todo 以令牌身份筛选，只支持本人待办。
    static func todos(_ core: WorkCore, workspaceIds: [String], page: Int) throws -> JSONValue {
        guard let token = token(core).value else {
            throw TapdAdapter.Failure(message: "还没有 TAPD 个人令牌", detail: "请在设置的「TAPD 连接」里一键配置 MCP。")
        }
        let client: McpStdioClient
        do {
            client = try connect(try server(config: mcpConfig(core), token: token, apiBase: TapdAdapter.credentials(core).endpoint))
        } catch let failure as McpStdioClient.Failure {
            throw TapdAdapter.Failure(message: failure.message, detail: failure.detail)
        }
        defer { client.close() }
        let names = Dictionary(uniqueKeysWithValues: (TapdAdapter.settings(core)["workspaces"]?.arrayValue ?? []).compactMap { item -> (String, String)? in
            guard let id = item["id"]?.text else { return nil }
            return (id, item["name"]?.text ?? id)
        })
        var items: [JSONValue] = []
        var errors: [JSONValue] = []
        var hasMore = false
        for workspace in workspaceIds {
            for (type, wrapper) in [("story", "Story"), ("bug", "Bug")] {
                do {
                    let data = try decode(try client.callTool("get_todo", arguments: .obj([
                        "workspace_id": .string(workspace), "entity_type": .string(type),
                        "limit": .int(TapdAdapter.pageSize), "page": .int(page),
                    ])), tool: "get_todo")
                    var rows = (data.arrayValue ?? []).compactMap { $0[wrapper] ?? $0 }
                    if rows.count >= TapdAdapter.pageSize { hasMore = true }
                    rows = enrich(rows, client: client, workspace: workspace, type: type, wrapper: wrapper)
                    items += rows.compactMap { TapdAdapter.todoSummary($0, type: type, workspaceName: names[workspace]) }
                } catch let failure as McpStdioClient.Failure {
                    errors.append(.obj(["workspaceId": .string(workspace), "message": .string(failure.message),
                                        "detail": .str(failure.detail)]))
                }
            }
        }
        var seen = Set<String>()
        items = items.filter { seen.insert($0["ref"]?.serialized() ?? UUID().uuidString).inserted }
        items.sort { ($0["modified"]?.stringValue ?? "") > ($1["modified"]?.stringValue ?? "") }
        return .obj(["items": .array(items), "page": .int(page), "hasMore": .bool(hasMore),
                     "user": .null, "errors": .array(errors), "fetchedAt": .string(WorkClock.iso()),
                     "byId": .bool(false), "transport": .string("mcp")])
    }

    /// `get_todo` 只返回 id、标题、优先级、状态键与创建人（2026-11-19 实测）。按 ID 批量读详情补处理人、迭代与时间，
    /// 用工作流状态表把状态键翻成名称，再读迭代名。都是只读查询，任何一步失败都保留已有字段。
    static func enrich(_ rows: [JSONValue], client: McpStdioClient, workspace: String, type: String, wrapper: String) -> [JSONValue] {
        guard !rows.isEmpty else { return rows }
        var merged = rows.compactMap(\.objectValue)
        let ids = merged.compactMap { $0["id"]?.text }
        let isBug = type == "bug"
        let fields = isBug
            ? "id,current_owner,reporter,iteration_id,created,modified,begin,due,deadline,severity,priority,status"
            : "id,owner,creator,iteration_id,created,modified,begin,due,priority,status"
        if let detail = try? decode(try client.callTool(isBug ? "get_bug" : "get_stories_or_tasks", arguments: .obj([
            "workspace_id": .string(workspace),
            "options": .obj(["entity_type": .str(isBug ? nil : "stories"), "id": .string(ids.joined(separator: ",")),
                             "fields": .string(fields), "limit": .int(ids.count)]),
        ])), tool: isBug ? "get_bug" : "get_stories_or_tasks") {
            let byId = Dictionary((detail.arrayValue ?? []).compactMap { ($0[wrapper] ?? $0).objectValue }
                .compactMap { row in row["id"]?.text.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
            for index in merged.indices {
                guard let id = merged[index]["id"]?.text, let extra = byId[id] else { continue }
                for (key, value) in extra where merged[index][key]?.text == nil { merged[index][key] = value }
            }
        }
        let statusMap = try? decode(try client.callTool("get_workflows_status_map", arguments: .obj([
            "workspace_id": .string(workspace), "options": .obj(["system": .string(isBug ? "bug" : "story")]),
        ])), tool: "get_workflows_status_map")
        if let map = statusMap?.objectValue {
            for index in merged.indices where merged[index]["v_status"]?.text == nil {
                if let key = merged[index]["status"]?.text, let label = map[key]?.text { merged[index]["v_status"] = .string(label) }
            }
        }
        let iterationIds = Array(Set(merged.compactMap { $0["iteration_id"]?.text }.filter { $0 != "0" }))
        if !iterationIds.isEmpty, let data = try? decode(try client.callTool("get_iterations", arguments: .obj([
            "workspace_id": .string(workspace),
            "options": .obj(["id": .string(iterationIds.joined(separator: ",")), "fields": .string("id,name"),
                             "limit": .int(iterationIds.count)]),
        ])), tool: "get_iterations") {
            let names = Dictionary((data.arrayValue ?? []).compactMap { ($0["Iteration"] ?? $0).objectValue }
                .compactMap { row -> (String, String)? in
                    guard let id = row["id"]?.text, let name = row["name"]?.text else { return nil }
                    return (id, name)
                }, uniquingKeysWith: { first, _ in first })
            for index in merged.indices {
                if let id = merged[index]["iteration_id"]?.text, let name = names[id] { merged[index]["iteration_name"] = .string(name) }
            }
        }
        return merged.map { .object($0) }
    }

    /// 重新检测：握手 + 工具发现，不调用任何读写工具。
    static func test(_ core: WorkCore) -> JSONValue {
        guard let token = token(core).value else {
            return .obj(["connected": .bool(false), "message": .string("还没有 TAPD 个人令牌"), "checkedAt": .string(WorkClock.iso())])
        }
        do {
            let client = try connect(try server(config: mcpConfig(core), token: token, apiBase: TapdAdapter.credentials(core).endpoint))
            defer { client.close() }
            let names = try client.listTools().map(\.name)
            let missing = requiredTools.filter { !names.contains($0) }
            return .obj([
                "connected": .bool(missing.isEmpty),
                "transport": .string("mcp"),
                "server": client.serverInfo,
                "message": .str(missing.isEmpty ? nil : "缺少工具：\(missing.joined(separator: "、"))"),
                "scenarios": .array(scenarioReport(tools: Set(names))),
                "checkedAt": .string(WorkClock.iso()),
            ])
        } catch let failure as McpStdioClient.Failure {
            return .obj(["connected": .bool(false), "transport": .string("mcp"), "message": .string(failure.message),
                         "detail": .str(failure.detail), "checkedAt": .string(WorkClock.iso())])
        } catch {
            return .obj(["connected": .bool(false), "message": .string("\(error)"), "checkedAt": .string(WorkClock.iso())])
        }
    }
}
