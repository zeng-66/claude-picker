import Foundation
import CFNetwork

/// CLI 引擎的安装与维护：「可安装」目录（白名单命令，界面只能按 ID 触发）与 DeepSeek Harness 的版本巡检和升级。
/// 全部是同步调用，只能在后台线程用。
enum CliMaintenance {
    // MARK: 可安装

    struct Installable: Sendable {
        var id: String
        var label: String
        var command: String?
        /// 官方安装命令。只有登记在这里的命令才会执行，网页不能传入任意命令。
        var install: String?
        var homepage: String?
        var note: String
    }

    static let installables: [Installable] = [
        Installable(id: "qoder", label: "Qoder CLI", command: "qodercli",
                    install: "curl -fsSL https://qoder.com/install | bash", homepage: "https://qoder.com",
                    note: "官方安装脚本，装到 ~/.local/bin/qodercli。目前只做检测与安装，会话入口待接入。"),
        Installable(id: "pi", label: "Pi", command: "pi",
                    install: "curl -fsSL https://pi.dev/install.sh | sh", homepage: "https://docs.pi.dev/latest",
                    note: "官方安装脚本，命令为 pi。目前只做检测与安装，会话入口待接入。"),
        Installable(id: "workbuddy", label: "WorkBuddy", command: nil, install: nil, homepage: nil,
                    note: "CLI 启动入口待验证"),
    ]

    static func locate(_ command: String) -> String? {
        let home = NSHomeDirectory()
        return LoginEnv.shared.find(command, extra: ["\(home)/.local/bin/\(command)", "/opt/homebrew/bin/\(command)",
                                                     "/usr/local/bin/\(command)"])
    }

