import Foundation

/// 会话操作。方法名对齐 `Web/src/bridge/protocol.js` 的 METHODS。
///
/// T10 卡（task-11）接 `session.create`（基于当前分支）；
/// T11 卡（task-12）接 worktree 模式与失败恢复。
enum SessionHandlers: BridgeModule {
    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        switch method {
        // T10 / T11 在这里追加 case，未列出的方法落到 .unknown。
        default:
            return .unknown
        }
    }
}
