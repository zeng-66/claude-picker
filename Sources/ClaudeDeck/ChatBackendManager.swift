import Foundation
import Darwin

/// 图形聊天模式的本地 Node 服务（Swttch backend）。
///
/// 一个 App 实例只启动一份服务；后台会话由服务维护，WebView 关闭或重建不结束任务。
/// 服务只绑定 loopback，端口由系统分配（PORT=0），每次启动生成新的 token 与一次性配对码。
/// token 只存在于内存和子进程环境变量里，不写日志。
@MainActor
final class ChatBackendManager: ObservableObject {
    static let shared = ChatBackendManager()

    enum State: Equatable {
        case idle
        case starting
        case ready(port: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// 本次启动的一次性配对码，仅首次加载页面时放进 URL；页面用它换取 token。
    private(set) var pairCode = ""
    private var token = ""
    private var process: Process?
    private var stopping = false
    private var stdoutBuffer = ""
    private var startTimeout: DispatchWorkItem?

    var isRunning: Bool { process != nil }

    var port: Int? {
        if case .ready(let p) = state { return p }
        return nil
    }

    // MARK: 定位运行时与资源

    /// Swttch 产物根目录：需含 backend/dist/backend.mjs 与 webview/dist/index.html。
    /// 依次查找：app 内置资源 → 环境变量 → 设置 → 用户主目录下的 project/swttch（开发期）。
    static func locateSwttch(setting: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("swttch")) }
        if let env = ProcessInfo.processInfo.environment["CLAUDE_PICKER_SWTTCH_DIR"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if !setting.isEmpty { candidates.append(URL(fileURLWithPath: (setting as NSString).expandingTildeInPath)) }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("project/swttch"))
        return candidates.first { isSwttchRoot($0) }
    }

