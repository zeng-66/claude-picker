import AppKit
import Darwin
import SwiftUI
import SwiftTerm

/// 一个内嵌终端会话：包装 LocalProcessTerminalView，负责启停 claude。
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    @Published private(set) var title: String = ""
    @Published private(set) var alive = false
    /// 终端正在吐字 → true；停 1 秒无输出 → false。会话行转圈只认这个。
    @Published private(set) var busy = false
    /// 标题通道（OSC 0 spinner）新鲜期：claude 忙时每 960ms 重写一次标题（◐ ◑ 交替），
    /// 空闲时写一次 ✳。新鲜期内 busy 以标题为准，CPU 采样让位；
    /// 过期后（如设了 CLAUDE_CODE_DISABLE_TERMINAL_TITLE）回落 CPU 启发式。
    private var titleFreshUntil = Date.distantPast
    private static let kTitleFreshSeconds: TimeInterval = 5.0
    /// 见过带 spinner 前缀的标题（◐/✳/>/*）→ 标题通道确认活着，
    /// busy 之后全听标题的；CPU 启发式只给关了标题通道的场景兜底。
    private var titleChannelActive = false
    private var idleWork: DispatchWorkItem?
    let view: LocalProcessTerminalView
    let cwd: String
    private let resumeId: String?
    private let sessionId: String?
    /// 进程起来后一段时间内不接受注入命令（claude 还在初始化）
    private var readyAt = Date.distantFuture
    /// 切到这个会话后的短暂抑制期：挂载视图会触发 PTY resize → claude 整屏重绘，
    /// 那是重绘不是任务在跑，不能因此转圈。
    private var suppressUntil = Date.distantPast
    /// 直接采样 claude 进程的 CPU 时间来判断它是否真的在工作。
    /// 之前用「PTY 有输出」推断，但滚轮、打字、重绘都会产生输出，导致一直误转圈；
    /// CPU 时间只在模型真的生成、真的跑工具时才增长，这是唯一可靠的信号。
    private var cpuTimer: Timer?
    private var lastCpuNanos: UInt64 = 0
    private var lastCpuSample = Date.distantPast
    /// 连续几次采样都低于阈值才置闲，避免生成中的短暂停顿让转圈闪烁
    private var idleSamples = 0
    /// 一个采样窗口内 CPU 时间增长超过这个值就认为在跑。
    /// 实测（0.4 秒窗口）：空闲时 15k~155k 纳秒，claude 生成时 350k~4.1M 纳秒，
    /// 250k 正好落在两者之间。
    private static let kBusyCpuNanos: UInt64 = 250_000
    private static let kSampleInterval: TimeInterval = 0.4
    /// 连续两拍超阈值才算在跑，避免空闲时偶发的小尖峰误转圈
    private var busySamples = 0
    /// 是否正显示在右侧；后台输出才算「未读」
    private var isForeground = true
    /// 用户主动关闭（terminate）时为 true，此时进程退出不算「自然结束」
    private var terminating = false
    /// 用户刚在终端里操作过（按键 / 滚轮 / 点击 / 拖拽）→ 这段时间内的输出是回显和重绘，
    /// 不能当成「claude 在跑」。TUI 对每次按键都会重绘，滚轮也会刷新状态栏。
    private var userInputUntil = Date.distantPast
    /// 进程自然退出（claude 结束）时回调，用于给会话行打绿点
    var onExit: (() -> Void)?
    /// 输出/空闲状态翻转时回调（只在真正翻转时触发，避免每批输出都通知 Store）
    var onBusy: ((Bool) -> Void)?

    init(cwd: String, resumeId: String?, sessionId: String? = nil,
         options: RenderOptions, fontName: String, fontSize: Double) {
        self.cwd = cwd
        self.resumeId = resumeId
        self.sessionId = sessionId
        self.view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        // claude 的 TUI 用不上鼠标；关掉 mouse reporting 后，直接用鼠标拖拽就能选中文字复制，
        // 不用先按住 shift（开启时拖拽事件会全部发给程序，屏幕上选不中任何东西）。
        self.view.allowMouseReporting = false
        super.init()
        configure(fontName: fontName, fontSize: fontSize)
        view.processDelegate = self
        start(options: options)
        // 会话行转圈只认 claude 进程的 CPU 时间，不看 PTY 输出（滚轮、打字、重绘都会产出输出）
        startCpuSampling()
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
        lastCpuNanos = processCpuNanos() ?? 0
        lastCpuSample = Date.distantPast
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

    /// 会话被切到前台：立刻置闲，并在抑制期内忽略重绘输出
    /// （视图重新挂载会触发 PTY resize，claude 会整屏重绘，那不是任务在跑）。
    @MainActor func noteActivated() {
        idleWork?.cancel()
        suppressUntil = Date().addingTimeInterval(1.2)
        isForeground = true
        awayOutput = false
        titleFreshUntil = Date.distantPast
        if busy { busy = false; onBusy?(false) }
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
        awayOutput = false
    }

    /// 后台期间真的产出过输出 → 才值得给会话行打绿点。
    private(set) var awayOutput = false

    /// 启动 CPU 采样：claude 在生成回复、执行工具时 CPU 时间持续增长；
    /// 空闲等输入时几乎不增长。这是判断「任务是否真在跑」的唯一可靠信号——
    /// PTY 输出不可靠，滚轮/打字/重绘都会产生输出。
    private func startCpuSampling() {
        cpuTimer?.invalidate()
        let t = Timer(timeInterval: Self.kSampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleCpu() }
        }
        RunLoop.main.add(t, forMode: .common)
        cpuTimer = t
    }

    /// 读进程累计 CPU 时间（user + system）。
    private func processCpuNanos() -> UInt64? {
        var info = rusage_info_current()
        let pid = self.pid
        guard pid > 0 else { return nil }
        let ok = withUnsafeMutablePointer(to: &info) { p -> Bool in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { pp in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, pp) == 0
            }
        }
        guard ok else { return nil }
        return info.ri_user_time + info.ri_system_time
    }

    @MainActor private func sampleCpu() {
        let now = Date()
        defer { lastCpuSample = now }
        guard let nanos = processCpuNanos() else { return }
        let delta = nanos >= lastCpuNanos ? nanos - lastCpuNanos : 0
        // 抑制期内也要推进基线：否则窗口一过，第一拍会把整段抑制期攒下的
        // CPU（resume 启动、打字重绘）当成一次爆发，误判成忙。
        lastCpuNanos = nanos
        guard Date() >= suppressUntil, now >= userInputUntil else { return }
        // 进程刚起来时 lastCpuNanos 是 0，第一拍必然是大数字，跳过这一次
        guard lastCpuSample != Date.distantPast else { return }
        // 标题通道确认在写 spinner 后就以标题为准，CPU 采样不再翻转状态
        guard !titleChannelActive, now >= titleFreshUntil else { return }
        if delta >= Self.kBusyCpuNanos {
            idleSamples = 0
            busySamples += 1
            // 连续两拍（约 0.8 秒）都在算才转圈
            guard busy || busySamples >= 2 else { return }
            if !busy {
                busy = true
                onBusy?(true)
            }
            if !isForeground { awayOutput = true }
        } else {
            busySamples = 0
            idleSamples += 1
            // 连续 2 拍（约 0.8 秒）都没 CPU 增长才算真的停下
            if busy && idleSamples >= 2 {
                busy = false
                onBusy?(false)
            }
        }
    }

    func terminate() {
        guard alive else { return }
        terminating = true
        idleWork?.cancel()
        cpuTimer?.invalidate()
        cpuTimer = nil
        busy = false
        view.terminate()
        alive = false
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !title.isEmpty else { return }
        let (clean, spin) = Self.parseSpinnerTitle(title)
        if !clean.isEmpty { self.title = clean }
        guard let spin else { return }
        // 见到 spinner 前缀说明标题通道活着：CPU 启发式从此退场
        titleChannelActive = true
        // 滚轮会向全屏 TUI 发 PgUp/PgDn，claude 处理按键时的重绘标题也带 spinner，
        // 用户输入抑制期（0.8s）内不把它当成忙；真在跑的话下一帧标题会补上。
        if spin, Date() < userInputUntil { return }
        titleFreshUntil = Date().addingTimeInterval(Self.kTitleFreshSeconds)
        if busy != spin {
            busy = spin
            onBusy?(spin)
        }
        if spin, !isForeground { awayOutput = true }
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
        idleWork?.cancel()
        cpuTimer?.invalidate()
        cpuTimer = nil
        busy = false
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
