import AppKit
import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@preconcurrency import WebKit

/// 真起一个 WKWebView 验 render.js：这是「验 WebKit 自己那一层」的用例，模型层的用例一律用替身。
/// 每条约几百毫秒。顺手把渲染结果截成图放到 AGENTIDEA_SNAPSHOT_DIR（若设了），给人眼看。
@MainActor
/// `prepare` 先跑（比如往编辑器里敲字），等 `settle` 秒让去抖的东西落地，再跑 `inspect` 取值。
private func renderAndInspect(_ payload: RenderPayload, size: CGSize = CGSize(width: 900, height: 600), snapshotName: String? = nil, prepare: String? = nil, settle: TimeInterval = 0, configure: (ContentRenderer) -> Void = { _ in }, inspect: String) async throws -> Any? {
    let renderer = ContentRenderer()
    configure(renderer)
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
    if let prepare {
        _ = try? await webView.evaluateJavaScript("(function(){ try { \(prepare); return true } catch (e) { return String(e) } })()")
        if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
    }
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
        RenderPayload(.code(path: "/x/Greeter.swift", text: source, language: "swift")),
        snapshotName: "code",
        inspect: "document.querySelectorAll('.code-view .line').length"
    )
    #expect((count as? NSNumber)?.intValue == 8)
    let keywords = try await renderAndInspect(
        RenderPayload(.code(path: "/x/Greeter.swift", text: source, language: "swift")),
        inspect: "document.querySelectorAll('.code-view .hljs-keyword').length"
    )
    #expect(((keywords as? NSNumber)?.intValue ?? 0) >= 3)
}

@Test @MainActor func wrappedCodeUsesPerLineNumbers() async throws {
    // 不换行：一个整块行号栏 + N 行；换行：每行自带行号、没有整块行号栏
    let source = (1...5).map { "line \($0) " + String(repeating: "x", count: 300) }.joined(separator: "\n")
    let plain = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: source, language: nil), wrap: false),
        inspect: "[document.querySelectorAll('.code-view .gutter').length, document.querySelectorAll('.code-view .line').length, document.querySelectorAll('.code-view .ln').length].join(',')"
    )
    #expect(plain as? String == "1,5,0")
    let wrapped = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: source, language: nil), wrap: true),
        snapshotName: "code-wrap",
        inspect: "[document.querySelectorAll('.code-view.wrap .gutter').length, document.querySelectorAll('.code-view.wrap .line').length, document.querySelectorAll('.code-view.wrap .ln').length].join(',')"
    )
    #expect(wrapped as? String == "0,5,5")
    // 运行时切换换行：代码要重画成另一种结构，并保持滚动位置
    let toggled = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: (1...400).map { "line \($0)" }.joined(separator: "\n"), language: nil), scrollTop: 600, wrap: false),
        inspect: "(function(){ const before = window.ide.getScrollTop(); window.ide.setWrap(true); return [before >= 500, document.querySelectorAll('.code-view.wrap .ln').length, Math.abs(window.ide.getScrollTop() - before) < 2].join(','); })()"
    )
    #expect(toggled as? String == "true,400,true")
}

/// 可编辑的代码用 CodeMirror 画：能拿到全文与光标，改了会发 edited 消息。
@Test @MainActor func editableCodeMountsEditorAndReportsEdits() async throws {
    let source = "let a = 1\nlet b = 2\n"
    let state = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.swift", text: source, language: "swift", editable: true, cursor: EditorCursor(line: 1, ch: 4)), scrollTop: 0),
        snapshotName: "editor",
        inspect: "(function(){ const s = window.ide.getState(); const cm = document.querySelector('.CodeMirror').CodeMirror; cm.setValue('changed'); return [document.querySelectorAll('.CodeMirror').length, JSON.stringify(s.text), s.cursor.line + ':' + s.cursor.ch, cm.getMode().name, window.ide.getState().text].join('|'); })()"
    )
    #expect(state as? String == "1|\"let a = 1\\nlet b = 2\\n\"|1:4|swift|changed")
    // 只读时没有编辑器
    let readOnly = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.swift", text: source, language: "swift", editable: false)),
        inspect: "[document.querySelectorAll('.CodeMirror').length, window.ide.getState().text === null].join(',')"
    )
    #expect(readOnly as? String == "0,true")
}

