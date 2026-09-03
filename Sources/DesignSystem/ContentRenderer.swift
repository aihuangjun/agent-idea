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
    /// render.js 画完一份内容：种类与它自己量的毫秒数。
    public var onRendered: ((String, Int) -> Void)?
    /// 编辑器里的文字变了（停手 300ms 后发一次）：文件路径与整份文本。
    public var onEdited: ((String, String) -> Void)?
    /// 编辑器里按了后退 / 前进（⌥← / ⌥→）。
    public var onNavigate: ((NavigationDirection) -> Void)?
    /// Web 内容进程被系统回收、页面重新加载好了：宿主要按当前状态重画（上次的 payload 里没有之后的编辑）。
    public var onShellReloaded: (() -> Void)?
    private var isRecoveringFromCrash = false

    public enum NavigationDirection: String, Sendable {
        case back
        case forward
    }

    /// WebView 里当前的状态：滚到哪、编辑器里的文字（没有编辑器时为 nil）、光标。
    public struct ViewState: Equatable, Sendable {
        public var scrollTop: Double
        public var text: String?
        public var cursor: EditorCursor?

        public init(scrollTop: Double = 0, text: String? = nil, cursor: EditorCursor? = nil) {
            self.scrollTop = scrollTop
            self.text = text
            self.cursor = cursor
        }
    }

    private var isReady = false
    private var pendingPayload: RenderPayload?
    /// 最近一次渲染的内容。Web 内容进程被系统回收后用它恢复现场。
    private var lastPayload: RenderPayload?
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

    /// 显示一份内容。页面没就绪就先存着，就绪后补发。
    public func render(_ payload: RenderPayload) {
        lastPayload = payload
        guard isReady else {
            pendingPayload = payload
            return
        }
        send(payload)
    }

    /// 当前状态：滚动位置、编辑器里的文字与光标。切标签前问一次，切回来时带在 payload 里恢复；
    /// 文字直接拿走，不用等编辑器那边停手 300ms 才发过来的那份。页面没就绪时立刻回一份空状态。
    public func currentState(_ completion: @escaping (ViewState) -> Void) {
        guard isReady else {
            completion(ViewState())
            return
        }
        webView.evaluateJavaScript("window.ide.getState()") { value, _ in
            let dictionary = value as? [String: Any] ?? [:]
            completion(ViewState(
                scrollTop: (dictionary["scrollTop"] as? NSNumber)?.doubleValue ?? 0,
                text: dictionary["text"] as? String,
                cursor: Self.cursor(from: dictionary["cursor"])
            ))
        }
    }

    private static func cursor(from value: Any?) -> EditorCursor? {
        guard let dictionary = value as? [String: Any],
              let line = (dictionary["line"] as? NSNumber)?.intValue, let ch = (dictionary["ch"] as? NSNumber)?.intValue else { return nil }
        return EditorCursor(line: line, ch: ch)
    }

    public func setZoom(_ zoom: Double) {
        self.zoom = zoom
        guard isReady else { return }
        webView.evaluateJavaScript("window.ide.setZoom(\(zoom))")
    }

    /// 基线到了（异步取的 HEAD 内容）：正在编辑这个文件的话立刻画标记，不用重画整个编辑器。
    public func setBase(path: String, text: String?) {
        guard isReady, let data = try? JSONEncoder().encode(["path": path, "base": text]), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.ide.setBase(\(json))")
    }

    public func setWrap(_ wrap: Bool) {
        lastPayload?.wrap = wrap
        pendingPayload?.wrap = wrap
        guard isReady else { return }
        webView.evaluateJavaScript("window.ide.setWrap(\(wrap))")
    }

    private func send(_ payload: RenderPayload) {
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else {
            Log.warn("web", "payload 编码失败")
            return
        }
        Log.info("web", "render \(payload.content.kindName) \(json.utf8.count) 字节")
        webView.evaluateJavaScript("window.ide.render(\(json))") { _, error in
            if let error { Log.warn("web", "render 失败：\(error)") }
        }
    }

    /// 页面就绪。didFinish 与 JS 的 ready 消息哪个先到都可以，但只有第一个信号补发。
    private func markReadyAndFlush() {
        let isFirstSignal = !isReady
        isReady = true
        if isFirstSignal, zoom != 1 {
            webView.evaluateJavaScript("window.ide.setZoom(\(zoom))")
        }
        if isFirstSignal, isRecoveringFromCrash, let onShellReloaded {
            // 让宿主重画：它手里有最新的草稿；这里存的 lastPayload 是崩溃前上一次渲染的样子
            isRecoveringFromCrash = false
            pendingPayload = nil
            onShellReloaded()
            return
        }
        guard let payload = pendingPayload ?? (isFirstSignal ? lastPayload : nil) else { return }
        pendingPayload = nil
        send(payload)
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
        isRecoveringFromCrash = onShellReloaded != nil
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
        case "rendered":
            let ms = (body["ms"] as? NSNumber)?.intValue ?? 0
            let kind = body["kind"] as? String ?? ""
            if ms >= 300 { Log.warn("web", "渲染 \(kind) 用了 \(ms) ms") }
            onRendered?(kind, ms)
        case "error":
            Log.warn("web", "页面脚本出错：\(body["message"] as? String ?? "") @ \(body["where"] as? String ?? "")")
        case "edited":
            if let path = body["path"] as? String, let text = body["text"] as? String { onEdited?(path, text) }
        case "navigate":
            if let direction = (body["direction"] as? String).flatMap(NavigationDirection.init) { onNavigate?(direction) }
        default:
            break
        }
    }
}

/// 把 `ContentRenderer` 的 WKWebView 放进 SwiftUI 层级。视图是壳、渲染器是本体。
///
/// 返回的是自己的容器，WebView 挂在容器里，而不是直接把共用的 WebView 交给 SwiftUI：切项目时 `ProjectContent` 换了身份，
/// 新的 representable 先把 WebView 搬走、旧的随后拆卸时会再把它从父视图里摘掉——同一个 NSView 被两边争，正文就空了。
/// 容器各是各的，拆旧容器不影响新容器；`updateNSView` 再核对一次归属，被摘走了就挂回来。
public struct ContentWebView: NSViewRepresentable {
    private let renderer: ContentRenderer

    public init(renderer: ContentRenderer) {
        self.renderer = renderer
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        // 只在 WebView 无家可归（所在容器已被拆下窗口）时才挂回来；它正在另一个活着的容器里就别抢——两个容器互抢会来回跳
        let webView = renderer.webView
        if webView.superview !== container, webView.window == nil { attach(to: container) }
    }

    private func attach(to container: NSView) {
        let webView = renderer.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
