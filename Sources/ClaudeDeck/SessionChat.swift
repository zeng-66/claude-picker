import Foundation

/// 会话级结构化聊天：同一个原始会话 ID 由执行器（Claude stream-json / Antigravity ACP / Codex App Server）驱动，
/// 网页外壳在第二栏渲染消息、工具记录、审批与中断。
///
/// 单写者约定：一个原始会话同时只能被终端、Swttch、Work 执行器或这里的其中之一持有（`SessionOwnership`）。
/// 换打开方式时先 `release`：运行中或等待审批的回合先中断并等结果，进程退出后才交给另一端。
@MainActor
final class SessionChatHub {
    static let shared = SessionChatHub()

    enum Phase: String {
        case starting, ready, running, awaiting, stopping, exited, failed
    }

    final class Run {
        var sessionId: String
        let provider: AgentProvider
        let cwd: String
        var process: (any AgentExecutorProcess)?
        var token = UUID().uuidString
        var phase: Phase = .starting
        var events: [JSONValue] = []
        var seq = 0
        var pending: [String: JSONValue] = [:]
        var queued: [String] = []
        var streaming = ""
        var info: JSONValue = .object([:])
        var lastError: String?
        /// 当前值（mode / model / effort）与可选项（modes / models / efforts，元素为 {id, label}）。
        var runtime: [String: JSONValue] = [:]
        /// Codex：各模型支持的推理强度。
        var modelEfforts: [String: [JSONValue]] = [:]
        var turnWaiters: [() -> Void] = []
        /// 原始会话仍被另一端持有时的退避重试次数（Codex 报 “already has an active writer”）。
        var writerRetries = 0
        /// 上下文占用 {used, total, model}。
        var context: JSONValue = .null
        var exitWaiters: [() -> Void] = []

        init(sessionId: String, provider: AgentProvider, cwd: String) {
            self.sessionId = sessionId
            self.provider = provider
            self.cwd = cwd
        }

        var busy: Bool { phase == .running || phase == .awaiting || phase == .stopping }
    }

    private var runs: [String: Run] = [:]
    /// 执行器回调按启动令牌找运行实例：占位 ID 换成原始 ID 后，回调仍能找到同一个 Run。
    private var runsByToken: [String: Run] = [:]
    /// 占位 ID 取得原始会话 ID：Store 据此改写侧栏与持久化记录。
    var onBound: ((_ placeholder: String, _ real: String, _ provider: AgentProvider) -> Void)?
    /// 忙闲变化：侧栏转圈、未读与提示缓存计时。
    var onBusy: ((_ sessionId: String, _ provider: AgentProvider, _ cwd: String, _ busy: Bool) -> Void)?
    /// 由 Store 提供：按原始 ID 重新接续（重新读取本地记录与运行参数）。
    var restartAfterWriterConflict: ((_ sessionId: String, _ provider: AgentProvider, _ cwd: String) -> Void)?

    static let historyLimit = 160

    func run(_ sessionId: String) -> Run? { runs[sessionId] }
    func isLive(_ sessionId: String) -> Bool {
        guard let run = runs[sessionId] else { return false }
        return run.phase != .exited && run.phase != .failed
    }

    // MARK: 启动

