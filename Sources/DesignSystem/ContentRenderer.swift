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
    var onFind: (() -> Void)?
    var onFindInPath: (() -> Void)?
    var contextActions: (() -> [ContentRenderer.ContextAction])?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let actions = contextActions?() ?? []
        guard !actions.isEmpty else { return }
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for action in actions.reversed() {
            let item = NSMenuItem(title: action.title, action: #selector(performContextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.insertItem(item, at: 0)
        }
    }

    @objc private func performContextAction(_ item: NSMenuItem) {
        (item.representedObject as? ContentRenderer.ContextAction)?.perform()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "f", modifiers == .command || modifiers == .control {
            onFind?()
            return true
        }
        // ⌃⇧F（在项目中查找）：CodeMirror 的 macDefault 键位把 Shift-Ctrl-F 退回 Ctrl-F（goCharRight）当「扩展选区」吃掉，
        // 到不了菜单，所以在页面之前截下来
        if event.charactersIgnoringModifiers?.lowercased() == "f", modifiers == [.control, .shift], let onFindInPath {
            onFindInPath()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

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
    public struct ContextAction {
        public let title: String
        public let perform: () -> Void

        public init(title: String, perform: @escaping () -> Void) {
            self.title = title
            self.perform = perform
        }
    }
    public var contextActions: (() -> [ContextAction])?
    /// HTML 不装 message handler，页面脚本无法向编辑器发送 edited / openPath 等消息。
    fileprivate var htmlWebView: CursorRestoringWebView?
    private var showingHTML = false
    private let htmlPreviewHandler = HTMLPreviewHandler()
    /// 渲染页按需取 tree-sitter 的 WASM 与查询（file:// 页面 fetch 不到本地文件）。
    private let webAssetHandler: WebAssetHandler
    public var onFind: (() -> Void)?
    /// 焦点在正文里时按了 ⌃⇧F（在项目中查找）。
    public var onFindInPath: (() -> Void)?
    public var displayedWebView: WKWebView { showingHTML ? (htmlWebView ?? webView) : webView }

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

    /// 上一处 / 下一处变更（IDEA 的 ⇧F7 / F7）。
    public typealias ChangeStep = DiffNavigationDirection
    public enum ChangeNavigationResult { case moved, boundary, unavailable }
    public var onDiffNavigate: ((ChangeStep, String) -> Void)?
    public var onDiffStatistics: ((String, DiffLineCounts) -> Void)?

    /// 页面报上来的：光标 / 视口前面、后面还有没有变更可跳。到头的那个方向的箭头灰掉。
    public struct ChangePosition: Equatable, Sendable {
        public var hasPrevious: Bool
        public var hasNext: Bool
        public var index: Int
        public var total: Int

        public init(hasPrevious: Bool = false, hasNext: Bool = false, index: Int = 0, total: Int = 0) {
            self.hasPrevious = hasPrevious
            self.hasNext = hasNext
            self.index = index
            self.total = total
        }
    }

    /// 页面里前面 / 后面还有没有变更可跳变了（渲染完、跳转后、光标移动、改动、滚动）。
    public var onChangePosition: ((ChangePosition) -> Void)?

    /// WebView 里当前的状态：滚到哪、编辑器里的文字（没有编辑器时为 nil）、光标。
    public struct ViewState: Equatable, Sendable {
        public var scrollTop: Double
        public var text: String?
        public var cursor: EditorCursor?
        /// 编辑器的撤销历史（JSON 文本），没有编辑器时为 nil。
        public var history: String?
        /// 实际显示的内容种类，未就绪时为 nil，避免把空页面当作已保存的 diff 位置。
        public var kind: String?
        public var diffViewState: String?

        public init(scrollTop: Double = 0, text: String? = nil, cursor: EditorCursor? = nil, history: String? = nil, kind: String? = nil, diffViewState: String? = nil) {
            self.scrollTop = scrollTop
            self.text = text
            self.cursor = cursor
            self.history = history
            self.kind = kind
            self.diffViewState = diffViewState
        }
    }

    private var isReady = false
    private var pendingPayload: RenderPayload?
    /// 最近一次渲染的内容。Web 内容进程被系统回收后用它恢复现场；测试也据此核对送出去的 payload。
    public private(set) var lastPayload: RenderPayload?
    private var renderRequest = UUID()
    private struct DiffReviewInput: Equatable {
        let path: String
        let oldText: String
        let newText: String
        let options: DiffReadingOptions
    }
    private struct DiffReviewResult: Sendable {
        let analysis: DiffReviewAnalysis
        let rawCounts: DiffLineCounts
    }
    private var completedDiffReview: DiffReviewInput?
    private var pendingDiffReview: (input: DiffReviewInput, task: Task<DiffReviewResult, Never>)?
    private var shellURL: URL?
    private var zoom: Double = 1
    /// 页面当前是浅色还是深色。页面重载（内容进程被回收）后要补发。
    private var isLightTheme = false
    private let messageProxy = ScriptMessageProxy()

    /// 编辑去抖后复用 Core 的比较模型。异步结果必须同时匹配请求、文件和页面原文。
    @discardableResult private func updateDiffReview(path: String, text: String, base: String? = nil) async -> Bool {
        guard var payload = lastPayload,
              case .diff(let displayPath, let language, let diff, let mode, let reason, var edit?) = payload.content,
              edit.filePath == path, !edit.readOnly else { return false }
        if let base { edit.oldText = base }
        edit.newText = text
        payload.content = .diff(path: displayPath, language: language, diff: diff, mode: mode, emptyReason: reason, edit: edit)
        lastPayload = payload
        let request = renderRequest
        let oldText = edit.oldText, options = payload.diffReading
        let input = DiffReviewInput(path: path, oldText: oldText, newText: text, options: options)
        if completedDiffReview == input { return true }
        let task: Task<DiffReviewResult, Never>
        if let pendingDiffReview, pendingDiffReview.input == input { task = pendingDiffReview.task }
        else {
            task = Task.detached(priority: .userInitiated) {
                let analysis = DiffReviewAnalysis(oldText: oldText, newText: text, options: options)
                let raw = options.whitespace == .none ? analysis : DiffReviewAnalysis(oldText: oldText, newText: text)
                return DiffReviewResult(analysis: analysis, rawCounts: DiffLineCounts(added: raw.added, removed: raw.removed))
            }
            pendingDiffReview = (input, task)
        }
        let result = await task.value
        guard renderRequest == request, lastPayload == payload else { return false }
        if completedDiffReview == input { return true }
        guard let data = try? JSONEncoder().encode(RenderPayload.DiffReviewUpdate(path: path, newText: text, analysis: result.analysis, baseIdentity: String(oldText.hashValue))),
              let json = String(data: data, encoding: .utf8),
              (try? await webView.evaluateJavaScript("window.ide.updateDiffReview(\(json))")) as? Bool == true else { return false }
        guard renderRequest == request else { return false }
        completedDiffReview = input
        if pendingDiffReview?.input == input { pendingDiffReview = nil }
        if options.whitespace != .none { onDiffStatistics?(path, result.rawCounts) }
        return true
    }

    override public init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let assets = WebAssetHandler(root: WebResources.shellURL?.deletingLastPathComponent())
        webAssetHandler = assets
        configuration.setURLSchemeHandler(assets, forURLScheme: WebAsset.scheme)
        webView = CursorRestoringWebView(frame: .zero, configuration: configuration)
        // 页面加载完成前 WKWebView 会先画自己的底色（白），深色下会闪一下；关掉它，
        // 透出宿主的 editorBackground（动态色，两个主题各自对得上）
        webView.setValue(false, forKey: "drawsBackground")
        super.init()

        messageProxy.target = self
        webView.configuration.userContentController.add(messageProxy, name: "ide")
        webView.navigationDelegate = self
        (webView as? CursorRestoringWebView)?.onFind = { [weak self] in self?.onFind?() }
        (webView as? CursorRestoringWebView)?.onFindInPath = { [weak self] in self?.onFindInPath?() }
        (webView as? CursorRestoringWebView)?.contextActions = { [weak self] in self?.contextActions?() ?? [] }
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
        renderRequest = UUID()
        pendingDiffReview = nil
        if case .diff(_, _, _, _, _, let edit?) = payload.content {
            completedDiffReview = DiffReviewInput(path: edit.filePath, oldText: edit.oldText, newText: edit.newText, options: payload.diffReading)
        } else { completedDiffReview = nil }
        showingHTML = payload.kindName == "html"
        webView.isHidden = showingHTML
        htmlWebView?.isHidden = !showingHTML
        lastPayload = payload
        if case .html(let path, let text, let directory) = payload.content {
            if htmlWebView == nil {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.setURLSchemeHandler(htmlPreviewHandler, forURLScheme: HTMLPreviewDocument.resourceScheme)
                let preview = CursorRestoringWebView(frame: webView.superview?.bounds ?? webView.frame, configuration: configuration)
                preview.navigationDelegate = self
                preview.onFind = { [weak self] in self?.onFind?() }
                preview.onFindInPath = { [weak self] in self?.onFindInPath?() }
                preview.autoresizingMask = [.width, .height]
                preview.pageZoom = zoom
                webView.superview?.addSubview(preview)
                htmlWebView = preview
            }
            htmlWebView?.isHidden = false
            let documentURL = HTMLPreviewDocument.resourceURL(for: URL(fileURLWithPath: path))
            htmlPreviewHandler.documentURL = documentURL
            htmlPreviewHandler.resourceDirectory = directory
            htmlPreviewHandler.document = Data(HTMLPreviewDocument.resolvingResources(in: text, relativeTo: documentURL).utf8)
            htmlWebView?.load(URLRequest(url: documentURL, cachePolicy: .reloadIgnoringLocalCacheData))
            return
        }
        htmlWebView?.stopLoading()
        guard isReady else {
            pendingPayload = payload
            return
        }
        send(payload)
    }

    /// 当前状态：滚动位置、编辑器里的文字与光标。切标签前问一次，切回来时带在 payload 里恢复；
    /// 文字直接拿走，不用等编辑器那边停手 300ms 才发过来的那份。页面没就绪时立刻回一份空状态。
    public func currentState(_ completion: @escaping (ViewState) -> Void) {
        if showingHTML {
            htmlWebView?.evaluateJavaScript("window.scrollY") { value, _ in
                completion(ViewState(scrollTop: (value as? NSNumber)?.doubleValue ?? 0))
            }
            return
        }
        guard isReady else {
            completion(ViewState())
            return
        }
        webView.evaluateJavaScript("window.ide.getState()") { value, _ in
            let dictionary = value as? [String: Any] ?? [:]
            completion(ViewState(
                scrollTop: (dictionary["scrollTop"] as? NSNumber)?.doubleValue ?? 0,
                text: dictionary["text"] as? String,
                cursor: Self.cursor(from: dictionary["cursor"]),
                history: dictionary["history"] as? String,
                kind: dictionary["kind"] as? String,
                diffViewState: dictionary["diffViewState"] as? String
            ))
        }
    }

    private static func cursor(from value: Any?) -> EditorCursor? {
        guard let dictionary = value as? [String: Any],
              let line = (dictionary["line"] as? NSNumber)?.intValue, let ch = (dictionary["ch"] as? NSNumber)?.intValue else { return nil }
        return EditorCursor(line: line, ch: ch)
    }

    /// 切页面的浅色 / 深色。外壳那半边由 `NSApp.appearance` 管，这里管 WebView 里的正文。
    public func setTheme(light: Bool) {
        guard isLightTheme != light else { return }
        isLightTheme = light
        // 页面还没就绪：记下来，markReadyAndFlush 会补发
        guard isReady else { return }
        webView.evaluateJavaScript("window.ide.setTheme('\(light ? "light" : "dark")')")
    }

    public func setZoom(_ zoom: Double) {
        self.zoom = zoom
        htmlWebView?.pageZoom = zoom
        guard isReady else { return }
        webView.evaluateJavaScript("window.ide.setZoom(\(zoom))")
    }

    /// 基线到了（异步取的 HEAD 内容）：正在编辑这个文件的话立刻画标记，不用重画整个编辑器。
    public func setBase(path: String, text: String?) {
        guard isReady, let data = try? JSONEncoder().encode(["path": path, "base": text]), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.ide.setBase(\(json))")
    }

    /// 跳到当前内容里的下一处 / 上一处变更：编辑器按光标找，只读 diff 按变更段落找（都在 render.js 里）。
    public func navigateChange(_ step: ChangeStep, completion: @escaping (ChangeNavigationResult) -> Void = { _ in }) {
        guard isReady else { completion(.unavailable); return }
        let request = renderRequest
        Task { [weak self] in
            guard let self else { completion(.unavailable); return }
            do {
                // 键盘导航可以早于 300ms 编辑去抖；先比较眼前的原文，不能按旧分组跨文件。
                if case .diff(_, _, _, _, _, let edit?) = self.lastPayload?.content, !edit.readOnly,
                   let text = try await self.webView.evaluateJavaScript("window.ide.getState().text") as? String {
                    guard self.renderRequest == request else { completion(.unavailable); return }
                    self.onEdited?(edit.filePath, text)
                    guard await self.updateDiffReview(path: edit.filePath, text: text) else { completion(.unavailable); return }
                }
                guard self.renderRequest == request else { completion(.unavailable); return }
                let value = try await self.webView.evaluateJavaScript("window.ide.navigateChange(\"\(step.rawValue)\")")
                completion((value as? [String: Any])?["moved"] as? Bool == true ? .moved : .boundary)
            } catch {
                Log.warn("web", "navigateChange 失败：\(error)")
                completion(.unavailable)
            }
        }
    }

    /// 跳到当前内容的某一行（行列从 0 数，render.js 夹到首尾）：不重画，编辑器里的草稿、撤销历史都不动。
    /// 页面还没就绪、正等着画一份内容时，挂到那份 payload 上，画完再跳。回调告诉调用方这种视图有没有行（HTML 预览没有）。
    /// `length` > 0 时从那一列起选中这么多（UTF-16 单元）：全项目搜索打开结果后把命中的文字选上。
    public func revealLine(_ position: EditorCursor, length: Int = 0, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !showingHTML else { completion(false); return }
        guard isReady else {
            guard pendingPayload != nil else { completion(false); return }
            pendingPayload?.revealLine = position
            pendingPayload?.revealLength = max(0, length)
            completion(true)
            return
        }
        webView.evaluateJavaScript("window.ide.revealLine({line: \(position.line), ch: \(position.ch), length: \(max(0, length))})") { value, error in
            if let error { Log.warn("web", "revealLine 失败：\(error)") }
            completion((value as? Bool) ?? false)
        }
    }

    /// 选区（没有选区就是光标）在新版本里占哪几行，从 1 数（复制引用用）。
    /// 编辑器、只读代码视图、diff 都有；Markdown 预览、HTML 预览、图片、页面没就绪时为 nil。
    public func referenceLines(_ completion: @escaping (ClosedRange<Int>?) -> Void) {
        guard !showingHTML, isReady else { completion(nil); return }
        webView.evaluateJavaScript("window.ide.reference()") { value, error in
            if let error { Log.warn("web", "reference 失败：\(error)") }
            guard let dictionary = value as? [String: Any], let from = Self.cursor(from: dictionary["from"]), let to = Self.cursor(from: dictionary["to"]) else {
                completion(nil)
                return
            }
            completion(FileReference.lineRange(fromLine: from.line, fromColumn: from.ch, toLine: to.line, toColumn: to.ch))
        }
    }

    /// 正文里选中的文字（编辑器的选区，只读视图的 DOM 选区）：在项目中查找拿它预填。没有选区、页面没就绪、HTML 预览时为 nil。
    public func selectedText(_ completion: @escaping (String?) -> Void) {
        guard !showingHTML, isReady else { completion(nil); return }
        webView.evaluateJavaScript("window.ide.selectedText()") { value, error in
            if let error { Log.warn("web", "selectedText 失败：\(error)") }
            let text = value as? String
            completion(text?.isEmpty == false ? text : nil)
        }
    }

    /// 编辑器里的撤销 / 重做（CodeMirror 自己的历史）。回调告诉调用方页面里有没有编辑器接下这一步：
    /// 没有（只读视图）的话调用方去撤文件操作。
    public func undo(_ completion: @escaping (Bool) -> Void) { performEditorCommand("undo", completion) }
    public func redo(_ completion: @escaping (Bool) -> Void) { performEditorCommand("redo", completion) }

    private func performEditorCommand(_ command: String, _ completion: @escaping (Bool) -> Void) {
        guard isReady, !showingHTML else {
            completion(false)
            return
        }
        webView.evaluateJavaScript("window.ide.\(command)()") { value, error in
            if let error { Log.warn("web", "\(command) 失败：\(error)") }
            completion((value as? Bool) ?? false)
        }
    }

    public func setWrap(_ wrap: Bool) {
        lastPayload?.wrap = wrap
        pendingPayload?.wrap = wrap
        guard isReady else { return }
        webView.evaluateJavaScript("window.ide.setWrap(\(wrap))")
    }

    /// 编辑器查全文（包括视口外的行），其它视图用 WebKit 的原生查找。
    public func find(_ query: String, backwards: Bool = false, caseSensitive: Bool = false, completion: @escaping (Bool) -> Void) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = caseSensitive
        configuration.wraps = true
        let target = displayedWebView
        let nativeFind = { target.find(query, configuration: configuration) { completion($0.matchFound) } }
        guard !showingHTML, isReady,
              let data = try? JSONSerialization.data(withJSONObject: ["query": query, "backwards": backwards, "caseSensitive": caseSensitive]),
              let json = String(data: data, encoding: .utf8) else { nativeFind(); return }
        webView.evaluateJavaScript("window.ide.find(\(json))") { result, _ in
            if let found = result as? Bool { completion(found) } else { nativeFind() }
        }
    }

    public func focusContent() {
        displayedWebView.window?.makeFirstResponder(displayedWebView)
        if !showingHTML, isReady { webView.evaluateJavaScript("window.ide.focusEditor()") }
    }

    public func clearFind() {
        if !showingHTML, isReady { webView.evaluateJavaScript("window.ide.clearFind()") }
        // WebKit 原生查找用空查询移除 HTML / Markdown / 只读视图里的搜索标记。
        displayedWebView.find("", configuration: WKFindConfiguration()) { _ in }
    }

    private func send(_ payload: RenderPayload) {
        guard payload.kindName != "html" else { return }
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
        // 页面每次都是从深色起步（style.css 的默认），浅色要在画正文之前补上，否则会闪一下深色
        if isFirstSignal, isLightTheme {
            webView.evaluateJavaScript("window.ide.setTheme('light')")
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
        if webView === htmlWebView {
            if showingHTML, let payload = lastPayload {
                htmlWebView?.evaluateJavaScript("window.scrollTo(0, \(payload.scrollTop))")
                onRendered?("html", 0)
            }
            return
        }
        markReadyAndFlush()
    }

    /// 只允许加载我们自己的 shell 页面。正文里的链接一旦真的导航出去，`window.ide` 就没了。
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if webView === htmlWebView {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                decisionHandler(.cancel)
                if let fragment = url.fragment, case .html(let path, _, _)? = lastPayload?.content,
                   url.scheme == HTMLPreviewDocument.resourceScheme, url.path == path {
                    webView.callAsyncJavaScript("document.getElementById(fragment)?.scrollIntoView()", arguments: ["fragment": fragment], in: nil, in: .page) { _ in }
                } else if url.isFileURL || url.scheme == HTMLPreviewDocument.resourceScheme { onOpenPath?(url.path) }
                else if ["https", "http"].contains(url.scheme ?? "") { onOpenExternal?(url) }
            } else {
                // 正文里的脚本可以运行，但不能把预览悄悄导航到别的主页面。
                let url = navigationAction.request.url
                let isPreview = url?.scheme == HTMLPreviewDocument.resourceScheme && url?.path == htmlPreviewHandler.documentURL?.path
                // 不允许子框架绕过资源协议加载任意 file:// 文档。
                let isLocalFile = url?.isFileURL == true
                decisionHandler(!isLocalFile && (navigationAction.targetFrame?.isMainFrame == false || isPreview) ? .allow : .cancel)
            }
            return
        }
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
        if webView === htmlWebView {
            if showingHTML, let lastPayload { render(lastPayload) }
            return
        }
        Log.warn("web", "内容进程被回收，重新加载渲染页")
        isRecoveringFromCrash = onShellReloaded != nil
        loadShell()
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // 只接受来自 shell 页面的消息：Markdown 允许内嵌 HTML，文档里的脚本同样能 postMessage。
        guard message.frameInfo.isMainFrame, message.webView?.url?.standardizedFileURL.path == shellURL?.path else { return }
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
            if let path = body["path"] as? String, let text = body["text"] as? String {
                onEdited?(path, text)
                Task { [weak self] in await self?.updateDiffReview(path: path, text: text) }
            }
        case "diffReview":
            if let path = body["path"] as? String, let text = body["text"] as? String {
                let base = body["base"] as? String
                Task { [weak self] in await self?.updateDiffReview(path: path, text: text, base: base) }
            }
        case "navigate":
            if let direction = (body["direction"] as? String).flatMap(NavigationDirection.init) { onNavigate?(direction) }
        case "changes":
            onChangePosition?(ChangePosition(hasPrevious: body["hasPrevious"] as? Bool ?? false, hasNext: body["hasNext"] as? Bool ?? false,
                                            index: body["index"] as? Int ?? 0, total: body["total"] as? Int ?? 0))
        case "diffNavigate":
            if let step = (body["direction"] as? String).flatMap(ChangeStep.init), let path = body["path"] as? String { onDiffNavigate?(step, path) }
        case "diffStatistics":
            // 正文显示过滤后的统计，文件列表始终保留原始增删数；过滤模式下由后台分析回传原始数。
            guard lastPayload?.diffReading.whitespace == DiffWhitespaceMode.none else { break }
            if let path = body["path"] as? String, let added = body["added"] as? Int, let removed = body["removed"] as? Int, added >= 0, removed >= 0 {
                onDiffStatistics?(path, DiffLineCounts(added: added, removed: removed))
            }
        case "find":
            onFind?()
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
        for webView in [renderer.webView, renderer.htmlWebView].compactMap({ $0 }) {
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
    }
}
