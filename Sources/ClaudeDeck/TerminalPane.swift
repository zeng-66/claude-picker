import AppKit
import SwiftUI
import SwiftTerm

/// 终端底色：与界面第二栏一致（原型 .terminal-pane 的 #202122）。窗口底色与终端视图共用。
let kTerminalBackground = NSColor(srgbRed: 0x20 / 255.0, green: 0x21 / 255.0, blue: 0x22 / 255.0, alpha: 1)
/// Antigravity 模式终端底色：#212734，避免纯黑暖灰背景下高亮输出过于刺眼。
let kAntigravityTerminalBackground = NSColor(srgbRed: 0x21 / 255.0, green: 0x27 / 255.0, blue: 0x34 / 255.0, alpha: 1)

private struct TerminalTheme {
    let background: NSColor
    let foreground: NSColor
    let caret: NSColor
    let ansiColors: [SwiftTerm.Color]?
}

/// 一个内嵌终端会话：包装 LocalProcessTerminalView，负责启停 claude。
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    @Published private(set) var title: String = ""
    @Published private(set) var alive = false
    /// 优先使用 OSC 7501 任务状态，兼容旧版 CLI 的 OSC 标题忙闲信号。
    @Published private(set) var busy = false
    private var hasProgramStatus = false
    let view: LocalProcessTerminalView
    let cwd: String
    let provider: AgentProvider
    var boundConversationId: String?
    private let resumeId: String?
    private let sessionId: String?
    private let displayName: String?
    private let initialPrompt: String?
    private var agyWatchTimer: Timer?
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

    /// - Parameters:
    ///   - provider: CLI 引擎（默认 `.claude`）。
    ///   - name: 新建会话的显示名（`claude --name`），恢复会话时忽略。
    ///   - prompt: 新建会话的首条提示词。
    init(cwd: String, resumeId: String?, sessionId: String? = nil,
         name: String? = nil, prompt: String? = nil,
         provider: AgentProvider = .claude,
         options: RenderOptions,
         agyOptions: AgyRenderOptions = AgyRenderOptions(),
         fontName: String, fontSize: Double) {
        self.cwd = cwd
        self.provider = provider
        self.boundConversationId = resumeId
        self.resumeId = resumeId
        self.sessionId = sessionId
        self.displayName = name
        self.initialPrompt = prompt
        self.view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        // 鼠标点击交给 CLI：Claude Code 全屏界面里的「展开工具调用」「Jump to bottom」等
        // 都靠鼠标上报实现。CLI 没开鼠标模式时仍由终端本地选字；开了以后按住 Shift 或 Option 拖动强制本地选中。
        self.view.allowMouseReporting = true
        self.view.allowMouseWheelReporting = true
        // 链接悬停即高亮，普通单击直接打开（默认要按住 ⌘）。拖动仍是选中文字。
        self.view.linkHighlightMode = .hover
        self.view.scrollSensitivity = 0.25
        super.init()
        configure(fontName: fontName, fontSize: fontSize)
        view.processDelegate = self
        start(options: options, agyOptions: agyOptions)
    }

    /// 按运行引擎返回对应的终端底色（Claude 保持 #202122，Antigravity 使用 #212734）。
    static func backgroundColor(for provider: AgentProvider) -> NSColor {
        provider == .antigravity ? kAntigravityTerminalBackground : kTerminalBackground
    }

    /// Antigravity 终端配色：#212734 深蓝灰底 + 柔和前景色 + 柔化 ANSI 16 色，
    /// 尤其将 Terminal.app 默认过饱和的深紫蓝（#492ee1 / #5833ff）替换为清晰柔和的浅蓝。
    private static let antigravityAnsiColors: [SwiftTerm.Color] = [
        // 常规 8 色（黑 / 红 / 绿 / 黄 / 蓝 / 品红 / 青 / 白）
        SwiftTerm.Color(red8: 0x19, green8: 0x1E, blue8: 0x2A),
        SwiftTerm.Color(red8: 0xE0, green8: 0x6C, blue8: 0x75),
        SwiftTerm.Color(red8: 0x98, green8: 0xC3, blue8: 0x79),
        SwiftTerm.Color(red8: 0xE5, green8: 0xC0, blue8: 0x7B),
        SwiftTerm.Color(red8: 0x73, green8: 0xB8, blue8: 0xF2),
        SwiftTerm.Color(red8: 0xC6, green8: 0x78, blue8: 0xDD),
        SwiftTerm.Color(red8: 0x56, green8: 0xB6, blue8: 0xC2),
        SwiftTerm.Color(red8: 0xB8, green8: 0xC0, blue8: 0xCC),
        // 高亮 8 色：降低纯白与原色刺眼度，保证深蓝底下的可读性
        SwiftTerm.Color(red8: 0x5C, green8: 0x67, blue8: 0x7A),
        SwiftTerm.Color(red8: 0xEB, green8: 0x82, blue8: 0x8A),
        SwiftTerm.Color(red8: 0xA9, green8: 0xD0, blue8: 0x8E),
        SwiftTerm.Color(red8: 0xED, green8: 0xCE, blue8: 0x93),
        SwiftTerm.Color(red8: 0x89, green8: 0xC4, blue8: 0xF4),
        SwiftTerm.Color(red8: 0xD3, green8: 0x94, blue8: 0xE5),
        SwiftTerm.Color(red8: 0x73, green8: 0xC9, blue8: 0xD4),
        SwiftTerm.Color(red8: 0xCF, green8: 0xD7, blue8: 0xE3),
    ]

    private static func theme(for provider: AgentProvider) -> TerminalTheme {
        switch provider {
        case .claude:
            return TerminalTheme(
                background: kTerminalBackground,
                foreground: NSColor(srgbRed: 0.86, green: 0.85, blue: 0.84, alpha: 1),
                caret: NSColor(srgbRed: 0.95, green: 0.55, blue: 0.35, alpha: 1),
                ansiColors: nil
            )
        case .antigravity:
            return TerminalTheme(
                background: kAntigravityTerminalBackground,
                foreground: NSColor(srgbRed: 0xC5 / 255.0, green: 0xCD / 255.0, blue: 0xD9 / 255.0, alpha: 1),
                caret: NSColor(srgbRed: 0.95, green: 0.55, blue: 0.35, alpha: 1),
                ansiColors: antigravityAnsiColors
            )
        }
    }

    private func configure(fontName: String, fontSize: Double) {
        let theme = Self.theme(for: provider)
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        if let ansiColors = theme.ansiColors {
            view.installColors(ansiColors)
        }
        applyFont(fontName: fontName, fontSize: fontSize)
        view.caretColor = theme.caret
    }

    func applyFont(fontName: String, fontSize: Double) {
        let size = CGFloat(fontSize)
        let f = fontName.isEmpty
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : (NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
        view.font = f
    }

    private func start(options: RenderOptions, agyOptions: AgyRenderOptions) {
        guard !alive else { return }
        var args = ["-lc"]
        let cmd: String
        let execLabel: String
        switch provider {
        case .claude:
            var c = "exec claude"
            if let r = resumeId {
                c = "exec claude --resume \(shellQuote(r))"
            } else if let s = sessionId {
                c = "exec claude --session-id \(shellQuote(s))"
            }
            c += " " + options.flags()
            if resumeId == nil {
                if let name = displayName, !name.isEmpty { c += " --name \(shellQuote(name))" }
                // 提示词放在最后，前面加 `--` 防止以 `-` 开头的内容被当成选项
                if let prompt = initialPrompt, !prompt.isEmpty { c += " -- \(shellQuote(prompt))" }
            }
            cmd = c
            execLabel = "claude"
        case .antigravity:
            var c = "exec agy"
            if let r = resumeId, !r.isEmpty {
                c = "exec agy --conversation \(shellQuote(r))"
            }
            let flags = agyOptions.flags()
            if !flags.isEmpty { c += " " + flags }
            if resumeId == nil, let prompt = initialPrompt, !prompt.isEmpty {
                c += " -i \(shellQuote(prompt))"
            }
            cmd = c
            execLabel = "agy"
        }
        args.append(cmd)
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        view.startProcess(executable: "/bin/zsh", args: args, environment: env,
                          execName: execLabel, currentDirectory: cwd)
        alive = true
        readyAt = Date().addingTimeInterval(provider == .antigravity ? 2.2 : 1.6)
        if provider == .antigravity {
            startAgyBusyMonitor()
        }
    }

    private func startAgyBusyMonitor() {
        agyWatchTimer?.invalidate()
        agyWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.alive, !self.terminating, !self.hasProgramStatus,
                      let cid = self.boundConversationId, !cid.isEmpty else { return }
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let working = AgySessionScanner.isConversationBusy(id: cid)
                    Task { @MainActor [weak self] in
                        guard let self, self.alive, !self.terminating, !self.hasProgramStatus else { return }
                        if working, !self.busy, Date() < self.suppressUntil || Date() < self.userInputUntil { return }
                        self.updateBusy(working)
                    }
                }
            }
        }
    }

    /// 往 PTY 里打字（等同用户键盘输入）
    @discardableResult
    func send(_ text: String) -> Bool {
        guard alive, Date() >= readyAt, let proc = view.process, proc.running else { return false }
        let bytes = ArraySlice(Array(text.utf8))
        proc.send(data: bytes)
        return true
    }

    /// 把输入框里的一段提示词交给 claude：按「粘贴」送进去（多行内容走括号粘贴，不会被逐行提交），
    /// 稍等一下再回车。会话还没准备好时返回 false，由调用方稍后重试。
    @MainActor @discardableResult
    func submit(_ text: String) -> Bool {
        guard isReady, let proc = view.process, proc.running else { return false }
        view.pasteText(text.replacingOccurrences(of: "\r\n", with: "\n"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.send("\r")
        }
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
        agyWatchTimer?.invalidate()
        agyWatchTimer = nil
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
        agyWatchTimer?.invalidate()
        agyWatchTimer = nil
        updateBusy(false)
        hasProgramStatus = false
        alive = false
        if natural { onExit?() }
    }
}

/// 终端视图：SwiftTerm 默认不给右键菜单，这里补上「复制 / 粘贴 / 全选」，
/// 否则选中文本后没有任何途径把内容放进剪贴板。
final class CopyableTerminalView: LocalProcessTerminalView {
    /// 开启鼠标上报后，CLI 进入鼠标模式时 SwiftTerm 会把右键发给 CLI，菜单弹不出来。
    /// 右键始终留给本地菜单，保证选中后能复制。
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func rightMouseUp(with event: NSEvent) {}

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
