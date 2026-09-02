import AppKit
import Core
import DesignSystem
import Foundation
import Testing
@preconcurrency import WebKit

/// 真起一个 WKWebView 验 render.js：这是「验 WebKit 自己那一层」的用例，模型层的用例一律用替身。
/// 每条约几百毫秒。顺手把渲染结果截成图放到 AGENTIDEA_SNAPSHOT_DIR（若设了），给人眼看。
@MainActor
private func renderAndInspect(_ payload: [String: Any], size: CGSize = CGSize(width: 900, height: 600), snapshotName: String? = nil, inspect: String) async throws -> Any? {
    let renderer = ContentRenderer()
    let webView = renderer.webView
    webView.frame = CGRect(origin: .zero, size: size)
    // 离屏视图要挂到窗口上才会真正排版
    let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = webView
    renderer.render(payload)

    // 等 window.ide 就绪并渲染出内容（#root 下有东西），再问要看的值
    let deadline = Date().addingTimeInterval(8)
    var rendered = false
    while Date() < deadline, !rendered {
        try? await Task.sleep(nanoseconds: 100_000_000)
        let value = try? await webView.evaluateJavaScript("(function(){ try { return document.getElementById('root').children.length > 0 } catch (e) { return false } })()")
        rendered = (value as? Bool) ?? false
    }
    #expect(rendered, "页面在 8 秒内没渲染出内容")
    let result = try? await webView.evaluateJavaScript("(function(){ try { return \(inspect) } catch (e) { return String(e) } })()")
    if let directory = ProcessInfo.processInfo.environment["AGENTIDEA_SNAPSHOT_DIR"], let snapshotName {
        let image = try await webView.takeSnapshot(configuration: nil)
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(snapshotName).png"))
        }
    }
    return result
}

@Test @MainActor func codeRendersWithLineNumbersAndHighlight() async throws {
    let source = """
    import Foundation

    /// 多行
    /// 注释
    struct Greeter {
        let name = "world"
        func hello() -> String { "hello \\(name) \\(42)" }
    }
    """
    let count = try await renderAndInspect(
        ["kind": "code", "path": "/x/Greeter.swift", "text": source, "language": "swift"],
        snapshotName: "code",
        inspect: "document.querySelectorAll('table.code tr').length"
    )
    #expect((count as? NSNumber)?.intValue == 8)
    let keywords = try await renderAndInspect(
        ["kind": "code", "path": "/x/Greeter.swift", "text": source, "language": "swift"],
        inspect: "document.querySelectorAll('table.code .hljs-keyword').length"
    )
    #expect(((keywords as? NSNumber)?.intValue ?? 0) >= 3)
}

@Test @MainActor func singleLineJSONIsPrettyPrinted() async throws {
    let json = "{\"a\":1,\"b\":[1,2,3],\"c\":{\"d\":\"e\"},\"long\":\"" + String(repeating: "x", count: 150) + "\"}"
    let rows = try await renderAndInspect(
        ["kind": "code", "path": "/x/a.json", "text": json, "language": "json"],
        inspect: "document.querySelectorAll('table.code tr').length"
    )
    #expect(((rows as? NSNumber)?.intValue ?? 0) > 5)
}

@Test @MainActor func markdownRendersHeadingsCodeAndTaskList() async throws {
    let markdown = """
    # 标题

    - [x] 完成
    - [ ] 未完成

    ```swift
    let a = 1
    ```

    ```mermaid
    graph TD; A-->B;
    ```
    """
    let summary = try await renderAndInspect(
        ["kind": "markdown", "path": "/x/a.md", "markdown": markdown, "docDir": "file:///x/", "view": "preview"],
        snapshotName: "markdown",
        inspect: "[document.querySelectorAll('article.md h1').length, document.querySelectorAll('input[type=checkbox]').length, document.querySelectorAll('pre.hljs .hljs-keyword').length, document.querySelectorAll('.mermaid').length].join(',')"
    )
    #expect(summary as? String == "1,2,1,1")
}

@Test @MainActor func diffSideBySideShowsPairsAndWordHighlights() async throws {
    let diff = UnifiedDiffParser.parse("""
    --- a/App.swift
    +++ b/App.swift
    @@ -1,4 +1,5 @@ struct App
     import Foundation
    -let greeting = "hello world"
    -let count = 1
    +let greeting = "hello there world"
    +let count = 2
    +let extra = true
     func main() {}
    """)
    let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DiffLayout.sideBySide(diff))) as! [Any]
    let payload: [String: Any] = [
        "kind": "diff", "path": "App.swift", "language": "swift", "mode": "side",
        "rows": rows, "binary": false, "empty": false, "added": diff.addedCount, "removed": diff.removedCount,
    ]
    let summary = try await renderAndInspect(
        payload, snapshotName: "diff-side",
        inspect: "[document.querySelectorAll('table.diff.side tr').length, document.querySelectorAll('td.src.del').length, document.querySelectorAll('td.src.add').length, document.querySelectorAll('td.src.empty').length, document.querySelectorAll('.wd').length > 0 ? 1 : 0].join(',')"
    )
    // 1 hunk + 1 ctx + 3 配对 + 1 ctx = 6 行；2 删 3 增 1 空；有词级高亮
    #expect(summary as? String == "6,2,3,1,1")
}

@Test @MainActor func diffUnifiedShowsMarkers() async throws {
    let diff = UnifiedDiffParser.parse("""
    --- a/a.txt
    +++ b/a.txt
    @@ -1,2 +1,2 @@
    -old
    +new
     same
    """)
    let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DiffLayout.unified(diff))) as! [Any]
    let payload: [String: Any] = ["kind": "diff", "path": "a.txt", "mode": "unified", "rows": rows, "binary": false, "empty": false, "added": 1, "removed": 1]
    let summary = try await renderAndInspect(
        payload, snapshotName: "diff-unified",
        inspect: "document.querySelector('.message') ? document.querySelector('.message').innerText : [document.querySelectorAll('table.diff.unified tr').length, document.querySelectorAll('td.src.del .marker').length, document.querySelectorAll('td.src.add .marker').length].join(',')"
    )
    #expect(summary as? String == "4,1,1")
}
