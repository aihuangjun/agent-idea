import AppKit
import Core
import Foundation
import SwiftUI
@preconcurrency import WebKit

/// 弱引用转发器。`WKUserContentController` 会强引用 message handler，
/// 直接把 renderer 注册进去会形成引用环，实例永远无法释放。
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// 一块会把光标还回去的 WebView。
///
/// `NSCursor` 是应用全局的一份状态。WebKit 把光标改成 I 形或手型之后，SwiftUI 的按钮不认领光标，
/// 于是那个光标会一路跟到目录树、标签栏上。规矩：谁改的光标谁负责还回去。
final class CursorRestoringWebView: WKWebView {
    private var cursorTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        cursorTracking = area
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
    }
}

/// 持有唯一一个 WKWebView，负责与 render.js 通信。
///
/// 页面只加载一次，切换内容靠 `window.ide.render(...)`——重新 load 会让 2.5MB 的 mermaid 反复初始化。
@MainActor
public final class ContentRenderer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    public let webView: WKWebView

    /// 正文里点了 http(s) 链接。
    public var onOpenExternal: ((URL) -> Void)?
    /// Markdown 里点了指向本地文件的相对链接。
    public var onOpenPath: ((String) -> Void)?

    private var isReady = false
    private var pendingPayload: [String: Any]?
    private var lastPayload: [String: Any]?
    private var shellURL: URL?
    private var zoom: Double = 1
    private let messageProxy = ScriptMessageProxy()

    override public init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = CursorRestoringWebView(frame: .zero, configuration: configuration)
        // 页面自己的底色是深色，但页面加载完成前 WKWebView 是白的，会闪一下
        webView.setValue(false, forKey: "drawsBackground")
        super.init()

        messageProxy.target = self
        webView.configuration.userContentController.add(messageProxy, name: "ide")
        webView.navigationDelegate = self
        // 正文区不接文件拖放：拖进来的目录该由窗口那一层当「打开项目」处理，WebKit 接了会当成导航。
        webView.unregisterDraggedTypes()
        loadShell()
    }

    deinit {
        // 渲染器与窗口同生死，这里几乎不会跑到；真跑到时代理是弱引用，留着也不会指向野对象。
        MainActor.assumeIsolated {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "ide")
        }
    }

    private func loadShell() {
        guard let index = WebResources.shellURL else {
            assertionFailure("渲染页缺失，检查 Package.swift 的 resources 配置与 build_app.sh 的拷贝路径")
            return
        }
        shellURL = index.standardizedFileURL
        isReady = false
        // 文档里的图片散落在项目任意目录，本地自用应用直接放开根目录读权限。
        webView.loadFileURL(index, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    // MARK: - 渲染

    /// 显示一份内容。`payload` 的结构见 render.js 顶部注释。
    public func render(_ payload: [String: Any]) {
        lastPayload = payload
        guard isReady else {
            pendingPayload = payload
            return
        }
        call("window.ide.render", argument: payload)
    }

    public func showMessage(title: String, detail: String) {
        render(["kind": "message", "title": title, "detail": detail])
    }

    /// 当前滚动位置。切标签前问一次，切回来时带在 payload 里恢复。
    public func currentScrollTop(_ completion: @escaping (Double) -> Void) {
        guard isReady else {
            completion(0)
            return
        }
        webView.evaluateJavaScript("window.ide.getScrollTop()") { value, _ in
            completion((value as? NSNumber)?.doubleValue ?? 0)
        }
    }

    public func setZoom(_ zoom: Double) {
        self.zoom = zoom
        guard isReady else { return }
        webView.evaluateJavaScript("window.ide.setZoom(\(zoom))")
    }

    public func setWrap(_ wrap: Bool) {
        lastPayload?["wrap"] = wrap
        pendingPayload?["wrap"] = wrap
        guard isReady else { return }
        webView.evaluateJavaScript("window.ide.setWrap(\(wrap))")
    }

    private func call(_ function: String, argument: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: argument),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("\(function)(\(json))")
    }

    /// 页面就绪。didFinish 与 JS 的 ready 消息哪个先到都可以，但只有第一个信号补发。
    private func markReadyAndFlush() {
        let isFirstSignal = !isReady
        isReady = true
        if isFirstSignal, zoom != 1 {
            webView.evaluateJavaScript("window.ide.setZoom(\(zoom))")
        }
        guard let payload = pendingPayload ?? (isFirstSignal ? lastPayload : nil) else { return }
        pendingPayload = nil
        call("window.ide.render", argument: payload)
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        markReadyAndFlush()
    }

    /// 只允许加载我们自己的 shell 页面。正文里的链接一旦真的导航出去，`window.ide` 就没了。
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.isFileURL, url.standardizedFileURL.path == shellURL?.path {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, !url.isFileURL {
            onOpenExternal?(url)
        }
    }

    /// Web 内容进程被系统回收（大文档时会发生）：重新加载页面并恢复当前内容。
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.warn("web", "内容进程被回收，重新加载渲染页")
        loadShell()
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // 只接受来自 shell 页面的消息：Markdown 允许内嵌 HTML，文档里的脚本同样能 postMessage。
        guard message.webView?.url?.standardizedFileURL.path == shellURL?.path else { return }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            markReadyAndFlush()
        case "openExternal":
            if let href = body["href"] as? String, let url = URL(string: href) { onOpenExternal?(url) }
        case "openPath":
            if let path = body["path"] as? String { onOpenPath?(path) }
        default:
            break
        }
    }
}

/// 把 `ContentRenderer` 的 WKWebView 放进 SwiftUI 层级。视图是壳、渲染器是本体。
public struct ContentWebView: NSViewRepresentable {
    private let renderer: ContentRenderer

    public init(renderer: ContentRenderer) {
        self.renderer = renderer
    }

    public func makeNSView(context: Context) -> NSView { renderer.webView }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}
