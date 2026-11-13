import AppKit
import SwiftUI
import SwiftTerm

/// 一个内嵌终端会话：包装 LocalProcessTerminalView，负责启停 claude。
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    @Published private(set) var title: String = ""
    @Published private(set) var alive = false
    /// 优先使用 OSC 7501 任务状态，兼容旧版 CLI 的 OSC 标题忙闲信号。
    @Published private(set) var busy = false
    private var hasProgramStatus = false
    let view: LocalProcessTerminalView
    let cwd: String
    private let resumeId: String?
    private let sessionId: String?
    /// 进程起来后一段时间内不接受注入命令（claude 还在初始化）
    private var readyAt = Date.distantFuture
    /// 切到这个会话后的短暂抑制期：挂载视图会触发 PTY resize → claude 整屏重绘，
    /// 那是重绘不是任务在跑，不能因此转圈。
    private var suppressUntil = Date.distantPast
    /// 是否正显示在右侧；后台输出才算「未读」
    private var isForeground = true
    /// 用户主动关闭（terminate）时为 true，此时进程退出不算「自然结束」
    private var terminating = false
    /// 用户刚在终端里操作过（按键 / 滚轮 / 点击 / 拖拽）→ 这段时间内的输出是回显和重绘，
    /// 不能当成「claude 在跑」。TUI 对每次按键都会重绘，滚轮也会刷新状态栏。
    private var userInputUntil = Date.distantPast
    /// 进程自然退出时回调
    var onExit: (() -> Void)?
    /// 任务忙闲翻转时回调
    var onBusy: ((Bool) -> Void)?

    init(cwd: String, resumeId: String?, sessionId: String? = nil,
         options: RenderOptions, fontName: String, fontSize: Double) {
        self.cwd = cwd
        self.resumeId = resumeId
        self.sessionId = sessionId
        self.view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        // 文本选中保留本地处理，滚轮单独使用应用的滚动协议。
        self.view.allowMouseReporting = false
        self.view.allowMouseWheelReporting = true
        self.view.scrollSensitivity = 0.25
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
        if let r = resumeId {
            cmd = "exec claude --resume \(shellQuote(r))"
        } else if let s = sessionId {
            cmd = "exec claude --session-id \(shellQuote(s))"
        }
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

    /// 会话被切到前台时保留真实任务状态，并忽略挂载引起的重绘。
    /// （视图重新挂载会触发 PTY resize，claude 会整屏重绘，那不是任务在跑）。
    @MainActor func noteActivated() {
        suppressUntil = Date().addingTimeInterval(1.2)
        isForeground = true
        awayOutput = false
    }

    /// 用户刚在终端里做了操作：接下来 0.8 秒内的输出是这次操作的画面更新，
    /// 不是 claude 在跑任务，不要置忙。
    @MainActor func noteUserInput() {
        userInputUntil = Date().addingTimeInterval(0.8)
    }

    /// 会话被切到后台：视图卸载同样触发重绘，抑制期内不要把重绘当成新输出。
    @MainActor func noteDetached() {
        suppressUntil = Date().addingTimeInterval(1.2)
        isForeground = false
        awayOutput = busy
    }

    /// 切走后仍在执行或新开始执行的任务，完成后才会产生未读标记。
    private(set) var awayOutput = false

    func terminate() {
        guard alive else { return }
        terminating = true
        busy = false
        view.terminate()
        alive = false
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard alive, !terminating, !title.isEmpty else { return }
        let (clean, spin) = Self.parseSpinnerTitle(title)
        if !clean.isEmpty { self.title = clean }
        guard let spin, !hasProgramStatus else { return }
        // 空闲信号始终生效。切换视图和编辑输入期间的忙帧可能来自重绘，
        // 只有空闲会话需要过滤，运行中的任务保留状态直到收到明确的空闲信号。
        let now = Date()
        if spin, !busy, now < suppressUntil || now < userInputUntil { return }
        updateBusy(spin)
    }

    /// 新版 Claude 协商到 OSC 7501 后会省略标题 spinner，直接发布任务状态。
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        guard alive, !terminating else { return }
        hasProgramStatus = true
        let working = records.contains { $0.state == .working }
        if !working, records.contains(where: { $0.state == .blocked }) {
            awayOutput = false
        }
        updateBusy(working)
    }

    private func updateBusy(_ working: Bool) {
        if working, !isForeground { awayOutput = true }
        guard busy != working else { return }
        busy = working
        onBusy?(working)
    }

    /// 解析 claude 的 OSC 0 标题：忙帧 ◐ ◑（VTE 终端用 >）每 960ms 交替，
    /// 空闲帧 ✳（VTE 用 *）。返回剥离 spinner 后的干净标题与忙状态；
    /// 无 spinner 前缀时忙状态为 nil（不接管 busy）。
    static func parseSpinnerTitle(_ raw: String) -> (clean: String, spin: Bool?) {
        guard let first = raw.first else { return (raw, nil) }
        let spin: Bool
        switch first {
        case "◐", "◑", "◒", "◓", ">": spin = true
        case "✳", "*": spin = false
        default: return (raw, nil)
        }
        return (String(raw.dropFirst()).trimmingCharacters(in: .whitespaces), spin)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let natural = !terminating
        updateBusy(false)
        hasProgramStatus = false
        alive = false
        if natural { onExit?() }
    }
}

/// 终端视图：SwiftTerm 默认不给右键菜单，这里补上「复制 / 粘贴 / 全选」，
/// 否则选中文本后没有任何途径把内容放进剪贴板。
final class CopyableTerminalView: LocalProcessTerminalView {
    /// SwiftTerm 默认没有右键菜单，选中文本后无处可放；补上「复制 / 粘贴 / 全选」。
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: "粘贴", action: #selector(paste(_:)), keyEquivalent: "v")
        pasteItem.target = self
        menu.addItem(pasteItem)
        menu.addItem(.separator())
        let allItem = NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: "a")
        allItem.target = self
        menu.addItem(allItem)
        return menu
    }
}

/// SwiftUI 包装：把 LocalProcessTerminalView 塞进视图树。
struct TerminalPane: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView { session.view }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
