import Foundation

// Work 领域模型。Work / Run / Session / 来源对话各有自己的身份，互不代替。

enum WorkStatus: String, Sendable, CaseIterable {
    case queued, running
    case waitingUser = "waiting_user"
    case waitingReview = "waiting_review"
    case failed, interrupted, completed, cancelled

    /// 已结束：不会再被调度，也不接受执行类命令（重试除外）。
    var isTerminal: Bool { self == .completed || self == .cancelled }
    var label: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "执行中"
        case .waitingUser: return "待回答"
        case .waitingReview: return "待审阅"
        case .failed: return "失败"
        case .interrupted: return "已中断"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        }
    }
}

enum RunStatus: String, Sendable {
    case preparing, running
    case waitingUser = "waiting_user"
    case waitingReview = "waiting_review"
    case failed, interrupted, completed, cancelled, superseded

    var isLive: Bool { self == .preparing || self == .running || self == .waitingUser }
}

enum WorkOrigin: String, Sendable {
    case local, tapd, wecom
}

enum DeliveryStatus: String, Sendable {
    case notRequested = "not_requested"
    case pending, sent, unknown, failed
}

enum AttentionKind: String, Sendable {
    case question       // 业务问题（AskUserQuestion）
    case permission     // 工具权限请求
}

enum AttentionStatus: String, Sendable {
    case open, answered, expired, cancelled
}

struct TapdRef: Sendable, Equatable, Hashable {
    let workspaceId: String
    let entityType: String      // story | task | bug
    let entityId: String        // 完整 ID，不用页面短号

    var json: JSONValue {
        .object(["workspaceId": .string(workspaceId), "entityType": .string(entityType), "entityId": .string(entityId)])
    }

    init(workspaceId: String, entityType: String, entityId: String) {
        self.workspaceId = workspaceId
        self.entityType = entityType
        self.entityId = entityId
    }

    init?(json: JSONValue?) {
        guard let workspaceId = json?["workspaceId"]?.text,
              let entityType = json?["entityType"]?.text,
              let entityId = json?["entityId"]?.text,
              ["story", "task", "bug"].contains(entityType) else { return nil }
        self.init(workspaceId: workspaceId, entityType: entityType, entityId: entityId)
    }
}

struct WorkProject: Sendable, Equatable {
    let id: String
    let path: String        // 规范化（解析过符号链接）的根目录
    let name: String
    let available: Bool

    init(id: String, path: String, name: String, available: Bool) {
        self.id = id
        self.path = path
        self.name = name
        self.available = available
    }

    init(row: DBRow) {
        id = row.text("id")
        path = row.text("path")
        name = row.text("name")
        available = row.bool("available")
    }

    var json: JSONValue {
        .object(["id": .string(id), "path": .string(path), "name": .string(name), "available": .bool(available)])
    }
}

struct Work: Sendable {
    let id: String
    let displayId: String
    let projectId: String
    var title: String
    var objective: String
    var scope: String
    let origin: WorkOrigin
    let sourceConversationId: String?
    let sourceEventId: String?
    var status: WorkStatus
    var startRequested: Bool
    var currentRunId: String?
    var attentionId: String?
    var sessionId: String?
    var isolation: String           // worktree | project
    var workspacePath: String?
    var branch: String?
    var baseCommit: String?
    var permissionMode: String?
    var model: String?
    var unread: Bool
    var archived: Bool
    var statusReason: String?
    var revision: Int
    let createdAt: String
    var updatedAt: String
    var queuedAt: String?

    init(row: DBRow) {
        id = row.text("id")
        displayId = row.text("display_id")
        projectId = row.text("project_id")
        title = row.text("title")
        objective = row.text("objective")
        scope = row.text("scope")
        origin = WorkOrigin(rawValue: row.text("origin")) ?? .local
        sourceConversationId = row.string("source_conversation_id")
        sourceEventId = row.string("source_event_id")
        status = WorkStatus(rawValue: row.text("status")) ?? .failed
        startRequested = row.bool("start_requested")
        currentRunId = row.string("current_run_id")
        attentionId = row.string("attention_id")
        sessionId = row.string("session_id")
        isolation = row.string("isolation") ?? "worktree"
        workspacePath = row.string("workspace_path")
        branch = row.string("branch")
        baseCommit = row.string("base_commit")
        permissionMode = row.string("permission_mode")
        model = row.string("model")
        unread = row.bool("unread")
        archived = row.bool("archived")
        statusReason = row.string("status_reason")
        revision = row.int("revision") ?? 1
        createdAt = row.text("created_at")
        updatedAt = row.text("updated_at")
        queuedAt = row.string("queued_at")
    }

