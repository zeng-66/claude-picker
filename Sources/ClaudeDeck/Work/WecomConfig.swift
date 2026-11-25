import Foundation

/// 企业微信多机器人配置：每个 Bot 独立的连接凭据、对话模式、默认 CLI 和生效范围。
///
/// - 设置键 `robot.bots` 保存 Bot 列表；没有该键时把旧的单 Bot 设置（`robot`）当作 id 为 `default` 的一个 Bot，
///   旧配置不设范围，迁移为显式的「全部人员、全部会话、全部项目」，保持原有行为。
/// - Secret 按 Bot 存钥匙串（`wecom.bot.<id>.secret`）；`default` 沿用旧的 `wecom.botSecret`。
/// - 授权取人员、场景、项目三项交集：同一项内命中任一值即可，三项都要命中；空集合一律拒绝。
struct WecomBotConfig: Sendable, Equatable {
    struct Group: Sendable, Equatable {
        var chatId: String
        var name: String
    }

    struct Scope: Sendable, Equatable {
        var allUsers = false
        var users: [String] = []
        var allowSingle = false
        var allGroups = false
        var groups: [Group] = []
        var allProjects = false
        var projects: [String] = []
        /// 角色组（应用内维护，成员为 userid）。nil：所有使用者都可发起 Work；数组：只有名单内的人可以。
        var initiators: [String]? = nil
        /// 拍板人：除发起人外，名单内的人也可以在决策卡上做决定。
        var deciders: [String] = []

        static let everything = Scope(allUsers: true, allowSingle: true, allGroups: true, allProjects: true)
    }

    var id: String
    var name: String
    var enabled: Bool
    var botId: String?
    var corpId: String
    var mode: String           // chat：直接对话；work：创建和跟进 Work
    var defaultCli: AgentProvider
    var scope: Scope
    var legacy: Bool

    static let legacyId = "default"
    static let settingsKey = "robot.bots"

    var accountId: String? { botId.map { SourceGateway.botAccountPrefix + $0 } }
    var statusKey: String { legacy ? "robot.status" : "robot.status.\(id)" }
    var direct: Bool { mode != "work" }

    // MARK: 读取

    static func all(_ core: WorkCore) -> [WecomBotConfig] {
        if let list = core.getSetting(settingsKey)?.arrayValue {
            return list.compactMap(parse)
        }
        let robot = SourceGateway.settings(core)
        guard robot["botId"]?.text != nil || robot["enabled"]?.boolValue == true else { return [] }
        return [legacyConfig(robot)]
    }

    static func legacyConfig(_ robot: JSONValue) -> WecomBotConfig {
        WecomBotConfig(id: legacyId, name: robot["name"]?.text ?? "开发协作助手",
                       enabled: robot["enabled"]?.boolValue == true, botId: robot["botId"]?.text,
                       corpId: robot["corpId"]?.text ?? "", mode: robot["mode"]?.text == "work" ? "work" : "chat",
                       defaultCli: .claude, scope: .everything, legacy: true)
    }