    static func isSwttchRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("backend/dist/backend.mjs").path)
            && fm.fileExists(atPath: url.appendingPathComponent("webview/dist/index.html").path)
    }

    /// Node 可执行文件：app 内置 → 设置 / 环境变量 → 登录 shell 的 PATH → nvm → Homebrew。
    /// 从 Finder 启动时不能假定继承了终端 PATH，所以这里逐个兜底。
    static func locateNode(setting: String, loginPath: String) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("node/bin/node").path) }
        if !setting.isEmpty { candidates.append((setting as NSString).expandingTildeInPath) }
        if let env = ProcessInfo.processInfo.environment["CLAUDE_PICKER_NODE"], !env.isEmpty { candidates.append(env) }
        for dir in loginPath.split(separator: ":") { candidates.append("\(dir)/node") }
        let nvm = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvm.path) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += sorted.map { nvm.appendingPathComponent("\($0)/bin/node").path }
        }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// 登录 shell 的 PATH，供 backend 查找 claude 与它自己派生的命令。只取一次。
    static let loginShellPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let fallback = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        guard (try? p.run()) != nil else { return fallback }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return fallback }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return s.isEmpty ? fallback : s
    }()

    static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePicker/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("chat-backend.log")
    }

    // MARK: 生命周期

    /// 未运行时启动；已在启动或已就绪时什么也不做。
    func ensureStarted(settings: AppSettings) {
        switch state {
        case .starting, .ready: return
        case .idle, .failed: start(settings: settings)
        }
    }

    func start(settings: AppSettings) {
        guard process == nil else { return }
        let loginPath = Self.loginShellPath
        guard let root = Self.locateSwttch(setting: settings.swttchDir) else {
            state = .failed("找不到图形聊天资源（backend/dist 与 webview/dist）。请在设置里指定 Swttch 目录，或先构建上游。")
            return
        }
        guard let node = Self.locateNode(setting: settings.nodePath, loginPath: loginPath) else {
            state = .failed("找不到 Node.js（需要 18 以上）。请安装 Node，或在设置里指定 node 路径。")
            return
        }

        token = Self.randomHex(32)
        pairCode = Self.randomHex(12)
        stopping = false
        stdoutBuffer = ""

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [root.appendingPathComponent("backend/dist/backend.mjs").path]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        let nodeDir = (node as NSString).deletingLastPathComponent
        env["PATH"] = nodeDir + ":" + loginPath
        env["PORT"] = "0"
        env["CCG_BIND"] = "127.0.0.1"
        env["CCG_AUTH_TOKEN"] = token
        env["CCG_INITIAL_PAIR_CODE"] = pairCode
        env["WEBVIEW_DIR"] = root.appendingPathComponent("webview/dist").path
        // App 退出或崩溃时 backend 自行关闭，并结束它拥有的 CLI 子进程。
        env["CCG_HOST_PID"] = String(getpid())
        // 生命周期由本 App 管理，不让 backend 因暂时没有页面连接而自行退出。
        env["CCG_DISABLE_IDLE_SHUTDOWN"] = "true"
        env["NODE_ENV"] = "production"
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardInput = FileHandle.nullDevice
        if let log = Self.openLog() {
            p.standardError = log
        } else {
            p.standardError = FileHandle.nullDevice
        }

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.consumeStdout(s) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor [weak self] in self?.didExit(proc, code: code) }
        }

        do {
            try p.run()
        } catch {
            state = .failed("启动 Node 服务失败：\(error.localizedDescription)")
            return
        }
        process = p
        state = .starting

        // 等待明确的就绪信号（stdout 首行 PORT:n），超时视为失败。
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .starting else { return }
                self.state = .failed("Node 服务 20 秒内未就绪，详见日志：\(Self.logURL.path)")
                self.stop()
            }
        }
        startTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    private func consumeStdout(_ chunk: String) {
        stdoutBuffer += chunk
        while let nl = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<nl]).trimmingCharacters(in: .whitespaces)
            stdoutBuffer.removeSubrange(...nl)
            if state == .starting, let port = Self.parsePortLine(line) {
                startTimeout?.cancel()
                state = .ready(port: port)
            }
        }
    }

    static func parsePortLine(_ line: String) -> Int? {
        guard line.hasPrefix("PORT:"), let n = Int(line.dropFirst(5)), n > 0, n < 65536 else { return nil }
        return n
    }

    private func didExit(_ proc: Process, code: Int32) {
        guard proc === process else { return }
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        startTimeout?.cancel()
        if stopping {
            state = .idle
        } else {
            // 服务崩溃不自动重启、不重发消息，交给用户决定是否恢复，避免重复执行工具。
            state = .failed("Node 服务已退出（代码 \(code)），详见日志：\(Self.logURL.path)")
        }
    }

    /// 异步停止：先 SIGTERM（backend 会结束自己的 CLI 子进程），3 秒后仍在则 SIGKILL。
    func stop() {
        guard let p = process else { state = .idle; return }
        stopping = true
        let pid = p.processIdentifier
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// 退出 App 时同步停止，受控超时兜底；只结束本 App 启动的那一个进程。
    func stopAndWait(timeout: TimeInterval = 3) {
        guard let p = process else { return }
        stopping = true
        p.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil
        state = .idle
    }

    // MARK: 会话控制（/internal/session-control）

    /// 对 backend 持有 CLI 的会话发控制请求：set_permission_mode / set_model / interrupt。
    /// backend 没有该会话的进程时返回 false（新设置会在下次启动时生效）。
    func sessionControl(sessionId: String, action: String, extra: [String: String] = [:]) async -> Bool {
        guard let port else { return false }
        guard let url = URL(string: "http://127.0.0.1:\(port)/internal/session-control") else { return false }
        var body: [String: String] = ["sessionId": sessionId, "action": action]
        for (k, v) in extra { body[k] = v }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "x-ccg-token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 5
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: 工具

    private static func randomHex(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        b.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        return b.map { String(format: "%02x", $0) }.joined()
    }

    private static func openLog() -> FileHandle? {
        let url = logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // 超过 5MB 截断，避免无限增长。
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            try? Data().write(to: url)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        return h
    }
}
