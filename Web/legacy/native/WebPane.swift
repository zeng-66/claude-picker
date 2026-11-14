import SwiftUI
import WebKit

/// 第三栏：Git 工作台 / 文件预览的 Web 前端容器。
///
/// 生命周期完全交给 SwiftUI —— 调用方写 `if store.thirdVisible { WebPane() }`，
/// 收起时整个 WKWebView 连同它的 JS 堆一起销毁。mermaid + elk 的 chunk 上兆，
/// 不能让它常驻后台。
struct WebPane: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: Bridge.handlerName)
        // 打包模式走自定义 scheme；dev 模式是 http，不需要。
        if Bridge.developmentURL() == nil, let root = Bridge.webRoot() {
            config.setURLSchemeHandler(WebBundleSchemeHandler(root: root), forURLScheme: Bridge.scheme)
        }

        let view = WKWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = NSColor(srgbRed: 0.067, green: 0.071, blue: 0.078, alpha: 1)
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        context.coordinator.webView = view
        Bridge.liveWebView = view
        context.coordinator.load(into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: Bridge.handlerName)
        view.stopLoading()
        coordinator.webView = nil
        if Bridge.liveWebView === view { Bridge.liveWebView = nil }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?

        /// 三种入口，优先级从高到低：vite dev server → 打包进 bundle 的 web → 一段说明。
        func load(into view: WKWebView) {
            if let url = Bridge.developmentURL() {
                view.load(URLRequest(url: url))
                return
            }
            guard Bridge.bundledIndex() != nil, let index = Bridge.appIndexURL() else {
                view.loadHTMLString(Bridge.missingBuildHTML, baseURL: nil)
                return
            }
            view.load(URLRequest(url: index))
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == Bridge.handlerName,
                  let body = message.body as? [String: Any] else { return }
            Bridge.reply(to: body, on: webView)
        }
    }
}