    /// 确保会话有一个存活的执行器。`resume == false` 时新建底层会话（Claude 用预生成 ID，其它引擎由 CLI 分配）。
    func ensure(sessionId: String, provider: AgentProvider, cwd: String, resume: Bool,
                runtime: [String: JSONValue], history: [JSONValue]) throws {
        if let run = runs[sessionId], run.phase != .exited, run.phase != .failed { return }
        guard AgentExecutorFactory.supportsStructured(provider) else {
            throw GitError.commandFailed("\(provider.label) 暂不支持结构化聊天，请使用终端打开", recoverable: true)
        }
        // 与终端共用同一套定位规则（含 CLAUDE_PICKER_*_BIN 覆盖），保证两端驱动的是同一个 CLI。
        guard let executable = CliBinaryLocator.find(provider) else {
            throw GitError.commandFailed("本机未检测到 \(provider.label)（\(provider.commandName)）", recoverable: true)
        }
        let realId = sessionId.hasPrefix("pending-") ? "" : sessionId
        if !realId.isEmpty {
            if SessionOwnership.shared.heldByExecutor(realId) {
                throw GitError.commandFailed("这个会话正由 Work 执行器驱动，等它结束后再打开", recoverable: true)
            }
            if SessionOwnership.shared.heldByTerminal(realId) {
                throw GitError.commandFailed("这个会话正由终端或 Swttch 持有，请先切换打开方式", recoverable: true)
            }
        }
        let previous = runs[sessionId]
        let run = Run(sessionId: sessionId, provider: provider, cwd: cwd)
        run.runtime = runtime
        if let previous {
            // 进程退出后重开：保留界面上的记录与本会话改过的运行参数，接着往下写。
            run.events = previous.events
            run.seq = previous.seq
            run.modelEfforts = previous.modelEfforts
            run.writerRetries = previous.writerRetries
            run.context = previous.context
            for (key, value) in previous.runtime where !value.isNull { run.runtime[key] = value }
        } else {
            for item in history.suffix(Self.historyLimit) {
                append(run, kind: item["kind"]?.stringValue ?? "assistant", payload: item["payload"] ?? .object([:]),
                       emit: false, at: item["at"]?.doubleValue)
            }
            if !history.isEmpty {
                append(run, kind: "status", payload: .obj(["text": .string("以上为本地记录中的最近消息")]), emit: false)
            }
        }
        let cliId = provider == .claude ? sessionId : realId
        let config = ExecutorConfig(provider: provider, executable: executable, cwd: cwd, sessionId: cliId,
                                    resume: resume && !realId.isEmpty, permissionMode: run.runtime["mode"]?.text,
                                    model: run.runtime["model"]?.text, effort: run.runtime["effort"]?.text,
                                    environment: LoginEnv.shared.environment.merging(ProcessInfo.processInfo.environment) { login, _ in login })
        let token = run.token
        guard let process = AgentExecutorFactory.make(config, onEvent: { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, token: token) }
            }
        }) else {
            throw GitError.commandFailed("\(provider.label) 暂不支持结构化聊天", recoverable: true)
        }
        runs[sessionId] = run
        if let previous { runsByToken.removeValue(forKey: previous.token) }
        runsByToken[token] = run
        do {
            try process.start()
        } catch {
            run.phase = .failed
            run.lastError = error.localizedDescription
            append(run, kind: "error", payload: .obj(["message": .string("无法启动 \(provider.label)：\(error.localizedDescription)")]))
            throw GitError.commandFailed("无法启动 \(provider.label)：\(error.localizedDescription)", recoverable: true)
        }
        run.process = process
        if !realId.isEmpty { SessionOwnership.shared.setTerminal(realId, held: true) }
        append(run, kind: "status", payload: .obj([
            "text": .string(resume && !realId.isEmpty ? "正在接续 \(provider.label) 会话…" : "正在启动 \(provider.label)…"),
        ]))
        emitState(run)
    }

    // MARK: 输入、审批与中断

    func send(sessionId: String, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let run = runs[sessionId], run.phase != .exited, run.phase != .failed else {
            throw GitError.commandFailed("会话执行器未运行，请重新打开该会话", recoverable: true)
        }
        guard !run.busy else {
            throw GitError.commandFailed("当前回合还在进行，请等待结束或先中断", recoverable: true)
        }
        append(run, kind: "user", payload: .obj(["text": .string(trimmed), "at": .number(Date().timeIntervalSince1970)]))
        if run.phase == .starting {
            run.queued.append(trimmed)
            return
        }
        deliver(run, text: trimmed)
    }

    private func deliver(_ run: Run, text: String) {
        guard let process = run.process else { return }
        run.phase = .running
        run.streaming = ""
        emitState(run)
        onBusy?(run.sessionId, run.provider, run.cwd, true)
        if !process.sendUserMessage(text) {
            run.phase = .ready
            append(run, kind: "error", payload: .obj(["message": .string("消息未送达执行器")]))
            emitState(run)
            onBusy?(run.sessionId, run.provider, run.cwd, false)
        }
    }

    func respond(sessionId: String, requestId: String, allow: Bool) throws {
        guard let run = runs[sessionId], let card = run.pending.removeValue(forKey: requestId) else {
            throw GitError.commandFailed("这条审批已经处理或已失效", recoverable: true)
        }
        let ok = run.process?.respondPermission(requestId: requestId, allow: allow, updatedInput: nil,
                                                message: allow ? nil : "用户在 ClaudePicker 拒绝了此操作") ?? false
        append(run, kind: "permission_resolved", payload: .obj([
            "requestId": .string(requestId),
            "allow": .bool(allow),
            "delivered": .bool(ok),
            "toolName": card["toolName"] ?? .null,
        ]))
        if run.phase == .awaiting, run.pending.isEmpty { run.phase = .running }
        emitState(run)
    }

    func interrupt(sessionId: String) {
        guard let run = runs[sessionId], run.busy, let process = run.process else { return }
        // 先拒掉待审批，执行器才会结束等待。
        for id in run.pending.keys.sorted() {
            _ = process.respondPermission(requestId: id, allow: false, updatedInput: nil, message: "用户中断了本轮")
            append(run, kind: "permission_resolved", payload: .obj(["requestId": .string(id), "allow": .bool(false),
                                                                     "delivered": .bool(true)]))
        }
        run.pending.removeAll()
        run.phase = .stopping
        emitState(run)
        _ = process.interrupt(requestId: "picker-interrupt-\(UUID().uuidString.prefix(8))")
    }

    /// 释放会话：运行中或待审批时先中断并等待回合结束，再关闭执行器。`completion(false)` 时调用方保留原界面。
    func release(sessionId: String, timeout: TimeInterval = 12, completion: @escaping (Bool, String?) -> Void) {
        guard let run = runs[sessionId], let process = run.process, run.phase != .exited, run.phase != .failed else {
            completion(true, nil)
            return
        }
        var settled = false
        let finish: (Bool, String?) -> Void = { ok, message in
            guard !settled else { return }
            settled = true
            completion(ok, message)
        }
        let shutdown = {
            // 关闭 stdin 后宽限 2 秒，再 SIGTERM、SIGKILL；只有收到进程退出才交出会话。
            run.exitWaiters.append { finish(true, nil) }
            process.shutdown(grace: 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                MainActor.assumeIsolated {
                    finish(false, "执行器没有按时退出，已保留当前界面")
                }
            }
        }
        if run.busy {
            run.turnWaiters.append { shutdown() }
            if run.phase != .stopping { interrupt(sessionId: sessionId) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    guard !settled, run.busy else { return }
                    finish(false, "当前回合没有在 \(Int(timeout)) 秒内结束，已保留当前界面")
                }
            }
        } else {
            shutdown()
        }
    }

    /// App 退出：不等回合，直接结束全部执行器。
    func terminateAll() {
        for run in runs.values {
            run.process?.shutdown(grace: 1)
            if !run.sessionId.hasPrefix("pending-") { SessionOwnership.shared.setTerminal(run.sessionId, held: false) }
        }
        runs.removeAll()
        runsByToken.removeAll()
    }

    // MARK: 快照

    func snapshot(sessionId: String) -> [String: Any] {
        guard let run = runs[sessionId] else {
            return ["sessionId": sessionId, "phase": "closed", "events": [], "pending": [], "streaming": ""]
        }
        return [
            "sessionId": run.sessionId,
            "provider": run.provider.rawValue,
            "cwd": run.cwd,
            "phase": run.phase.rawValue,
            "events": run.events.map(\.any),
            "pending": run.pending.keys.sorted().compactMap { run.pending[$0]?.any },
            "streaming": run.streaming,
            "info": run.info.any,
            "runtime": runtimeJSON(run).any,
            "context": run.context.any,
            "error": run.lastError ?? NSNull(),
        ]
    }

    /// 由宿主读取本地记录后更新（Claude、Antigravity）。
    func setContext(sessionId: String, used: Int, total: Int, model: String?) {
        guard let run = runs[sessionId] else { return }
        run.context = .obj(["used": .int(used), "total": .int(total), "model": .str(model)])
        emitState(run)
    }

    // MARK: 运行参数

    private static func choices(_ list: JSONValue?, id: String, label: String) -> JSONValue? {
        guard let items = list?.arrayValue, !items.isEmpty else { return nil }
        return .array(items.compactMap { item in
            guard let value = item[id]?.text ?? item["id"]?.text ?? item.text else { return nil }
            return .obj(["id": .string(value), "label": .string(item[label]?.text ?? item["label"]?.text ?? value)])
        })
    }

    /// 执行器报告的可选项与当前值并入会话的运行参数（不覆盖用户已改的值）。
    private func absorbRuntime(_ run: Run, info: JSONValue) {
        if let modes = Self.choices(info["availableModes"], id: "id", label: "name") {
            // 与 Claude 桌面端的权限模式用同一套中文名。
            let names = ["default": "手动", "accept-edits": "接受编辑", "acceptEdits": "接受编辑", "auto": "自动", "plan": "规划",
                         "bypassPermissions": "跳过权限"]
            run.runtime["modes"] = .array((modes.arrayValue ?? []).map { item in
                guard let id = item["id"]?.text, let name = names[id] else { return item }
                return .obj(["id": .string(id), "label": .string(name)])
            })
        }
        if let models = info["availableModels"]?.arrayValue, !models.isEmpty {
            if run.provider == .codex {
                run.runtime["models"] = .array(models.compactMap { model in
                    guard let id = model["id"]?.text else { return nil }
                    run.modelEfforts[id] = model["efforts"]?.arrayValue ?? []
                    return .obj(["id": .string(id), "label": .string(model["label"]?.text ?? id)])
                })
            } else if let list = Self.choices(info["availableModels"], id: "modelId", label: "name") {
                run.runtime["models"] = list
            }
        }
        for (key, source) in [("mode", "permissionMode"), ("model", "model"), ("effort", "effort")] {
            if run.runtime[key]?.text == nil, let value = info[source]?.text { run.runtime[key] = .string(value) }
        }
        if run.provider == .codex { refreshCodexEfforts(run) }
    }

    private func refreshCodexEfforts(_ run: Run) {
        guard let model = run.runtime["model"]?.text, let efforts = run.modelEfforts[model], !efforts.isEmpty else { return }
        let labels = ["none": "关闭", "minimal": "最低", "low": "低", "medium": "中", "high": "高", "xhigh": "极高", "max": "最高", "ultra": "超高"]
        run.runtime["efforts"] = .array(efforts.compactMap(\.text).map { .obj(["id": .string($0), "label": .string(labels[$0] ?? $0)]) })
    }

    private func runtimeJSON(_ run: Run) -> JSONValue {
        var out = run.runtime
        for key in ["modes", "models", "efforts"] where out[key] == nil { out[key] = .array([]) }
        return .object(out)
    }

    enum RuntimeOutcome {
        case applied
        /// 回合进行中或执行器不支持热切换：值已记下，下一回合或重启后生效。
        case deferred
        /// 需要按原 ID 重启执行器才生效（Claude 的推理强度）。
        case restart
    }

    func setRuntime(sessionId: String, key: String, value: String) throws -> RuntimeOutcome {
        guard ["mode", "model", "effort"].contains(key), let run = runs[sessionId] else {
            throw GitError.commandFailed("会话执行器未运行，请重新打开该会话", recoverable: true)
        }
        let catalog = run.runtime[key == "mode" ? "modes" : key == "model" ? "models" : "efforts"]?.arrayValue ?? []
        guard catalog.isEmpty || catalog.contains(where: { $0["id"]?.text == value }) else {
            throw GitError.commandFailed("这个引擎不支持该选项", recoverable: true)
        }
        run.runtime[key] = .string(value)
        if run.provider == .codex, key == "model" { refreshCodexEfforts(run) }
        var outcome: RuntimeOutcome = .deferred
        if let process = run.process, run.phase != .exited, run.phase != .failed {
            if process.updateRuntime(key: key, value: value) {
                outcome = .applied
            } else if !run.busy {
                outcome = .restart
            }
        }
        let label = catalog.first { $0["id"]?.text == value }?["label"]?.text ?? value
        let name = key == "mode" ? "模式" : key == "model" ? "模型" : "推理强度"
        append(run, kind: "status", payload: .obj(["text": .string(
            outcome == .applied && run.provider != .codex ? "\(name)已切换为「\(label)」"
                : outcome == .restart ? "\(name)已改为「\(label)」，正在按原会话重新接续"
                : "\(name)已改为「\(label)」，下一回合起生效")]))
        emitState(run)
        return outcome
    }

    // MARK: 事件

    private func handle(_ event: ExecutorEvent, token: String) {
        guard let run = runsByToken[token], runs[run.sessionId] === run else { return }
        switch event {
        case .ready:
            run.phase = .ready
            run.writerRetries = 0
            append(run, kind: "status", payload: .obj(["text": .string("\(run.provider.label) 已就绪")]))
            emitState(run)
            if !run.queued.isEmpty {
                let text = run.queued.joined(separator: "\n\n")
                run.queued.removeAll()
                deliver(run, text: text)
            }
        case .sessionInfo(let info):
            run.info = info
            absorbRuntime(run, info: info)
            if let real = info["sessionId"]?.text, real != run.sessionId, run.sessionId.hasPrefix("pending-") {
                bind(run, to: real)
            }
            emitState(run)
        case .turnStarted:
            if run.phase == .ready { run.phase = .running; emitState(run) }
        case .delta(let text):
            guard run.busy else { return }
            run.streaming += text
            Bridge.emit("claude-picker:session-chat", detail: ["sessionId": run.sessionId, "delta": text])
        case .assistantText(let text):
            run.streaming = ""
            append(run, kind: "assistant", payload: .obj(["text": .string(text)]))
        case .toolUse(let id, let name, let input):
            append(run, kind: "tool_use", payload: .obj(["toolUseId": .string(id), "name": .string(name),
                                                         "input": input.truncated(limit: 4000)]))
        case .toolResult(let id, let isError, let content):
            append(run, kind: "tool_result", payload: .obj(["toolUseId": .string(id), "isError": .bool(isError),
                                                            "content": content.truncated(limit: 6000)]))
        case .permissionRequest(let requestId, let toolName, let input, let detail):
            let card: JSONValue = .obj([
                "requestId": .string(requestId),
                "toolName": .string(toolName),
                "input": input.truncated(limit: 4000),
                "description": detail["description"] ?? .null,
                "at": .number(Date().timeIntervalSince1970),
            ])
            run.pending[requestId] = card
            run.phase = .awaiting
            append(run, kind: "permission", payload: card)
            emitState(run)
        case .controlAck(let requestId, let ok, let detail):
            if requestId == ClaudeProcess.initializeRequestId, !ok {
                let message = detail["message"]?.text ?? detail.serialized()
                if message.contains("active writer"), run.writerRetries < 5, let restart = restartAfterWriterConflict {
                    // 上一个持有者刚释放：稍后按原 ID 重新接续，不立刻判失败。
                    run.writerRetries += 1
                    run.process?.shutdown(grace: 0)
                    run.process = nil
                    append(run, kind: "status", payload: .obj(["text": .string("原会话仍在释放，稍后重试接续（第 \(run.writerRetries) 次）")]))
                    let sid = run.sessionId, provider = run.provider, cwd = run.cwd, attempt = run.writerRetries
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 1.5) {
                        MainActor.assumeIsolated {
                            guard let current = self.runs[sid], current === run, current.process == nil else { return }
                            current.phase = .exited
                            restart(sid, provider, cwd)
                        }
                    }
                    return
                }
                run.lastError = message
                append(run, kind: "error", payload: .obj(["message": .string("会话握手失败：\(message)")]))
                run.phase = .failed
                run.process?.shutdown(grace: 1)
                emitState(run)
            }
        case .turnResult(let result):
            if let context = result["context"], context["used"]?.intValue != nil { run.context = context }
            let wasBusy = run.busy
            run.streaming = ""
            run.pending.removeAll()
            run.phase = .ready
            append(run, kind: "turn_result", payload: result)
            emitState(run)
            if wasBusy { onBusy?(run.sessionId, run.provider, run.cwd, false) }
            let waiters = run.turnWaiters
            run.turnWaiters.removeAll()
            waiters.forEach { $0() }
        case .exited(let code, let stderr):
            markExited(run, code: code, stderr: stderr)
        }
    }

    private func markExited(_ run: Run, code: Int32, stderr: String) {
        guard run.phase != .exited else { return }
        let wasBusy = run.busy
        let expected = run.phase == .stopping || run.exitWaiters.count > 0
        run.phase = run.phase == .failed ? .failed : .exited
        run.pending.removeAll()
        run.streaming = ""
        run.process = nil
        if !run.sessionId.hasPrefix("pending-") { SessionOwnership.shared.setTerminal(run.sessionId, held: false) }
        if !expected, code != 0 {
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            run.lastError = tail.isEmpty ? "执行器退出（代码 \(code)）" : String(tail.suffix(600))
            append(run, kind: "error", payload: .obj(["message": .string(run.lastError ?? "")]))
        } else {
            append(run, kind: "status", payload: .obj(["text": .string("执行器已关闭，发送消息时会按原始 ID 重新接续")]))
        }
        emitState(run)
        if wasBusy { onBusy?(run.sessionId, run.provider, run.cwd, false) }
        let waiters = run.turnWaiters + run.exitWaiters
        run.turnWaiters.removeAll()
        run.exitWaiters.removeAll()
        waiters.forEach { $0() }
    }

    private func bind(_ run: Run, to real: String) {
        let placeholder = run.sessionId
        runs.removeValue(forKey: placeholder)
        run.sessionId = real
        runs[real] = run
        SessionOwnership.shared.setTerminal(real, held: true)
        Bridge.emit("claude-picker:session-chat", detail: ["sessionId": placeholder, "reboundTo": real])
        onBound?(placeholder, real, run.provider)
    }

    private func append(_ run: Run, kind: String, payload: JSONValue, emit: Bool = true, at: Double? = nil) {
        run.seq += 1
        let event: JSONValue = .obj([
            "seq": .int(run.seq),
            "kind": .string(kind),
            "at": .number(at ?? Date().timeIntervalSince1970),
            "payload": payload,
        ])
        run.events.append(event)
        if run.events.count > 600 { run.events.removeFirst(run.events.count - 600) }
        if emit {
            Bridge.emit("claude-picker:session-chat", detail: ["sessionId": run.sessionId, "event": event.any])
        }
    }

    private func emitState(_ run: Run) {
        Bridge.emit("claude-picker:session-chat", detail: [
            "sessionId": run.sessionId,
            "state": [
                "phase": run.phase.rawValue,
                "pending": run.pending.keys.sorted().compactMap { run.pending[$0]?.any },
                "info": run.info.any,
                "runtime": runtimeJSON(run).any,
                "context": run.context.any,
                "error": run.lastError ?? NSNull(),
            ] as [String: Any],
        ])
    }
}

