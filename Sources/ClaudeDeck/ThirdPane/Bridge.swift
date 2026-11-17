import Foundation
import WebKit

/// JS ⇄ Swift 的桥。
///
/// 信封与 `Web/src/shell/bridge.js` 一一对应：
/// 请求 `{id, method, params}` → 应答 `{id, ok, result}` 或 `{id, ok:false, error}`；
/// 原生 → 网页的单向事件走 `window.dispatchEvent(new CustomEvent(name, {detail}))`。
enum Bridge {
    static let handlerName = "claudeBridge"

    /// 网页外壳所在的 WebView（`ShellView` 创建时登记）。原生侧主动推事件用。
    @MainActor static weak var liveWebView: WKWebView?

    /// 原生 → 网页的单向事件：`window.dispatchEvent(new CustomEvent(name, {detail}))`。
    /// 还没有 WebView 时直接丢弃，返回 false。
    @MainActor @discardableResult
    static func emit(_ name: String, detail: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: detail) else { return false }
        return emit(name, json: data)
    }

    /// 同上，`detail` 已经序列化好（状态快照先序列化再比较是否有变化，不必编码两次）。
    @MainActor @discardableResult
    static func emit(_ name: String, json data: Data) -> Bool {
        guard let webView = liveWebView,
              let json = String(data: data, encoding: .utf8),
              let nameData = try? JSONSerialization.data(withJSONObject: [name]),
              let nameJSON = String(data: nameData, encoding: .utf8)
        else { return false }
        let js = "window.dispatchEvent(new CustomEvent(\(nameJSON)[0], { detail: \(json) }))"
        webView.evaluateJavaScript(js, completionHandler: nil)
        return true
    }

    /// 打包模式用的自定义 scheme。不能直接用 `file://` —— 页面 origin 是 `null`，
    /// Vite 产物里的 `<script type="module">` 会被 CORS 拦掉，第三栏就是一片白。
    static let scheme = "claude-picker"
    static let appHost = "app"

    /// 开发模式：`CLAUDE_PICKER_WEB_URL=http://127.0.0.1:5173/ .build/debug/ClaudeDeck`
    /// 就能直接连 vite dev server（带 HMR），不用每次重新打包。
    static func developmentURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["CLAUDE_PICKER_WEB_URL"],
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file"
        else { return nil }
        return url
    }

    /// 打包后的入口：`Contents/Resources/web/index.html`（由 scripts/build-app.sh 拷进去）。
    static func bundledIndex() -> URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
    }

    /// 打包后的前端根目录，给自定义 scheme 当静态根用。
    static func webRoot() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true)
    }

    /// 页面实际加载的地址：`claude-picker://app/index.html`。
    static func appIndexURL() -> URL? {
        URL(string: "\(scheme)://\(appHost)/index.html")
    }

    /// 从源码树直接 `swift run` 时 bundle 里没有 web，给一句能照着做的提示，
    /// 而不是让用户对着白屏猜。
    static let missingBuildHTML = """
    <!doctype html>
    <html><head><meta charset="utf-8"></head>
    <body style="margin:0;background:#111214;color:#858890;
                 font:13px/1.7 -apple-system,BlinkMacSystemFont,sans-serif;padding:28px">
      <p style="color:#dadbdd;margin:0 0 14px">界面的前端产物还没有构建。</p>
      <pre style="color:#dadbdd;background:#1b1c20;border:1px solid #34353a;
                  border-radius:6px;padding:10px 12px;overflow:auto">cd Web &amp;&amp; npm install &amp;&amp; npm run build</pre>
      <p style="margin:14px 0 0">然后用 <code style="color:#de9771">./scripts/build-app.sh</code> 重新打包。</p>
      <p style="margin:6px 0 0">开发时更省事：<code style="color:#de9771">CLAUDE_PICKER_WEB_URL=http://127.0.0.1:5173/</code>
      指向 vite dev server，改代码即时生效。</p>
    </body></html>
    """

    /// 能力域清单。新模块只需在这里加一行 —— 各模块的方法表在自己的文件里，
    /// 多张任务卡并行时不会互相踩。
    // 元类型数组只在这里初始化一次、之后只读，不存在并发写。
    nonisolated(unsafe) private static let modules: [any BridgeModule.Type] = [
        GitHandlers.self,
        FileHandlers.self,
        McpHandlers.self,
        AppHandlers.self,
        SessionHandlers.self,
        WorkHandlers.self,
        UpdateHandlers.self,
    ]

    /// 起子进程、读写文件的方法放到后台线程：fetch / pull / push、MCP 健康检查、建 worktree
    /// 都可能要几十秒，同步执行会把整个窗口（含终端）冻住。其余方法读写 `@MainActor` 的 Store，
    /// 留在主线程。
    static func runsInBackground(_ method: String) -> Bool {
        method.hasPrefix("git.") || method.hasPrefix("file.") || method.hasPrefix("mcp.") || method.hasPrefix("update.")
            || method == "session.create" || WorkHandlers.handles(method)
    }

    static func dispatch(method: String, params: Any?) throws -> BridgeOutcome {
        for module in modules {
            switch try module.handle(method, params: params) {
            case .handled(let value):
                return .handled(value)
            case .unknown:
                continue
            }
        }
        return .unknown
    }

    /// 处理一条请求并回包。没有模块认领的方法回 `NOT_IMPLEMENTED`。
    @MainActor
    static func reply(to body: [String: Any], on webView: WKWebView?) {
        guard body["id"] != nil else { return }
        let method = body["method"] as? String ?? ""

        guard runsInBackground(method),
              let request = try? JSONSerialization.data(withJSONObject: body)
        else {
            send(envelope(for: body), on: webView)
            return
        }
        Task { @MainActor [weak webView] in
            // 跨线程只传 Data（Sendable）：后台还原请求、算出应答再序列化回来。
            let response: Data? = await Task.detached(priority: .userInitiated) {
                guard let restored = try? JSONSerialization.jsonObject(with: request) as? [String: Any]
                else { return nil }
                return try? JSONSerialization.data(withJSONObject: envelope(for: restored))
            }.value
            guard let response,
                  let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
            else { return }
            send(object, on: webView)
        }
    }

    private static func envelope(for body: [String: Any]) -> [String: Any] {
        let id = body["id"] ?? NSNull()
        let method = body["method"] as? String ?? ""
        let params = body["params"]

        let envelope: [String: Any]
        do {
            switch try dispatch(method: method, params: params) {
            case .handled(let value):
                envelope = ["id": id, "ok": true, "result": value]
            case .unknown:
                envelope = notImplemented(id: id, method: method)
            }
        } catch let error as GitError {
            envelope = ["id": id, "ok": false, "error": error.jsonObject]
        } catch let error as WorkError {
            envelope = ["id": id, "ok": false, "error": error.jsonObject]
        } catch {
            envelope = [
                "id": id,
                "ok": false,
                "error": [
                    "code": "COMMAND_FAILED",
                    "message": "原生侧处理失败：\(method)",
                    "detail": "\(error)",
                    "recoverable": false,
                ],
            ]
        }
        return envelope
    }

    private static func notImplemented(id: Any, method: String) -> [String: Any] {
        [
            "id": id,
            "ok": false,
            "error": [
                "code": "NOT_IMPLEMENTED",
                "message": "原生侧尚未接线：\(method)",
                "detail": NSNull(),
                "recoverable": false,
            ],
        ]
    }

    @MainActor
    private static func send(_ envelope: [String: Any], on webView: WKWebView?) {
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8)
        else { return }
        // json 是合法 JSON 字面量，直接当 JS 表达式传入，不需要二次转义。
        let js = "window.__claudeBridge && window.__claudeBridge.receive(\(json))"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

