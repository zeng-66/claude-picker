import Foundation

/// 通过官方 `agy -p "/usage"` 与 `agy -p "/credits"` 查询 Antigravity 模型配额与 AI 积分余额。
enum AntigravityUsage {
    struct Bucket: Codable, Equatable, Sendable {
        let id: String
        let label: String
        let usedPercent: Double
        let resetsAt: Date?
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let buckets: [Bucket]
        let remainingCredits: Int?
        let fetchedAt: Date
    }

    struct FetchError: Error, Sendable {
        let message: String
    }

    static var cacheURL: URL { AppDataDir.url.appendingPathComponent("antigravity-usage.json") }

    static func loadCache(now: Date = Date()) -> Snapshot? {
        guard let data = try? Data(contentsOf: cacheURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        let validBuckets = snap.buckets.filter { $0.resetsAt.map { $0 > now } ?? true }
        if validBuckets.isEmpty && snap.remainingCredits == nil { return nil }
        return Snapshot(buckets: validBuckets, remainingCredits: snap.remainingCredits, fetchedAt: snap.fetchedAt)
    }

    static func saveCache(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    static func parseUsageOutput(_ data: Data) -> [Bucket] {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        func parseDate(_ raw: String?) -> Date? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return isoFrac.date(from: s) ?? iso.date(from: s)
        }

        func normalizeGroup(_ name: String) -> String {
            let lower = name.lowercased()
            if lower.contains("gemini") { return "Gemini" }
            if lower.contains("claude") || lower.contains("gpt") { return "Claude/GPT" }
            return name
                .replacingOccurrences(of: " Models", with: "")
                .replacingOccurrences(of: " models", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func normalizeWindow(_ raw: String) -> String {
            let lower = raw.lowercased()
            if lower == "weekly" || lower.contains("weekly") { return "每周" }
            if lower == "5h" || lower.contains("five hour") { return "5 小时" }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let command = obj["command"] as? [String: Any],
               let cmdData = command["data"] as? [String: Any],
               let groups = cmdData["groups"] as? [[String: Any]] {
                var out: [Bucket] = []
                for group in groups {
                    let groupLabel = normalizeGroup(group["name"] as? String ?? "")
                    for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                        if (bucket["disabled"] as? Bool) == true { continue }
                        guard let frac = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue else { continue }
                        let used = min(100, max(0, ((1.0 - frac) * 100.0).rounded()))
                        let winRaw = (bucket["window"] as? String) ?? (bucket["name"] as? String) ?? ""
                        let winLabel = normalizeWindow(winRaw)
                        let label = [groupLabel, winLabel].filter { !$0.isEmpty }.joined(separator: " ")
                        let id = (bucket["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label
                        out.append(Bucket(
                            id: id,
                            label: label,
                            usedPercent: used,
                            resetsAt: parseDate(bucket["reset_time"] as? String)
                        ))
                    }
                }
                if !out.isEmpty { return out }
            }
            if let response = obj["response"] as? String, !response.isEmpty {
                return parseUsageTSV(response, normalizeGroup: normalizeGroup, normalizeWindow: normalizeWindow, parseDate: parseDate)
            }
        }

        let text = String(decoding: data, as: UTF8.self)
        return parseUsageTSV(text, normalizeGroup: normalizeGroup, normalizeWindow: normalizeWindow, parseDate: parseDate)
    }

    private static func parseUsageTSV(
        _ text: String,
        normalizeGroup: (String) -> String,
        normalizeWindow: (String) -> String,
        parseDate: (String?) -> Date?
    ) -> [Bucket] {
        var out: [Bucket] = []
        for (idx, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3 else { continue }
            let pctStr = cols[2].lowercased()
            if pctStr == "disabled" { continue }
            let cleanPct = pctStr.replacingOccurrences(of: "%", with: "")
            guard let remaining = Double(cleanPct) else { continue }
            let used = min(100, max(0, (100.0 - remaining).rounded()))
            let groupLabel = normalizeGroup(cols[0])
            let winLabel = normalizeWindow(cols[1])
            let label = [groupLabel, winLabel].filter { !$0.isEmpty }.joined(separator: " ")
            let reset = cols.count >= 4 ? parseDate(cols[3]) : nil
            out.append(Bucket(id: "tsv-\(idx)-\(label)", label: label, usedPercent: used, resetsAt: reset))
        }
        return out
    }

    static func parseCreditsOutput(_ data: Data) -> Int? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let command = obj["command"] as? [String: Any],
               let cmdData = command["data"] as? [String: Any] {
                if let n = cmdData["remaining_credits"] as? NSNumber { return n.intValue }
                if let s = cmdData["remaining_credits"] as? String,
                   let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return n
                }
            }
            if let response = obj["response"] as? String {
                if let parsed = parseCreditsTSV(response) { return parsed }
            }
        }
        return parseCreditsTSV(String(decoding: data, as: UTF8.self))
    }

    private static func parseCreditsTSV(_ text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2, cols[0].lowercased().contains("remaining credits"),
                  let value = Int(cols[1]) else { continue }
            return value
        }
        return nil
    }

    static func fetch() -> Result<Snapshot, FetchError> {
        if ProcessInfo.processInfo.environment["CLAUDE_PICKER_TEST_SHELL"] != nil {
            return .failure(FetchError(message: "测试环境跳过外部查询"))
        }
        guard let executable = CliBinaryLocator.find(.antigravity) else {
            return .failure(FetchError(message: "未检测到 agy CLI"))
        }

        let env = LoginEnv.shared.environment
        func runAgy(_ prompt: String, printTimeout: String) -> Data? {
            let result = Proc.run(
                executable,
                ["-p", prompt, "--output-format", "json", "--print-timeout", printTimeout],
                env: env,
                timeout: 15
            )
            guard result.ok else { return nil }
            let data = Data(result.stdout.utf8)
            return data.isEmpty ? nil : data
        }

        final class Box: @unchecked Sendable {
            var usageData: Data?
            var creditsData: Data?
        }
        let box = Box()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.usageData = runAgy("/usage", printTimeout: "12s")
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.creditsData = runAgy("/credits", printTimeout: "10s")
            group.leave()
        }
        group.wait()

        let buckets = box.usageData.map(parseUsageOutput) ?? []
        let credits = box.creditsData.flatMap(parseCreditsOutput)
        if buckets.isEmpty && credits == nil {
            return .failure(FetchError(message: "Antigravity 额度暂不可用，请检查 agy 登录状态"))
        }
        return .success(Snapshot(buckets: buckets, remainingCredits: credits, fetchedAt: Date()))
    }
}
