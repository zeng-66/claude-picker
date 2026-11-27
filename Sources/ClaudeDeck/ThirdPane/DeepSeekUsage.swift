import Foundation

/// 查询 DeepSeek 官方账户余额（`GET /user/balance`）。
/// 优先读取环境变量 `DEEPSEEK_API_KEY`，否则从 DSH 凭据库 `~/.dsh/.credentials.yaml` 提取。
enum DeepSeekUsage {
    struct Snapshot: Codable, Equatable, Sendable {
        let currency: String
        let total: Double
        let granted: Double
        let toppedUp: Double
        let isAvailable: Bool
        let fetchedAt: Date
    }

    static var cacheURL: URL { AppDataDir.url.appendingPathComponent("deepseek-balance.json") }

    static func loadCache() -> Snapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func saveCache(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    static func resolveApiKey(
        env: [String: String] = LoginEnv.shared.environment,
        credentialsURL: URL? = nil
    ) -> String? {
        for candidate in [ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], env["DEEPSEEK_API_KEY"]] {
            if let key = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return key
            }
        }
        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"]
            ?? env["DSH_HOME"]
            ?? "\(NSHomeDirectory())/.dsh"
        let url = credentialsURL ?? URL(fileURLWithPath: dshHome).appendingPathComponent(".credentials.yaml")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return extractKeyFromCredentialsYAML(content, keyName: "DEEPSEEK_API_KEY")
    }

    static func extractKeyFromCredentialsYAML(_ yaml: String, keyName: String) -> String? {
        func unquote(_ raw: String) -> String {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")), s.count >= 2 {
                s = String(s.dropFirst().dropLast())
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lines = yaml.components(separatedBy: .newlines)
        var inBlock = false
        var blockIndent = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count

            if inBlock {
                if indent <= blockIndent {
                    inBlock = false
                } else if let colon = trimmed.firstIndex(of: ":") {
                    let subKey = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                    let subVal = unquote(String(trimmed[trimmed.index(after: colon)...]))
                    if ["value", "secret", "apiKey", "token", "key"].contains(subKey), !subVal.isEmpty {
                        return subVal
                    }
                    if subVal.hasPrefix("sk-") { return subVal }
                } else {
                    let candidate = unquote(trimmed)
                    if candidate.hasPrefix("sk-") { return candidate }
                }
            }

            if !inBlock, trimmed.hasPrefix("\(keyName):") {
                let rest = unquote(String(trimmed.dropFirst(keyName.count + 1)))
                if !rest.isEmpty, !rest.hasPrefix("{"), !rest.hasPrefix("#") {
                    return rest
                }
                inBlock = true
                blockIndent = indent
            }
        }
        return nil
    }

    static func parsePayload(_ data: Data, fetchedAt: Date = Date()) -> Snapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = obj["balance_infos"] as? [[String: Any]],
              !infos.isEmpty else { return nil }

        func parseAmount(_ raw: Any?) -> Double? {
            if let n = raw as? NSNumber { return n.doubleValue }
            if let s = raw as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }

        let primary = infos.first { ($0["currency"] as? String)?.uppercased() == "CNY" } ?? infos[0]
        guard let currency = primary["currency"] as? String, !currency.isEmpty,
              let total = parseAmount(primary["total_balance"]),
              let granted = parseAmount(primary["granted_balance"]),
              let toppedUp = parseAmount(primary["topped_up_balance"]) else {
            return nil
        }
        let available = (obj["is_available"] as? Bool) ?? (total > 0)
        return Snapshot(currency: currency, total: total, granted: granted, toppedUp: toppedUp,
                        isAvailable: available, fetchedAt: fetchedAt)
    }

    struct FetchError: Error, Sendable {
        let message: String
    }

    static func fetch() -> Result<Snapshot, FetchError> {
        let env = LoginEnv.shared.environment
        guard let apiKey = resolveApiKey(env: env) else {
            return .failure(FetchError(message: "未配置 DEEPSEEK_API_KEY"))
        }
        let rawBase = ProcessInfo.processInfo.environment["DEEPSEEK_BASE_URL"]
            ?? env["DEEPSEEK_BASE_URL"]
            ?? "https://api.deepseek.com"
        let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/user/balance") else {
            return .failure(FetchError(message: "余额接口地址无效"))
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var result: Result<Snapshot, FetchError> = .failure(FetchError(message: "请求超时")) }
        let box = Box()
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err {
                box.result = .failure(FetchError(message: err.localizedDescription))
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                box.result = .failure(FetchError(message: "DeepSeek API 密钥无效或无权限"))
                return
            }
            guard (200...299).contains(code), let data else {
                box.result = .failure(FetchError(message: "HTTP \(code)"))
                return
            }
            if let snapshot = parsePayload(data) {
                box.result = .success(snapshot)
            } else {
                box.result = .failure(FetchError(message: "余额响应格式异常"))
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        return box.result
    }
}
