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

/// 终端中点击的文件链接解析结果：用于在第三栏预览并按需定位到指定行。
struct TerminalFileTarget: Equatable, Sendable {
    let projectPath: String
    let path: String
    let displayPath: String
    let line: Int?
    let column: Int?
}

/// 将 SwiftTerm 捕获到的链接文本解析为本地文件目标。
/// 网页链接（http/https）与其他协议返回 nil，交由 SwiftTerm 原有安全校验与系统浏览器处理。
enum TerminalLinkResolver {
    private static let numericSchemes: Set<String> = [
        "tel", "sms", "facetime", "facetime-audio", "callto", "fax",
    ]

    static func resolve(
        link rawLink: String,
        isExplicit: Bool,
        cwd: String,
        projectRoot: String? = nil,
        hostCurrentDirectory: String? = nil,
        fileManager: FileManager = .default
    ) -> TerminalFileTarget? {
        let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\0"),
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }

        let extracted: (path: String, line: Int?, column: Int?)
        if trimmed.lowercased().hasPrefix("file://") {
            guard let parsed = parseFileURL(trimmed) else { return nil }
            extracted = parsed
        } else {
            // OSC 8 显式超链接若非 file://，一律交由 SwiftTerm 按协议校验。
            if isExplicit { return nil }
            // 带协议头的 URL（http/https/mailto/ssh 等）不拦截，交给系统浏览器或 SwiftTerm 校验。
            if hasURLScheme(trimmed) { return nil }
            extracted = splitLocationSuffix(trimmed, cwd: cwd, hostCurrentDirectory: hostCurrentDirectory, fileManager: fileManager)
        }

        let expandedPath = (extracted.path as NSString).expandingTildeInPath
        guard !expandedPath.isEmpty else { return nil }

