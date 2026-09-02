import DesignSystem
import Foundation
import Testing

@Test func webShellAndAssetsShip() throws {
    let shell = try #require(WebResources.shellURL)
    let web = shell.deletingLastPathComponent()
    for name in ["render.js", "style.css", "hljs-idea-dark.css", "vendor/markdown-it.min.js", "vendor/highlight.min.js", "vendor/mermaid.min.js"] {
        #expect(FileManager.default.fileExists(atPath: web.appendingPathComponent(name).path), "缺 \(name)")
    }
    let html = try String(contentsOf: shell, encoding: .utf8)
    // CSP 必须在，且不能给脚本 unsafe-inline：Markdown 允许内嵌 HTML
    #expect(html.contains("Content-Security-Policy"))
    #expect(!html.contains("script-src 'self' 'unsafe-inline'"))
}

@Test func renderScriptExposesTheContract() throws {
    let shell = try #require(WebResources.shellURL)
    let script = try String(contentsOf: shell.deletingLastPathComponent().appendingPathComponent("render.js"), encoding: .utf8)
    for entry in ["render(payload)", "getScrollTop()", "setZoom(zoom)", "setWrap(wrap)", "type: \"ready\"", "type: \"openExternal\"", "type: \"openPath\""] {
        #expect(script.contains(entry), "render.js 缺少 \(entry)")
    }
}

@Test func fileIconsCoverCommonTypes() {
    #expect(FileIcon.file(named: "a.swift").systemName == "swift")
    #expect(FileIcon.file(named: "README.md").systemName == "doc.richtext")
    #expect(FileIcon.file(named: ".gitignore").systemName == "arrow.triangle.branch")
    #expect(FileIcon.file(named: "unknown.zzz").systemName == "doc")
    #expect(FileIcon.folder(isExpanded: true).systemName == "folder.fill")
}
