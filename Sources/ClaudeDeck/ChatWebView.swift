import AppKit
import WebKit

/// Swttch 页面地址的拼装与解析（纯函数，便于回归测试）。
enum ChatRoute {
    /// `/sessions/<id>` 或 `/sessions/new`，带 workingDir；`is_desktop=1` 让页面隐藏自身顶栏（嵌入宿主模式）。
    static func path(cwd: String, sid: String?) -> String {
        var c = URLComponents()
        c.path = "/sessions/" + (sid ?? "new")
        c.queryItems = [URLQueryItem(name: "workingDir", value: cwd),
                        URLQueryItem(name: "is_desktop", value: "1")]
        // URLComponents 不转义 query 里的 `+`，页面按 form 规则会读成空格。
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.string ?? "/sessions/new"
    }

    static func url(port: Int, cwd: String, sid: String?, pair: String?) -> URL? {
        var s = "http://127.0.0.1:\(port)" + path(cwd: cwd, sid: sid)
        if let pair, !pair.isEmpty { s += "&pair=\(pair)" }
        return URL(string: s)
    }

    /// 从页面当前地址读出 (workingDir, sessionId)。新建页 `/sessions/new` 的 sessionId 为 nil。
    static func parse(_ url: URL?) -> (cwd: String, sid: String?)? {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = c.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "sessions" else { return nil }
        guard let cwd = c.queryItems?.first(where: { $0.name == "workingDir" })?.value, !cwd.isEmpty else { return nil }
        let id = String(parts[1])
        return (cwd, id == "new" ? nil : id)
    }
}

/// 复用一个 WKWebView 承载 Swttch 聊天界面，放进网页外壳第二栏的「洞」里（取代终端视图）。
/// 会话切换只改页面路由、不重载页面，每个会话的输入草稿、滚动位置和待审批状态由页面自己保留。
/// 服务启动中 / 失败时，在同一个 WebView 里显示一张本地状态页。
@MainActor
final class ChatHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = ChatHost()
    private static let actionScheme = "picker-chat"

    let webView: WKWebView
    /// 页面当前加载的是哪一次启动的 backend（端口变了说明服务重启，需要带新配对码重载）。
    private var loadedPort: Int?
    /// 页面路由变化：(workingDir, sessionId)；新会话拿到 id 后由此通知 Store。
    var onRouteChange: ((String, String?) -> Void)?
    var onRetry: (() -> Void)?
    var onFallback: (() -> Void)?
    private var urlObservation: NSKeyValueObservation?

    override init() {
        let config = WKWebViewConfiguration()
        // 不落盘：配对得到的 token 只活在本次进程；端口每次不同，持久化只会留下无用的源数据。
        config.websiteDataStore = .nonPersistent()
        config.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.appearance = NSAppearance(named: .darkAqua)
        webView.underPageBackgroundColor = kTerminalBackground
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            let url = wv.url
            MainActor.assumeIsolated {
                guard let self, let r = ChatRoute.parse(url) else { return }
                self.onRouteChange?(r.cwd, r.sid)
            }
        }
    }

    /// 显示某个会话。backend 未就绪时显示状态页，就绪后由调用方再调一次。
    func show(cwd: String, sid: String?, backend: ChatBackendManager) {
        switch backend.state {
        case .idle, .starting:
            showStatus("正在启动图形聊天服务…", actions: false)
            return
        case .failed(let message):
            showStatus(message, actions: true)
            return
        case .ready:
            break
        }
        guard let port = backend.port else { return }
        if loadedPort == port, webView.url?.host == "127.0.0.1" {
            if let cur = ChatRoute.parse(webView.url), cur.cwd == cwd, cur.sid == sid { return }
            // 同页路由切换：pushState + popstate，React Router 会跟随，页面状态不丢。
            let path = ChatRoute.path(cwd: cwd, sid: sid)
            let js = "history.pushState(null, '', \(Self.jsString(path))); window.dispatchEvent(new PopStateEvent('popstate'));"
            webView.evaluateJavaScript(js, completionHandler: nil)
            return
        }
        guard let url = ChatRoute.url(port: port, cwd: cwd, sid: sid, pair: backend.pairCode) else { return }
        loadedPort = port
        webView.load(URLRequest(url: url))
    }

    /// 服务停止或切回终端模式时清空页面，下次使用重新配对加载。
    func reset() {
        loadedPort = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    func showStatus(_ message: String, actions: Bool) {
        loadedPort = nil
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let buttons = actions ? """
            <p><a href="\(Self.actionScheme)://retry">重试</a><a href="\(Self.actionScheme)://fallback">切回原生终端</a></p>
            """ : ""
        let html = """
        <!doctype html><meta charset="utf-8"><style>
        html,body{margin:0;height:100%;background:#202122;color:rgba(255,255,255,.6);
          font:13px -apple-system,BlinkMacSystemFont,sans-serif}
        body{display:flex;align-items:center;justify-content:center;text-align:center;padding:24px;box-sizing:border-box}
        div{max-width:460px;line-height:1.6;user-select:text;-webkit-user-select:text;word-break:break-all}
        a{display:inline-block;margin:14px 6px 0;padding:5px 14px;border-radius:6px;
          background:rgba(255,255,255,.1);color:#fff;text-decoration:none}
        a:hover{background:rgba(255,255,255,.18)}
        </style><body><div>\(escaped)\(buttons)</div></body>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        if url.scheme == Self.actionScheme {
            decisionHandler(.cancel)
            if url.host == "retry" { onRetry?() } else if url.host == "fallback" { onFallback?() }
            return
        }
        // 页面内只允许本地服务与空白页；其余链接交给系统默认浏览器。
        if url.scheme == "about" || url.host == "127.0.0.1" || url.host == "localhost" {
            return decisionHandler(.allow)
        }
        if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame == true {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        showStatus("页面加载失败：\(error.localizedDescription)", actions: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebView 进程崩溃不影响 backend 里的会话，重载页面即可恢复连接。
        loadedPort = nil
        webView.reload()
    }

    // MARK: WKUIDelegate

    /// `window.open` / target=_blank：外部链接用系统浏览器打开。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    /// `<input type=file>`：系统文件选择面板。
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { resp in
            MainActor.assumeIsolated { completionHandler(resp == .OK ? panel.urls : nil) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "确定")
        a.addButton(withTitle: "取消")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
}