/// 结构化聊天打开已有会话时，从本地记录取最近的对话，作为界面上的上文（只读，不重放给 CLI）。
enum SessionChatHistory {
    static func load(provider: AgentProvider, fileURL: URL?, limit: Int = 160) -> [JSONValue] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return [] }
        let tail = data.count > 4_000_000 ? data.suffix(4_000_000) : data
        var out: [JSONValue] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in tail.split(separator: 0x0a) {
            guard let row = JSONValue.parse(Data(line)) else { continue }
            var items: [JSONValue]
            switch provider {
            case .claude: items = claudeItems(row)
            case .codex: items = codexItems(row)
            default: return []
            }
            // 历史消息沿用记录里的时间，而不是载入时间。
            if let stamp = row["timestamp"]?.text, let date = iso.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) {
                items = items.map { item in
                    guard case .object(var dict) = item else { return item }
                    dict["at"] = .number(date.timeIntervalSince1970)
                    return .object(dict)
                }
            }
            out += items
        }
        return Array(out.suffix(limit))
    }

    static func claudeItems(_ row: JSONValue) -> [JSONValue] {
        guard let type = row["type"]?.stringValue, type == "user" || type == "assistant",
              row["isMeta"]?.boolValue != true, row["isSidechain"]?.boolValue != true,
              let content = row["message"]?["content"] else { return [] }
        if type == "user" {
            if let text = content.stringValue { return userItem(text) }
            // 工具结果随下一条 user 记录写回：带上错误状态，界面才能区分完成与被拒。
            let results = (content.arrayValue ?? []).filter { $0["type"]?.stringValue == "tool_result" }
            if !results.isEmpty {
                return results.map { part in
                    item("tool_result", ["toolUseId": part["tool_use_id"] ?? .null,
                                         "isError": .bool(part["is_error"]?.boolValue == true),
                                         "content": (part["content"] ?? .null).truncated(limit: 2000)])
                }
            }
            let texts = (content.arrayValue ?? []).filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }
            return texts.isEmpty ? [] : userItem(texts.joined(separator: "\n"))
        }
        var items: [JSONValue] = []
        for part in content.arrayValue ?? [] {
            switch part["type"]?.stringValue {
            case "text":
                if let text = part["text"]?.text { items.append(item("assistant", ["text": .string(text)])) }
            case "tool_use":
                items.append(item("tool_use", ["toolUseId": part["id"] ?? .null, "name": part["name"] ?? .null,
                                               "input": (part["input"] ?? .null).truncated(limit: 2000), "history": .bool(true)]))
            default: break
            }
        }
        return items
    }

    static func codexItems(_ row: JSONValue) -> [JSONValue] {
        guard row["type"]?.stringValue == "response_item", let payload = row["payload"],
              payload["type"]?.stringValue == "message", let role = payload["role"]?.stringValue else { return [] }
        // Codex 把 AGENTS.md 指令、<environment_context> 等作为 user 消息里的独立 input_text 段注入，逐段剔除。
        let text = (payload["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
            .filter { role != "user" || !injectedCodexContext($0) }
            .joined(separator: "\n")
        switch role {
        case "user": return userItem(text)
        case "assistant": return text.isEmpty ? [] : [item("assistant", ["text": .string(text)])]
        default: return []
        }
    }

    static func injectedCodexContext(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("# AGENTS.md instructions") || trimmed.hasPrefix("<")
    }

    private static func userItem(_ text: String) -> [JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 跳过 CLI 注入的上下文、命令回显与系统提醒。
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted") else { return [] }
        return [item("user", ["text": .string(trimmed)])]
    }

    private static func item(_ kind: String, _ payload: [String: JSONValue?]) -> JSONValue {
        .obj(["kind": .string(kind), "payload": .obj(payload)])
    }
}
