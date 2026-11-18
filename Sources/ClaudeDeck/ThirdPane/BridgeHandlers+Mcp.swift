import Foundation

/// MCP 服务管理（设置 › 工具服务）。全部在后台线程执行：健康检查和握手要拉起外部进程。
enum McpHandlers: BridgeModule {
    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        guard method.hasPrefix("mcp.") else { return .unknown }
        let dict = params as? [String: Any] ?? [:]
        let provider = AgentProvider.parse(BridgeSupport.optionalString(dict, "provider"))
        let service = McpService(provider: provider)
        // 没选项目时用家目录：只看用户级配置
        let projectPath = (BridgeSupport.optionalString(dict, "projectPath")
            .map { ($0 as NSString).expandingTildeInPath }) ?? NSHomeDirectory()

        switch method {
        case "mcp.importFromClaude":
            return .handled(try service.importFromClaude(projectPath: projectPath))
        case "mcp.list":
            return .handled(try BridgeSupport.encode(service.list(projectPath: projectPath)))

        case "mcp.status":
            return .handled(try BridgeSupport.encode(BridgeSupport.blocking {
                try await service.status(projectPath: projectPath)
            }))

        case "mcp.tools":
            let id = try BridgeSupport.string(dict, "id")
            return .handled(try BridgeSupport.encode(BridgeSupport.blocking {
                await service.tools(projectPath: projectPath, id: id)
            }))

        case "mcp.reconnect":
            let id = try BridgeSupport.string(dict, "id")
            return .handled(try BridgeSupport.encode(BridgeSupport.blocking {
                try await service.reconnect(projectPath: projectPath, id: id)
            }))

        case "mcp.add":
            let name = try BridgeSupport.string(dict, "name")
            let transport = BridgeSupport.optionalString(dict, "transport") ?? "stdio"
            let endpoint = try BridgeSupport.string(dict, "endpoint")
            let id = try BridgeSupport.blocking {
                try await service.add(projectPath: projectPath, name: name,
                                      transport: transport, endpoint: endpoint)
            }
            return .handled(["id": id])

        case "mcp.remove":
            let id = try BridgeSupport.string(dict, "id")
            return try BridgeSupport.done { try await service.remove(projectPath: projectPath, id: id) }

        case "mcp.setEnabled":
            let id = try BridgeSupport.string(dict, "id")
            try service.setEnabled(projectPath: projectPath, id: id,
                                   enabled: BridgeSupport.boolean(dict, "enabled"))
            return .handled(["ok": true])

        default:
            return .unknown
        }
    }
}
