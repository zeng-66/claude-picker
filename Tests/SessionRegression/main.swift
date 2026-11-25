import Foundation
import SQLite3

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL \(message)")
    }
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("session.jsonl")
let head = "{\"type\":\"user\",\"cwd\":\"/tmp/project\",\"message\":{\"content\":\"Original prompt\"}}\n"
try (head + "{\"type\":\"ai-title\",\"aiTitle\":\"Session summary\"}\n").write(to: file, atomically: true, encoding: .utf8)
check(SessionScanner.parse(file)?.title == "Session summary", "history title uses the latest summary")
try (head + "{ \"type\" : \"summary\", \"summary\" : \"Updated summary\" }\n").write(to: file, atomically: true, encoding: .utf8)
check(SessionScanner.tailSummary(file) == "Updated summary", "JSON whitespace does not hide a summary")
try (String(repeating: "中", count: 100) + "\n{\"type\":\"ai-title\",\"aiTitle\":\"Unicode tail\"}\n").write(to: file, atomically: true, encoding: .utf8)
check(SessionScanner.tailSummary(file, bytes: 80) == "Unicode tail", "a tail beginning inside UTF-8 still finds the summary")
try (head + "{\"type\":\"summary\",\"summary\":\"Earlier\"}\n"
    + String(repeating: "{\"type\":\"progress\",\"text\":\"Later output\"}\n", count: 3000))
    .write(to: file, atomically: true, encoding: .utf8)
check(SessionScanner.tailSummary(file) == "Earlier", "find a summary before a large output tail")
try head.write(to: file, atomically: true, encoding: .utf8)
check(SessionScanner.parse(file)?.title == "Original prompt", "legacy sessions keep their prompt title")
check(SessionScanner.parse(file)?.summary == nil, "legacy sessions have no invented summary")
try (head + "{\"type\":\"summary\",\"summary\":\"Earlier\"}\n"
    + "{\"type\":\"ai-title\",\"aiTitle\":\" Latest \"}\n"
    + "{\"type\":\"summary\",\"summary\":\"  \"}\n"
    + "{\"type\":\"ai-title\",")
    .write(to: file, atomically: true, encoding: .utf8)
check(SessionScanner.tailSummary(file) == "Latest", "skip blank and partially written records")

// MARK: - Antigravity 会话扫描、上下文统计与跨引擎 <thread-handoff> 组装回归

