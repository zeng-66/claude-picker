import Foundation

/// agent-starter 能力包的只读索引（docs/agent-workspace-prototype/AGENT_STARTER_INTEGRATION.md §3.1）。
///
/// 只读取文件、解析 SKILL.md 的 frontmatter 和岗位配置里的字段名；不执行 bootstrap / install / 任何脚本，
/// 不修改包目录，也不改用户级的 .claude / .workbuddy 配置。包里实际没有的岗位不会被列出来。
enum AgentPack {
    static func index(path raw: String) -> JSONValue {
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return .obj(["valid": .bool(false), "path": .string(root.path), "reason": .string("目录不存在或不可读")])
        }
        let template = root.appendingPathComponent("template")
        let rolesDir = root.appendingPathComponent("roles")
        guard fm.fileExists(atPath: template.path) || fm.fileExists(atPath: rolesDir.path) else {
            return .obj(["valid": .bool(false), "path": .string(root.path),
                         "reason": .string("这个目录里没有 template/ 或 roles/，不像是 agent-starter 能力包")])
        }

        func skills(in directory: URL, source: String) -> [JSONValue] {
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
            return names.sorted().compactMap { name -> JSONValue? in
                let file = directory.appendingPathComponent(name).appendingPathComponent("SKILL.md")
                // 符号链接解析后必须仍在包目录内，否则标为失效而不是读到包外面去。
                let real = file.resolvingSymlinksInPath().standardizedFileURL
                guard fm.fileExists(atPath: file.path) else { return nil }
                guard real.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: real),
                      let text = String(data: data, encoding: .utf8) else {
                    return .obj(["name": .string(name), "source": .string(source), "available": .bool(false),
                                 "reason": .string("文件不可读或指向包目录之外"), "file": .string(file.path)])
                }
                let meta = frontmatter(text)
                return .obj(["name": .string(meta["name"] ?? name), "description": .str(meta["description"]),
                             "source": .string(source), "available": .bool(true), "file": .string(real.path),
                             "version": .string(String(Hashing.sha256(data).prefix(16)))])
            }
        }

        var roles: [JSONValue] = []
        if let names = try? fm.contentsOfDirectory(atPath: rolesDir.path) {
            for name in names.sorted() where !name.hasPrefix(".") {
                let dir = rolesDir.appendingPathComponent(name)
                var roleIsDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &roleIsDir), roleIsDir.boolValue else { continue }
                let config = dir.appendingPathComponent("config.json")
                let configData = try? Data(contentsOf: config)
                let parsed = configData.flatMap { JSONValue.parse($0) }
                roles.append(.obj([
                    "id": .string(name),
                    "title": .str(parsed?["title"]?.text ?? parsed?["name"]?.text),
                    "configKeys": .array((parsed?.objectValue?.keys.sorted() ?? []).map { .string($0) }),
                    "configVersion": .str(configData.map { String(Hashing.sha256($0).prefix(16)) }),
                    "skills": .array(skills(in: dir.appendingPathComponent("skills"), source: "roles/\(name)")),
                ]))
            }
        }
        let base = skills(in: template.appendingPathComponent("skills"), source: "template")
        let knowledge = template.appendingPathComponent("knowledge")
        let knowledgeFiles = ((try? fm.contentsOfDirectory(atPath: knowledge.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let policy = template.appendingPathComponent("permissions/policy.json")
        return .obj([
            "valid": .bool(true), "path": .string(root.path),
            "roles": .array(roles), "skills": .array(base),
            "knowledge": .array(knowledgeFiles.map { .string($0) }),
            "policy": .obj(["present": .bool(fm.fileExists(atPath: policy.path)),
                            "version": .str((try? Data(contentsOf: policy)).map { String(Hashing.sha256($0).prefix(16)) }),
                            // 策略文件只是版本化输入：这里没有执行守卫，也不代表宿主权限已经生效。
                            "enforced": .bool(false)]),
            "indexedAt": .string(WorkClock.iso()),
        ])
    }

    /// 只取 `---` 之间的 `key: value` 行，不做 YAML 的完整解析。
    static func frontmatter(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return result }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }
}
