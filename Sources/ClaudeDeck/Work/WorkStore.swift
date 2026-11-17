import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Work 数据库：表结构、迁移与仓储方法。只在 WorkCore 的串行队列上调用。
///
/// 主领域状态只存在这里，不放在 WebView 的 localStorage 里。迁移前先备份；
/// 打开比自己新的库时拒绝写入，不破坏既有数据。
final class WorkStore: @unchecked Sendable {
    static let schemaVersion = 1

    let db: SQLiteDB
    let directory: URL
    /// 状态目录的独占锁：同一目录只允许一个实例调度（见 `acquireOwnership`）。
    private var lockFD: Int32 = -1
    private(set) var isOwner = false

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("work.sqlite3").path
        db = try SQLiteDB(path: path)
        acquireOwnership()
        try migrate(path: path)
    }

    deinit {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }

    /// 拿不到锁说明另一个实例正在管理同一个状态目录：本实例只读，不调度、不接受写命令。
    private func acquireOwnership() {
        let lockPath = directory.appendingPathComponent("owner.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            isOwner = true
            let stamp = "\(getpid())\n"
            ftruncate(fd, 0)
            _ = stamp.withCString { write(fd, $0, strlen($0)) }
        } else {
            close(fd)
        }
    }

    // MARK: 迁移

    private func migrate(path: String) throws {
        let current = db.userVersion
        if current > Self.schemaVersion {
            throw WorkError.unavailable("Work 数据库由更新的版本创建（结构版本 \(current)），当前版本只支持到 \(Self.schemaVersion)。数据未被修改，请升级应用。")
        }
        guard current < Self.schemaVersion else { return }
        guard isOwner else { return }
        if current > 0 {
            // 升级前留一份备份；失败时原库不动，备份路径写进错误信息。
            let backup = path + ".v\(current).bak"
            try? FileManager.default.removeItem(atPath: backup)
            try db.exec("VACUUM INTO '\(backup.replacingOccurrences(of: "'", with: "''"))'")
        }
        try db.transaction {
            if current < 1 { try db.exec(Self.schemaV1) }
        }
        db.userVersion = Self.schemaVersion
    }

    private static let schemaV1 = """
    CREATE TABLE projects(
        id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
        available INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE counters(name TEXT PRIMARY KEY, value INTEGER NOT NULL);
    CREATE TABLE works(
        id TEXT PRIMARY KEY, display_id TEXT NOT NULL UNIQUE,
        project_id TEXT NOT NULL REFERENCES projects(id),
        title TEXT NOT NULL, objective TEXT NOT NULL, scope TEXT NOT NULL DEFAULT '',
        origin TEXT NOT NULL, source_conversation_id TEXT, source_event_id TEXT,
        status TEXT NOT NULL, start_requested INTEGER NOT NULL DEFAULT 0,
        current_run_id TEXT, attention_id TEXT, session_id TEXT,
        isolation TEXT NOT NULL DEFAULT 'worktree', workspace_path TEXT, branch TEXT, base_commit TEXT,
        permission_mode TEXT, model TEXT,
        unread INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
        status_reason TEXT, idempotency_key TEXT UNIQUE,
        revision INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, queued_at TEXT);
    CREATE INDEX works_status ON works(status);
    CREATE INDEX works_project ON works(project_id);
    CREATE TABLE work_tapd_refs(
        work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
        workspace_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '', business_status TEXT,
        snapshot_hash TEXT, snapshot_modified TEXT, snapshot_json TEXT, created_at TEXT NOT NULL,
        PRIMARY KEY(work_id, workspace_id, entity_type, entity_id));
    CREATE INDEX tapd_refs_entity ON work_tapd_refs(workspace_id, entity_type, entity_id);
    CREATE TABLE runs(
        id TEXT PRIMARY KEY, work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
        attempt INTEGER NOT NULL, session_id TEXT, workspace_path TEXT,
        executor TEXT NOT NULL DEFAULT 'claude', status TEXT NOT NULL,
        base_commit TEXT, reviewed_commit TEXT, reviewed_tree TEXT,
        pid INTEGER, exit_code INTEGER, error TEXT,
        started_at TEXT, ended_at TEXT, created_at TEXT NOT NULL);
    CREATE INDEX runs_work ON runs(work_id);
    CREATE TABLE sessions(
        id TEXT PRIMARY KEY, project_id TEXT, work_id TEXT, cwd TEXT NOT NULL,
        backend TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE source_conversations(
        id TEXT PRIMARY KEY, origin TEXT NOT NULL, account_id TEXT NOT NULL,
        remote_conversation_id TEXT NOT NULL, remote_thread_id TEXT NOT NULL DEFAULT '',
        actor_id TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        UNIQUE(origin, account_id, remote_conversation_id, remote_thread_id));
    CREATE TABLE input_events(
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES source_conversations(id),
        remote_event_id TEXT NOT NULL, kind TEXT NOT NULL, actor_id TEXT NOT NULL DEFAULT '',
        actor_verified INTEGER NOT NULL DEFAULT 0, text TEXT NOT NULL DEFAULT '',
        payload_json TEXT, work_id TEXT, intent_id TEXT, result_json TEXT, created_at TEXT NOT NULL,
        UNIQUE(conversation_id, remote_event_id));
    CREATE TABLE intents(
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, event_id TEXT NOT NULL,
        objective TEXT NOT NULL, title TEXT, project_id TEXT, related_work_id TEXT,
        resolution TEXT NOT NULL, evidence_json TEXT, question TEXT,
        status TEXT NOT NULL, work_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE attentions(
        id TEXT PRIMARY KEY, work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
        run_id TEXT NOT NULL, kind TEXT NOT NULL, request_id TEXT NOT NULL,
        tool_name TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', body_json TEXT,
        status TEXT NOT NULL, answer_json TEXT, answered_by TEXT,
        revision INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, answered_at TEXT,
        UNIQUE(run_id, request_id));
    CREATE TABLE evidence(
        id TEXT PRIMARY KEY, work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
        run_id TEXT, kind TEXT NOT NULL, title TEXT NOT NULL, detail_json TEXT,
        commit_sha TEXT, tree_hash TEXT, created_at TEXT NOT NULL);
    CREATE INDEX evidence_work ON evidence(work_id);
    CREATE TABLE deliveries(
        id TEXT PRIMARY KEY, work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
        target TEXT NOT NULL, target_json TEXT, body TEXT NOT NULL, body_hash TEXT NOT NULL,
        status TEXT NOT NULL, remote_id TEXT, error TEXT, attempts INTEGER NOT NULL DEFAULT 0,
        evidence_version TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        UNIQUE(work_id, target, body_hash));
    CREATE TABLE effects(
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, ref_id TEXT NOT NULL, payload_json TEXT,
        status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
        lease_owner TEXT, lease_until TEXT, next_attempt_at TEXT, last_error TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE INDEX effects_status ON effects(status);
    CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE run_events(
        seq INTEGER PRIMARY KEY AUTOINCREMENT, work_id TEXT NOT NULL, run_id TEXT,
        work_seq INTEGER NOT NULL, kind TEXT NOT NULL, payload_json TEXT, created_at TEXT NOT NULL);
    CREATE UNIQUE INDEX run_events_work ON run_events(work_id, work_seq);
    CREATE TABLE activity(
        seq INTEGER PRIMARY KEY AUTOINCREMENT, work_id TEXT NOT NULL, run_id TEXT,
        kind TEXT NOT NULL, title TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
        actor TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL);
    CREATE INDEX activity_work ON activity(work_id);
    CREATE TABLE pending_inputs(
        id TEXT PRIMARY KEY, work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
        text TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, sent_at TEXT);
    CREATE TABLE drafts(
        scope TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, updated_at TEXT NOT NULL,
        PRIMARY KEY(scope, key));
    CREATE TABLE requests(
        request_id TEXT PRIMARY KEY, method TEXT NOT NULL, result_json TEXT, created_at TEXT NOT NULL);
    """

    // MARK: 设置

    func setting(_ key: String) -> JSONValue? {
        JSONValue.parse((try? db.first("SELECT value FROM settings WHERE key = ?", [.text(key)]))?.string("value"))
    }

    func setSetting(_ key: String, _ value: JSONValue) throws {
        try db.run("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(value.serialized())])
    }

    // MARK: 幂等请求

    /// 同一个 requestId 的命令只生效一次，重复到达直接返回第一次的结果。
    func recordedResult(requestId: String?) -> JSONValue? {
        guard let requestId, !requestId.isEmpty else { return nil }
        return JSONValue.parse((try? db.first("SELECT result_json FROM requests WHERE request_id = ?",
                                              [.text(requestId)]))?.string("result_json"))
    }

    func recordResult(requestId: String?, method: String, result: JSONValue) {
        guard let requestId, !requestId.isEmpty else { return }
        _ = try? db.run("INSERT OR IGNORE INTO requests(request_id, method, result_json, created_at) VALUES(?,?,?,?)",
                        [.text(requestId), .text(method), .text(result.serialized()), .text(WorkClock.iso())])
    }

    // MARK: 项目

    /// 按规范化路径登记项目，已登记的更新名称与可用状态。返回项目身份。
    @discardableResult
    func upsertProject(path: String, name: String, available: Bool) throws -> WorkProject {
        let now = WorkClock.iso()
        if let row = try db.first("SELECT * FROM projects WHERE path = ?", [.text(path)]) {
            try db.run("UPDATE projects SET name = ?, available = ?, updated_at = ? WHERE id = ?",
                       [.text(name), .of(available), .text(now), .text(row.text("id"))])
            return WorkProject(id: row.text("id"), path: path, name: name, available: available)
        }
        let id = UUID().uuidString.lowercased()
        try db.run("INSERT INTO projects(id, path, name, available, created_at, updated_at) VALUES(?,?,?,?,?,?)",
                   [.text(id), .text(path), .text(name), .of(available), .text(now), .text(now)])
        return WorkProject(id: id, path: path, name: name, available: available)
    }

    func project(id: String) -> WorkProject? {
        (try? db.first("SELECT * FROM projects WHERE id = ?", [.text(id)])).flatMap { $0 }.map(WorkProject.init(row:))
    }

    func project(path: String) -> WorkProject? {
        (try? db.first("SELECT * FROM projects WHERE path = ?", [.text(path)])).flatMap { $0 }.map(WorkProject.init(row:))
    }

    func projects() -> [WorkProject] {
        ((try? db.query("SELECT * FROM projects ORDER BY name")) ?? []).map(WorkProject.init(row:))
    }

    func markProjectsUnavailable(except paths: Set<String>) throws {
        for project in projects() where !paths.contains(project.path) && project.available {
            try db.run("UPDATE projects SET available = 0, updated_at = ? WHERE id = ?",
                       [.text(WorkClock.iso()), .text(project.id)])
        }
    }

    // MARK: Work

    /// Work 编号在创建 Work 的同一个事务里分配，并发创建不会撞号。
    func nextDisplayId() throws -> String {
        try db.run("INSERT INTO counters(name, value) VALUES('work', 1000) ON CONFLICT(name) DO NOTHING")
        try db.run("UPDATE counters SET value = value + 1 WHERE name = 'work'")
        let value = try db.first("SELECT value FROM counters WHERE name = 'work'")?.int("value") ?? 1001
        return "WORK-\(value)"
    }

    func work(id: String) -> Work? {
        (try? db.first("SELECT * FROM works WHERE id = ?", [.text(id)])).flatMap { $0 }.map(Work.init(row:))
    }

    func work(displayId: String) -> Work? {
        (try? db.first("SELECT * FROM works WHERE display_id = ? COLLATE NOCASE", [.text(displayId)]))
            .flatMap { $0 }.map(Work.init(row:))
    }

    func work(idempotencyKey: String) -> Work? {
        (try? db.first("SELECT * FROM works WHERE idempotency_key = ?", [.text(idempotencyKey)]))
            .flatMap { $0 }.map(Work.init(row:))
    }

    func works(includeArchived: Bool = true) -> [Work] {
        let sql = includeArchived ? "SELECT * FROM works ORDER BY created_at DESC"
            : "SELECT * FROM works WHERE archived = 0 ORDER BY created_at DESC"
        return ((try? db.query(sql)) ?? []).map(Work.init(row:))
    }

    func works(status: WorkStatus) -> [Work] {
        ((try? db.query("SELECT * FROM works WHERE status = ? ORDER BY COALESCE(queued_at, created_at)",
                        [.text(status.rawValue)])) ?? []).map(Work.init(row:))
    }

    func insertWork(id: String, displayId: String, projectId: String, title: String, objective: String,
                    scope: String, origin: WorkOrigin, sourceConversationId: String?, sourceEventId: String?,
                    startRequested: Bool, isolation: String, permissionMode: String?, model: String?,
                    idempotencyKey: String?) throws {
        let now = WorkClock.iso()
        try db.run("""
            INSERT INTO works(id, display_id, project_id, title, objective, scope, origin,
                source_conversation_id, source_event_id, status, start_requested, isolation,
                permission_mode, model, idempotency_key, revision, created_at, updated_at, queued_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,?,?,?)
            """, [.text(id), .text(displayId), .text(projectId), .text(title), .text(objective), .text(scope),
                  .text(origin.rawValue), .of(sourceConversationId), .of(sourceEventId),
                  .text(WorkStatus.queued.rawValue), .of(startRequested), .text(isolation),
                  .of(permissionMode), .of(model), .of(idempotencyKey), .text(now), .text(now), .text(now)])
    }

    /// 写回 Work 的可变字段并把 revision 加一。调用方已在事务里完成了状态机判断。
    func save(_ work: inout Work) throws {
        work.revision += 1
        work.updatedAt = WorkClock.iso()
        try db.run("""
            UPDATE works SET title = ?, objective = ?, scope = ?, status = ?, start_requested = ?,
                current_run_id = ?, attention_id = ?, session_id = ?, isolation = ?, workspace_path = ?,
                branch = ?, base_commit = ?, permission_mode = ?, model = ?, unread = ?, archived = ?,
                status_reason = ?, revision = ?, updated_at = ?, queued_at = ?
            WHERE id = ?
            """, [.text(work.title), .text(work.objective), .text(work.scope), .text(work.status.rawValue),
                  .of(work.startRequested), .of(work.currentRunId), .of(work.attentionId), .of(work.sessionId),
                  .text(work.isolation), .of(work.workspacePath), .of(work.branch), .of(work.baseCommit),
                  .of(work.permissionMode), .of(work.model), .of(work.unread), .of(work.archived),
                  .of(work.statusReason), .of(work.revision), .text(work.updatedAt), .of(work.queuedAt),
                  .text(work.id)])
    }

    // MARK: TAPD 关联

    func tapdRefs(workId: String) -> [DBRow] {
        (try? db.query("SELECT * FROM work_tapd_refs WHERE work_id = ? ORDER BY created_at", [.text(workId)])) ?? []
    }

    func addTapdRef(workId: String, ref: TapdRef, title: String, businessStatus: String?,
                    snapshotHash: String?, snapshotModified: String?, snapshot: JSONValue?) throws {
        try db.run("""
            INSERT OR REPLACE INTO work_tapd_refs(work_id, workspace_id, entity_type, entity_id, title,
                business_status, snapshot_hash, snapshot_modified, snapshot_json, created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [.text(workId), .text(ref.workspaceId), .text(ref.entityType), .text(ref.entityId), .text(title),
                  .of(businessStatus), .of(snapshotHash), .of(snapshotModified),
                  .of(snapshot?.serialized()), .text(WorkClock.iso())])
    }

    /// 已关联到同一个 TAPD 对象的 Work（完整 TapdRef 比较，短号相同的不同对象不会混）。
    func works(tapdRef ref: TapdRef) -> [Work] {
        ((try? db.query("""
            SELECT w.* FROM works w JOIN work_tapd_refs r ON r.work_id = w.id
            WHERE r.workspace_id = ? AND r.entity_type = ? AND r.entity_id = ? ORDER BY w.created_at
            """, [.text(ref.workspaceId), .text(ref.entityType), .text(ref.entityId)])) ?? []).map(Work.init(row:))
    }

    // MARK: Run

    func run(id: String) -> WorkRun? {
        (try? db.first("SELECT * FROM runs WHERE id = ?", [.text(id)])).flatMap { $0 }.map(WorkRun.init(row:))
    }

    func runs(workId: String) -> [WorkRun] {
        ((try? db.query("SELECT * FROM runs WHERE work_id = ? ORDER BY attempt", [.text(workId)])) ?? [])
            .map(WorkRun.init(row:))
    }

    func liveRuns() -> [WorkRun] {
        ((try? db.query("SELECT * FROM runs WHERE status IN ('preparing','running','waiting_user')")) ?? [])
            .map(WorkRun.init(row:))
    }

    func insertRun(workId: String, sessionId: String?, workspacePath: String?, baseCommit: String?) throws -> WorkRun {
        let id = UUID().uuidString.lowercased()
        let attempt = (try db.first("SELECT COALESCE(MAX(attempt), 0) + 1 AS n FROM runs WHERE work_id = ?",
                                    [.text(workId)])?.int("n")) ?? 1
        let now = WorkClock.iso()
        try db.run("""
            INSERT INTO runs(id, work_id, attempt, session_id, workspace_path, status, base_commit, created_at)
            VALUES(?,?,?,?,?,?,?,?)
            """, [.text(id), .text(workId), .of(attempt), .of(sessionId), .of(workspacePath),
                  .text(RunStatus.preparing.rawValue), .of(baseCommit), .text(now)])
        guard let run = run(id: id) else { throw WorkError.failed("无法创建 Run") }
        return run
    }

    func save(_ run: WorkRun) throws {
        try db.run("""
            UPDATE runs SET session_id = ?, workspace_path = ?, status = ?, base_commit = ?, reviewed_commit = ?,
                reviewed_tree = ?, pid = ?, exit_code = ?, error = ?, started_at = ?, ended_at = ? WHERE id = ?
            """, [.of(run.sessionId), .of(run.workspacePath), .text(run.status.rawValue), .of(run.baseCommit),
                  .of(run.reviewedCommit), .of(run.reviewedTree), .of(run.pid), .of(run.exitCode), .of(run.error),
                  .of(run.startedAt), .of(run.endedAt), .text(run.id)])
    }

    // MARK: 会话登记

    func upsertSession(id: String, projectId: String?, workId: String?, cwd: String, backend: String) throws {
        let now = WorkClock.iso()
        try db.run("""
            INSERT INTO sessions(id, project_id, work_id, cwd, backend, created_at, updated_at) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET backend = excluded.backend, cwd = excluded.cwd, updated_at = excluded.updated_at
            """, [.text(id), .of(projectId), .of(workId), .text(cwd), .text(backend), .text(now), .text(now)])
    }

    func workSessionIds() -> [String] {
        ((try? db.query("SELECT id FROM sessions WHERE work_id IS NOT NULL")) ?? []).map { $0.text("id") }
    }

    // MARK: Attention

    func attention(id: String) -> WorkAttention? {
        (try? db.first("SELECT * FROM attentions WHERE id = ?", [.text(id)])).flatMap { $0 }.map(WorkAttention.init(row:))
    }

    func attentions(workId: String) -> [WorkAttention] {
        ((try? db.query("SELECT * FROM attentions WHERE work_id = ? ORDER BY created_at", [.text(workId)])) ?? [])
            .map(WorkAttention.init(row:))
    }

    func openAttentions(runId: String) -> [WorkAttention] {
        ((try? db.query("SELECT * FROM attentions WHERE run_id = ? AND status = 'open' ORDER BY created_at",
                        [.text(runId)])) ?? []).map(WorkAttention.init(row:))
    }

    func insertAttention(workId: String, runId: String, kind: AttentionKind, requestId: String,
                         toolName: String, title: String, body: JSONValue) throws -> WorkAttention {
        let id = UUID().uuidString.lowercased()
        try db.run("""
            INSERT INTO attentions(id, work_id, run_id, kind, request_id, tool_name, title, body_json, status, created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [.text(id), .text(workId), .text(runId), .text(kind.rawValue), .text(requestId), .text(toolName),
                  .text(title), .text(body.serialized()), .text(AttentionStatus.open.rawValue), .text(WorkClock.iso())])
        guard let attention = attention(id: id) else { throw WorkError.failed("无法创建 Attention") }
        return attention
    }

    func save(_ attention: inout WorkAttention, answeredBy: String? = nil) throws {
        attention.revision += 1
        try db.run("""
            UPDATE attentions SET status = ?, answer_json = ?, answered_by = COALESCE(?, answered_by),
                revision = ?, answered_at = ? WHERE id = ?
            """, [.text(attention.status.rawValue), .of(attention.answer?.serialized()), .of(answeredBy),
                  .of(attention.revision), .of(attention.answeredAt), .text(attention.id)])
    }

    // MARK: 事件流（每个 Work 自己的连续序号，前端据此发现缺口）

    @discardableResult
    func appendEvent(workId: String, runId: String?, kind: String, payload: JSONValue) throws -> JSONValue {
        let next = (try db.first("SELECT COALESCE(MAX(work_seq), 0) + 1 AS n FROM run_events WHERE work_id = ?",
                                 [.text(workId)])?.int("n")) ?? 1
        let now = WorkClock.iso()
        try db.run("INSERT INTO run_events(work_id, run_id, work_seq, kind, payload_json, created_at) VALUES(?,?,?,?,?,?)",
                   [.text(workId), .of(runId), .of(next), .text(kind), .text(payload.serialized()), .text(now)])
        return .obj(["seq": .int(next), "workId": .string(workId), "runId": .str(runId),
                     "kind": .string(kind), "payload": payload, "at": .string(now)])
    }

    func events(workId: String, after: Int = 0, limit: Int = 5000) -> [JSONValue] {
        ((try? db.query("SELECT * FROM run_events WHERE work_id = ? AND work_seq > ? ORDER BY work_seq LIMIT ?",
                        [.text(workId), .of(after), .of(limit)])) ?? []).map { row in
            .obj(["seq": .int(row.int("work_seq")), "workId": .string(workId), "runId": .str(row.string("run_id")),
                  "kind": .string(row.text("kind")), "payload": row.json("payload_json") ?? .null,
                  "at": .string(row.text("created_at"))])
        }
    }

    func lastEventSeq(workId: String) -> Int {
        (try? db.first("SELECT COALESCE(MAX(work_seq), 0) AS n FROM run_events WHERE work_id = ?", [.text(workId)]))?
            .int("n") ?? 0
    }

    // MARK: 活动

    func addActivity(workId: String, runId: String?, kind: String, title: String, detail: String = "",
                     actor: String = "") {
        _ = try? db.run("INSERT INTO activity(work_id, run_id, kind, title, detail, actor, created_at) VALUES(?,?,?,?,?,?,?)",
                        [.text(workId), .of(runId), .text(kind), .text(title), .text(detail), .text(actor),
                         .text(WorkClock.iso())])
    }

    func activity(workId: String, limit: Int = 300) -> [JSONValue] {
        ((try? db.query("SELECT * FROM activity WHERE work_id = ? ORDER BY seq DESC LIMIT ?",
                        [.text(workId), .of(limit)])) ?? []).map { row in
            .obj(["seq": .int(row.int("seq")), "runId": .str(row.string("run_id")), "kind": .string(row.text("kind")),
                  "title": .string(row.text("title")), "detail": .string(row.text("detail")),
                  "actor": .string(row.text("actor")), "at": .string(row.text("created_at"))])
        }
    }

    // MARK: 证据

    @discardableResult
    func addEvidence(workId: String, runId: String?, kind: String, title: String, detail: JSONValue,
                     commit: String? = nil, tree: String? = nil) throws -> String {
        let id = UUID().uuidString.lowercased()
        try db.run("""
            INSERT INTO evidence(id, work_id, run_id, kind, title, detail_json, commit_sha, tree_hash, created_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [.text(id), .text(workId), .of(runId), .text(kind), .text(title), .text(detail.serialized()),
                  .of(commit), .of(tree), .text(WorkClock.iso())])
        return id
    }

    func evidence(workId: String) -> [JSONValue] {
        ((try? db.query("SELECT * FROM evidence WHERE work_id = ? ORDER BY created_at", [.text(workId)])) ?? []).map { row in
            .obj(["id": .string(row.text("id")), "runId": .str(row.string("run_id")), "kind": .string(row.text("kind")),
                  "title": .string(row.text("title")), "detail": row.json("detail_json") ?? .null,
                  "commit": .str(row.string("commit_sha")), "tree": .str(row.string("tree_hash")),
                  "at": .string(row.text("created_at"))])
        }
    }

    // MARK: 待发送的用户输入

    func addPendingInput(id: String, workId: String, text: String) throws -> Bool {
        do {
            try db.run("INSERT INTO pending_inputs(id, work_id, text, status, created_at) VALUES(?,?,?,'pending',?)",
                       [.text(id), .text(workId), .text(text), .text(WorkClock.iso())])
            return true
        } catch let error as DBError where error.isConstraint {
            return false    // 同一个 messageId 重复提交
        }
    }

    func pendingInputs(workId: String) -> [DBRow] {
        (try? db.query("SELECT * FROM pending_inputs WHERE work_id = ? AND status = 'pending' ORDER BY created_at",
                       [.text(workId)])) ?? []
    }

    func markInputSent(id: String) {
        _ = try? db.run("UPDATE pending_inputs SET status = 'sent', sent_at = ? WHERE id = ?",
                        [.text(WorkClock.iso()), .text(id)])
    }

    func inputExists(id: String) -> Bool {
        ((try? db.first("SELECT 1 AS x FROM pending_inputs WHERE id = ?", [.text(id)])) ?? nil) != nil
    }

    // MARK: 草稿（按所属上下文保存：会话输入、提交信息、回填 / 汇报正文）

    func draft(scope: String, key: String) -> String? {
        (try? db.first("SELECT value FROM drafts WHERE scope = ? AND key = ?", [.text(scope), .text(key)]))?.string("value")
    }

    func setDraft(scope: String, key: String, value: String) {
        if value.isEmpty {
            _ = try? db.run("DELETE FROM drafts WHERE scope = ? AND key = ?", [.text(scope), .text(key)])
        } else {
            _ = try? db.run("""
                INSERT INTO drafts(scope, key, value, updated_at) VALUES(?,?,?,?)
                ON CONFLICT(scope, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """, [.text(scope), .text(key), .text(value), .text(WorkClock.iso())])
        }
    }

    // MARK: 投递

    func deliveries(workId: String) -> [DBRow] {
        (try? db.query("SELECT * FROM deliveries WHERE work_id = ? ORDER BY created_at", [.text(workId)])) ?? []
    }

    func delivery(id: String) -> DBRow? {
        (try? db.first("SELECT * FROM deliveries WHERE id = ?", [.text(id)])) ?? nil
    }

    static func deliveryJSON(_ row: DBRow) -> JSONValue {
        .obj(["id": .string(row.text("id")), "workId": .string(row.text("work_id")),
              "target": .string(row.text("target")), "targetInfo": row.json("target_json") ?? .null,
              "body": .string(row.text("body")), "bodyHash": .string(row.text("body_hash")),
              "status": .string(row.text("status")), "remoteId": .str(row.string("remote_id")),
              "error": .str(row.string("error")), "attempts": .int(row.int("attempts")),
              "evidenceVersion": .str(row.string("evidence_version")),
              "createdAt": .string(row.text("created_at")), "updatedAt": .string(row.text("updated_at"))])
    }

    // MARK: 副作用队列（outbox）

    func enqueueEffect(kind: String, refId: String, payload: JSONValue = .null) throws -> String {
        let id = UUID().uuidString.lowercased()
        let now = WorkClock.iso()
        try db.run("""
            INSERT INTO effects(id, kind, ref_id, payload_json, status, created_at, updated_at, next_attempt_at)
            VALUES(?,?,?,?,'pending',?,?,?)
            """, [.text(id), .text(kind), .text(refId), .text(payload.serialized()), .text(now), .text(now), .text(now)])
        return id
    }

    /// 领取一条到期的副作用。租约过期只说明上次执行结果未知，不代表它没有执行过。
    func leaseEffect(owner: String, leaseSeconds: TimeInterval = 120) -> DBRow? {
        let now = WorkClock.iso()
        guard let row = try? db.first("""
            SELECT * FROM effects WHERE (status = 'pending' AND next_attempt_at <= ?)
               OR (status = 'leased' AND lease_until < ?) ORDER BY created_at LIMIT 1
            """, [.text(now), .text(now)]) else { return nil }
        let until = WorkClock.iso(Date().addingTimeInterval(leaseSeconds))
        _ = try? db.run("""
            UPDATE effects SET status = 'leased', lease_owner = ?, lease_until = ?, attempts = attempts + 1, updated_at = ?
            WHERE id = ?
            """, [.text(owner), .text(until), .text(now), .text(row.text("id"))])
        return (try? db.first("SELECT * FROM effects WHERE id = ?", [.text(row.text("id"))])) ?? nil
    }

    func finishEffect(id: String, status: String, error: String? = nil, retryAfter: TimeInterval? = nil) {
        let now = WorkClock.iso()
        if let retryAfter {
            _ = try? db.run("UPDATE effects SET status = 'pending', last_error = ?, next_attempt_at = ?, updated_at = ? WHERE id = ?",
                            [.of(error), .text(WorkClock.iso(Date().addingTimeInterval(retryAfter))), .text(now), .text(id)])
        } else {
            _ = try? db.run("UPDATE effects SET status = ?, last_error = ?, updated_at = ? WHERE id = ?",
                            [.text(status), .of(error), .text(now), .text(id)])
        }
    }
}
