import AppKit
import WebKit

/// 窗口内容：整窗的网页外壳 + 嵌在它下面的终端视图。
///
/// 网页画出全部界面，只把第二栏里终端所在的矩形留成透明的「洞」；终端视图（SwiftTerm）
/// 放在网页下面、对齐到这个洞。这样网页里的弹窗、菜单、提示能盖在终端上面，
/// 而洞里的鼠标事件由 `hitTest` 改道交给终端。网页通过 `app.layout` 回报三样东西：
/// - `terminal`：洞的矩形（没有洞 = 终端栏收起或没有会话）
/// - `overlays`：压在洞上面、仍要由网页响应的控件（收起 / 关闭按钮）
/// - `drag`：标题栏上可以拖动窗口的空白区域
/// - `blocked`：有弹窗或菜单打开，整窗的鼠标与键盘都交给网页
@MainActor
final class ShellView: NSView, WKScriptMessageHandler {
    let webView: WKWebView
    private let terminalHost = NSView()
    private var terminalView: NSView?
    private var dragViews: [WindowDragView] = []

    private var terminalRect: CGRect?
    private var overlayRects: [CGRect] = []
    private var blocked = false
    /// 弹窗打开前键盘在终端里：弹窗关掉后还回去。
    private var restoreTerminalFocus = false
    /// 终端视图刚挂载但网页尚未回报非零洞口时，暂存焦点请求，待宿主可见时兑现。
    private var pendingTerminalFocus = false
    /// 网页能不能画透明底。不能时退回「终端盖在网页上面、弹窗打开时暂时隐藏终端」。
    private let webIsTransparent: Bool

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        // 打包模式走自定义 scheme；dev 模式是 http，不需要。
        if Bridge.developmentURL() == nil, let root = Bridge.webRoot() {
            config.setURLSchemeHandler(WebBundleSchemeHandler(root: root), forURLScheme: Bridge.scheme)
        }
        webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        // WKWebView 没有公开的「不画背景」开关，这个 KVC 键对应它一直以来的 `_drawsBackground`。
        // 先确认 setter 在，再设；系统哪天拿掉了就走不透明的退路，而不是崩溃。
        webIsTransparent = webView.responds(to: Selector(("_setDrawsBackground:")))
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = kTerminalBackground.cgColor

        terminalHost.wantsLayer = true
        terminalHost.layer?.backgroundColor = kTerminalBackground.cgColor
        terminalHost.isHidden = true

        if webIsTransparent {
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = .clear
        } else {
            webView.underPageBackgroundColor = NSColor(srgbRed: 0.094, green: 0.098, blue: 0.11, alpha: 1)
        }
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.autoresizingMask = [.width, .height]
        config.userContentController.add(self, name: Bridge.handlerName)

        if webIsTransparent {
            addSubview(terminalHost)
            addSubview(webView)
        } else {
            addSubview(webView)
            addSubview(terminalHost)
        }
        Bridge.liveWebView = webView
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 三种入口，优先级从高到低：vite dev server → 打包进 bundle 的 web → 一段说明。
    private func load() {
        if let url = Bridge.developmentURL() {
            webView.load(URLRequest(url: url))
            return
        }
        guard Bridge.bundledIndex() != nil, let index = Bridge.appIndexURL() else {
            webView.loadHTMLString(Bridge.missingBuildHTML, baseURL: nil)
            return
        }
        webView.load(URLRequest(url: index))
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Bridge.handlerName,
              let body = message.body as? [String: Any] else { return }
        Bridge.reply(to: body, on: webView)
    }

    // MARK: 终端

    /// 换上当前会话的终端视图（nil = 没有会话）。旧视图只是摘下来，进程不受影响。
    func showTerminal(_ view: NSView?, backgroundColor: NSColor = kTerminalBackground) {
        layer?.backgroundColor = backgroundColor.cgColor
        terminalHost.layer?.backgroundColor = backgroundColor.cgColor
        if view == nil { pendingTerminalFocus = false }
        guard terminalView !== view else { return }
        terminalView?.removeFromSuperview()
        terminalView = view
        if let view {
            if terminalHost.bounds.width > 1 && terminalHost.bounds.height > 1 {
                view.frame = terminalHost.bounds
            }
            view.autoresizingMask = [.width, .height]
            terminalHost.addSubview(view)
        }
        updateTerminalVisibility()
    }