/// 编辑器里的 ⌥← / ⌥→ 是应用的后退 / 前进，不是按词移动：要发 navigate 消息给宿主。
@Test @MainActor func editorForwardsOptionArrowsAsNavigation() async throws {
    let received = Locked<[String]>([])
    _ = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: "hello world", language: nil, editable: true)),
        prepare: "const cm = document.querySelector('.CodeMirror').CodeMirror; cm.setCursor({line: 0, ch: 11}); for (const code of [37, 39]) { const e = new KeyboardEvent('keydown', {keyCode: code, altKey: true, bubbles: true}); Object.defineProperty(e, 'keyCode', {value: code}); cm.triggerOnKeyDown(e); }",
        settle: 0.3,
        configure: { renderer in renderer.onNavigate = { direction in received.value.append(direction.rawValue) } },
        inspect: "document.querySelector('.CodeMirror').CodeMirror.getCursor().ch"
    )
    #expect(received.value == ["back", "forward"])
}

/// 行号旁的变更标记：与 HEAD 基线比，改过的行蓝、新增的行绿，删除不画；基线可以晚一步再送来。
@Test @MainActor func editorMarksChangedAndAddedLinesAgainstBase() async throws {
    let base = "a\nb\nc\nd\ne\n"
    // 改了 b（→B）、删了 c、在 d 后加了两行：b 是改过，x/y 是新增
    let text = "a\nB\nd\nx\ny\ne\n"
    let marks = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: text, language: nil, editable: true, base: base)),
        snapshotName: "editor-marks",
        inspect: "Array.from(document.querySelectorAll('.cm-change-mark')).map(m => m.className.replace('cm-change-mark ', '')).join(',')"
    )
    #expect(marks as? String == "modified,added,added")
    // 基线后到（setBase）；换成一样的内容标记就没了；编辑之后重新算
    let late = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: text, language: nil, editable: true)),
        prepare: "window.ide.setBase({path: '/x/a.txt', base: \(String(reflecting: base))}); const before = document.querySelectorAll('.cm-change-mark').length; window.ide.setBase({path: '/x/a.txt', base: \(String(reflecting: text))}); const same = document.querySelectorAll('.cm-change-mark').length; document.querySelector('.CodeMirror').CodeMirror.replaceRange('z\\n', {line: 0, ch: 0}); window.__marks = [before, same]",
        settle: 0.5,
        inspect: "window.__marks.concat([Array.from(document.querySelectorAll('.cm-change-mark')).map(m => m.className.replace('cm-change-mark ', '')).join('+')]).join(',')"
    )
    #expect(late as? String == "3,0,added")
    // 只读视图、没有基线：都没有标记
    let none = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: text, language: nil, editable: true)),
        inspect: "document.querySelectorAll('.cm-change-mark').length"
    )
    #expect((none as? NSNumber)?.intValue == 0)
}

/// Markdown 分栏：左边编辑器、右边预览；预览随编辑更新。
@Test @MainActor func markdownSplitViewEditsAndPreviews() async throws {
    let result = try await renderAndInspect(
        RenderPayload(.markdown(path: "/x/a.md", markdown: "# 一", documentDirectory: URL(fileURLWithPath: "/x/"), view: .split, editable: true)),
        snapshotName: "markdown-split",
        prepare: "document.querySelector('.md-split .CodeMirror').CodeMirror.setValue('# 一\\n\\n## 二')",
        settle: 0.6,
        inspect: "[document.querySelectorAll('.md-pane article.md h1').length, document.querySelectorAll('.md-pane article.md h2').length, window.ide.getState().text].join('|')"
    )
    #expect(result as? String == "1|1|# 一\n\n## 二")
}

@Test @MainActor func singleLineJSONIsPrettyPrinted() async throws {
    let json = "{\"a\":1,\"b\":[1,2,3],\"c\":{\"d\":\"e\"},\"long\":\"" + String(repeating: "x", count: 150) + "\"}"
    let rows = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.json", text: json, language: "json")),
        inspect: "document.querySelectorAll('.code-view .line').length"
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
        RenderPayload(.markdown(path: "/x/a.md", markdown: markdown, documentDirectory: URL(fileURLWithPath: "/x/"), view: .preview)),
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
    let payload = RenderPayload(.diff(path: "App.swift", language: "swift", diff: diff, mode: .sideBySide, emptyReason: nil))
    let summary = try await renderAndInspect(
        payload, snapshotName: "diff-side",
        inspect: "[document.querySelectorAll('table.diff.side tr').length, document.querySelectorAll('td.src.del').length, document.querySelectorAll('td.src.add').length, document.querySelectorAll('td.src.empty').length, document.querySelectorAll('.wd').length > 0 ? 1 : 0].join(',')"
    )
    // 1 hunk + 1 ctx + 3 配对 + 1 ctx = 6 行；2 删 3 增 1 空；有词级高亮
    #expect(summary as? String == "6,2,3,1,1")
}