    static func parse(_ value: JSONValue) -> WecomBotConfig? {
        guard let id = value["id"]?.text else { return nil }
        let scope = value["scope"] ?? .object([:])
        let cli = AgentProvider(rawValue: value["defaultCli"]?.text ?? "claude") ?? .claude
        return WecomBotConfig(
            id: id,
            name: value["name"]?.text ?? "企业微信机器人",
            enabled: value["enabled"]?.boolValue == true,
            botId: value["botId"]?.text,
            corpId: value["corpId"]?.text ?? "",
            mode: value["mode"]?.text == "work" ? "work" : "chat",
            defaultCli: cli.supportsStructuredChat ? cli : .claude,
            scope: Scope(
                allUsers: scope["allUsers"]?.boolValue == true,
                users: strings(scope["users"]),
                allowSingle: scope["single"]?.boolValue == true,
                allGroups: scope["allGroups"]?.boolValue == true,
                groups: (scope["groups"]?.arrayValue ?? []).compactMap { item in
                    guard let chatId = item["chatId"]?.text else { return nil }
                    return Group(chatId: chatId, name: item["name"]?.text ?? chatId)
                },
                allProjects: scope["allProjects"]?.boolValue == true,
                projects: strings(scope["projects"]),
                initiators: scope["initiators"]?.arrayValue == nil ? nil : strings(scope["initiators"]),
                deciders: strings(scope["deciders"])),
            legacy: false)
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        var seen = Set<String>()
        return (value?.arrayValue ?? []).compactMap { $0.text?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var json: JSONValue {
        .obj([
            "id": .string(id), "name": .string(name), "enabled": .bool(enabled), "botId": .str(botId),
            "corpId": .string(corpId), "mode": .string(mode), "defaultCli": .string(defaultCli.rawValue),
            "legacy": .bool(legacy),
            "scope": .obj([
                "allUsers": .bool(scope.allUsers), "users": .array(scope.users.map { .string($0) }),
                "single": .bool(scope.allowSingle), "allGroups": .bool(scope.allGroups),
                "groups": .array(scope.groups.map { .obj(["chatId": .string($0.chatId), "name": .string($0.name)]) }),
                "allProjects": .bool(scope.allProjects), "projects": .array(scope.projects.map { .string($0) }),
                "initiators": scope.initiators.map { list in .array(list.map { .string($0) }) } ?? .null,
                "deciders": .array(scope.deciders.map { .string($0) }),
            ]),
        ])
    }

    // MARK: 凭据

    static func secretAccount(_ id: String) -> String { "wecom.bot.\(id).secret" }

    static func secret(_ id: String) -> String? {
        id == legacyId ? Keychain.get(.wecomBotSecret) : Keychain.get(account: secretAccount(id))
    }

    static func setSecret(_ id: String, _ value: String) throws {
        if id == legacyId { try Keychain.set(.wecomBotSecret, value) } else { try Keychain.set(account: secretAccount(id), value) }
    }

    static func clearSecret(_ id: String) {
        if id == legacyId { Keychain.delete(.wecomBotSecret) } else { Keychain.delete(account: secretAccount(id)) }
    }

    // MARK: 授权

    enum Decision: Equatable {
        case allowed
        case denied(String)
    }

    /// 人员与场景的授权（项目在理解意图后单独校验）。身份缺失或任一项未命中都拒绝。
    func authorize(userId: String, chatType: String, chatId: String) -> Decision {
        guard enabled else { return .denied("这个机器人已停用") }
        guard !userId.isEmpty else { return .denied("没有拿到发送人身份，无法授权") }
        let userOk = scope.allUsers || scope.users.contains(userId)
        guard userOk else { return .denied("你还没有被授权使用「\(name)」，请联系管理员在 Claude Picker 中添加") }
        if chatType == "group" {
            guard scope.allGroups || scope.groups.contains(where: { $0.chatId == chatId }) else {
                return .denied("「\(name)」没有在这个群启用")
            }
        } else {
            guard scope.allowSingle else { return .denied("「\(name)」不接受私聊") }
        }
        guard scope.allProjects || !scope.projects.isEmpty else { return .denied("「\(name)」还没有可用的项目") }
        return .allowed
    }

    /// 任务发起人：可以在 Work 模式下创建或追加 Work。
    func canInitiate(_ userId: String) -> Bool {
        guard let initiators = scope.initiators else { return true }
        return initiators.contains(userId)
    }

    /// 决策卡允许的操作者：发起人本人 + 拍板人。
    func cardDeciders(actor: String) -> [String] {
        var seen = Set<String>()
        return ([actor] + scope.deciders).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 这个机器人是否在某个群生效（用于同群多 Bot 的冲突裁决）。
    func covers(group chatId: String) -> Bool {
        enabled && (scope.allGroups || scope.groups.contains { $0.chatId == chatId })
    }

    func allows(projectId: String) -> Bool {
        scope.allProjects || scope.projects.contains(projectId)
    }

    /// 生效范围内的项目。单项目时可作为默认项目。
    func projects(from all: [WorkProject]) -> [WorkProject] {
        all.filter { $0.available && allows(projectId: $0.id) }
    }

    /// 会话归属键：企业 / Bot / 私聊或群聊 / 会话 / 发送人 / 项目，各自独立续聊。
    static func bindingKey(corpId: String, botId: String, chatType: String, conversationId: String,
                           actorId: String, projectId: String) -> String {
        "wecom.binding." + WorkText.sha256([corpId, botId, chatType, conversationId, actorId, projectId].joined(separator: "\n"))
    }
}
