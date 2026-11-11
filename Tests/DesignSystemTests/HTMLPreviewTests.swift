import AppKit
import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@preconcurrency import WebKit

@MainActor
private func waitForHTML(_ webView: WKWebView, _ expression: String) async -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if (try? await webView.evaluateJavaScript("(() => { try { return !!(\(expression)); } catch (_) { return false; } })()")) as? Bool == true { return true }
        await Task.yield()
    }
    return false
}

@Test @MainActor func localHTMLSupportsWebsitePathsModulesFetchImagesAndNavigation() async throws {
    try await withTemporaryDirectory { project in
        let pages = project.appendingPathComponent("pages", isDirectory: true)
        let assets = project.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "h1 { color: rgb(12, 34, 56); }".write(to: assets.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try "export const label = '模块加载成功';".write(to: assets.appendingPathComponent("module.js"), atomically: true, encoding: .utf8)
        try #"{"label":"本地 JSON"}"#.write(to: project.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><rect width="24" height="24" fill="green"/></svg>"#.write(to: assets.appendingPathComponent("中文 image.svg"), atomically: true, encoding: .utf8)
        try "<p>目录首页</p>".write(to: pages.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let html = """
        <!doctype html><html><head><link rel="stylesheet" href="/assets/style.css?v=1"></head><body>
        <h1>初始文本</h1><img src="../assets/中文 image.svg"><iframe src="/pages/"></iframe>
        <a id="local" href="/pages/index.html">本地页面</a><a id="external" href="https://example.com/">外部页面</a>
        <script type="module">
        import { label } from '/assets/module.js';
        document.querySelector('h1').textContent = label;
        fetch('../data.json?v=1').then(r => r.json()).then(data => { window.dataLabel = data.label; }).catch(e => { window.fetchError = String(e); });
        </script></body></html>
        """
        let file = pages.appendingPathComponent("中文 page.html")
        let renderer = ContentRenderer()
        let payload = RenderPayload(.html(path: file.path, text: html, documentDirectory: project))
        renderer.render(payload)
        let preview = renderer.displayedWebView
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = preview
        defer { preview.stopLoading(); window.contentView = nil }
        #expect(await waitForHTML(preview, "document.querySelector('h1')?.textContent === '模块加载成功' && window.dataLabel === '本地 JSON' && document.images[0]?.naturalWidth === 24 && document.querySelector('iframe')?.contentDocument?.body?.textContent.includes('目录首页')"))
        let color = try await preview.evaluateJavaScript("getComputedStyle(document.querySelector('h1')).color") as? String
        #expect(color == "rgb(12, 34, 56)")
        #expect(try await preview.evaluateJavaScript("typeof window.webkit?.messageHandlers?.ide") as? String == "undefined")

        // 刷新取到最新资源，并继续使用未落盘的 HTML。
        try "h1 { color: rgb(65, 43, 21); }".write(to: assets.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        renderer.render(payload)
        #expect(await waitForHTML(preview, "document.querySelector('h1')?.textContent === '模块加载成功' && getComputedStyle(document.querySelector('h1')).color === 'rgb(65, 43, 21)'"))
        #expect(renderer.displayedWebView === preview)

        var openedPath: String?
        renderer.onOpenPath = { openedPath = $0 }
        _ = try await preview.evaluateJavaScript("document.getElementById('local').click()")
        let localDeadline = Date().addingTimeInterval(10)
        while openedPath == nil, Date() < localDeadline { await Task.yield() }
        #expect(openedPath == pages.appendingPathComponent("index.html").resolvingSymlinksInPath().path)
        var openedExternal: URL?
        renderer.onOpenExternal = { openedExternal = $0 }
        _ = try await preview.evaluateJavaScript("document.getElementById('external').click()")
        let externalDeadline = Date().addingTimeInterval(10)
        while openedExternal == nil, Date() < externalDeadline { await Task.yield() }
        #expect(openedExternal?.absoluteString == "https://example.com/")
    }
}

@Test @MainActor func htmlPreviewExplainsInvalidResourceScopeInsteadOfShowingABlankPage() async throws {
    try await withTemporaryDirectory { project in
        let renderer = ContentRenderer()
        renderer.render(RenderPayload(.html(path: project.deletingLastPathComponent().appendingPathComponent("outside.html").path,
                                           text: "<h1>outside</h1>", documentDirectory: project)))
        #expect(renderer.displayedWebView === renderer.webView)
        #expect(await waitForHTML(renderer.webView, "document.body.textContent.includes('HTML 预览失败') && document.body.textContent.includes('源码')"))
    }
}

@Test @MainActor func leavingHTMLPreviewUnloadsScriptsAndResources() async throws {
    let renderer = ContentRenderer()
    let root = URL(fileURLWithPath: "/project", isDirectory: true)
    let payload = RenderPayload(.html(path: root.appendingPathComponent("game.html").path,
                                     text: "<canvas></canvas><script>window.ticks=0;setInterval(()=>window.ticks++,16)</script>", documentDirectory: root))
    renderer.render(payload)
    let preview = renderer.displayedWebView
    #expect(await waitForHTML(preview, "window.ticks >= 2"))
    renderer.render(RenderPayload(.code(path: "/project/a.txt", text: "source", language: nil)))
    renderer.render(RenderPayload(.code(path: "/project/b.txt", text: "next file", language: nil)))
    #expect(renderer.displayedWebView === renderer.webView)
    // 隐藏视图或 stopLoading 并不会销毁已运行的脚本、canvas 和 GPU 资源。
    #expect(await waitForHTML(preview, "document.URL === 'about:blank' && document.body.childElementCount === 0 && typeof window.ticks === 'undefined'"))
    renderer.render(payload)
    #expect(renderer.displayedWebView === preview)
    #expect(await waitForHTML(preview, "window.ticks >= 2 && !!document.querySelector('canvas')"))
}
