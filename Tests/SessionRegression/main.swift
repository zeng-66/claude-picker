import Foundation

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
if failures > 0 { exit(1) }
print("Session regression checks passed")