/// 可编辑的工作区 diff：并排是 MergeView（左基线只读、右可改），单列是编辑器 + 新增行底色 + 被删行小块；改了会报 edited。
@Test @MainActor func editableDiffMountsEditorOnTheWorkingCopy() async throws {
    let edit = DiffEdit(oldText: "a\nb\nc\n", newText: "a\nB\nc\nd\n", filePath: "/x/a.txt", cursor: EditorCursor(line: 1, ch: 0))
    let side = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: "a.txt", isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil, edit: edit)),
        snapshotName: "diff-editable-side",
        inspect: "[document.querySelectorAll('.CodeMirror-merge').length, document.querySelectorAll('.CodeMirror-merge-pane .CodeMirror').length, JSON.stringify(window.ide.getState().text), document.querySelector('.CodeMirror-merge-pane:not(.CodeMirror-merge-left) .CodeMirror').CodeMirror.getOption('readOnly'), document.querySelector('.diff-summary .add').textContent, document.querySelector('.diff-summary .del').textContent].join('|')"
    )
    #expect(side as? String == "1|2|\"a\\nB\\nc\\nd\\n\"|false|+2|−1")

    let unified = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: "a.txt", isBinary: false, hunks: []), mode: .unified, emptyReason: nil, edit: edit)),
        snapshotName: "diff-editable-unified",
        prepare: "document.querySelector('.CodeMirror').CodeMirror.replaceRange('e\\n', {line: 4, ch: 0})",
        settle: 0.5,
        inspect: "[document.querySelectorAll('.CodeMirror-merge').length, document.querySelectorAll('.cm-diff-added').length, document.querySelectorAll('.cm-diff-removed').length, document.querySelector('.cm-diff-removed').textContent, document.querySelector('.diff-summary .add').textContent, window.ide.getState().text.split('\\n').length].join('|')"
    )
    // 改 b→B（1 处替换：1 删 1 增，增的那行算「改过」不算新增底色？——单列里替换行也带底色）；加 d、e 两行；被删的 b 以小块显示
    #expect(unified as? String == "0|3|1|b|+3|6")

    // 纯删除（掐头去尾后只剩删掉的行）：小块要有内容、挂在正确的位置，不能因为 NaN 让整段装饰失败
    let pureDeletion = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: "a.txt", isBinary: false, hunks: []), mode: .unified, emptyReason: nil,
                            edit: DiffEdit(oldText: "a\nb\nc\nd\n", newText: "a\nd\n", filePath: "/x/a.txt"))),
        inspect: "(function(){ const w = document.querySelector('.cm-diff-removed'); const line = w.closest('.CodeMirror-code') ? Array.from(document.querySelectorAll('.CodeMirror-code > div')).findIndex(d => d.contains(w)) : -1; return [document.querySelectorAll('.cm-diff-removed').length, w.textContent, document.querySelector('.diff-summary .del').textContent, document.querySelectorAll('.cm-diff-added').length].join('|'); })()"
    )
    #expect(pureDeletion as? String == "1|bc|−2|0")
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
    let payload = RenderPayload(.diff(path: "a.txt", language: nil, diff: diff, mode: .unified, emptyReason: nil))
    let summary = try await renderAndInspect(
        payload, snapshotName: "diff-unified",
        inspect: "document.querySelector('.message') ? document.querySelector('.message').innerText : [document.querySelectorAll('table.diff.unified tr').length, document.querySelectorAll('td.src.del .marker').length, document.querySelectorAll('td.src.add .marker').length].join(',')"
    )
    #expect(summary as? String == "4,1,1")
}