    static func version(of path: String) -> String? {
        let result = Proc.run(path, ["--version"], env: LoginEnv.shared.environment, timeout: 8)
        guard result.ok else { return nil }
        return result.stdout.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func catalog() -> JSONValue {
        .array(installables.map { item in
            let path = item.command.flatMap(locate)
            return .obj([
                "id": .string(item.id), "label": .string(item.label), "command": .str(item.command),
                "install": .str(item.install), "homepage": .str(item.homepage), "note": .string(item.note),
                "path": .str(path), "version": .str(path.flatMap(version)),
            ])
        })
    }

    static func install(id: String) throws -> JSONValue {
        guard let item = installables.first(where: { $0.id == id }), let command = item.install else {
            throw WorkError.invalid("这个条目没有可执行的安装命令")
        }
        let result = Proc.run("/bin/zsh", ["-lc", command], cwd: NSHomeDirectory(),
                              env: installEnvironment(), timeout: 600)
        let path = item.command.flatMap(locate)
        let log = WorkText.redact(result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return .obj([
            "ok": .bool(result.ok && path != nil),
            "exitCode": .int(Int(result.exitCode)),
            "timedOut": .bool(result.timedOut),
            "path": .str(path),
            "version": .str(path.flatMap(version)),
            "log": .string(String(log.suffix(3000))),
        ])
    }

    /// 安装脚本的环境：登录 shell 环境，再补上系统代理。
    /// curl 不读 macOS 系统代理；本机走代理上网时直连下载会被重置（SSL_ERROR_SYSCALL），安装就失败。
    /// 只用于安装命令，不改 LoginEnv，避免内网 git 等也被导到代理。
    static func installEnvironment(base: [String: String] = LoginEnv.shared.environment,
                                   system: [String: Any]? = systemProxySettings()) -> [String: String] {
        var env = base
        let proxyKeys = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"]
        guard !proxyKeys.contains(where: { !(env[$0] ?? "").isEmpty }), let system else { return env }
        func proxy(_ enable: String, _ host: String, _ port: String) -> String? {
            guard (system[enable] as? Int) == 1, let h = system[host] as? String, !h.isEmpty,
                  let p = system[port] as? Int else { return nil }
            return "http://\(h):\(p)"
        }
        let https = proxy("HTTPSEnable", "HTTPSProxy", "HTTPSPort")
        let http = proxy("HTTPEnable", "HTTPProxy", "HTTPPort")
        if let value = https ?? http { env["https_proxy"] = value; env["HTTPS_PROXY"] = value }
        if let value = http ?? https { env["http_proxy"] = value; env["HTTP_PROXY"] = value }
        if let exceptions = system["ExceptionsList"] as? [String], !exceptions.isEmpty, env["no_proxy"] == nil {
            env["no_proxy"] = exceptions.joined(separator: ",")
        }
        return env
    }

    static func systemProxySettings() -> [String: Any]? {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
    }

    // MARK: DeepSeek Harness

    struct DoctorReport: Equatable, Sendable {
        var launcher: String?
        var profile: String?
        var dsh: String?
        var problems: [String]
    }

    /// 解析 `dsh-tui doctor`：首行带启动器版本，✓ / ✗ 行逐项给出结果。
    static func parseDoctor(_ text: String) -> DoctorReport {
        var report = DoctorReport(launcher: nil, profile: nil, dsh: nil, problems: [])
        for raw in text.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            if raw.hasPrefix("dsh-tui doctor"), let version = raw.split(separator: " ").last { report.launcher = String(version) }
            if raw.hasPrefix("✓ dsh:") || raw.hasPrefix("✗ dsh:") {
                report.dsh = raw.dropFirst(6).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
            }
            if raw.contains("profile:"), !raw.contains("↔"), let range = raw.range(of: "profile:") {
                report.profile = raw[range.upperBound...].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
            }
            if raw.hasPrefix("✗") { report.problems.append(String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        }
        return report
    }

    /// 语义化版本比较（预发布后缀视为更旧）。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> ([Int], Bool) {
            let core = value.split(separator: "-", maxSplits: 1)
            let numbers = core.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
            return (numbers, core.count > 1)
        }
        let (a, aPre) = parts(candidate), (b, bPre) = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return !aPre && bPre
    }

    static let deepseekPackage = "@deepseek-harness-tui/dsh-tui"

    /// 只读巡检：`dsh-tui doctor` + 查询 npm 上的最新版本。不改任何东西。
    static func deepseekCheck() -> JSONValue {
        guard let tui = locate("dsh-tui") else {
            return .obj(["installed": .bool(false), "checkedAt": .string(WorkClock.iso())])
        }
        let env = LoginEnv.shared.environment
        let doctor = Proc.run(tui, ["doctor"], env: env, timeout: 60)
        let report = parseDoctor(doctor.stdout + "\n" + doctor.stderr)
        var latest: String?
        let npm = locate("npm") ?? ((tui as NSString).deletingLastPathComponent + "/npm")
        if FileManager.default.isExecutableFile(atPath: npm) {
            let view = Proc.run(npm, ["view", deepseekPackage, "version"], env: env, timeout: 30)
            if view.ok { latest = view.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) }
        }
        let installed = report.profile ?? report.launcher
        let updateAvailable = latest.flatMap { latest in installed.map { isNewer(latest, than: $0) } } ?? false
        return .obj([
            "installed": .bool(true),
            "launcher": .str(report.launcher), "profile": .str(report.profile), "dsh": .str(report.dsh),
            "latest": .str(latest),
            "updateAvailable": .bool(updateAvailable),
            "problems": .array(report.problems.map { .string($0) }),
            "needsAttention": .bool(updateAvailable || !report.problems.isEmpty),
            "checkedAt": .string(WorkClock.iso()),
        ])
    }

    /// 升级并对齐 TUI、dsh 引擎与启动器（`dsh-tui update`），完成后重新巡检。
    static func deepseekUpgrade() -> JSONValue {
        guard let tui = locate("dsh-tui") else { return .obj(["ok": .bool(false), "log": .string("未检测到 dsh-tui")]) }
        let result = Proc.run(tui, ["update"], cwd: NSHomeDirectory(), env: LoginEnv.shared.environment, timeout: 900)
        let log = WorkText.redact(result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return .obj([
            "ok": .bool(result.ok),
            "exitCode": .int(Int(result.exitCode)),
            "log": .string(String(log.suffix(3000))),
            "report": deepseekCheck(),
        ])
    }
}
