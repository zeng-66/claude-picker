import Foundation

/// SPEC §11.1 的错误码。字面量就是桥信封里 `error.code` 的取值，不要改名。
enum GitErrorCode: String, Codable, Sendable, CaseIterable {
    case notARepository = "NOT_A_REPOSITORY"
    case detachedHead = "DETACHED_HEAD"
    case branchExists = "BRANCH_EXISTS"
    case worktreePathExists = "WORKTREE_PATH_EXISTS"
    case dirtyWorktree = "DIRTY_WORKTREE"
    case mergeConflict = "MERGE_CONFLICT"
    case permissionDenied = "PERMISSION_DENIED"
    case commandFailed = "COMMAND_FAILED"
}

/// 能力层唯一的错误类型。字段与 SPEC §11.1 的 `GitError` 一一对应，
/// T3 直接 `JSONEncoder().encode(error)` 就能塞进 `{id, ok:false, error:{...}}` 信封。
struct GitError: Error, Codable, Sendable, Equatable {
    let code: GitErrorCode
    let message: String
    /// stderr 原文；没有子进程输出的错误留 nil。
    let detail: String?
    let recoverable: Bool

    init(code: GitErrorCode, message: String, detail: String? = nil, recoverable: Bool = false) {
        self.code = code
        self.message = message
        self.detail = detail
        self.recoverable = recoverable
    }

    // MARK: - 常用构造

    static func notARepository(_ path: String, detail: String? = nil) -> GitError {
        GitError(code: .notARepository, message: "不是 Git 仓库：\(path)", detail: detail)
    }

    static func detachedHead(detail: String? = nil) -> GitError {
        GitError(code: .detachedHead, message: "当前处于 detached HEAD，没有分支名", detail: detail)
    }

    static func branchExists(_ branch: String, detail: String? = nil) -> GitError {
        GitError(code: .branchExists, message: "分支已存在：\(branch)", detail: detail)
    }

    static func worktreePathExists(_ path: String, detail: String? = nil) -> GitError {
        GitError(code: .worktreePathExists, message: "Worktree 路径已存在：\(path)", detail: detail)
    }

    static func dirtyWorktree(_ detail: String?) -> GitError {
        GitError(code: .dirtyWorktree, message: "工作区有未提交变更", detail: detail, recoverable: true)
    }

    static func mergeConflict(_ detail: String?) -> GitError {
        GitError(code: .mergeConflict, message: "存在未解决的合并冲突", detail: detail, recoverable: true)
    }

    static func permissionDenied(_ message: String) -> GitError {
        GitError(code: .permissionDenied, message: message)
    }

    static func commandFailed(_ message: String, detail: String? = nil, recoverable: Bool = true) -> GitError {
        GitError(code: .commandFailed, message: message, detail: detail, recoverable: recoverable)
    }

    /// 本卡只定签名、由后续卡片填实现的写操作。错误码受 SPEC 约束只有 8 个，
    /// 因此复用 COMMAND_FAILED，用固定前缀让前端/日志能识别。
    static func notImplemented(_ feature: String) -> GitError {
        GitError(code: .commandFailed,
                 message: "尚未实现：\(feature)（后续任务卡补全）",
                 detail: nil,
                 recoverable: false)
    }
}