/// 把 `claude-picker://app/...` 映射到 `Contents/Resources/web` 下的静态文件。
///
/// 这是替代 `file://` 的正经做法：页面拿到一个固定 origin，ES module、fetch、
/// 相对路径全都能正常工作，也不用去动 WebKit 的私有偏好键。
final class WebBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    private let rootPrefix: String
    private let lock = NSLock()
    private var cancelled = Set<ObjectIdentifier>()

    init(root: URL) {
        let standardized = root.standardizedFileURL
        self.root = standardized
        self.rootPrefix = standardized.path + "/"
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        defer {
            lock.lock()
            cancelled.remove(key)
            lock.unlock()
        }

        guard let url = task.request.url, let file = resolve(url) else {
            fail(task, key, code: 400)
            return
        }
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
            fail(task, key, code: 404)
            return
        }
        let response = URLResponse(url: url,
                                   mimeType: Self.mimeType(for: file.pathExtension),
                                   expectedContentLength: data.count,
                                   textEncodingName: "utf-8")
        guard !isCancelled(key) else { return }
        task.didReceive(response)
        guard !isCancelled(key) else { return }
        task.didReceive(data)
        guard !isCancelled(key) else { return }
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock()
        cancelled.insert(ObjectIdentifier(task))
        lock.unlock()
    }

    // MARK: 内部

    /// 拒绝越出 web 根目录的路径（`..`、绝对路径、软链接穿出）。
    private func resolve(_ url: URL) -> URL? {
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        guard let decoded = path.removingPercentEncoding, decoded.hasPrefix("/") else { return nil }
        let file = root.appendingPathComponent(String(decoded.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(rootPrefix) else { return nil }
        return file
    }

    private func isCancelled(_ key: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(key)
    }

    private func fail(_ task: WKURLSchemeTask, _ key: ObjectIdentifier, code: Int) {
        guard !isCancelled(key) else { return }
        task.didFailWithError(NSError(domain: "ClaudePicker.WebBundle", code: code))
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        case "txt", "md": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}
