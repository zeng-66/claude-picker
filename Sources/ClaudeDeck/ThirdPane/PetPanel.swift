import AppKit
import Combine
import WebKit

/// Clawd 桌宠 P2：整个桌面上都能看到的透明悬浮窗（docs/ui-refactor-v003.md §9）。
///
/// - 透明、无边框、不抢焦点的 `NSPanel`，浮在普通窗口之上，出现在所有桌面空间和全屏 App 旁边；
///   主窗口最小化后仍然显示，退出 App 时一起关闭。
/// - 内容是一个独立的 WKWebView，加载同一份网页（`?pet=desktop`），状态与动画引擎和窗口内桌宠共用。
/// - 只有桌宠本体和提示气泡可以点；其余透明区域鼠标穿透（网页回报可点区域，按鼠标位置切换 `ignoresMouseEvents`）。
/// - 拖动由网页按屏幕坐标增量回报，原生移动窗口；右键弹原生菜单。
@MainActor
final class PetController: NSObject, WKScriptMessageHandler {
    static private(set) var shared: PetController?

    private let store: Store
    private weak var app: AppDelegate?
    private var panel: PetPanel?
    private var webView: WKWebView?
    private var hitRects: [CGRect] = []
    private var monitors: [Any] = []
    private var settingsObserver: AnyCancellable?
    private var lastActivity = Date.distantPast
    private var dragging = false

    /// 桌宠上方留给提示气泡的高度。
    static let bubbleArea: CGFloat = 104
    static let minWidth: CGFloat = 280

    init(store: Store, app: AppDelegate) {
        self.store = store
        self.app = app
        super.init()
        PetController.shared = self
        settingsObserver = store.$settings
            .map(\.pet)
            .removeDuplicates { $0.enabled == $1.enabled && $0.size == $1.size }
            .receive(on: RunLoop.main)
            .sink { [weak self] pet in
                MainActor.assumeIsolated { self?.apply(pet) }
            }
    }

    // MARK: 显示 / 隐藏

    private func apply(_ pet: PetSettings) {
        if pet.enabled { show(pet) } else { hide() }
    }

    private func panelSize(_ pet: PetSettings) -> NSSize {
        // Codex 像素版高宽比 208/192，Dev Life 为正方形：按较高的那个留空间。
        NSSize(width: max(CGFloat(pet.size), Self.minWidth), height: ceil(CGFloat(pet.size) * 1.1) + Self.bubbleArea)
    }

    private func show(_ pet: PetSettings) {
        let size = panelSize(pet)
        if panel == nil { create(size: size, pet: pet) }
        guard let panel else { return }
        if panel.frame.size != size {
            // 尺寸变化时保持桌宠底边中心不动。
            let old = panel.frame
            let origin = NSPoint(x: old.midX - size.width / 2, y: old.minY)
            panel.setFrame(clamped(NSRect(origin: origin, size: size)), display: true)
        }
        panel.orderFrontRegardless()
        installMonitors()
    }

    private func hide() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    private func create(size: NSSize, pet: PetSettings) {
        let config = WKWebViewConfiguration()
        if Bridge.developmentURL() == nil, let root = Bridge.webRoot() {
            config.setURLSchemeHandler(WebBundleSchemeHandler(root: root), forURLScheme: Bridge.scheme)
        }
        config.userContentController.add(self, name: Bridge.handlerName)
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        if web.responds(to: Selector(("_setDrawsBackground:"))) { web.setValue(false, forKey: "drawsBackground") }
        web.underPageBackgroundColor = .clear
        web.allowsMagnification = false
        web.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) { web.isInspectable = true }