    private func updateTerminalVisibility() {
        let visible = terminalRect != nil && terminalView != nil && (webIsTransparent || !blocked)
        let wasHidden = terminalHost.isHidden
        if terminalHost.isHidden == visible { terminalHost.isHidden = !visible }
        if wasHidden && visible, let terminalView {
            if terminalHost.bounds.width > 1 && terminalHost.bounds.height > 1,
               terminalView.frame != terminalHost.bounds {
                terminalView.frame = terminalHost.bounds
            }
            terminalView.needsDisplay = true
            if pendingTerminalFocus && !blocked {
                pendingTerminalFocus = false
                window?.makeFirstResponder(terminalView)
            }
        }
    }

    func focusTerminal(_ view: NSView) {
        guard view === terminalView, !blocked else { return }
        if !terminalHost.isHidden {
            pendingTerminalFocus = false
            window?.makeFirstResponder(view)
        } else {
            pendingTerminalFocus = true
        }
    }

    func focusWeb() {
        guard window?.firstResponder !== webView else { return }
        window?.makeFirstResponder(webView)
    }

    private var terminalHasFocus: Bool {
        guard let terminalView, let responder = window?.firstResponder as? NSView else { return false }
        return responder === terminalView || responder.isDescendant(of: terminalView)
    }

    // MARK: 布局（app.layout）

    private static func rect(_ value: Any?) -> CGRect? {
        guard let object = value as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? { (object[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard let x = number("x"), let y = number("y"), let w = number("w"), let h = number("h"),
              w > 1, h > 1 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func applyLayout(_ layout: [String: Any]) {
        // 网页坐标（左上角原点、CSS px）与本视图（isFlipped）一一对应。
        let hole = Self.rect(layout["terminal"])
        overlayRects = (layout["overlays"] as? [Any] ?? []).compactMap(Self.rect)
        let nextBlocked = layout["blocked"] as? Bool ?? (layout["blocked"] as? NSNumber)?.boolValue ?? false

        if hole != terminalRect {
            terminalRect = hole
        }
        if let hole {
            // 对齐到整像素，避免终端文字发虚
            let aligned = backingAlignedRect(hole, options: .alignAllEdgesNearest)
            if terminalHost.frame != aligned {
                terminalHost.frame = aligned
            }
            if let terminalView, terminalView.frame != terminalHost.bounds {
                terminalView.frame = terminalHost.bounds
            }
        }

        let dragRects = (layout["drag"] as? [Any] ?? []).compactMap(Self.rect)
        while dragViews.count < dragRects.count {
            let view = WindowDragView()
            dragViews.append(view)
            addSubview(view)
        }
        for (index, view) in dragViews.enumerated() {
            if index < dragRects.count {
                view.frame = dragRects[index]
                view.isHidden = nextBlocked
            } else {
                view.isHidden = true
            }
        }

        if nextBlocked != blocked {
            blocked = nextBlocked
            if blocked {
                restoreTerminalFocus = terminalHasFocus
                focusWeb()
            } else if restoreTerminalFocus {
                restoreTerminalFocus = false
                updateTerminalVisibility()
                if let terminalView, !terminalHost.isHidden { window?.makeFirstResponder(terminalView) }
            }
        }
        updateTerminalVisibility()
    }

    // MARK: 命中测试

    /// 洞里的事件交给终端；洞上面的网页控件、弹窗打开期间一律交给网页。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard webIsTransparent, !blocked, !terminalHost.isHidden, let hole = terminalRect else {
            return super.hitTest(point)
        }
        let local = superview.map { convert(point, from: $0) } ?? point
        guard hole.contains(local), !overlayRects.contains(where: { $0.contains(local) }) else {
            return super.hitTest(point)
        }
        return terminalHost.hitTest(local) ?? terminalHost
    }
}

/// 标题栏上的窗口拖动区：透明、盖在网页上面，按下即拖动窗口，双击缩放。
private final class WindowDragView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            // 跟随「系统设置 › 桌面与程序坞 › 连按窗口标题栏」的选择
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.performMiniaturize(nil) }
            else if action != "None" { window.performZoom(nil) }
            return
        }
        window.performDrag(with: event)
    }
}
