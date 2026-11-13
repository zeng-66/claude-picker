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
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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
    check(!session.view.allowMouseReporting, "text selection keeps local mouse handling")
}
if failures > 0 { exit(1) }
print("Terminal regression checks passed")