/// 上一处 / 下一处变更（F7 / ⇧F7）：只读 diff 表格按连续的变更行段落跳并高亮，编辑器按光标找、光标落到那一行；到头了不动。
@Test @MainActor func navigateChangeStepsThroughDiffAndEditor() async throws {
    // 两处改动，中间隔着上下文行
    let diff = UnifiedDiffParser.parse("""
    --- a/a.txt
    +++ b/a.txt
    @@ -1,7 +1,7 @@
     l1
    -l2
    +L2
     l3
     l4
    -l5
    -l6
    +L5
    +L6
     l7
    """)
    // 每一步都会把「前面 / 后面还有没有」报给宿主：一开始只有后面，跳到最后一处只有前面
    let positions = Locked<[ContentRenderer.ChangePosition]>([])
    let table = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: diff, mode: .sideBySide, emptyReason: nil)),
        prepare: "window.__seq = [JSON.stringify(window.ide.navigateChange('next')), document.querySelectorAll('tr.current-change').length, JSON.stringify(window.ide.navigateChange('next')), document.querySelectorAll('tr.current-change').length, JSON.stringify(window.ide.navigateChange('next')), JSON.stringify(window.ide.navigateChange('previous')), (function(){ document.dispatchEvent(new KeyboardEvent('keydown', {key: 'F7', bubbles: true, cancelable: true})); return document.querySelector('tr.current-change td.ln').textContent; })()].join('|')",
        settle: 0.3,
        configure: { renderer in renderer.onChangePosition = { position in positions.value.append(position) } },
        inspect: "window.__seq"
    )
    #expect(table as? String == "{\"index\":0,\"total\":2}|1|{\"index\":1,\"total\":2}|2|{\"index\":1,\"total\":2}|{\"index\":0,\"total\":2}|5")
    #expect(positions.value.first == ContentRenderer.ChangePosition(hasPrevious: false, hasNext: true))
    #expect(positions.value.last == ContentRenderer.ChangePosition(hasPrevious: true, hasNext: false))

    let unified = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: diff, mode: .unified, emptyReason: nil)),
        inspect: "[JSON.stringify(window.ide.navigateChange('previous')), JSON.stringify(window.ide.navigateChange('next')), document.querySelectorAll('tr.current-change').length].join('|')"
    )
    #expect(unified as? String == "{\"index\":-1,\"total\":2}|{\"index\":0,\"total\":2}|2")

    // 可编辑 diff（并排是 MergeView 的 chunk，单列是行级 diff 的分组）与带基线的编辑器：光标在改动的第一行
    let edit = DiffEdit(oldText: "a\nb\nc\nd\ne\nf\n", newText: "a\nB\nc\nd\nE\nf\n", filePath: "/x/a.txt")
    let sequence = "[window.ide.navigateChange('next').index, cm().getCursor().line, window.ide.navigateChange('next').index, cm().getCursor().line, window.ide.navigateChange('next').index, cm().getCursor().line, window.ide.navigateChange('previous').index, cm().getCursor().line].join(',')"
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: "a.txt", isBinary: false, hunks: []), mode: mode, emptyReason: nil, edit: edit)),
            inspect: "(function(){ const cm = () => document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror; return \(sequence); })()"
        )
        #expect(result as? String == "0,1,1,4,1,4,0,1", "\(mode)")
    }
    let editorPositions = Locked<[ContentRenderer.ChangePosition]>([])
    let editorResult = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: "a\nX\nc\nd\n", language: nil, editable: true, base: "a\nb\nc\n")),
        prepare: "const cm = () => document.querySelector('.CodeMirror').CodeMirror; window.__seq = [window.ide.navigateChange('next').index, cm().getCursor().line, window.ide.navigateChange('next').index, cm().getCursor().line].join(',')",
        settle: 0.3,
        configure: { renderer in renderer.onChangePosition = { position in editorPositions.value.append(position) } },
        inspect: "window.__seq"
    )
    #expect(editorResult as? String == "0,1,1,3")
    // 光标停在第一处改动上时前面没有、后面有；跳到最后一处后只有前面
    #expect(editorPositions.value.first == ContentRenderer.ChangePosition(hasPrevious: false, hasNext: true))
    #expect(editorPositions.value.last == ContentRenderer.ChangePosition(hasPrevious: true, hasNext: false))
    let noBase = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: "a\n", language: nil, editable: true)),
        inspect: "String(window.ide.navigateChange('next'))"
    )
    #expect(noBase as? String == "null")
}
