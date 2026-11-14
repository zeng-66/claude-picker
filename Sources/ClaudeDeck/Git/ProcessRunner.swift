import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 全模块唯一的 login shell 路径。外部命令（git 等）必须经它启动才能继承用户的 PATH，
/// 与 `TerminalPane.swift:76` 的既有做法一致；新代码只认这个常量，不要在别处再写字面量。
let loginShellPath = "/bin/zsh"

/// 一次外部命令的结果。跨并发域只传值，所以是 Sendable。
struct ProcessOutput: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

/// 进程层自己的失败原因。GitService 会把它翻成 SPEC 里的 COMMAND_FAILED，
/// 但保留可辨识的类型，便于调用方区分「命令失败」和「命令没跑完」。
enum ProcessRunnerError: Error, Sendable, Equatable {
    case timedOut(command: String, seconds: TimeInterval)
    case cancelled(command: String)
    case launchFailed(command: String, reason: String)

    var message: String {
        switch self {
        case let .timedOut(command, seconds):
            return "命令超时（\(Int(seconds))s）：\(command)"
        case let .cancelled(command):
            return "命令已取消：\(command)"
        case let .launchFailed(command, reason):
            return "命令启动失败：\(command)（\(reason)）"
        }
    }
}

/// 唯一执行外部命令的地方。
///
/// 调用方只给「可执行文件 + 参数数组」，拼 shell 命令行这件事在这里一次做完：
/// 每个参数单引号包裹、内部单引号按 POSIX 规则写成 `'\''`，因此分支名/文件名里的
/// 空格、引号、`$`、`;` 都只是字面量，不会被 shell 解释。
actor ProcessRunner {
    static let shared = ProcessRunner()
    static let defaultTimeout: TimeInterval = 30
    /// 收到 terminate 后仍不退出的进程，再等这么久补一个 SIGKILL。
    static let killGracePeriod: TimeInterval = 2

    private var running: [UUID: ProcessBox] = [:]

    // MARK: - 执行

    func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        timeout: TimeInterval = ProcessRunner.defaultTimeout
    ) async throws -> ProcessOutput {
        let commandLine = Self.shellCommand(executable: executable, arguments: arguments)
        let box = try ProcessBox(command: commandLine)
        let id = UUID()
        running[id] = box
        defer {
            box.cleanup()
            running[id] = nil
        }

        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(timeout, 0)))
            guard !Task.isCancelled else { return }
            await self?.stop(id: id, reason: .timedOut)
        }
        defer { watchdog.cancel() }

        let outcome = await withTaskCancellationHandler {
            await Self.execute(box, workingDirectory: workingDirectory)
        } onCancel: {
            Task { await self.stop(id: id, reason: .cancelled) }
        }

        if let reason = box.stopReason {
            switch reason {
            case .timedOut: throw ProcessRunnerError.timedOut(command: commandLine, seconds: timeout)
            case .cancelled: throw ProcessRunnerError.cancelled(command: commandLine)
            }
        }
        if let reason = outcome.launchError {
            throw ProcessRunnerError.launchFailed(command: commandLine, reason: reason)
        }
        return ProcessOutput(exitCode: outcome.exitCode,
                             stdout: String(decoding: outcome.stdout, as: UTF8.self),
                             stderr: String(decoding: outcome.stderr, as: UTF8.self))
    }

    // MARK: - 内部

    private func stop(id: UUID, reason: ProcessBox.StopReason) {
        running[id]?.stop(reason)
    }

    private static func execute(_ box: ProcessBox, workingDirectory: String?) async -> ProcessBox.Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: box.execute(workingDirectory: workingDirectory))
            }
        }
    }

    private static func briefFailure(_ output: ProcessOutput) -> String {
        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "退出码 \(output.exitCode)" : stderr
    }

    // MARK: - shell 转义

    /// 单引号包裹；字符串里的 `'` 写成 `'\''`。
    static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 组装 `zsh -lc` 的命令行。`exec` 让 shell 被目标进程替换，退出码就是目标进程的。
    static func shellCommand(executable: String, arguments: [String]) -> String {
        (["exec", shellQuote(executable)] + arguments.map(shellQuote)).joined(separator: " ")
    }
}

// MARK: - 单次进程

/// 一次进程执行的可变状态。
///
/// `Process` / `FileHandle` 都不是 Sendable，这里按「谁碰谁负责」收敛：
/// - 启动与等待只在 `execute` 所在的唯一后台线程上发生；
/// - 其它线程只经 `NSLock` 读写停止原因，并调 `terminate` / `kill`。
/// 因此标 `@unchecked Sendable`，而不是把构建配置改成非严格并发。
private final class ProcessBox: @unchecked Sendable {
    enum StopReason: Sendable {
        case timedOut
        case cancelled
    }

    struct Outcome: Sendable {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        var launchError: String?
    }

    let command: String
    private let process = Process()
    private let lock = NSLock()
    private var stopped: StopReason?
    private var started = false
    private var finished = false
    private let workDirectory: URL
    private let stdoutURL: URL
    private let stderrURL: URL

    init(command: String) throws {
        self.command = command
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-picker-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        stdoutURL = workDirectory.appendingPathComponent("stdout")
        stderrURL = workDirectory.appendingPathComponent("stderr")
    }

    var stopReason: StopReason? {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop(_ reason: StopReason) {
        lock.lock()
        if stopped == nil { stopped = reason }
        let shouldSignal = started && !finished
        lock.unlock()
        guard shouldSignal, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ProcessRunner.killGracePeriod) { [self] in
            if process.isRunning, pid > 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// stdout/stderr 落到临时文件而不是管道：管道写满 64KB 就会卡住子进程，
    /// 而这里要等它退出，用文件可以彻底避开这个死锁。
    func execute(workingDirectory: String?) -> Outcome {
        guard begin() else {
            return Outcome(exitCode: 0, stdout: Data(), stderr: Data(), launchError: nil)
        }
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: stdoutURL),
              let errHandle = try? FileHandle(forWritingTo: stderrURL) else {
            finish()
            return Outcome(exitCode: 0, stdout: Data(), stderr: Data(),
                           launchError: "无法创建临时输出文件")
        }

        process.executableURL = URL(fileURLWithPath: loginShellPath)
        process.arguments = ["-lc", command]
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            finish()
            return Outcome(exitCode: 0, stdout: Data(), stderr: Data(),
                           launchError: error.localizedDescription)
        }
        // 取消/超时可能在 begin() 之后、run() 之前发生，这里补一刀。
        if stopReason != nil { process.terminate() }

        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()
        let stdout = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderr = (try? Data(contentsOf: stderrURL)) ?? Data()
        finish()
        return Outcome(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr, launchError: nil)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stopped == nil else { return false }
        started = true
        return true
    }

    private func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}
