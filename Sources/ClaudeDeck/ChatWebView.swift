import AppKit
import UserNotifications
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
final class ChatHost: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let shared = ChatHost()
    private static let actionScheme = "picker-chat"
    private static let notifyHandler = "pickerNotify"

    /// WKWebView 里网页通知权限永远停在「未决定」，页面就会挂出「回复完成时收到通知」横幅且通知发不出去。
    /// 文档开始前换掉 `window.Notification`：权限恒为 granted，`new Notification()` 转给宿主发系统通知。
    private static let notificationShim = """
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.\(notifyHandler).postMessage(m); } catch (_) {} };
      class PickerNotification extends EventTarget {
        constructor(title, opts) {
          super();
          opts = opts || {};
          this.title = String(title);
          this.body = opts.body ? String(opts.body) : '';
          this.tag = opts.tag ? String(opts.tag) : '';
          this.onclick = this.onclose = this.onshow = this.onerror = null;
          post({ title: this.title, body: this.body, tag: this.tag });
        }
        close() { try { this.onclose && this.onclose(new Event('close')); } catch (_) {} }
        static get permission() { return 'granted'; }
        static requestPermission(cb) { try { cb && cb('granted'); } catch (_) {} return Promise.resolve('granted'); }
      }
      Object.defineProperty(window, 'Notification', { value: PickerNotification, writable: true, configurable: true });
    })();
    """

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
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.notificationShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        // ChatHost 是常驻单例，被 content controller 强引用不构成泄漏。
        content.add(self, name: Self.notifyHandler)
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

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.notifyHandler, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == "127.0.0.1",
              let body = message.body as? [String: Any],
              let title = body["title"] as? String, !title.isEmpty else { return }
        ChatNotifier.shared.post(title: title, body: body["body"] as? String ?? "",
                                 tag: body["tag"] as? String ?? "")
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

/// 图形聊天页的系统通知。权限在第一次发通知时向系统申请（只弹一次）；
/// App 在前台时也显示横幅：页面只在用户没看着那个会话时才发，比如正停在另一个会话上。
/// 声音由 backend 按用户设置单独播放，这里不再出声。
@MainActor
final class ChatNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ChatNotifier()
    private var authorized: Bool?

    func post(title: String, body: String, tag: String) {
        // `swift run` 等无 bundle 的进程里 UNUserNotificationCenter 会直接崩溃。
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // 同一会话的新通知替换旧的，不堆叠。
        let id = tag.isEmpty ? UUID().uuidString : "chat-" + tag
        if authorized == true {
            Self.deliver(id: id, title: title, body: body)
            return
        }
        center.requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in
                self.authorized = granted
                if granted { Self.deliver(id: id, title: title, body: body) }
            }
        }
    }

    private static func deliver(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
        completionHandler()
    }
}