let agyRoot = directory.appendingPathComponent("agy-home", isDirectory: true)
let agyWorkspace = directory.appendingPathComponent("agy-project", isDirectory: true)
try FileManager.default.createDirectory(at: agyRoot.appendingPathComponent("cache"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: agyWorkspace, withIntermediateDirectories: true)

let dbPath = agyRoot.appendingPathComponent("conversation_summaries.db").path
var db: OpaquePointer?
if sqlite3_open(dbPath, &db) == SQLITE_OK, let db {
    let ddl = """
    CREATE TABLE conversation_summaries(
        conversation_id TEXT PRIMARY KEY,
        title TEXT,
        preview TEXT,
        last_modified_time TEXT,
        workspace_uris TEXT,
        status TEXT,
        parent_conversation_id TEXT,
        nesting_depth INTEGER,
        not_fully_idle INTEGER,
        killed INTEGER,
        app_data_dir TEXT
    );
    """
    sqlite3_exec(db, ddl, nil, nil, nil)
    let wsURI = URL(fileURLWithPath: agyWorkspace.path).absoluteString
    let inserts = """
    INSERT INTO conversation_summaries VALUES
      ('agy-main-1', '多引擎架构评估', '<USER_REQUEST>评估 Antigravity 集成</USER_REQUEST>', '2026-11-18T10:00:00Z', '["\(wsURI)"]', 'CASCADE_RUN_STATUS_IDLE', '', 0, 0, 0, ''),
      ('agy-sub-1', '子代理调研', 'subagent prompt', '2026-11-18T10:05:00Z', '["\(wsURI)"]', 'CASCADE_RUN_STATUS_IDLE', 'agy-main-1', 1, 0, 0, ''),
      ('agy-killed-1', '已销毁会话', 'killed prompt', '2026-11-18T10:06:00Z', '["\(wsURI)"]', 'CASCADE_RUN_STATUS_IDLE', '', 0, 0, 1, '');
    """
    sqlite3_exec(db, inserts, nil, nil, nil)
    sqlite3_close(db)
}

// 写入 transcript.jsonl，验证 `<USER_REQUEST>` 清洗与 1M Token 用量提取
let transcriptURL = AgySessionScanner.transcriptURL(for: "agy-meta-only", root: agyRoot)
try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let transcriptLines = [
    #"{"type":"USER_INPUT","source":"USER_EXPLICIT","content":"<ADDITIONAL_METADATA>meta</ADDITIONAL_METADATA>\n<USER_REQUEST>\n修复登录回调死循环\n</USER_REQUEST>"}"#,
    #"{"type":"PLANNER_RESPONSE","model":"gemini-4-carbon-high","content":"已定位并修复重定向条件。","input_tokens":18500,"cache_read_tokens":42000,"output_tokens":1200}"#,
].joined(separator: "\n") + "\n"
try transcriptLines.write(to: transcriptURL, atomically: true, encoding: .utf8)

let metaJSON: [String: Any] = [
    "conversations": [
        "agy-meta-only": [
            "last_modified_time": "2026-11-18T11:30:00Z",
            "summary": [
                "WorkspaceURIs": [URL(fileURLWithPath: agyWorkspace.path).absoluteString],
            ],
        ],
    ],
]
let metaData = try JSONSerialization.data(withJSONObject: metaJSON)
try metaData.write(to: agyRoot.appendingPathComponent("cache/conversation_metadata.json"))

let scanned = AgySessionScanner.scan(root: agyRoot)
let agySessions = scanned[agyWorkspace.path] ?? []
check(agySessions.count == 2, "AgySessionScanner filters out subagents and killed conversations (got \(agySessions.count))")
check(agySessions.allSatisfy { $0.provider == .antigravity }, "AgySessionScanner tags sessions as .antigravity")
check(agySessions.first { $0.id == "agy-main-1" }?.title == "多引擎架构评估", "SQLite title read properly")
check(agySessions.first { $0.id == "agy-meta-only" }?.title == "修复登录回调死循环", "Strips <USER_REQUEST> and <ADDITIONAL_METADATA> wrappers")

let usageSnap = AgyContextUsage.read(transcriptURL)
check(usageSnap?.used == 61_700 && usageSnap?.windowTotal == 1_048_576, "AgyContextUsage reads PLANNER_RESPONSE tokens with 1M default window")

let handoffFromAgy = HandoffBuilder.fromSessionFile(
    sourceProvider: .antigravity,
    targetProvider: .claude,
    title: "修复登录回调死循环",
    cwd: agyWorkspace.path,
    fileURL: transcriptURL
)
check(handoffFromAgy.contains("<thread-handoff>") && handoffFromAgy.contains("Antigravity")
      && handoffFromAgy.contains("Claude Code") && handoffFromAgy.contains("修复登录回调死循环")
      && !handoffFromAgy.contains("<USER_REQUEST>"),
      "HandoffBuilder produces clean 4-layer envelope from Antigravity transcript")

// 逐会话打开方式：会话记录优先，旧配置可读，不支持的引擎回到终端。
check(InteractionMode.resolve(recorded: nil, provider: .claude, global: .chat, overrides: [:]) == .chat,
      "未记录的旧会话沿用全局 Swttch 设置")
check(InteractionMode.resolve(recorded: nil, provider: .antigravity, global: .chat, overrides: [:]) == .terminal,
      "Swttch 仅支持 Claude，其它引擎回到终端")
check(InteractionMode.resolve(recorded: "terminal", provider: .claude, global: .structured, overrides: [:]) == .terminal,
      "会话记录优先于全局默认")
check(InteractionMode.resolve(recorded: nil, provider: .codex, global: .terminal, overrides: ["codex": .structured]) == .structured,
      "引擎覆盖决定新会话打开方式")
check(InteractionMode.resolve(recorded: "structured", provider: .dsh, global: .terminal, overrides: [:]) == .terminal,
      "DeepSeek 不支持结构化聊天")
check(InteractionMode.resolve(recorded: "bogus", provider: .claude, global: .terminal, overrides: [:]) == .terminal,
      "无法识别的记录回到默认")
let legacySettings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"interactionMode":"chat"}"#.utf8))
check(legacySettings.interactionMode == .chat && legacySettings.providerModes.isEmpty, "旧版 settings.json 的图形聊天设置仍可读")
let futureSettings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"interactionMode":"structured","providerModes":{"codex":"structured"}}"#.utf8))
check(futureSettings.interactionMode == .structured && futureSettings.providerModes["codex"] == .structured, "新打开方式字段可读")
let legacyTree = try JSONDecoder().decode(TreeOrder.self, from: Data(#"{"projects":["/tmp"],"titles":{"a":"b"}}"#.utf8))
check(legacyTree.sessionModes.isEmpty && legacyTree.titles["a"] == "b", "旧版 tree.json 缺少 sessionModes 时仍可读")

if failures > 0 { exit(1) }
print("Session regression checks passed")
