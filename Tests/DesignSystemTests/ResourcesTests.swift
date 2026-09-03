import Core
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
    for entry in ["render(payload)", "getScrollTop()", "setZoom(zoom)", "setWrap(wrap)", "type: \"ready\"", "type: \"openExternal\"", "type: \"openPath\"", "type: \"rendered\""] {
        #expect(script.contains(entry), "render.js 缺少 \(entry)")
    }
}

@Test func fileIconsCoverCommonTypes() {
    #expect(FileIcon.file(named: "a.swift").systemName == "swift")
    #expect(FileIcon.file(named: "README.md").systemName == "doc.richtext")
    #expect(FileIcon.file(named: ".gitignore").systemName == "arrow.triangle.branch")
    #expect(FileIcon.file(named: "unknown.zzz").systemName == "doc")
    #expect(FileIcon.folder.systemName == "folder.fill")
}

@Test func renderPayloadEncodesTheContractKeys() throws {
    let diff = UnifiedDiffParser.parse("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
    let payload = RenderPayload(.diff(path: "x", language: "swift", diff: diff, mode: .sideBySide, emptyReason: nil), scrollTop: 12, wrap: true)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
    #expect(json?["kind"] as? String == "diff")
    #expect(json?["mode"] as? String == "side")
    #expect(json?["scrollTop"] as? Double == 12)
    #expect(json?["wrap"] as? Bool == true)
    #expect(json?["added"] as? Int == 1 && json?["removed"] as? Int == 1)
    #expect((json?["rows"] as? [Any])?.count == 2)
    #expect(json?["emptyReason"] == nil)

    let markdown = RenderPayload(.markdown(path: "/p/a.md", markdown: "# x", documentDirectory: URL(fileURLWithPath: "/p/"), view: .preview))
    let markdownJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(markdown)) as? [String: Any]
    #expect(markdownJSON?["view"] as? String == "preview")
    #expect(markdownJSON?["editable"] as? Bool == false)
    let editable = RenderPayload(.code(path: "/p/a.py", text: "x", language: "python", editable: true, cursor: EditorCursor(line: 2, ch: 3)))
    let editableJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(editable)) as? [String: Any]
    #expect(editableJSON?["editable"] as? Bool == true)
    #expect((editableJSON?["cursor"] as? [String: Any])?["line"] as? Int == 2)
    #expect(markdownJSON?["docDir"] as? String == "file:///p/")
}
