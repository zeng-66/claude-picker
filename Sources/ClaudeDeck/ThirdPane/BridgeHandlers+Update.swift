import AppKit
import CryptoKit
import Foundation

/// main 的构建产物更新。网络与校验在 Bridge 后台队列执行。
enum UpdateHandlers: BridgeModule {
    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        guard method.hasPrefix("update.") else { return .unknown }
        let data = try BridgeSupport.blocking { try await MainReleaseUpdater.shared.request(method) }
        return .handled(try JSONSerialization.jsonObject(with: data))
    }
}

private actor MainReleaseUpdater {
    static let shared = MainReleaseUpdater()
    private struct Asset: Decodable, Sendable { let url: URL; let sha256: String; let size: Int64 }
    private struct Manifest: Decodable, Sendable {
        let schema: Int
        let branch: String
        let commit: String
        let version: String
        let assets: [String: Asset]
    }
    private struct Head: Decodable { let sha: String }
    private let repository = "zeng-66/claude-picker"
    private var releaseRoot: String { "https://github.com/\(repository)/releases/download/main-latest/" }
    private var state = "idle"
    private var busy = false
    private var manifest: Manifest?
    private var asset: Asset?
    private var installer: URL?
    private var platform: String {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x64"
        #endif
    }
    private var buildCommit: String { Bundle.main.object(forInfoDictionaryKey: "ClaudePickerCommit") as? String ?? "" }

    func request(_ method: String) async throws -> Data {
        if method == "update.status" { return try status() }
        guard !busy else { throw GitError.commandFailed("更新正在处理中") }
        busy = true
        defer { busy = false }
        switch method {
        case "update.check": try await check()
        case "update.download": try await download()
        case "update.install": try await install()
        default: throw GitError.commandFailed("未知更新操作")
        }
        return try status()
    }

    private func status() throws -> Data {
        var value: [String: String] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "本地构建",
            "commit": buildCommit, "platform": platform, "state": state,
        ]
        if let manifest { value["latestVersion"] = manifest.version; value["latestCommit"] = manifest.commit }
        return try JSONEncoder().encode(value)
    }

    private func json<T: Decodable>(_ url: String, as type: T.Type) async throws -> T? {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 30
        request.setValue("ClaudePicker", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200, data.count < 1024 * 1024 else { throw GitError.commandFailed("检查更新失败 HTTP \(code)") }
        return try JSONDecoder().decode(type, from: data)
    }

    private func check() async throws {
        guard let head = try await json("https://api.github.com/repos/\(repository)/commits/main", as: Head.self) else { state = "unpublished"; return }
        if head.sha == buildCommit && Bundle.main.object(forInfoDictionaryKey: "ClaudePickerDirty") as? String == "false" { state = "current"; return }
        guard let latest = try await json(releaseRoot + "manifest.json", as: Manifest.self), latest.commit == head.sha,
              let package = latest.assets[platform] else { state = "unpublished"; return }
        guard latest.schema == 1, latest.branch == "main", latest.commit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              package.url.absoluteString.hasPrefix(releaseRoot), package.url.pathExtension == "zip",
              package.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              package.size > 0, package.size <= 1024 * 1024 * 1024 else { throw GitError.commandFailed("更新清单无效") }
        manifest = latest
        asset = package
        state = "available"
    }

    private func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func download() async throws {
        try await check()
        guard state == "available", let asset, let manifest else { return }
        var request = URLRequest(url: asset.url)
        request.timeoutInterval = 600
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (response as? HTTPURLResponse)?.statusCode == 200, Int64(size) == asset.size,
              try digest(temporary) == asset.sha256 else { throw GitError.commandFailed("安装包 SHA-256 校验失败，请重新下载") }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePicker/updates/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("ClaudePicker-\(manifest.commit).zip")
        try FileManager.default.moveItem(at: temporary, to: destination)
        installer = destination
        state = "ready"
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitError.commandFailed("更新准备失败，请重新下载后重试") }
    }

    private func install() async throws {
        guard state == "ready", let installer, let asset, let manifest else { throw GitError.commandFailed("请先下载更新") }
        let hasActiveExecution = try BridgeSupport.onMain {
            let store = try AppHandlers.delegate().store
            return WorkCore.shared.activeExecutionCount() > 0 || !store.runningKeys.isEmpty || store.chatActive
        }
        guard !hasActiveExecution else { throw GitError.commandFailed("请先结束执行并关闭图形聊天会话后安装更新") }
        guard try digest(installer) == asset.sha256 else { state = "available"; throw GitError.commandFailed("安装包已变化，请重新下载") }
        let directory = installer.deletingLastPathComponent()
        let extracted = directory.appendingPathComponent("extracted", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", installer.path, extracted.path])
        let source = extracted.appendingPathComponent("ClaudePicker.app")
        guard let bundle = Bundle(url: source), bundle.bundleIdentifier == "local.zcl.claude-picker",
              bundle.object(forInfoDictionaryKey: "ClaudePickerCommit") as? String == manifest.commit else { throw GitError.commandFailed("安装包应用标识或提交不匹配") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
        let destination = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ClaudePicker.app")
        guard !FileManager.default.fileExists(atPath: destination.path + ".update-backup") else { throw GitError.commandFailed("上次更新备份仍在应用目录，请先检查并恢复该备份") }
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw GitError.commandFailed("应用目录不可写，请将 App 移到当前用户可写的 Applications 目录后更新") }
        // Shell receives paths as positional arguments. No path or user value is interpolated into executable code.
        let helper = directory.appendingPathComponent("install.sh")
        try """
        #!/bin/sh
        set -eu
        parent="$1"
        source="$2"
        target="$3"
        backup="${target}.update-backup"
        while kill -0 "$parent" 2>/dev/null; do sleep 1; done
        if [ -e "$backup" ]; then exit 1; fi
        if [ -e "$target" ]; then mv "$target" "$backup"; fi
        if mv "$source" "$target"; then
          if /usr/bin/open "$target"; then rm -rf "$backup"; fi
        else
          if [ -e "$backup" ]; then mv "$backup" "$target"; fi
          exit 1
        fi
        """.write(to: helper, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        state = "installing"
        Task { @MainActor in NSApplication.shared.terminate(nil) }
    }
}