    var json: JSONValue {
        .obj([
            "id": .string(id),
            "displayId": .string(displayId),
            "projectId": .string(projectId),
            "title": .string(title),
            "objective": .string(objective),
            "scope": .string(scope),
            "origin": .string(origin.rawValue),
            "sourceConversationId": .str(sourceConversationId),
            "sourceEventId": .str(sourceEventId),
            "status": .string(status.rawValue),
            "statusLabel": .string(status.label),
            "startRequested": .bool(startRequested),
            "currentRunId": .str(currentRunId),
            "attentionId": .str(attentionId),
            "sessionId": .str(sessionId),
            "isolation": .string(isolation),
            "workspacePath": .str(workspacePath),
            "branch": .str(branch),
            "baseCommit": .str(baseCommit),
            "permissionMode": .str(permissionMode),
            "model": .str(model),
            "unread": .bool(unread),
            "archived": .bool(archived),
            "statusReason": .str(statusReason),
            "revision": .int(revision),
            "createdAt": .string(createdAt),
            "updatedAt": .string(updatedAt),
        ])
    }
}

struct WorkRun: Sendable {
    let id: String
    let workId: String
    let attempt: Int
    var sessionId: String?
    var workspacePath: String?
    var status: RunStatus
    var baseCommit: String?
    var reviewedCommit: String?
    var reviewedTree: String?
    var pid: Int?
    var exitCode: Int?
    var error: String?
    var startedAt: String?
    var endedAt: String?
    let createdAt: String

    init(row: DBRow) {
        id = row.text("id")
        workId = row.text("work_id")
        attempt = row.int("attempt") ?? 1
        sessionId = row.string("session_id")
        workspacePath = row.string("workspace_path")
        status = RunStatus(rawValue: row.text("status")) ?? .failed
        baseCommit = row.string("base_commit")
        reviewedCommit = row.string("reviewed_commit")
        reviewedTree = row.string("reviewed_tree")
        pid = row.int("pid")
        exitCode = row.int("exit_code")
        error = row.string("error")
        startedAt = row.string("started_at")
        endedAt = row.string("ended_at")
        createdAt = row.text("created_at")
    }

    var json: JSONValue {
        .obj([
            "id": .string(id),
            "workId": .string(workId),
            "attempt": .int(attempt),
            "sessionId": .str(sessionId),
            "workspacePath": .str(workspacePath),
            "executor": .string("claude"),
            "status": .string(status.rawValue),
            "baseCommit": .str(baseCommit),
            "reviewedCommit": .str(reviewedCommit),
            "reviewedTree": .str(reviewedTree),
            "exitCode": .int(exitCode),
            "error": .str(error),
            "startedAt": .str(startedAt),
            "endedAt": .str(endedAt),
            "createdAt": .string(createdAt),
        ])
    }
}

struct WorkAttention: Sendable {
    let id: String
    let workId: String
    let runId: String
    let kind: AttentionKind
    let requestId: String       // 执行器的控制请求 ID：答复只回给这一条请求
    let toolName: String
    let title: String
    let body: JSONValue         // 问题与选项 / 工具参数
    var status: AttentionStatus
    var answer: JSONValue?
    var revision: Int
    let createdAt: String
    var answeredAt: String?

    init(row: DBRow) {
        id = row.text("id")
        workId = row.text("work_id")
        runId = row.text("run_id")
        kind = AttentionKind(rawValue: row.text("kind")) ?? .permission
        requestId = row.text("request_id")
        toolName = row.text("tool_name")
        title = row.text("title")
        body = row.json("body_json") ?? .null
        status = AttentionStatus(rawValue: row.text("status")) ?? .expired
        answer = row.json("answer_json")
        revision = row.int("revision") ?? 1
        createdAt = row.text("created_at")
        answeredAt = row.string("answered_at")
    }

    var json: JSONValue {
        .obj([
            "id": .string(id),
            "workId": .string(workId),
            "runId": .string(runId),
            "kind": .string(kind.rawValue),
            "toolName": .string(toolName),
            "title": .string(title),
            "body": body,
            "status": .string(status.rawValue),
            "answer": answer ?? .null,
            "revision": .int(revision),
            "createdAt": .string(createdAt),
            "answeredAt": .str(answeredAt),
        ])
    }
}

/// 宿主给来源侧（WorkBuddy）的目录判定契约：projectId 只能指向宿主已登记的项目。
struct WorkIntent: Sendable {
    var objective: String
    var title: String?
    var projectId: String?
    var relatedWorkId: String?
    var resolution: String          // resolved | needs_clarification
    var evidence: [String]
    var question: String?
}
