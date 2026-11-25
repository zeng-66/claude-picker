import Foundation

/// Read quota through the installed CLI. Authentication and account selection stay with Codex.
enum CodexUsage {
    struct Snapshot: Sendable {
        let windows: [Window]
        let fetchedAt: Date

        struct Window: Decodable, Sendable {
            let usedPercent: Double
            let windowDurationMins: Int
            let resetsAt: TimeInterval?
        }
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            struct Limits: Decodable {
                let primary: Snapshot.Window?
                let secondary: Snapshot.Window?
            }
            let rateLimits: Limits
        }
        let id: Int?
        let result: Result?
    }

    private final class ResponseBuffer: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var buffer = Data()
        private var complete = false
        private var payload: Snapshot?

        func receive(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !complete else { return }
            buffer.append(data)
            if data.isEmpty || buffer.count > 1_048_576 {
                complete = true
                done.signal()
                return
            }
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                let response = try? JSONDecoder().decode(Response.self, from: line)
                buffer.removeSubrange(...end)
                guard response?.id == 2 else { continue }
                if let limits = response?.result?.rateLimits {
                    let windows = [limits.primary, limits.secondary].compactMap { $0 }.filter {
                        (0...100).contains($0.usedPercent) && $0.windowDurationMins > 0
                    }
                    if !windows.isEmpty { payload = Snapshot(windows: windows, fetchedAt: Date()) }
                }
                complete = true
                done.signal()
                return
            }
        }

        func result() -> Snapshot? {
            lock.lock()
            defer { lock.unlock() }
            return payload
        }
    }

    static func fetch() -> Snapshot? {
        guard let executable = CliBinaryLocator.find(.codex) else { return nil }
        let task = Process()
        let input = Pipe()
        let output = Pipe()
        let buffer = ResponseBuffer()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["app-server", "--listen", "stdio://"]
        task.environment = LoginEnv.shared.environment
        task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { buffer.receive($0.availableData) }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if task.isRunning { task.terminate() }
        }
        guard (try? task.run()) != nil else { return nil }
        let requests = """
        {"id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-picker","version":"1.0"}}}
        {"method":"initialized"}
        {"id":2,"method":"account/rateLimits/read","params":{}}

        """
        guard (try? input.fileHandleForWriting.write(contentsOf: Data(requests.utf8))) != nil else { return nil }
        guard buffer.done.wait(timeout: .now() + 8) == .success else { return nil }
        return buffer.result()
    }
}
