import Foundation

/// CLI 引擎目录的安装与维护（`cli.*`）：可安装条目、白名单安装、DeepSeek Harness 巡检与升级。
/// 都会启动子进程，在后台线程执行（见 `Bridge.runsInBackground`）。
enum CliHandlers: BridgeModule {
    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        let dict = params as? [String: Any] ?? [:]
        switch method {
        case "cli.installables":
            return .handled(CliMaintenance.catalog().any)
        case "cli.install":
            let id = try BridgeSupport.string(dict, "id")
            return .handled(try CliMaintenance.install(id: id).any)
        case "cli.deepseekCheck":
            return .handled(CliMaintenance.deepseekCheck().any)
        case "cli.deepseekUpgrade":
            let result = CliMaintenance.deepseekUpgrade()
            try BridgeSupport.onMain { try AppHandlers.delegate().store.noteDeepSeekReport(result["report"] ?? .null) }
            return .handled(result.any)
        case "cli.deepseekDismiss":
            let signature = BridgeSupport.optionalString(dict, "signature") ?? ""
            try BridgeSupport.onMain { try AppHandlers.delegate().store.dismissDeepSeek(signature: signature) }
            return .handled(NSNull())
        default:
            return .unknown
        }
    }
}