        let resolvedURL: URL
        if expandedPath.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        } else {
            let baseDir = chooseBaseDirectory(for: expandedPath,
                                              cwd: cwd,
                                              hostCurrentDirectory: hostCurrentDirectory,
                                              fileManager: fileManager)
            resolvedURL = URL(fileURLWithPath: expandedPath, relativeTo: URL(fileURLWithPath: baseDir, isDirectory: true))
                .standardizedFileURL
        }

        let normalizedCwd = normalizeDir(cwd)
        let normalizedProject = projectRoot.map(normalizeDir)
        let candidateForBoundary = fileManager.fileExists(atPath: resolvedURL.path)
            ? resolvedURL.resolvingSymlinksInPath().standardizedFileURL
            : resolvedURL.standardizedFileURL
        let candidatePath = trimTrailingSlash(candidateForBoundary.path)

        if isInside(candidatePath, root: normalizedCwd) {
            let rel = relativePath(candidatePath, root: normalizedCwd)
            return TerminalFileTarget(projectPath: normalizedCwd,
                                      path: rel.isEmpty ? "." : rel,
                                      displayPath: candidatePath,
                                      line: extracted.line,
                                      column: extracted.column)
        }
        if let normalizedProject, isInside(candidatePath, root: normalizedProject) {
            let rel = relativePath(candidatePath, root: normalizedProject)
            return TerminalFileTarget(projectPath: normalizedProject,
                                      path: rel.isEmpty ? "." : rel,
                                      displayPath: candidatePath,
                                      line: extracted.line,
                                      column: extracted.column)
        }
        // 越界路径也交由第三栏走 FileService 边界检查并反馈可读提示，而不是绕过直接用 Finder/外部程序打开。
        return TerminalFileTarget(projectPath: normalizedCwd,
                                  path: candidatePath,
                                  displayPath: candidatePath,
                                  line: extracted.line,
                                  column: extracted.column)
    }

    private static func parseFileURL(_ raw: String) -> (path: String, line: Int?, column: Int?)? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "file" else { return nil }
        if let host = components.host, !host.isEmpty, !isLocalHost(host) {
            return nil
        }
        var path = components.path
        guard !path.isEmpty else { return nil }
        var line: Int?
        var column: Int?
        if let fragment = components.fragment, !fragment.isEmpty {
            let (fLine, fCol) = parseLineFragment(fragment)
            line = fLine
            column = fCol
        }
        if line == nil, let (stripped, sLine, sCol) = stripTrailingColonLocation(path) {
            path = stripped
            line = sLine
            column = sCol
        }
        return (path, line, column)
    }

    private static func parseLineFragment(_ fragment: String) -> (Int?, Int?) {
        // 支持 #L12、#L12C4、#L12-L20、#12、#12:4
        let clean = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = clean.range(of: #"^[Ll]?([0-9]+)(?:[Cc:]([0-9]+))?"#, options: .regularExpression) {
            let matched = String(clean[match])
            let nums = matched.split { !$0.isNumber }.compactMap { Int($0) }
            if let first = nums.first, first > 0 {
                return (first, nums.count > 1 && nums[1] > 0 ? nums[1] : nil)
            }
        }
        return (nil, nil)
    }

    private static func splitLocationSuffix(
        _ raw: String,
        cwd: String,
        hostCurrentDirectory: String?,
        fileManager: FileManager
    ) -> (path: String, line: Int?, column: Int?) {
        let expanded = (raw as NSString).expandingTildeInPath
        let directPath = expanded.hasPrefix("/")
            ? expanded
            : URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
        if fileManager.fileExists(atPath: directPath) {
            return (raw, nil, nil)
        }
        if let (stripped, line, column) = stripTrailingColonLocation(raw) {
            return (stripped, line, column)
        }
        return (raw, nil, nil)
    }

    private static func stripTrailingColonLocation(_ text: String) -> (String, Int, Int?)? {
        guard let range = text.range(of: #":([0-9]+)(?::([0-9]+))?$"#, options: .regularExpression) else {
            return nil
        }
        let suffix = String(text[range].dropFirst())
        let parts = suffix.split(separator: ":").compactMap { Int($0) }
        guard let line = parts.first, line > 0 else { return nil }
        let column = parts.count > 1 && parts[1] > 0 ? parts[1] : nil
        let base = String(text[..<range.lowerBound])
        guard !base.isEmpty else { return nil }
        return (base, line, column)
    }

    private static func hasURLScheme(_ link: String) -> Bool {
        guard let scheme = URL(string: link)?.scheme else { return false }
        if numericSchemes.contains(scheme.lowercased()) { return true }
        return link.range(of: #"^[^:/]+:[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) == nil
    }

    private static func chooseBaseDirectory(
        for relativePath: String,
        cwd: String,
        hostCurrentDirectory: String?,
        fileManager: FileManager
    ) -> String {
        if let oscDir = localDirectory(from: hostCurrentDirectory) {
            let candidate = URL(fileURLWithPath: relativePath, relativeTo: URL(fileURLWithPath: oscDir, isDirectory: true))
                .standardizedFileURL.path
            if fileManager.fileExists(atPath: candidate) {
                return oscDir
            }
        }
        return cwd
    }

    private static func localDirectory(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") { return raw }
        guard let url = URL(string: raw), url.scheme?.lowercased() == "file", !url.path.isEmpty else { return nil }
        if let host = url.host, !host.isEmpty, !isLocalHost(host) { return nil }
        return url.path
    }

    private static func isLocalHost(_ host: String) -> Bool {
        func short(_ value: String) -> String {
            let lower = value.lowercased()
            return lower.hasSuffix(".local") ? String(lower.dropLast(6)) : lower
        }
        if host.isEmpty || host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        var buf = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buf, buf.count - 1) == 0 else { return false }
        return short(host) == short(String(cString: buf))
    }

    private static func normalizeDir(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
        return trimTrailingSlash(resolved)
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func relativePath(_ path: String, root: String) -> String {
        if path == root { return "" }
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }
}

