import Foundation

/// 输入区上下文环 / 「模型上下文」弹窗的数据：取会话记录里最近一次主对话请求的 token 用量。
///
/// Claude Code 每条 assistant 记录都带 `message.usage`：
/// `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` 就是那次请求送进模型的
/// 上下文大小，`output_tokens` 会成为下一次请求的一部分，所以一并计入「已占用」。
struct ContextUsage: Sendable, Equatable {
    var model: String
    var cacheRead: Int
    var cacheCreation: Int
    var input: Int
    var output: Int

    var used: Int { cacheRead + cacheCreation + input + output }

    /// 记录里没有窗口容量：默认 200k；用量已经超过 200k 或模型名带 `[1m]` 就是 1M 窗口。
    func total(configuredModel: String?) -> Int {
        let oneMillion = (configuredModel ?? "").lowercased().contains("[1m]")
            || model.lowercased().contains("[1m]")
            || used > 200_000
        return oneMillion ? 1_000_000 : 200_000
    }

    /// `claude-opus-5-5` → `Opus 5.5`；`claude-sonnet-4-5-20250929` → `Sonnet 4.5`
    var modelLabel: String {
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().prefix { $0.count <= 2 && Int($0) != nil }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : name + " " + version.joined(separator: ".")
    }

    /// 从 jsonl 尾部往前找最近一条带 usage 的主对话 assistant 记录。先读 256 KB，找不到再读 4 MB
    /// （一次工具结果就可能有几百 KB）。
    static func read(_ url: URL) -> ContextUsage? {
        for bytes in [262_144, 4_194_304] {
            if let usage = scan(url, bytes: bytes) { return usage }
        }
        return nil
    }

    private static func scan(_ url: URL, bytes: Int) -> ContextUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return nil }
        let marker = Data("\"usage\"".utf8)
        var lines = chunk.split(separator: 0x0a)
        // 从文件中间开始读时第一行是半截，丢掉
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            let record = Data(line)
            guard record.range(of: marker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
                  (object["type"] as? String) == "assistant",
                  (object["isSidechain"] as? Bool) != true,
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            func number(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            let found = ContextUsage(model: message["model"] as? String ?? "",
                                     cacheRead: number("cache_read_input_tokens"),
                                     cacheCreation: number("cache_creation_input_tokens"),
                                     input: number("input_tokens"),
                                     output: number("output_tokens"))
            // 合成的占位记录（<synthetic>）用量全是 0，继续往前找真实的那条
            if found.used > 0 { return found }
        }
        return nil
    }
}
