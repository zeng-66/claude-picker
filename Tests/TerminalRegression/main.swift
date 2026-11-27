import AppKit
import Foundation

let application = NSApplication.shared
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let command = directory.appendingPathComponent("claude")
try "#!/bin/sh\n/bin/stty -echo -icanon\nexec /bin/cat\n".write(to: command, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
// A non-login test shell keeps the fake Claude isolated from the user's shell configuration.
let fakeShell = directory.appendingPathComponent("test-shell")
try "#!/bin/sh\nexec '\(command.path)'\n".write(to: fakeShell, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeShell.path)
setenv("CLAUDE_PICKER_TEST_SHELL", fakeShell.path, 1)
defer { try? FileManager.default.removeItem(at: directory) }
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL \(message)")
    }
}
MainActor.assumeIsolated {
    let session = TerminalSession(cwd: directory.path, resumeId: nil, options: RenderOptions(), fontName: "", fontSize: 12)
    defer { session.terminate() }
    check(session.view.scrollSensitivity == 0.25, "terminal wheel sensitivity is reduced to one quarter")
    session.setTerminalTitle(source: session.view, title: "◐ Working")
    check(session.busy, "busy title starts the running indicator")
    session.noteActivated()
    check(session.busy, "activating a running session preserves its indicator")
    session.setTerminalTitle(source: session.view, title: "✳ Idle")
    session.noteDetached()
    session.setTerminalTitle(source: session.view, title: "◑ Resize redraw")
    check(!session.busy, "detaching an idle session ignores a redraw spinner")
    check(!session.awayOutput, "a redraw does not mark background work")
    session.noteActivated()
    session.noteUserInput()
    session.setTerminalTitle(source: session.view, title: "◐ Draft redraw")
    check(!session.busy, "typing a draft keeps an idle session idle")
    session.setTerminalTitle(source: session.view, title: "✳ Idle")
    session.view.terminate()
    session.processTerminated(source: session.view, exitCode: 0)
    check(!session.busy, "process exit clears the running indicator")
}
MainActor.assumeIsolated {
    let session = TerminalSession(cwd: directory.path, resumeId: nil, options: RenderOptions(), fontName: "", fontSize: 12)
    defer { session.terminate() }
    RunLoop.current.run(until: Date().addingTimeInterval(1.7))
    check(session.send("\u{1b}]0;◐ Transport working\u{7}\n"), "the isolated terminal accepts input")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    check(session.busy, "OSC busy output travels through the real PTY and SwiftTerm parser")
    check(session.title == "Transport working", "the OSC spinner is stripped from the terminal title")
    session.noteDetached()
    check(session.send("\u{1b}]0;✳ Transport idle\u{7}\n"), "the isolated terminal accepts the idle frame")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    check(!session.busy, "OSC idle output clears activity through the real PTY")
    check(session.awayOutput, "a genuine task finishing in the background is eligible for an unread marker")
}
MainActor.assumeIsolated {
    let path = directory.resolvingSymlinksInPath().path
    let firstFile = directory.appendingPathComponent("first.jsonl")
    let initialRecord: [String: Any] = ["type": "user", "cwd": path, "message": ["content": "Original prompt"]]
    var records = try! JSONSerialization.data(withJSONObject: initialRecord)
    records.append(Data("\n{\"type\":\"ai-title\",\"aiTitle\":\"Fresh summary\"}\n".utf8))
    try! records.write(to: firstFile)
    let first = Session(id: "first", cwd: path, title: "Stale title", summary: nil,
                        date: .distantPast, fileURL: firstFile)
    let second = Session(id: "second", cwd: path, title: "Second", summary: nil, date: .distantPast)
    let store = Store([Project(id: 0, title: "Fixture", path: path, isHome: false, sessions: [first, second])])
    defer { store.terminateAll() }
    let firstKey = store.key(cwd: path, sid: first.id)
    store.open(cwd: path, sid: first.id, label: first.title)
    let terminal = store.active!
    RunLoop.current.run(until: Date().addingTimeInterval(1.3))
    check(store.projects[0].sessions[0].title == "Fresh summary", "opening history refreshes the saved summary")
    check(store.activeLabel == "Fresh summary", "the active label follows the refreshed summary")
    terminal.setTerminalTitle(source: terminal.view, title: "◐ Working")
    check(store.runningKeys.contains(firstKey), "busy signals reach the sidebar running state")
    terminal.noteUserInput()
    check(store.runningKeys.contains(firstKey), "typing during a task preserves its running state")
    store.open(cwd: path, sid: second.id, label: second.title)
    check(store.runningKeys.contains(firstKey), "switching away keeps a real task running")
    terminal.setTerminalTitle(source: terminal.view, title: "✳ Done")
    check(!store.runningKeys.contains(firstKey), "completion clears the shared running state")
    check(store.unreadKeys.contains(firstKey), "a real background completion marks the session unread")
    store.open(cwd: path, sid: first.id, label: first.title)
    check(!store.unreadKeys.contains(firstKey), "viewing a completed session clears its unread marker")
    store.open(cwd: path, sid: second.id, label: second.title)
    terminal.setTerminalTitle(source: terminal.view, title: "◑ Resize redraw")
    terminal.setTerminalTitle(source: terminal.view, title: "✳ Idle")
    check(!store.runningKeys.contains(firstKey), "switching away after completion does not restart the spinner")
    check(!store.unreadKeys.contains(firstKey), "switching away after completion does not create a green dot")
    terminal.view.terminate()
    terminal.processTerminated(source: terminal.view, exitCode: 0)
    check(!store.unreadKeys.contains(firstKey), "an idle process exit does not create a green dot")
}
MainActor.assumeIsolated {
    let session = TerminalSession(cwd: directory.path, resumeId: nil, options: RenderOptions(), fontName: "", fontSize: 12)
    defer { session.terminate() }
    session.noteActivated()
    session.noteUserInput()
    session.view.feed(text: "\u{1b}]7501;state=working:app=claude\u{7}")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(session.view.programStatusRecords.contains { $0.state == .working }, "SwiftTerm receives the structured working record")
    check(session.busy, "OSC 7501 starts loading immediately after submitting input")
    session.noteDetached()
    session.setTerminalTitle(source: session.view, title: "✳ Legacy idle")
    check(session.busy, "structured working state takes priority over legacy title frames")
    session.view.feed(text: "\u{1b}]7501;state=blocked:kind=permission\u{7}")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(!session.busy, "a permission prompt pauses the working indicator")
    check(!session.awayOutput, "waiting for permission does not mark a task completed")
    session.view.feed(text: "\u{1b}]7501;state=working\u{7}")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(session.busy, "the working indicator resumes after a blocked state")
    session.view.feed(text: "\u{1b}]7501;state=done\u{7}")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(!session.busy, "a structured completion clears loading")
    check(session.awayOutput, "a structured background completion is eligible for unread")
    session.view.feed(text: "\u{1b}]7501;state=working:id=agent\u{7}")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(session.busy, "a child agent keeps the session running after the main turn ends")
    session.view.feed(text: "\u{1b}]7501;state=done:id=agent\u{7}")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(!session.busy, "the session stops loading when all agents finish")
    session.noteActivated()
    session.noteDetached()
    session.view.feed(text: "\u{1b}]7501;state=idle\u{7}")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(!session.busy && !session.awayOutput, "an idle redraw after switching does not create activity")
}
MainActor.assumeIsolated {
    let session = TerminalSession(cwd: directory.path, resumeId: nil, options: RenderOptions(), fontName: "", fontSize: 12)
    defer { session.terminate() }
    session.view.scrollSensitivity = 0.25
    session.view.feed(text: (0..<200).map { String(format: "WHEEL-%04d\r\n", $0) }.joined())
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    func firstVisibleRow() -> Int {
        let snapshot = session.view.terminalContentSnapshot(region: .viewport)!
        let text = snapshot.rows.first!.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(text.dropFirst("WHEEL-".count))!
    }
    let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                        wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!
    let before = firstVisibleRow()
    session.view.scrollWheel(with: wheel)
    check(before - firstVisibleRow() == Int(abs(wheel.scrollingDeltaY) * 0.25),
          "a small physical wheel event respects fractional sensitivity")
    for _ in 0..<3 { session.view.scrollWheel(with: wheel) }
    check(before - firstVisibleRow() == Int(abs(wheel.scrollingDeltaY)),
          "four wheel events accumulate to one quarter of their original distance")
}
MainActor.assumeIsolated {
    let capture = directory.appendingPathComponent("wheel-input")
    try! "#!/bin/sh\n/bin/stty -echo -icanon\nexec /usr/bin/tee '\(capture.path)'\n".write(to: command, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    let session = TerminalSession(cwd: directory.path, resumeId: nil, options: RenderOptions(), fontName: "", fontSize: 12)
    defer { session.terminate() }
    // 等假 claude（tee）真正起来再发滚轮：机器忙时进程启动可能超过 0.2 秒
    let startDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: capture.path), Date() < startDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    session.view.feed(text: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                        wheelCount: 1, wheel1: 4, wheel2: 0, wheel3: 0)!)!
    session.view.scrollWheel(with: wheel)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(FileManager.default.fileExists(atPath: capture.path), "the wheel transport capture is running")
    let sent = (try? String(contentsOf: capture, encoding: .utf8)) ?? ""
    check(sent.contains("\u{1b}[<64;"), "a full-screen app receives a small wheel report for scrolling")
    check(!sent.contains("\u{1b}[5~"), "wheel input does not jump a full page when the app supports mouse reporting")
    check(session.view.allowMouseReporting, "clicks reach a CLI that turned on mouse reporting")
    check(session.view.linkHighlightMode == .hover, "links open on a plain click")

    // 全屏 CLI 开着鼠标模式：单击要原样发给它（展开工具调用、Jump to bottom 靠这个）
    func mouse(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        session.view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        return NSEvent.mouseEvent(with: type, location: NSPoint(x: 40, y: 300), modifierFlags: flags,
                                  timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: 1)!
    }
    let beforeClick = ((try? String(contentsOf: capture, encoding: .utf8)) ?? "").count
    session.view.mouseDown(with: mouse(.leftMouseDown))
    session.view.mouseUp(with: mouse(.leftMouseUp))
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let clickSent = String(((try? String(contentsOf: capture, encoding: .utf8)) ?? "").dropFirst(beforeClick))
    check(clickSent.contains("\u{1b}[<0;") && clickSent.contains("m"), "a click reaches the full-screen CLI as press and release")

    // Shift 按住时强制本地选中，不发给 CLI
    let beforeShift = ((try? String(contentsOf: capture, encoding: .utf8)) ?? "").count
    session.view.mouseDown(with: mouse(.leftMouseDown, .shift))
    session.view.mouseUp(with: mouse(.leftMouseUp, .shift))
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let shiftSent = String(((try? String(contentsOf: capture, encoding: .utf8)) ?? "").dropFirst(beforeShift))
    check(!shiftSent.contains("\u{1b}[<"), "shift-click stays local for text selection")
}
MainActor.assumeIsolated {
    // 图形聊天：路由拼装 / 解析与就绪信号解析，不启动 Node。
    let cwd = "/Users/me/My Project+1"
    let url = ChatRoute.url(port: 4321, cwd: cwd, sid: "abc-123", pair: "p0")
    check(url?.path == "/sessions/abc-123", "chat route targets the session")
    check(ChatRoute.parse(url)?.cwd == cwd, "workingDir survives spaces and plus signs")
    check(ChatRoute.parse(url)?.sid == "abc-123", "session id parses back")
    check(ChatRoute.parse(ChatRoute.url(port: 1, cwd: cwd, sid: nil, pair: nil))?.sid == nil, "new-session route has no id")
    check(url?.query?.contains("is_desktop=1") == true, "embedded host mode hides the page's own top bar")
    check(ChatRoute.parse(URL(string: "http://127.0.0.1:1/settings/general")) == nil, "non-session routes are ignored")
    check(ChatBackendManager.parsePortLine("PORT:62465") == 62465, "ready line yields the port")
    check(ChatBackendManager.parsePortLine("PHASE:boot") == nil, "other startup lines are ignored")
    check(ChatBackendManager.parsePortLine("PORT:0") == nil, "port zero is not ready")
}
MainActor.assumeIsolated {
    let claude = TerminalSession(cwd: directory.path, resumeId: nil, provider: .claude,
                                 options: RenderOptions(), fontName: "", fontSize: 12)
    defer { claude.terminate() }
    let agy = TerminalSession(cwd: directory.path, resumeId: nil, provider: .antigravity,
                              options: RenderOptions(), fontName: "", fontSize: 12)
    defer { agy.terminate() }
    check(claude.view.nativeBackgroundColor == kTerminalBackground,
          "claude terminal keeps #202122 background")
    check(agy.view.nativeBackgroundColor == kAntigravityTerminalBackground,
          "antigravity terminal uses #212734 background")
    check(TerminalSession.backgroundColor(for: .claude) == kTerminalBackground,
          "background helper returns #202122 for claude")
    check(TerminalSession.backgroundColor(for: .antigravity) == kAntigravityTerminalBackground,
          "background helper returns #212734 for antigravity")
    check(agy.view.nativeForegroundColor != claude.view.nativeForegroundColor,
          "antigravity terminal softens default foreground contrast")
}
do {
    // Codex 新会话：首行 session_meta 很长（带 AGENTS.md），按 ID 查找与新会话识别都要认得出来。
    let codexHome = directory.appendingPathComponent("codex-home")
    setenv("CODEX_HOME", codexHome.path, 1)
    defer { unsetenv("CODEX_HOME") }
    let now = Date()
    let fields = Calendar(identifier: .iso8601).dateComponents(in: .current, from: now)
    let day = codexHome.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", fields.year!, fields.month!, fields.day!))
    try! FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let id = "01a2125e-0b6d-7550-b318-4717b47d0802"
    let cwd = directory.appendingPathComponent("codex-project").path
    let meta: [String: Any] = ["type": "session_meta", "payload": [
        "id": id, "cwd": cwd, "timestamp": now.addingTimeInterval(30).ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)),
        "base_instructions": String(repeating: "x", count: 100_000),
    ]]
    var rollout = try! JSONSerialization.data(withJSONObject: meta)
    rollout.append(10)
    try! rollout.write(to: day.appendingPathComponent("rollout-test-\(id).jsonl"))
    check(CodexSessionScanner.find(id: id)?.cwd == cwd, "a codex session with a 100KB first line is found by id")
    check(CodexSessionScanner.newConversation(in: cwd, since: now, ignoring: [])?.id == id,
          "a codex session written after the terminal started binds to the new conversation")
    check(CodexSessionScanner.newConversation(in: cwd, since: now, ignoring: [id]) == nil,
          "known codex sessions are not rebound")
}
MainActor.assumeIsolated {
    // SwiftTerm 终端链接解析与第三栏拦截：相对路径、行列定位、工作树 cwd、file://、网页链接放行、越界路径
    let repoDir = directory.appendingPathComponent("link-repo").resolvingSymlinksInPath()
    let wtDir = repoDir.appendingPathComponent(".worktrees/wt-1")
    let srcDir = wtDir.appendingPathComponent("src")
    try! FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
    let fileInWt = srcDir.appendingPathComponent("App.swift")
    try! "let x = 1\n".write(to: fileInWt, atomically: true, encoding: .utf8)
    let rootFile = repoDir.appendingPathComponent("README.md")
    try! "# hello\n".write(to: rootFile, atomically: true, encoding: .utf8)

    let rel = TerminalLinkResolver.resolve(link: "src/App.swift:42:7", isExplicit: false,
                                           cwd: wtDir.path, projectRoot: repoDir.path)
    check(rel?.projectPath == wtDir.path && rel?.path == "src/App.swift" && rel?.line == 42 && rel?.column == 7,
          "relative path with line:col resolves against worktree cwd")

    let fileURLTarget = TerminalLinkResolver.resolve(link: "file://\(fileInWt.path)#L12C3", isExplicit: true,
                                                     cwd: wtDir.path, projectRoot: repoDir.path)
    check(fileURLTarget?.path == "src/App.swift" && fileURLTarget?.line == 12 && fileURLTarget?.column == 3,
          "file:// URL with fragment resolves to local file target")

    let rootTarget = TerminalLinkResolver.resolve(link: rootFile.path + ":1", isExplicit: false,
                                                  cwd: wtDir.path, projectRoot: repoDir.path)
    check(rootTarget?.projectPath == repoDir.path && rootTarget?.path == "README.md" && rootTarget?.line == 1,
          "absolute path inside parent project root resolves cleanly")

    let outside = TerminalLinkResolver.resolve(link: "/etc/hosts", isExplicit: false,
                                               cwd: wtDir.path, projectRoot: repoDir.path)
    check(outside?.projectPath == wtDir.path && outside?.path == "/etc/hosts",
          "out-of-bounds path is forwarded to third pane for FileService boundary rejection")

    check(TerminalLinkResolver.resolve(link: "https://example.com/docs", isExplicit: false, cwd: wtDir.path) == nil,
          "https links fall through to SwiftTerm / system browser")
    check(TerminalLinkResolver.resolve(link: "mailto:user@example.com", isExplicit: false, cwd: wtDir.path) == nil,
          "other URL schemes fall through to SwiftTerm policy")
    check(TerminalLinkResolver.resolve(link: "file://remote.example.com/tmp/a.txt", isExplicit: true, cwd: wtDir.path) == nil,
          "remote file:// host is not opened locally")

    // CopyableTerminalView 拦截测试：不触碰系统外部程序
    let session = TerminalSession(cwd: wtDir.path, resumeId: nil, projectRoot: repoDir.path,
                                  options: RenderOptions(), fontName: "", fontSize: 12)
    defer { session.terminate() }
    var captured: TerminalFileTarget?
    session.onOpenFile = { captured = $0 }
    check(session.handleActivatedLink("src/App.swift:9"),
          "TerminalSession intercepts file links into onOpenFile callback")
    check(captured?.path == "src/App.swift" && captured?.line == 9,
          "captured target preserves relative path and line number")
    check(!session.handleActivatedLink("https://example.com/docs"),
          "web links are not intercepted as local files")
}
if failures > 0 { exit(1) }
print("Terminal regression checks passed")
