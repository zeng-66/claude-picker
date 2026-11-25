import Foundation

/// 多机器人配置的增删改。第一次保存时把旧的单 Bot 设置迁移为列表中的 `default`（保留其 Secret 与原有行为）。
enum WecomBotAdmin {
    static func list(_ core: WorkCore) -> JSONValue {
        let status = WecomBot.shared.status()["bots"]?.arrayValue ?? []
        let bots = WecomBotConfig.all(core).map { config -> JSONValue in
            var item = config.json.objectValue ?? [:]
            item["secretSaved"] = .bool(WecomBotConfig.secret(config.id) != nil)
            item["status"] = status.first { $0["id"]?.stringValue == config.id } ?? .null
            return .object(item)
        }
        let projects = ((try? core.read { $0.projects() }) ?? []).filter(\.available)
        return .obj([
            "bots": .array(bots),
            "migrated": .bool(core.getSetting(WecomBotConfig.settingsKey) != nil),
            "projects": .array(projects.map { .obj(["id": .string($0.id), "name": .string($0.name), "path": .string($0.path)]) }),
            "engines": .array(AgentProvider.allCases.filter(\.supportsStructuredChat).map {
                .obj(["id": .string($0.rawValue), "label": .string($0.label)])
            }),
        ])
    }

    private static func stored(_ core: WorkCore) -> [JSONValue] {
        if let list = core.getSetting(WecomBotConfig.settingsKey)?.arrayValue { return list }
        // 迁移：旧单 Bot 变成列表里的一项，范围显式为「全部」，与升级前一致。
        return WecomBotConfig.all(core).map { config in
            var item = config.json.objectValue ?? [:]
            item["legacy"] = nil
            return .object(item)
        }
    }

    static func save(_ core: WorkCore, _ input: JSONValue) throws -> JSONValue {
        guard case .object(var bot) = input else { throw WorkError.invalid("缺少机器人配置") }
        let name = bot["name"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (1...50).contains(name.count) else { throw WorkError.invalid("机器人名称需为 1–50 个字符") }
        bot["name"] = .string(name)
        if let botId = bot["botId"]?.stringValue {
            let trimmed = botId.trimmingCharacters(in: .whitespacesAndNewlines)
            bot["botId"] = trimmed.isEmpty ? .null : .string(trimmed)
        }
        if let mode = bot["mode"]?.text, !["chat", "work"].contains(mode) { throw WorkError.invalid("未知的机器人对话模式") }
        if let cli = bot["defaultCli"]?.text {
            guard let provider = AgentProvider(rawValue: cli), provider.supportsStructuredChat else {
                throw WorkError.invalid("这个 CLI 还不支持企业微信直接对话")
            }
        }
        var list = stored(core)
        let id = bot["id"]?.text ?? "bot-\(UUID().uuidString.prefix(8).lowercased())"
        bot["id"] = .string(id)
        let isNew = !list.contains { $0["id"]?.stringValue == id }
        // 新机器人默认停用，登记允许人员之前不接收消息。
        if isNew, bot["enabled"] == nil { bot["enabled"] = .bool(false) }
        guard let parsed = WecomBotConfig.parse(.object(bot)) else { throw WorkError.invalid("机器人配置不完整") }
        if parsed.enabled, !parsed.scope.allUsers, parsed.scope.users.isEmpty {
            throw WorkError.invalid("启用前请先登记允许的人员")
        }
        if let botId = parsed.botId, list.contains(where: { $0["id"]?.stringValue != id && $0["botId"]?.stringValue == botId }) {
            throw WorkError.invalid("这个 Bot ID 已由另一个机器人配置使用")
        }
        let value = parsed.json.objectValue.map { dict -> JSONValue in
            var copy = dict
            copy["legacy"] = nil
            return .object(copy)
        } ?? .null
        if let index = list.firstIndex(where: { $0["id"]?.stringValue == id }) { list[index] = value } else { list.append(value) }
        try core.putSetting(WecomBotConfig.settingsKey, .array(list))
        return value
    }

    static func delete(_ core: WorkCore, id: String) throws {
        var list = stored(core)
        list.removeAll { $0["id"]?.stringValue == id }
        try core.putSetting(WecomBotConfig.settingsKey, .array(list))
        WecomBotConfig.clearSecret(id)
    }
}
