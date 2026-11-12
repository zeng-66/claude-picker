import AppKit
import SwiftUI
import SwiftTerm

/// 一个内嵌终端会话：包装 LocalProcessTerminalView，负责启停 claude。
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published private(set) var title: String = ""
    @Published private(set) var alive = false
    let view: LocalProcessTerminalView
    let cwd: String
    private let resumeId: String?
    /// 进程起来后一段时间内不接受注入命令（claude 还在初始化）
    private var readyAt = Date.distantFuture

    init(cwd: String, resumeId: String?, options: RenderOptions, fontName: String, fontSize: Double) {
        self.cwd = cwd
        self.resumeId = resumeId
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init()
        configure(fontName: fontName, fontSize: fontSize)
        view.processDelegate = self
        start(options: options)
    }

    private func configure(fontName: String, fontSize: Double) {
        view.nativeBackgroundColor = NSColor(srgbRed: 0.055, green: 0.062, blue: 0.078, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)
        applyFont(fontName: fontName, fontSize: fontSize)
        view.caretColor = NSColor(srgbRed: 0.95, green: 0.55, blue: 0.35, alpha: 1)
    }

    func applyFont(fontName: String, fontSize: Double) {
        let size = CGFloat(fontSize)
        let f = fontName.isEmpty
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : (NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
        view.font = f
    }

    private func start(options: RenderOptions) {
        guard !alive else { return }
        var args = ["-lc"]
        var cmd = "exec claude"
        if let r = resumeId { cmd = "exec claude --resume \(shellQuote(r))" }
        cmd += " " + options.flags()
        args.append(cmd)
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        view.startProcess(executable: "/bin/zsh", args: args, environment: env,
                          execName: "claude", currentDirectory: cwd)
        alive = true
        readyAt = Date().addingTimeInterval(1.6)
    }

    /// 往 PTY 里打字（等同用户键盘输入）
    @discardableResult
    func send(_ text: String) -> Bool {
        guard alive, Date() >= readyAt, let proc = view.process, proc.running else { return false }
        let bytes = ArraySlice(Array(text.utf8))
        proc.send(data: bytes)
        return true
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var pid: pid_t { view.process?.shellPid ?? 0 }
    var isReady: Bool { alive && Date() >= readyAt }

    func terminate() {
        guard alive else { return }
        view.terminate()
        alive = false
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        if !title.isEmpty { self.title = title }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        alive = false
    }
}

/// SwiftUI 包装：把 LocalProcessTerminalView 塞进视图树。
struct TerminalPane: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView { session.view }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