        let panel = PetPanel(contentRect: initialFrame(size: size, pet: pet),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true // 网页回报可点区域之前，整窗穿透
        panel.contentView = web
        self.panel = panel
        webView = web
        Bridge.petWebView = web

        if let dev = Bridge.developmentURL(), var parts = URLComponents(url: dev, resolvingAgainstBaseURL: false) {
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "pet", value: "desktop")]
            if let url = parts.url { web.load(URLRequest(url: url)) }
        } else if let url = URL(string: "\(Bridge.scheme)://\(Bridge.appHost)/index.html?pet=desktop") {
            web.load(URLRequest(url: url))
        }
    }

    /// 上次的位置（仍在某块屏幕上时）；否则主屏右下角。
    private func initialFrame(size: NSSize, pet: PetSettings) -> NSRect {
        if let x = pet.desktopX, let y = pet.desktopY {
            let rect = NSRect(x: x, y: y, width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { return clamped(rect) }
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.maxX - size.width - 24, y: visible.minY + 16, width: size.width, height: size.height)
    }

    /// 让窗口留在它所在（或离它最近）的那块屏幕的可见区域里。
    private func clamped(_ rect: NSRect) -> NSRect {
        let center = NSPoint(x: rect.midX, y: rect.minY + 40)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.min { distance($0.frame, center) < distance($1.frame, center) }
        guard let visible = screen?.visibleFrame else { return rect }
        var out = rect
        out.origin.x = min(max(out.origin.x, visible.minX - (out.width - Self.minWidth) / 2), visible.maxX - out.width)
        // 上方的气泡区可以伸出屏幕顶边，桌宠本体必须在屏幕里。
        out.origin.y = min(max(out.origin.y, visible.minY), visible.maxY - out.height + Self.bubbleArea)
        return out
    }

    private func distance(_ frame: NSRect, _ point: NSPoint) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return hypot(dx, dy)
    }

    // MARK: 鼠标穿透

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func pointerMoved() {
        guard let panel else { return }
        if !dragging {
            let mouse = NSEvent.mouseLocation
            let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
            let inside = hitRects.contains { $0.insetBy(dx: -2, dy: -2).contains(local) }
            if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        }
        // 整个桌面上的鼠标活动：让桌宠知道用户还在（入睡 / 叫醒 / 空闲小剧场）。
        if Date().timeIntervalSince(lastActivity) > 3 {
            lastActivity = Date()
            emitToPet("claude-picker:pet-activity", [:])
        }
    }

    private func emitToPet(_ name: String, _ detail: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8),
              let nameData = try? JSONSerialization.data(withJSONObject: [name]),
              let nameJSON = String(data: nameData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent(\(nameJSON)[0], { detail: \(json) }))",
                                   completionHandler: nil)
    }

    // MARK: 网页 → 原生（pet.*）

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Bridge.handlerName, let body = message.body as? [String: Any] else { return }
        Bridge.reply(to: body, on: webView)
    }

    func handle(_ method: String, _ params: [String: Any]) throws -> Any? {
        func number(_ key: String) -> CGFloat { CGFloat((params[key] as? NSNumber)?.doubleValue ?? 0) }
        switch method {
        case "pet.hit":
            hitRects = (params["rects"] as? [[String: Any]] ?? []).compactMap { rect in
                guard let x = rect["x"] as? NSNumber, let y = rect["y"] as? NSNumber,
                      let w = rect["w"] as? NSNumber, let h = rect["h"] as? NSNumber else { return nil }
                return CGRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue)
            }
            pointerMoved()
            return nil
        case "pet.move":
            guard let panel else { return nil }
            dragging = true
            panel.ignoresMouseEvents = false
            var frame = panel.frame
            frame.origin.x += number("dx")
            frame.origin.y -= number("dy") // 网页 y 向下，屏幕 y 向上
            panel.setFrame(clamped(frame), display: true)
            return nil
        case "pet.moveEnd":
            dragging = false
            if let frame = panel?.frame {
                store.applySettings(["pet": ["desktopX": Double(frame.minX), "desktopY": Double(frame.minY)]])
            }
            return nil
        case "pet.click":
            app?.petCommand("petClick")
            return nil
        case "pet.open":
            if let displayId = params["displayId"] as? String, !displayId.isEmpty {
                app?.petCommand("openWork", ["displayId": displayId])
            } else {
                app?.petCommand("restoreTerminal")
            }
            return nil
        case "pet.menu":
            showMenu()
            return nil
        default:
            return nil
        }
    }

    // MARK: 右键菜单

    private func showMenu() {
        guard let webView else { return }
        let menu = NSMenu()
        func item(_ title: String, _ action: String) {
            let entry = menu.addItem(withTitle: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = action
        }
        item("打开当前会话", "restoreTerminal")
        item("打开悬浮输入", "openConsole")
        item("显示主窗口", "showMain")
        menu.addItem(.separator())
        item("挥手", "react:hello")
        item("跳一下", "react:jump")
        menu.addItem(.separator())
        item("桌宠设置…", "openPetSettings")
        item("隐藏桌宠", "hide")
        let location = webView.convert(webView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        menu.popUp(positioning: nil, at: location, in: webView)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        if action.hasPrefix("react:") {
            emitToPet("claude-picker:pet", ["name": String(action.dropFirst(6))])
        } else if action == "hide" {
            emitToPet("claude-picker:pet", ["name": "bye"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                MainActor.assumeIsolated {
                    self?.store.applySettings(["pet": ["enabled": false]])
                    self?.store.pushState()
                }
            }
        } else if action == "showMain" {
            app?.petCommand(nil)
        } else {
            app?.petCommand(action)
        }
    }
}

/// 可以成为 key 的无边框面板：网页里的点击、拖动不用先点一下「激活」。不会激活整个 App。
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// `pet.*` 桥方法：只来自桌宠窗口的网页。
enum PetHandlers: BridgeModule {
    static func handle(_ method: String, params: Any?) throws -> BridgeOutcome {
        guard method.hasPrefix("pet.") else { return .unknown }
        let input = try JSONSerialization.data(withJSONObject: params as? [String: Any] ?? [:])
        try MainActor.assumeIsolated {
            let dict = (try JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
            _ = try PetController.shared?.handle(method, dict)
        }
        return .handled(NSNull())
    }
}