/// 一个内嵌终端会话：包装 LocalProcessTerminalView，负责启停 claude。
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    /// 启动 CLI 的 zsh 的 argv[0]。不能用 CLI 名：见 `start` 里的说明（c 开头会触发 csh 仿真）。
    static let shellArgv0 = "zsh"

    @Published private(set) var title: String = ""
    @Published private(set) var alive = false
    /// 优先使用 OSC 7501 任务状态，兼容旧版 CLI 的 OSC 标题忙闲信号。
    @Published private(set) var busy = false
    private var hasProgramStatus = false
    let view: LocalProcessTerminalView
    let cwd: String
    let projectRoot: String?
    let provider: AgentProvider
    var boundConversationId: String?
    private var hostDirectory: String?
    private let resumeId: String?
    private let sessionId: String?
    private let displayName: String?
    private let initialPrompt: String?
    private var agyWatchTimer: Timer?
    private var hookReviewNotified = false
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
    /// 用户点击终端内的文件路径时回调，交由第三栏预览。
    var onOpenFile: ((TerminalFileTarget) -> Void)?

    /// - Parameters:
    ///   - provider: CLI 引擎（默认 `.claude`）。
    ///   - name: 新建会话的显示名（`claude --name`），恢复会话时忽略。
    ///   - prompt: 新建会话的首条提示词。
    init(cwd: String, resumeId: String?, sessionId: String? = nil,
         projectRoot: String? = nil,
         name: String? = nil, prompt: String? = nil,
         provider: AgentProvider = .claude,
         options: RenderOptions,
         agyOptions: AgyRenderOptions = AgyRenderOptions(),
         codexOptions: CodexRenderOptions = CodexRenderOptions(),
         fontName: String, fontSize: Double) {
        self.cwd = cwd
        self.projectRoot = projectRoot
        self.provider = provider
        self.boundConversationId = resumeId
        self.resumeId = resumeId
        self.sessionId = sessionId
        self.displayName = name
        self.initialPrompt = prompt
        let terminalView = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        self.view = terminalView
        // 鼠标点击交给 CLI：Claude Code 全屏界面里的「展开工具调用」「Jump to bottom」等
        // 都靠鼠标上报实现。CLI 没开鼠标模式时仍由终端本地选字；开了以后按住 Shift 或 Option 拖动强制本地选中。
        self.view.allowMouseReporting = true
        self.view.allowMouseWheelReporting = true
        // 链接悬停即高亮，普通单击直接打开（默认要按住 ⌘）。拖动仍是选中文字。
        self.view.linkHighlightMode = .hover
        self.view.scrollSensitivity = 0.25
        super.init()
        terminalView.linkInterceptor = { [weak self] request in
            self?.handleActivatedLink(request.link, isExplicit: request.isExplicit) ?? false
        }
        configure(fontName: fontName, fontSize: fontSize)
        view.processDelegate = self
        start(options: options, agyOptions: agyOptions, codexOptions: codexOptions)
    }

    @MainActor @discardableResult
    func handleActivatedLink(_ link: String, isExplicit: Bool = false) -> Bool {
        guard let target = TerminalLinkResolver.resolve(
            link: link,
            isExplicit: isExplicit,
            cwd: cwd,
            projectRoot: projectRoot,
            hostCurrentDirectory: hostDirectory
        ) else {
            return false
        }
        onOpenFile?(target)
        return true
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
        case .claude, .codex, .dsh:
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

    private func start(options: RenderOptions, agyOptions: AgyRenderOptions, codexOptions: CodexRenderOptions) {
        guard !alive else { return }
        var args = ["-lc"]
        let cmd: String
        switch provider {
        case .claude:
            let executable = shellQuote(CliBinaryLocator.find(provider) ?? provider.commandName)
            var c = "exec \(executable)"
            if let r = resumeId {
                c = "exec \(executable) --resume \(shellQuote(r))"
            } else if let s = sessionId {
                c = "exec \(executable) --session-id \(shellQuote(s))"
            }
            c += " " + options.flags()
            if resumeId == nil {
                if let name = displayName, !name.isEmpty { c += " --name \(shellQuote(name))" }
                // 提示词放在最后，前面加 `--` 防止以 `-` 开头的内容被当成选项
                if let prompt = initialPrompt, !prompt.isEmpty { c += " -- \(shellQuote(prompt))" }
            }
            cmd = c
        case .antigravity:
            let executable = shellQuote(CliBinaryLocator.find(provider) ?? provider.commandName)
            var c = "exec \(executable)"
            if let r = resumeId, !r.isEmpty {
                c = "exec \(executable) --conversation \(shellQuote(r))"
            }
            let flags = agyOptions.flags()
            if !flags.isEmpty { c += " " + flags }
            if resumeId == nil, let prompt = initialPrompt, !prompt.isEmpty {
                c += " -i \(shellQuote(prompt))"
            }
            cmd = c
        case .codex:
            let executable = shellQuote(CliBinaryLocator.find(provider) ?? provider.commandName)
            let flags = codexOptions.flags()
            var command = "exec \(executable)"
            if let resumeId {
                command += " resume"
                if !flags.isEmpty { command += " " + flags }
                command += " \(shellQuote(resumeId))"
            } else {
                if !flags.isEmpty { command += " " + flags }
                if let prompt = initialPrompt, !prompt.isEmpty {
                    command += " -- \(shellQuote(prompt))"
                }
            }
            cmd = command
        case .dsh:
            let executable = shellQuote(CliBinaryLocator.find(provider) ?? provider.commandName)
            var command = "exec \(executable) --backend dsh"
            if let resumeId {
                command += " --resume \(shellQuote(resumeId))"
            } else if let prompt = initialPrompt, !prompt.isEmpty {
                command += " -- \(shellQuote(prompt))"
            }
            cmd = command
        }
        // nvm 等安装的 CLI 是 `#!/usr/bin/env node` 脚本；`zsh -lc` 不读 .zshrc，找不到 node。
        // 把可执行文件所在目录放到 PATH 最前面，同目录里的 node 随之可用。
        if let found = CliBinaryLocator.find(provider) {
            let dir = (found as NSString).deletingLastPathComponent
            args.append("export PATH=\(shellQuote(dir)):\"$PATH\"; \(cmd)")
        } else {
            args.append(cmd)
        }
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        // argv[0] 必须是 zsh：zsh 按 argv[0] 首字母选择仿真模式，`claude`、`codex` 以 c 开头会进入 csh 仿真，
        // 开启 CSH_JUNKIE_QUOTES 后单引号字符串不能跨行，多行的接力信封会报 `zsh:1: unmatched '` 并直接退出。
        // exec 之后进程名由 CLI 自己决定，这里不需要用 CLI 名充当 argv[0]。
        view.startProcess(executable: "/bin/zsh", args: args, environment: env,
                          execName: Self.shellArgv0, currentDirectory: cwd)
        alive = true
        readyAt = Date().addingTimeInterval(provider == .dsh ? 3.0 : (provider == .antigravity ? 2.2 : 1.6))
        if provider == .antigravity {
            startAgyBusyMonitor()
        }
        if provider == .codex, ProcessInfo.processInfo.environment["CLAUDE_PICKER_TEST_SHELL"] == nil {
            for delay in [1.2, 2.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.alive, !self.terminating, !self.hookReviewNotified,
                              let snapshot = self.view.terminalContentSnapshot(region: .viewport) else { return }
                        let hasPrompt = snapshot.rows.contains { $0.text.contains("Hooks need review") }
                        if hasPrompt {
                            self.hookReviewNotified = true
                            Bridge.emit("claude-picker:command", detail: [
                                "name": "runtimeSavedNextLaunch",
                                "text": "Codex 检测到待确认 Hook：请在终端按方向键选择 Trust 或 Continue without trusting 回车后进入原对话",
                            ])
                        }
                    }
                }
            }
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

    /// 向终端 TUI（如 Ink 驱动的 dsh-tui）发送斜杠指令并稍候补发回车；若尚在启动窗口内则自动延迟到就绪后发送。
    @MainActor
    func sendSlashCommand(_ command: String) {
        let wait = max(0, readyAt.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.alive, !self.terminating, let proc = self.view.process, proc.running else { return }
            let bytes = ArraySlice(Array(command.utf8))
            proc.send(data: bytes)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.alive, !self.terminating, let p = self.view.process, p.running else { return }
                p.send(data: ArraySlice(Array("\r".utf8)))
            }
        }
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

    /// 结束终端并等整棵进程树真正退出后再回调（交接同一原始会话前必须如此，
    /// 例如 Codex 的 npm 启动器还会拉起原生子进程，子进程未退出前线程仍被它持有）。超时后强制结束残留进程。
    func terminateAndWait(timeout: TimeInterval = 6, completion: @escaping @MainActor (Bool) -> Void) {
        let root = pid
        guard alive, root > 0 else {
            terminate()
            completion(true)
            return
        }
        let tree = Self.processTree(root: root)
        terminate()
        // 同步向子进程树发 SIGTERM，避免 npm 启动器等拉起的原生子进程未随 PTY SIGHUP 及时退出。
        for child in tree where child != root { kill(child, SIGTERM) }
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            func running() -> [pid_t] { tree.filter { kill($0, 0) == 0 && !Self.isZombie($0) } }
            while !running().isEmpty, Date() < deadline { usleep(100_000) }
            var left = running()
            if !left.isEmpty {
                for pid in left { kill(pid, SIGKILL) }
                let hard = Date().addingTimeInterval(1.5)
                while !running().isEmpty, Date() < hard { usleep(100_000) }
                left = running()
            }
            let gone = left.isEmpty
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(gone) } }
        }
    }

    private nonisolated static func isZombie(_ pid: pid_t) -> Bool {
        let result = Proc.run("/bin/ps", ["-p", "\(pid)", "-o", "stat="], timeout: 2)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z")
    }

    /// 根进程及其全部后代（`ps` 的 pid/ppid 快照）。
    nonisolated static func processTree(root: pid_t) -> [pid_t] {
        let result = Proc.run("/bin/ps", ["-A", "-o", "pid=,ppid="], timeout: 5)
        var children: [pid_t: [pid_t]] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ").compactMap { pid_t($0) }
            if parts.count == 2 { children[parts[1], default: []].append(parts[0]) }
        }
        var out: [pid_t] = [root], queue = [root]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where !out.contains(child) {
                out.append(child)
                queue.append(child)
            }
        }
        return out
    }

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
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        hostDirectory = directory
    }
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
    /// 拦截终端内激活的链接：返回 true 表示已由宿主在第三栏打开，不再走系统默认打开流程。
    var linkInterceptor: ((TerminalLinkRequest) -> Bool)?

    override func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        if linkInterceptor?(request) == true { return }
        super.requestOpenLink(source: source, request: request)
    }

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
