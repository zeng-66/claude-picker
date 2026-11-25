import Foundation
import Security

/// 连接凭据（企业微信机器人 Secret、TAPD 令牌）只存在 macOS 钥匙串里：
/// 不进数据库、不进设置文件、不出现在日志和桥接返回值里。界面只能知道「有没有保存」。
///
/// 测试用 `CLAUDE_PICKER_KEYCHAIN=memory` 换成进程内存储，不碰真实钥匙串。
enum Keychain {
    static let service = "ClaudePicker"

    enum Key: String, CaseIterable, Sendable {
        case wecomBotSecret = "wecom.botSecret"
        case tapdToken = "tapd.token"
    }

    private final class Memory: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: String] = [:]
    }
    private static let memory = Memory()
    private static var inMemory: Bool { ProcessInfo.processInfo.environment["CLAUDE_PICKER_KEYCHAIN"] == "memory" }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ key: Key) -> String? { get(account: key.rawValue) }
    static func has(_ key: Key) -> Bool { get(account: key.rawValue) != nil }
    static func set(_ key: Key, _ value: String) throws { try set(account: key.rawValue, value) }
    static func delete(_ key: Key) { delete(account: key.rawValue) }

    /// 按账户名存取（多机器人各自的 Secret 等动态凭据）。
    static func get(account: String) -> String? {
        if inMemory {
            memory.lock.lock(); defer { memory.lock.unlock() }
            return memory.values[account]
        }
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func has(account: String) -> Bool { get(account: account) != nil }

    static func set(account: String, _ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkError.invalid("内容不能为空") }
        if inMemory {
            memory.lock.lock(); memory.values[account] = trimmed; memory.lock.unlock()
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "ClaudePicker \(account)"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw WorkError.failed("写入钥匙串失败（\(added)）") }
        } else if status != errSecSuccess {
            throw WorkError.failed("写入钥匙串失败（\(status)）")
        }
    }

    static func delete(account: String) {
        if inMemory {
            memory.lock.lock(); memory.values[account] = nil; memory.lock.unlock()
            return
        }
        SecItemDelete(query(account) as CFDictionary)
    }
}
