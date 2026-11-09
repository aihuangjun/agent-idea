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
/// 新增的异步断言用 `waitFor` 等 JS 条件成立，避免固定时长等待。
private func renderAndInspect(_ payload: RenderPayload, size: CGSize = CGSize(width: 900, height: 600), snapshotName: String? = nil, prepare: String? = nil, settle: TimeInterval = 0, resizeTo: CGSize? = nil, waitFor: String? = nil, configure: (ContentRenderer) -> Void = { _ in }, inspect: String) async throws -> Any? {
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
    if let resizeTo { window.setContentSize(resizeTo) }
    if let waitFor {
        let deadline = Date().addingTimeInterval(10)
        var ready = false
        while !ready, Date() < deadline {
            ready = (try? await webView.evaluateJavaScript("(() => { try { return !!(\(waitFor)); } catch (_) { return false; } })()")) as? Bool ?? false
            if !ready { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        #expect(ready, "等待渲染条件超时：\(waitFor)")
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

@Test @MainActor func diffContextExpansionPreservesWholeDocumentsAndSearchesHiddenLines() async throws {
    let old = (0..<150).map { "original line \($0)" }.joined(separator: "\n") + "\n"
    let new = old.replacingOccurrences(of: "original line 60\n", with: "changed line 60\n")
        .replacingOccurrences(of: "original line 130\n", with: "changed line 130\n")
    for mode in DiffViewMode.allCases {
        for readOnly in [false, true] {
            let result = try await renderAndInspect(
                RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                    edit: DiffEdit(oldText: old, newText: new, filePath: "/x/a.txt", readOnly: readOnly)),
                              wrap: true, revealChange: .first, diffReading: .init(collapseUnchanged: true)),
                size: CGSize(width: 580, height: 440),
                inspect: """
                (() => {
                  const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
                  const before = cm.getValue(), history = JSON.stringify(cm.historySize());
                  const first = cm.getCursor().line;
                  const fold = document.querySelector('.diff-context-fold');
                  const singleAction = fold.querySelectorAll('button').length === 1;
                  fold.querySelector('button').click();
                  const expanded = singleAction && cm.getAllMarks().every(mark => !mark.collapsed || mark.find().from.line > 15 || mark.find().to.line < 15);
                  const nav = window.ide.navigateChange('next');
                  const next = cm.getCursor().line;
                  const found = window.ide.find({query:'original line 15', caseSensitive:true});
                  const visible = cm.getAllMarks().every(mark => { const r = mark.find(); return !r || r.from.line > 15 || r.to.line < 15; });
                  return [first, expanded, nav.index, nav.total, next, found, visible, cm.getValue() === before,
                    JSON.stringify(cm.historySize()) === history, cm.getOption('readOnly')].join('|');
                })()
                """
            )
            #expect(result as? String == "60|true|1|2|130|true|true|true|true|\(readOnly)", "\(mode), readOnly=\(readOnly): \(String(describing: result))")
        }
    }
}

@Test @MainActor func expandingContextKeepsExistingCodeAtTheSameScreenPosition() async throws {
    let old = (0..<250).map { "line \($0)\n" }.joined()
    let new = old.replacingOccurrences(of: "line 90\n", with: "CHANGED 90\n").replacingOccurrences(of: "line 200\n", with: "CHANGED 200\n")
    for mode in DiffViewMode.allCases {
        for readOnly in [false, true] {
            let result = try await renderAndInspect(
                RenderPayload(.diff(path: "stable", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                    edit: DiffEdit(oldText: old, newText: new, filePath: "/x/stable", readOnly: readOnly)),
                              wrap: true, revealChange: .first, diffReading: .init(collapseUnchanged: true)),
                size: CGSize(width: 640, height: 440),
                prepare: """
                const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
                const panes = [...document.querySelectorAll('.CodeMirror')].map(node => node.CodeMirror);
                const y = pane => pane.charCoords({line:90,ch:0}, 'window').top;
                (async () => {
                  panes.forEach(pane => pane.refresh());
                  await new Promise(resolve => setTimeout(resolve, 0));
                  const before = panes.map(y), text = cm.getValue(), history = JSON.stringify(cm.historySize());
                  window.__expansionPositions = {before, tops: panes.map(pane => pane.getScrollInfo().top)};
                  const button = document.querySelector('.CodeMirror-merge-editor .diff-context-fold button, .diff-host .diff-context-fold button');
                  window.__oneExpandButton = button.parentNode.querySelectorAll('button').length === 1;
                  button.click();
                  window.__maximumMovement = 0;
                  for (let i = 0; i < 6; i++) {
                    panes.forEach(pane => pane.refresh());
                    await new Promise(resolve => setTimeout(resolve, 0));
                    panes.forEach((pane, index) => window.__maximumMovement = Math.max(window.__maximumMovement, Math.abs(y(pane) - before[index])));
                  }
                  // A middle fold has visible context above it. Opening it must retain
                  // that context rather than moving to the next change below the fold.
                  const middle = cm.getAllMarks().find(mark => mark.collapsed && mark.find().from.line > 90);
                  middle.replacedWith.querySelector('button').click();
                  for (let i = 0; i < 6; i++) {
                    panes.forEach(pane => pane.refresh());
                    await new Promise(resolve => setTimeout(resolve, 0));
                    panes.forEach((pane, index) => window.__maximumMovement = Math.max(window.__maximumMovement, Math.abs(y(pane) - before[index])));
                  }
                  window.__expansionResult = [window.__maximumMovement < 1.5, cm.getValue() === text,
                    JSON.stringify(cm.historySize()) === history, window.__oneExpandButton,
                    cm.getAllMarks().every(mark => !mark.collapsed || mark.find().from.line > 15 || mark.find().to.line < 15)].join('|');
                  window.__expansionPositions.after = panes.map(y);
                  window.__expansionPositions.afterTops = panes.map(pane => pane.getScrollInfo().top);
                })();
                """,
                waitFor: "window.__expansionResult != null",
                inspect: "window.__expansionResult + '|' + window.__maximumMovement + '|' + JSON.stringify(window.__expansionPositions)"
            )
            #expect((result as? String)?.hasPrefix("true|true|true|true|true|") == true, "\(mode), readOnly=\(readOnly): \(String(describing: result))")
        }
    }
}

@Test @MainActor func editingExpandedContextPreservesScrollAndDoesNotRefoldIt() async throws {
    let old = (0..<1000).map { "line \($0)\n" }.joined()
    let new = old.replacingOccurrences(of: "line 100\n", with: "CHANGED 100\n")
        .replacingOccurrences(of: "line 500\n", with: "CHANGED 500\n").replacingOccurrences(of: "line 900\n", with: "CHANGED 900\n")
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "typing", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                edit: DiffEdit(oldText: old, newText: new, filePath: "/x/typing")), wrap: true, revealChange: .first, diffReading: .init(collapseUnchanged: true)),
            size: CGSize(width: 700, height: 450),
            prepare: """
            (async () => {
            const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
            // Expand every region, including those outside CodeMirror's virtual viewport.
            while (cm.getAllMarks().some(mark => mark.collapsed)) {
              const mark = cm.getAllMarks().find(mark => mark.collapsed);
              mark.replacedWith.querySelector('button').click();
            }
            cm.refresh();
            await new Promise(resolve => setTimeout(resolve, 0));
            cm.getWrapperElement().dispatchEvent(new WheelEvent('wheel', {bubbles:true}));
            cm.setCursor(480, cm.getLine(480).length);
            cm.scrollTo(null, cm.heightAtLine(474, 'local'));
            cm.replaceRange(' inserted\\nnew user line', cm.getCursor(), null, '+input');
            cm.setCursor(481, 13);
            // Offscreen WebKit defers the wrapper's native scroll event. Deliver it so
            // CodeMirror can reset that outer wrapper before measuring the real scroller.
            cm.getWrapperElement().dispatchEvent(new Event('scroll'));
            window.__typingY = cm.charCoords(cm.getCursor(), 'window').top;
            window.__typingTop = cm.getScrollInfo().top;
            })();
            """,
            waitFor: "window.__typingY != null && document.querySelector('.diff-summary .add').textContent === '+5'",
            inspect: """
            (() => { const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
              return [Math.abs(cm.charCoords(cm.getCursor(),'window').top - window.__typingY) < 1.5,
                Math.abs(cm.getScrollInfo().top - window.__typingTop) < cm.defaultTextHeight() * 2 + 2,
                cm.getAllMarks().every(mark => !mark.collapsed), cm.getValue().includes('inserted\\nnew user line'),
                cm.getCursor().line, cm.getScrollInfo().top - window.__typingTop,
                cm.charCoords(cm.getCursor(),'window').top - window.__typingY].join('|'); })()
            """
        )
        #expect((result as? String)?.hasPrefix("true|true|true|true|481|") == true, "\(mode): \(String(describing: result))")
    }
}

@Test @MainActor func passiveDiffPaneCannotPullTheActiveEditorBackwards() async throws {
    let text = (0..<300).map { "line \($0)\n" }.joined()
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "sync", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                            edit: DiffEdit(oldText: text, newText: text, filePath: "/x/sync"))),
        prepare: """
        (async () => {
          const l = document.querySelector('.CodeMirror-merge-left .CodeMirror').CodeMirror;
          const r = document.querySelector('.CodeMirror-merge-editor .CodeMirror').CodeMirror;
          r.getWrapperElement().dispatchEvent(new WheelEvent('wheel', {bubbles:true}));
          r.scrollTo(null, 1000); await new Promise(resolve => setTimeout(resolve, 0));
          const top = r.getScrollInfo().top;
          l.scrollTo(null, 0); await new Promise(resolve => setTimeout(resolve, 0));
          const stable = r.getScrollInfo().top === top;
          l.getWrapperElement().dispatchEvent(new WheelEvent('wheel', {bubbles:true}));
          l.scrollTo(null, 500);
          await new Promise(resolve => setTimeout(resolve, 0));
          window.__syncResult = [stable, Math.abs(r.getScrollInfo().top - 500) < 1].join('|');
        })();
        """,
        waitFor: "window.__syncResult != null",
        inspect: "window.__syncResult"
    )
    #expect(result as? String == "true|true")
}

@Test @MainActor func diffReadingStateSurvivesModeTabAndThemeChanges() async throws {
    let old = (0..<600).map { "line \($0)\n" }.joined()
    let new = old.replacingOccurrences(of: "line 100\n", with: "CHANGED 100\n").replacingOccurrences(of: "line 500\n", with: "CHANGED 500\n")
    for mode in DiffViewMode.allCases {
        for readOnly in [false, true] {
            let content = RenderPayload.Content.diff(path: "restore", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                                      edit: DiffEdit(oldText: old, newText: new, filePath: "/x/restore", readOnly: readOnly))
            let payload = RenderPayload(content, wrap: true, revealChange: .first, diffReading: .init(collapseUnchanged: true))
            let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            let result = try await renderAndInspect(payload, size: CGSize(width: 700, height: 450), prepare: """
            (async () => {
              const working = () => document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
              let cm = working();
              // Open the prefix and middle, then read in the middle of the expanded context.
              while (cm.getAllMarks().some(mark => mark.collapsed && mark.find().from.line < 500))
                cm.getAllMarks().find(mark => mark.collapsed && mark.find().from.line < 500).replacedWith.querySelector('button').click();
              cm.getWrapperElement().dispatchEvent(new WheelEvent('wheel', {bubbles:true}));
              cm.scrollTo(null, cm.heightAtLine(120, 'local') - 70);
              cm.refresh(); await new Promise(resolve => setTimeout(resolve, 0));
              cm.getWrapperElement().dispatchEvent(new Event('scroll'));
              const y = cm.charCoords({line:120,ch:0}, 'window').top, state = window.ide.getState();
              const next = \(encoded);
              next.revealChange = null; next.mode = next.mode === 'side' ? 'unified' : 'side';
              next.scrollTop = state.scrollTop; next.diffViewState = state.diffViewState;
              next.edit.cursor = state.cursor;
              // Switching another tab flushes the old document before the saved state returns.
              window.ide.render({kind:'message',title:'another tab',detail:'',scrollTop:0,wrap:false});
              window.ide.render(next);
              cm = working(); cm.refresh(); await new Promise(resolve => setTimeout(resolve, 0));
              cm.getWrapperElement().dispatchEvent(new Event('scroll'));
              const afterMode = Math.abs(cm.charCoords({line:120,ch:0}, 'window').top - y) < 2;
              const beforeTheme = cm.charCoords({line:120,ch:0}, 'window').top;
              window.ide.setTheme('light');
              cm = working(); cm.refresh(); await new Promise(resolve => setTimeout(resolve, 0));
              cm.getWrapperElement().dispatchEvent(new Event('scroll'));
              window.__restoreResult = [afterMode, Math.abs(cm.charCoords({line:120,ch:0}, 'window').top - beforeTheme) < 2,
                cm.getAllMarks().every(mark => !mark.collapsed || mark.find().from.line > 50 || mark.find().to.line < 50),
                cm.getValue() === next.edit.newText, cm.getOption('readOnly')].join('|');
            })();
            """, waitFor: "window.__restoreResult != null", inspect: "window.__restoreResult")
            #expect(result as? String == "true|true|true|true|\(readOnly)", "\(mode): \(String(describing: result))")
        }
    }
}

@Test @MainActor func ignoredWhitespaceControlsHighlightCountsNavigationAndLiveEdits() async throws {
    let old = "a  \n  b\nc\nOLD\ne\nf\nSECOND\nend\n"
    let new = "a\n\tb\nc\nNEW\ne\nf\nCHANGED\nend\n"
    for mode in DiffViewMode.allCases {
        let positions = Locked<[ContentRenderer.ChangePosition]>([])
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                edit: DiffEdit(oldText: old, newText: new, filePath: "/x/a.txt")),
                          revealChange: .first, diffReading: .init(collapseUnchanged: true, whitespace: .all)),
            prepare: """
            const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
            window.__first = [cm.getCursor().line, document.querySelector('.diff-summary .add').textContent];
            cm.replaceRange('OLD', {line:3,ch:0}, {line:3,ch:3});
            """,
            waitFor: "document.querySelector('.diff-summary .add').textContent === '+1'",
            configure: { $0.onChangePosition = { positions.value.append($0) } },
            inspect: """
            (() => { const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
              const nav = window.ide.navigateChange('next');
              return [window.__first.join(','), nav.total, cm.getCursor().line, cm.getLine(0), cm.getLine(1)].join('|'); })()
            """
        )
        #expect(result as? String == "3,+2|1|6|a|\tb", "\(mode): \(String(describing: result))")
        #expect(positions.value.last?.total == 1)
    }
}

@Test @MainActor func sideDiffAlignsWrappedContextAfterFoldingAndResize() async throws {
    let long = String(repeating: "unchanged content ", count: 50)
    let old = "start\nold\nold two\n\(long)\n" + (0..<80).map { "keep \($0)\n" }.joined() + "end\n"
    let new = "start\nnew\n\(long)\n" + (0..<80).map { "keep \($0)\n" }.joined() + "END\n"
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                            edit: DiffEdit(oldText: old, newText: new, filePath: "/x/a.txt")), wrap: true, diffReading: .init(collapseUnchanged: true)),
        size: CGSize(width: 1000, height: 600), resizeTo: CGSize(width: 540, height: 420),
        waitFor: """
        (() => {
          const l = document.querySelector('.CodeMirror-merge-left .CodeMirror').CodeMirror, r = document.querySelector('.CodeMirror-merge-editor .CodeMirror').CodeMirror;
          const wrappedHeight = l.charCoords({line:3,ch:l.getLine(3).length},'local').bottom - l.charCoords({line:3,ch:0},'local').top;
          return innerWidth === 540 && l.getLineHandle(3).height >= wrappedHeight - 1
            && Math.abs(l.heightAtLine(3,'local')-r.heightAtLine(2,'local')) < 1 && Math.abs(l.heightAtLine(4,'local')-r.heightAtLine(3,'local')) < 1;
        })()
        """,
        inspect: """
        (() => {
          const l = document.querySelector('.CodeMirror-merge-left .CodeMirror').CodeMirror, r = document.querySelector('.CodeMirror-merge-editor .CodeMirror').CodeMirror;
          return [Math.abs(l.heightAtLine(4,'local') - r.heightAtLine(3,'local')) < 1,
            l.getLine(3) === r.getLine(2), document.documentElement.scrollWidth <= innerWidth + 1,
            [...document.querySelectorAll('.CodeMirror')].every(x => x.getBoundingClientRect().right <= innerWidth + 1)].join('|');
        })()
        """
    )
    #expect(result as? String == "true|true|true|true")
}

@Test @MainActor func clearingOldFoldMarkersDoesNotExpandUnrelatedRegions() async throws {
    let old = (0..<150).map { "line \($0)\n" }.joined()
    let new = old.replacingOccurrences(of: "line 60\n", with: "CHANGED 60\n").replacingOccurrences(of: "line 130\n", with: "CHANGED 130\n")
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                edit: DiffEdit(oldText: old, newText: new, filePath: "/x/a", cursor: .init(line: 10, ch: 0), readOnly: true)),
                          diffReading: .init(collapseUnchanged: true, whitespace: .all)),
            prepare: "window.ide.setTheme('light'); setTimeout(() => window.__foldCallbacksDrained = true, 0)",
            waitFor: "window.__foldCallbacksDrained",
            inspect: """
            (() => { const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
              return [cm.getAllMarks().some(mark => mark.collapsed && mark.find()?.from.line > 60), cm.getValue().includes('CHANGED 130'),
                document.querySelector('.diff-summary .add').textContent, window.ide.getState().text === null, window.ide.undo()].join('|'); })()
            """
        )
        #expect(result as? String == "true|true|+2|true|false", "\(mode): \(String(describing: result))")
    }
}

@Test @MainActor func diffRevertRestoresCompleteChunksIncludingEOFAndCanUndo() async throws {
    for (old, new) in [("a", "a\nb"), ("a\n", "a"), ("a\nb\n", "a\n"), ("", "new\n"), ("a\nb\nc\n", "a\nB\nc\n")] {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                                edit: DiffEdit(oldText: old, newText: new, filePath: "/x/a")), diffReading: .init(collapseUnchanged: true)),
            prepare: "window.__beforeRevert = window.ide.getState().text; document.querySelector('.diff-revert-button').click()",
            waitFor: "document.querySelector('.diff-summary .add').textContent === '+0' && document.querySelector('.diff-summary .del').textContent === '−0'",
            inspect: "(() => { const text = window.ide.getState().text; window.ide.undo(); return [text, window.ide.getState().text === window.__beforeRevert]; })()"
        )
        let values = result as? [Any]
        #expect(values?[0] as? String == old, "\(old.debugDescription) → \(new.debugDescription): \(String(describing: result))")
        #expect(values?[1] as? Bool == true)
    }
}

@Test @MainActor func diffArrowImmediatelyAfterEditingUsesTheLatestChangeRegions() async throws {
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                edit: DiffEdit(oldText: "a\nb\nc\nd\ne\nf\ng\n", newText: "a\nB\nc\nd\ne\nF\ng\n", filePath: "/x/a")),
                          revealChange: .first, diffReading: .init(collapseUnchanged: true)),
            prepare: """
            const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
            cm.replaceRange('b', {line:1,ch:0}, {line:1,ch:1});
            cm.replaceRange('D', {line:3,ch:0}, {line:3,ch:1}); cm.setCursor(1,0);
            document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowDown', bubbles:true, cancelable:true}));
            """,
            waitFor: "window.ide.getState().cursor.line === 3",
            configure: { renderer in renderer.onDiffNavigate = { [weak renderer] step, _ in renderer?.navigateChange(step) } },
            inspect: "[window.ide.getState().cursor.line, document.querySelector('.diff-summary .add').textContent].join('|')"
        )
        #expect(result as? String == "3|+2", "\(mode): \(String(describing: result))")
    }
}

@Test @MainActor func deletedWholeFileStartsAtTheFirstDeletedLine() async throws {
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "deleted", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                            edit: DiffEdit(oldText: (0..<120).map { "removed \($0)\n" }.joined(), newText: "", filePath: "deleted", readOnly: true)),
                      revealChange: .first, diffReading: .init(collapseUnchanged: true)),
        waitFor: "document.querySelector('.CodeMirror-merge-left .CodeMirror').CodeMirror.getScrollInfo().top < 1",
        inspect: "[document.querySelector('.CodeMirror-merge-left .CodeMirror').CodeMirror.getScrollInfo().top < 1, document.querySelector('.diff-summary .del').textContent].join('|')"
    )
    #expect(result as? String == "true|−120")
}

@Test @MainActor func mixedInsertionsDeletionsAndEditsKeepAlignmentBoundedAcrossRefreshes() async throws {
    let old = (0..<50).map { "line \($0)\n" }.joined()
    let new = old.replacingOccurrences(of: "line 3\n", with: "CHANGED 3\n")
        .replacingOccurrences(of: "line 10\n", with: "line 10\ninserted A\ninserted B\n")
        .replacingOccurrences(of: "line 20\nline 21\n", with: "")
        .replacingOccurrences(of: "line 30\n", with: "CHANGED 30\n")
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "mixed", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                            edit: DiffEdit(oldText: old, newText: new, filePath: "/x/mixed")), wrap: true, diffReading: .init(collapseUnchanged: true)),
        size: CGSize(width: 720, height: 450),
        prepare: """
        window.__alignmentDone = false;
        (async () => {
          const left = document.querySelector('.CodeMirror-merge-left .CodeMirror').CodeMirror;
          const right = document.querySelector('.CodeMirror-merge-editor .CodeMirror').CodeMirror;
          right.replaceRange('temporary\\n', {line:0,ch:0}); right.undo();
          window.__maximumHeight = 0;
          for (let i = 0; i < 10; i++) {
            left.refresh(); right.refresh();
            await new Promise(resolve => setTimeout(resolve, 0));
            window.__maximumHeight = Math.max(window.__maximumHeight, left.getScrollInfo().height, right.getScrollInfo().height);
          }
          window.__alignmentDone = true;
        })();
        """,
        waitFor: "window.__alignmentDone",
        inspect: """
        (() => { const l = document.querySelector('.CodeMirror-merge-left .CodeMirror').CodeMirror;
          const r = document.querySelector('.CodeMirror-merge-editor .CodeMirror').CodeMirror;
          return [window.__maximumHeight < 2000, [[12,14],[23,23],[39,39]].every(([a,b]) => Math.abs(l.heightAtLine(a,'local')-r.heightAtLine(b,'local')) < 1),
            r.getValue().includes('inserted B'), document.querySelectorAll('.diff-revert-button').length > 0].join('|'); })()
        """
    )
    #expect(result as? String == "true|true|true|true", "\(String(describing: result))")
}

@Test @MainActor func findSearchesTheWholeEditorAndWrapsLiterally() async throws {
    let result = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: "First [x]\n" + String(repeating: "other\n", count: 300) + "last [X]\n", language: nil, editable: true)),
        inspect: """
        (() => {
          const cm = document.querySelector('.CodeMirror').CodeMirror;
          const search = (backwards = false, caseSensitive = false, query = '[x]') => window.ide.find({query, backwards, caseSensitive});
          const result = [search(), cm.getCursor('from').line, cm.getSelection()];
          result.push(search(), cm.getCursor('from').line, cm.getSelection());
          result.push(search(), cm.getCursor('from').line);
          result.push(search(true), cm.getCursor('from').line);
          result.push(search(false, true), cm.getSelection());
          result.push(search(false, true, 'missing'));
          window.ide.focusEditor();
          result.push(cm.hasFocus());
          return result.join('|');
        })()
        """
    )
    #expect(result as? String == "true|0|[x]|true|301|[X]|true|0|true|301|true|[x]|false|true")
}

@Test @MainActor func findIncludesTheBaseSideOfEditableDiff() async throws {
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                            edit: DiffEdit(oldText: "deleted only", newText: "new text", filePath: "/x/a.txt"))),
        inspect: "[window.ide.find({query: 'deleted', backwards: false, caseSensitive: false}), document.querySelector('.CodeMirror-merge-left .CodeMirror').CodeMirror.getSelection()].join('|')"
    )
    #expect(result as? String == "true|deleted")
}

@Test @MainActor func findIncludesDeletedTextOutsideTheUnifiedEditorViewport() async throws {
    let prefix = String(repeating: "same\n", count: 300)
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .unified, emptyReason: nil,
                            edit: DiffEdit(oldText: prefix + "deleted needle\n", newText: prefix + "replacement\n", filePath: "/x/a.txt"))),
        inspect: """
        (() => {
          const find = query => window.ide.find({query, backwards: false, caseSensitive: false});
          const marks = () => document.querySelectorAll('.cm-find-removed').length;
          const result = [find('deleted needle'), marks(), document.querySelector('.cm-find-removed')?.textContent];
          result.push(find('missing'), marks(), find('deleted needle'));
          window.ide.clearFind();
          result.push(marks(), find('deleted needle'), find(''), marks());
          return result.join('|');
        })()
        """
    )
    #expect(result as? String == "true|1|deleted needle|false|0|true|0|true|false|0")
}

@Test @MainActor func newEditableDiffRevealsTheFirstDifferenceAndRestoresVisitedPositions() async throws {
    let oldLines = (0..<700).map { "line \($0)" }
    var newLines = oldLines
    newLines[400] = "FIRST DIFFERENCE"
    newLines[600] = "SECOND DIFFERENCE"
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                edit: DiffEdit(oldText: oldLines.joined(separator: "\n"), newText: newLines.joined(separator: "\n"), filePath: "/x/a.txt")), wrap: true, revealChange: .first),
            inspect: """
            (() => {
              const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
              const state = window.ide.getState();
              const visible = cm.getViewport();
              return [state.cursor.line, state.scrollTop > 1000, visible.from <= 400 && visible.to > 400,
                      window.ide.navigateChange('next').index, cm.getCursor().line].join('|');
            })()
            """
        )
        #expect(result as? String == "400|true|true|1|600", "\(mode)")
        let restored = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                edit: DiffEdit(oldText: oldLines.joined(separator: "\n"), newText: newLines.joined(separator: "\n"), filePath: "/x/a.txt", cursor: EditorCursor(line: 10, ch: 2))), scrollTop: 0),
            inspect: "[window.ide.getState().cursor.line, window.ide.getState().cursor.ch, window.ide.getState().scrollTop].join('|')"
        )
        #expect(restored as? String == "10|2|0", "回到页首的已访问标签也不能再次自动跳走：\(mode)")
    }
}

@Test @MainActor func initialDiffRevealHandlesLineZeroDeletionAndIdenticalFiles() async throws {
    let examples: [(String, String, Int)] = [("old\nrest", "new\nrest", 0), ("a\nremoved\nb", "a\nb", 1), ("same", "same", 0)]
    for (old, new, expected) in examples {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .unified, emptyReason: nil,
                                edit: DiffEdit(oldText: old, newText: new, filePath: "/x/a.txt")), revealChange: .first),
            inspect: "window.ide.getState().cursor.line"
        )
        #expect((result as? NSNumber)?.intValue == expected)
    }
}

@Test @MainActor func newReadOnlyDiffSelectsTheFirstChangedRun() async throws {
    let diff = UnifiedDiffParser.parse("--- a/a.txt\n+++ b/a.txt\n@@ -1,4 +1,4 @@\n-first\n+FIRST\n same\n-second\n+SECOND\n end\n")
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: diff, mode: mode, emptyReason: nil), revealChange: .first),
            inspect: "[document.querySelector('tr.current-change td.src').textContent.includes('first') || document.querySelector('tr.current-change td.src').textContent.includes('FIRST'), window.ide.navigateChange('next').index].join('|')"
        )
        #expect(result as? String == "true|1")
    }
}

@Test @MainActor func firstDifferenceAtDeletedEOFHasNoUnreachableNextChange() async throws {
    for mode in DiffViewMode.allCases {
        let positions = Locked<[ContentRenderer.ChangePosition]>([])
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                edit: DiffEdit(oldText: "kept\nremoved", newText: "kept", filePath: "/x/a.txt")), revealChange: .first),
            configure: { $0.onChangePosition = { positions.value.append($0) } },
            inspect: "[window.ide.getState().cursor.line, window.ide.navigateChange('next').index, window.ide.navigateChange('next').total].join('|')"
        )
        #expect(result as? String == "0|0|1", "\(mode)")
        #expect(positions.value.last == ContentRenderer.ChangePosition(index: 1, total: 1), "唯一差异已自动定位，两侧都应到头：\(mode)")
    }
}

@Test @MainActor func htmlPreviewLoadsLocalResourcesAndScriptsWithoutTheEditorBridge() async throws {
    try await withTemporaryDirectory { directory in
        let web = directory.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "h1 { color: rgb(12, 34, 56); }".write(to: web.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try "document.querySelector('h1').textContent = 'HTML ready';".write(to: web.appendingPathComponent("local.js"), atomically: true, encoding: .utf8)
        try "window.outsideRan = true".write(to: directory.appendingPathComponent("outside.js"), atomically: true, encoding: .utf8)
        let html = "<!doctype html><html><head><link rel='stylesheet' href='style.css'></head><body><h1>Loading</h1><script src='local.js'></script><script src='../outside.js' onerror='window.outsideBlocked = true'></script><script>window.inlineRan = true</script></body></html>"
        let renderer = ContentRenderer()
        renderer.render(RenderPayload(.html(path: web.appendingPathComponent("page.html").path, text: html, documentDirectory: web)))
        let webView = renderer.displayedWebView
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        var result: String?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            result = try? await webView.evaluateJavaScript("[document.querySelector('h1')?.textContent, document.querySelector('h1') ? getComputedStyle(document.querySelector('h1')).color : '', window.inlineRan, typeof window.webkit?.messageHandlers?.ide, window.outsideBlocked, typeof window.outsideRan].join('|')") as? String
            if result == "HTML ready|rgb(12, 34, 56)|true|undefined|true|undefined" { break }
            await Task.yield()
        }
        #expect(result == "HTML ready|rgb(12, 34, 56)|true|undefined|true|undefined")
        let found = await withCheckedContinuation { continuation in renderer.find("HTML ready") { continuation.resume(returning: $0) } }
        #expect(found)
        renderer.render(RenderPayload(.code(path: "/x/a.txt", text: "source", language: nil, editable: true)))
        #expect(renderer.displayedWebView === renderer.webView)
    }
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

/// 编辑器的撤销历史随 getState 带走、随 payload 带回来：切走再切回的编辑器 ⌘Z 还能撤到切走之前；
/// window.ide.undo() 在只读视图里回 false（宿主去撤文件操作）。
@Test @MainActor func editorHistoryRoundTripsThroughPayload() async throws {
    let history = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: "one\n", language: nil, editable: true)),
        prepare: "document.querySelector('.CodeMirror').CodeMirror.replaceRange('X', {line: 0, ch: 0})",
        inspect: "[typeof window.ide.getState().history, window.ide.getState().text, window.ide.undo(), window.ide.getState().text, window.ide.redo(), window.ide.getState().text].join('|')"
    )
    #expect(history as? String == "string|Xone\n|true|one\n|true|Xone\n")
    let recorded = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: "one\n", language: nil, editable: true)),
        prepare: "document.querySelector('.CodeMirror').CodeMirror.replaceRange('X', {line: 0, ch: 0})",
        inspect: "window.ide.getState().history"
    )
    let restored = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: "Xone\n", language: nil, editable: true, history: recorded as? String)),
        inspect: "[window.ide.undo(), window.ide.getState().text].join('|')"
    )
    #expect(restored as? String == "true|one\n", "带着历史重画之后能撤到切走之前")
    let readOnly = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: "one\n", language: nil, editable: false)),
        inspect: "[window.ide.undo(), window.ide.redo(), window.ide.getState().history === null].join('|')"
    )
    #expect(readOnly as? String == "false|false|true")
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

/// 长行的可达性必须验证真实滚动条和行末坐标，不能只检查 lineWrapping 选项。
@Test @MainActor func diffLongLinesHaveVisibleScrollbarsAndReachableLineEnds() async throws {
    let line = String(repeating: "long_unbroken_value", count: 80) + "_END"
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: String(repeating: "long-directory/", count: 30) + "a.txt", language: nil,
                                diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                edit: DiffEdit(oldText: "old_" + line, newText: "new_" + line, filePath: "/x/a.txt")), wrap: false),
            size: CGSize(width: 640, height: 320), snapshotName: "diff-long-lines-scrollbars-\(mode.rawValue)",
            inspect: """
            (() => Array.from(document.querySelectorAll('.CodeMirror-merge-pane .CodeMirror, .diff-host .CodeMirror')).map(node => {
              const cm = node.CodeMirror, bar = node.querySelector('.CodeMirror-hscrollbar');
              const visibleBeforeScrolling = getComputedStyle(bar).visibility == 'visible';
              bar.scrollLeft = 1e7; bar.dispatchEvent(new Event('scroll'));
              const rect = node.getBoundingClientRect(), end = cm.charCoords({line: 0, ch: cm.getLine(0).length}, 'page');
              const b = bar.getBoundingClientRect(), css = getComputedStyle(bar);
              return [css.display != 'none', visibleBeforeScrolling && css.visibility == 'visible', b.height >= 8, b.bottom <= innerHeight + 1,
                      cm.getScrollInfo().left > 100, end.left <= rect.right && end.left >= rect.left].join(',');
            }).join('|'))()
            """
        )
        let expected = mode == .sideBySide ? "true,true,true,true,true,true|true,true,true,true,true,true" : "true,true,true,true,true,true"
        #expect(result as? String == expected)
    }
}

@Test @MainActor func diffLongUnbrokenLinesWrapInBothPanesAndCanToggleBack() async throws {
    let line = String(repeating: "0123456789abcdef", count: 80)
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                            edit: DiffEdit(oldText: "old_" + line, newText: "new_" + line, filePath: "/x/a.txt")), wrap: true),
        size: CGSize(width: 640, height: 320), snapshotName: "diff-long-lines-wrapped",
        prepare: "window.ide.setWrap(false); window.ide.setWrap(true)",
        waitFor: "Array.from(document.querySelectorAll('.CodeMirror-hscrollbar')).every(bar => getComputedStyle(bar).display == 'none')",
        inspect: """
        (() => {
          const panes = Array.from(document.querySelectorAll('.CodeMirror-merge-pane .CodeMirror'));
          const wrapped = panes.every(node => {
            const cm = node.CodeMirror, info = cm.getScrollInfo();
            return cm.getOption('lineWrapping') && node.querySelector('pre.CodeMirror-line').getBoundingClientRect().height > cm.defaultTextHeight() * 2
                   && info.width <= info.clientWidth + 1;
          });
          window.ide.setWrap(false);
          const unwrapped = panes.every(node => !node.CodeMirror.getOption('lineWrapping') && node.CodeMirror.getScrollInfo().width > node.CodeMirror.getScrollInfo().clientWidth + 100);
          window.ide.setWrap(true);
          return [wrapped, unwrapped, panes.every(node => node.CodeMirror.getOption('lineWrapping'))].join('|');
        })()
        """
    )
    #expect(result as? String == "true|true|true")
}

@Test @MainActor func unifiedDeletedLongLinesRemainReadableWithAndWithoutWrapping() async throws {
    let deleted = String(repeating: "删除🙂_very_long_url/", count: 100) + "DELETED_END"
    for wrap in [false, true] {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .unified, emptyReason: nil,
                                edit: DiffEdit(oldText: deleted + "\nkeep\n", newText: "keep\n", filePath: "/x/a.txt")), wrap: wrap),
            size: CGSize(width: 700, height: 400), snapshotName: "unified-deleted-long-\(wrap)",
            prepare: "window.ide.setZoom(2.5)", resizeTo: CGSize(width: 480, height: 280),
            waitFor: "innerWidth == 480 && Math.abs(document.querySelector('.CodeMirror').CodeMirror.defaultTextHeight() - parseFloat(getComputedStyle(document.querySelector('.CodeMirror')).lineHeight)) < 2 && (!document.querySelector('.CodeMirror-wrap') || document.querySelector('.cm-diff-removed').getBoundingClientRect().right <= 480)",
            inspect: """
            (() => {
              const node = document.querySelector('.CodeMirror'), cm = node.CodeMirror, removed = node.querySelector('.cm-diff-removed');
              const bar = node.querySelector('.CodeMirror-hscrollbar');
              if (!cm.getOption('lineWrapping')) { bar.scrollLeft = 1e8; bar.dispatchEvent(new Event('scroll')); }
              const text = removed.firstChild.firstChild, range = document.createRange();
              range.setStart(text, text.length - 11); range.setEnd(text, text.length);
              const end = range.getBoundingClientRect(), pane = node.getBoundingClientRect();
              return [removed.textContent.endsWith('DELETED_END'), end.left >= pane.left && end.right <= pane.right,
                      !cm.getOption('lineWrapping') || (removed.offsetHeight > cm.defaultTextHeight() * 2 && cm.charCoords({line: 0, ch: 0}, 'page').top >= removed.getBoundingClientRect().bottom - 1)].join('|');
            })()
            """
        )
        #expect(result as? String == "true|true|true", "wrap=\(wrap)")
    }
}

@Test @MainActor func unifiedWrappingResetsHorizontalExtentAfterScrollingToDeletedLineEnd() async throws {
    let deleted = String(repeating: "删除🙂_very_long_url/", count: 100) + "DELETED_END"
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .unified, emptyReason: nil,
                            edit: DiffEdit(oldText: deleted + "\nkeep\n", newText: "keep\n", filePath: "/x/a.txt")), wrap: false),
        prepare: """
        const bar = document.querySelector('.CodeMirror-hscrollbar');
        bar.scrollLeft = 1e8; bar.dispatchEvent(new Event('scroll'));
        window.ide.setWrap(true); window.ide.setZoom(2.5);
        """,
        resizeTo: CGSize(width: 480, height: 280),
        waitFor: "innerWidth == 480 && document.querySelector('.cm-diff-removed').getBoundingClientRect().right <= 480 && Math.abs(document.querySelector('.CodeMirror').CodeMirror.defaultTextHeight() - parseFloat(getComputedStyle(document.querySelector('.CodeMirror')).lineHeight)) < 2",
        inspect: """
        (() => {
          const node = document.querySelector('.CodeMirror'), cm = node.CodeMirror, removed = node.querySelector('.cm-diff-removed');
          const info = cm.getScrollInfo(), pane = node.getBoundingClientRect(), rect = removed.getBoundingClientRect();
          const wrapped = info.left == 0 && info.width <= info.clientWidth + 1 && rect.left >= pane.left && rect.right <= pane.right;
          window.ide.setWrap(false);
          const bar = node.querySelector('.CodeMirror-hscrollbar');
          bar.scrollLeft = 1e8; bar.dispatchEvent(new Event('scroll'));
          const updated = node.querySelector('.cm-diff-removed').firstChild.firstChild, range = document.createRange();
          range.setStart(updated, updated.length - 11); range.setEnd(updated, updated.length);
          const end = range.getBoundingClientRect();
          return [wrapped, end.left >= pane.left && end.right <= pane.right, cm.getValue() == 'keep\\n'].join('|');
        })()
        """
    )
    #expect(result as? String == "true|true|true")
}

@Test @MainActor func diffResizeAndZoomKeepLastLineAndScrollbarsReachable() async throws {
    let line = String(repeating: "中文🙂_https://host/path?key=value\t", count: 60) + "END_OF_FILE"
    let text = "first\n" + (1...100).map { "context \($0)" }.joined(separator: "\n") + "\n" + line
    for mode in DiffViewMode.allCases {
        for wrap in [false, true] {
            let result = try await renderAndInspect(
                RenderPayload(.diff(path: String(repeating: "long/path/", count: 50), language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                    edit: DiffEdit(oldText: text, newText: "changed\n" + text, filePath: "/x/a.txt")), wrap: wrap),
                size: CGSize(width: 1000, height: 650), snapshotName: "diff-resize-\(mode.rawValue)-\(wrap)",
                prepare: "window.__expectedText = window.ide.getState().text; window.ide.setZoom(2.5)",
                resizeTo: CGSize(width: 480, height: 280),
                waitFor: "innerWidth == 480 && innerHeight == 280 && Array.from(document.querySelectorAll('.CodeMirror')).every(node => parseFloat(getComputedStyle(node).fontSize) > 30 && Math.abs(node.CodeMirror.defaultTextHeight() - parseFloat(getComputedStyle(node).lineHeight)) < 2)",
                inspect: """
                (() => {
                  const checks = Array.from(document.querySelectorAll('.CodeMirror')).map(node => {
                    const cm = node.CodeMirror, line = cm.lastLine(), ch = cm.getLine(line).length;
                    cm.scrollIntoView({line, ch}, 0);
                    const end = cm.charCoords({line, ch}, 'page'), pane = node.getBoundingClientRect();
                    const hbar = node.querySelector('.CodeMirror-hscrollbar').getBoundingClientRect();
                    return { fits: end.left >= pane.left && end.right <= pane.right + 1 && end.bottom <= pane.bottom + 1
                             && (cm.getOption('lineWrapping') || (hbar.height >= 8 && hbar.bottom <= innerHeight + 1)),
                             end: [end.left, end.right, end.bottom], pane: [pane.left, pane.right, pane.bottom], bar: [hbar.height, hbar.bottom] };
                  });
                  return [checks.every(check => check.fits) ? true : JSON.stringify(checks), window.ide.getState().text == window.__expectedText,
                          document.documentElement.scrollWidth <= innerWidth + 1].join('|');
                })()
                """
            )
            #expect(result as? String == "true|true|true", "mode=\(mode), wrap=\(wrap)")
        }
    }
}

@Test @MainActor func readOnlyDiffLongLinesStayInsideTheirColumnsAtLargeZoom() async throws {
    let line = String(repeating: "中文🙂_long_unbroken_value", count: 80) + "LINE_END"
    let diff = UnifiedDiffParser.parse("--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-OLD_\(line)\n+NEW_\(line)\n")
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: String(repeating: "long/path/", count: 50), language: nil, diff: diff, mode: mode, emptyReason: nil)),
            size: CGSize(width: 1000, height: 650), prepare: "window.ide.setZoom(2.5)", resizeTo: CGSize(width: 480, height: 280),
            waitFor: "innerWidth == 480 && parseFloat(getComputedStyle(document.querySelector('table.diff')).fontSize) > 30",
            inspect: """
            (() => {
              const cells = Array.from(document.querySelectorAll('td.src:not(.empty)'));
              const fits = cells.every(cell => cell.scrollWidth <= cell.clientWidth + 1 && cell.textContent.endsWith('LINE_END'));
              return [fits, document.querySelector('table.diff').getBoundingClientRect().right <= innerWidth + 1,
                      document.documentElement.scrollWidth <= innerWidth + 1].join('|');
            })()
            """
        )
        #expect(result as? String == "true|true|true", "mode=\(mode)")
    }
}

@Test @MainActor func diffThemeChangeKeepsUnsavedTextCursorAndUndoHistory() async throws {
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                edit: DiffEdit(oldText: "before\n", newText: "after\n", filePath: "/x/a.txt"))),
            prepare: """
            const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror;
            cm.replaceRange('draft_', {line: 0, ch: 0}); cm.setCursor(0, 6);
            window.ide.setTheme('light');
            """,
            inspect: """
            (() => {
              const state = window.ide.getState();
              window.ide.undo();
              return [state.text == 'draft_after\\n', state.cursor.ch == 6, window.ide.getState().text == 'after\\n'].join('|');
            })()
            """
        )
        #expect(result as? String == "true|true|true", "mode=\(mode)")
    }
}

@Test @MainActor func diffLateBaselineRefreshesGuttersAndCounts() async throws {
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                            edit: DiffEdit(oldText: "before\n", newText: "after\n", filePath: "/x/a.txt"))),
        prepare: "window.ide.setBase({path: '/x/a.txt', base: 'after\\n'})",
        waitFor: "document.querySelector('.diff-summary .add').textContent === '+0'",
        inspect: "[document.querySelectorAll('.CodeMirror-gutter-background[class*=diff-gutter-]').length, document.querySelector('.diff-summary .add').textContent, document.querySelector('.diff-summary .del').textContent, window.ide.getState().text].join('|')"
    )
    #expect(result as? String == "0|+0|−0|after\n")
}

@Test @MainActor func sideDiffGuttersDistinguishChangesAndFollowWrappingAndTheme() async throws {
    let long = String(repeating: "value ", count: 45)
    let edit = DiffEdit(oldText: "start\nold \(long)\nkeep A\nkeep B\nremoved\nkeep C\nkeep D\nend\n",
                        newText: "start\nnew \(long)\nkeep A\nkeep B\nkeep C\nkeep D\nadded\nend\n", filePath: "/x/a.txt")
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil, edit: edit)),
        size: CGSize(width: 600, height: 600), snapshotName: "diff-gutter-wrapped-light",
        prepare: """
        const before = getComputedStyle(document.querySelector('.CodeMirror-gutter-background.diff-gutter-added'), '::after').backgroundColor;
        window.__darkGutter = before;
        window.ide.setTheme('light'); window.ide.setWrap(true);
        """,
        waitFor: "document.querySelector('.CodeMirror-merge-editor .CodeMirror').CodeMirror.getOption('lineWrapping')",
        inspect: """
        (() => {
          const panes = ['left', 'editor'].map(side => document.querySelector('.CodeMirror-merge-' + side + ' .CodeMirror').CodeMirror);
          const describe = cm => { const out = []; cm.eachLine(line => { const marker = /diff-gutter-(\\w+)/.exec(line.gutterClass || ''); if (marker) out.push(cm.getLineNumber(line) + ':' + marker[1]); }); return out.join(','); };
          const mark = document.querySelector('.CodeMirror-merge-editor .CodeMirror-gutter-background.diff-gutter-modified');
          const css = getComputedStyle(mark, '::after');
          const pre = mark.parentElement.querySelector('pre.CodeMirror-line');
          return [describe(panes[0]), describe(panes[1]), window.__darkGutter, getComputedStyle(document.querySelector('.CodeMirror-gutter-background.diff-gutter-added'), '::after').backgroundColor,
                  css.width, mark.getBoundingClientRect().height >= pre.getBoundingClientRect().height, pre.getBoundingClientRect().height > panes[1].defaultTextHeight() * 2].join('|');
        })()
        """
    )
    #expect(result as? String == "1:modified,4:removed|1:modified,6:added|rgb(95, 173, 101)|rgb(6, 125, 23)|4px|true|true")
}

@Test @MainActor func sideDiffGuttersRefreshAfterEditingAndClearAfterReverting() async throws {
    let payload = RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                                      edit: DiffEdit(oldText: "a\nb\nc\n", newText: "a\nB\nc\n", filePath: "/x/a.txt")))
    let added = try await renderAndInspect(payload,
        prepare: "document.querySelector('.CodeMirror-merge-editor .CodeMirror').CodeMirror.replaceRange('new\\n', {line: 3, ch: 0})",
        waitFor: "document.querySelectorAll('.CodeMirror-gutter-background.diff-gutter-added').length == 1",
        inspect: "[document.querySelectorAll('.CodeMirror-gutter-background.diff-gutter-modified').length, document.querySelectorAll('.CodeMirror-gutter-background.diff-gutter-added').length].join('|')")
    #expect(added as? String == "2|1")
    let cleared = try await renderAndInspect(payload,
        prepare: "document.querySelector('.CodeMirror-merge-editor .CodeMirror').CodeMirror.setValue('a\\nb\\nc\\n')",
        waitFor: "document.querySelectorAll('.CodeMirror-gutter-background[class*=diff-gutter-]').length == 0",
        inspect: "document.querySelectorAll('.CodeMirror-gutter-background[class*=diff-gutter-]').length")
    #expect((cleared as? NSNumber)?.intValue == 0)
}

@Test @MainActor func sideDiffGuttersHandleEmptyFilesAndPureInsertionOrDeletion() async throws {
    for (old, new, side, kind) in [("", "new\n", "editor", "added"), ("old\n", "", "left", "removed"), ("", "new", "editor", "added"), ("old", "", "left", "removed")] {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                                edit: DiffEdit(oldText: old, newText: new, filePath: "/x/a.txt"))),
            inspect: "[document.querySelectorAll('.CodeMirror-gutter-background.diff-gutter-\(kind)').length, document.querySelectorAll('.CodeMirror-merge-\(side) .CodeMirror-gutter-background.diff-gutter-\(kind)').length, document.querySelectorAll('.diff-gutter-modified').length].join('|')")
        #expect(result as? String == "1|1|0")
    }
}

@Test @MainActor func readOnlySideDiffUsesTheSameGutterColors() async throws {
    let diff = UnifiedDiffParser.parse("""
    --- a/a.txt
    +++ b/a.txt
    @@ -1,8 +1,8 @@
     start
    -old
    +new
     keep A
     keep B
    -removed
     keep C
     keep D
    +added
     end
    """)
    let result = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: diff, mode: .sideBySide, emptyReason: nil)), snapshotName: "diff-gutter-readonly",
        inspect: """
        (() => {
          const marker = document.querySelector('td.ln.diff-gutter-removed');
          return [document.querySelectorAll('td.ln.diff-gutter-modified').length, document.querySelectorAll('td.ln.diff-gutter-added').length,
                  document.querySelectorAll('td.ln.diff-gutter-removed').length, getComputedStyle(marker, '::after').backgroundColor,
                  getComputedStyle(marker, '::after').width, document.querySelectorAll('td.ln.empty[class*=diff-gutter-]').length].join('|');
        })()
        """
    )
    #expect(result as? String == "2|1|1|rgb(229, 87, 101)|4px|0")
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
        prepare: "window.__seq = [JSON.stringify(window.ide.navigateChange('next')), document.querySelectorAll('tr.current-change').length, JSON.stringify(window.ide.navigateChange('next')), document.querySelectorAll('tr.current-change').length, JSON.stringify(window.ide.navigateChange('next')), JSON.stringify(window.ide.navigateChange('previous'))].join('|'); document.dispatchEvent(new KeyboardEvent('keydown', {key: 'F7', bubbles: true, cancelable: true}))",
        waitFor: "document.querySelector('tr.current-change td.ln').textContent == '5'",
        configure: { renderer in
            renderer.onChangePosition = { position in positions.value.append(position) }
            renderer.onDiffNavigate = { [weak renderer] step, _ in renderer?.navigateChange(step) }
        },
        inspect: "window.__seq + '|' + document.querySelector('tr.current-change td.ln').textContent"
    )
    #expect(table as? String == "{\"index\":0,\"total\":2,\"moved\":true}|1|{\"index\":1,\"total\":2,\"moved\":true}|2|{\"index\":1,\"total\":2,\"moved\":false}|{\"index\":0,\"total\":2,\"moved\":true}|5")
    #expect(positions.value.first == ContentRenderer.ChangePosition(hasPrevious: false, hasNext: true, index: 1, total: 2))
    #expect(positions.value.last == ContentRenderer.ChangePosition(hasPrevious: true, hasNext: false, index: 2, total: 2))

    let unified = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: diff, mode: .unified, emptyReason: nil)),
        inspect: "[JSON.stringify(window.ide.navigateChange('previous')), JSON.stringify(window.ide.navigateChange('next')), document.querySelectorAll('tr.current-change').length].join('|')"
    )
    #expect(unified as? String == "{\"index\":-1,\"total\":2,\"moved\":false}|{\"index\":0,\"total\":2,\"moved\":true}|2")

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
    #expect(editorPositions.value.first == ContentRenderer.ChangePosition(hasPrevious: false, hasNext: true, index: 1, total: 2))
    #expect(editorPositions.value.last == ContentRenderer.ChangePosition(hasPrevious: true, hasNext: false, index: 2, total: 2))
    let noBase = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: "a\n", language: nil, editable: true)),
        inspect: "String(window.ide.navigateChange('next'))"
    )
    #expect(noBase as? String == "null")
}

@Test @MainActor func tallReadOnlyDiffChangesReachBothFileBoundaries() async throws {
    let long = String(repeating: "very_long_unbroken_url_segment_", count: 150)
    let diff = UnifiedDiffParser.parse("--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-OLD_\(long)\n+NEW_\(long)\n")
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: diff, mode: mode, emptyReason: nil), revealChange: .first),
            size: CGSize(width: 480, height: 280),
            inspect: """
            (() => {
              const row = document.querySelector('tr.current-change'), rect = row.getBoundingClientRect();
              return [rect.top < 0 && rect.bottom > innerHeight,
                      window.ide.navigateChange('previous').moved === false,
                      window.ide.navigateChange('next').moved === false].join('|');
            })()
            """
        )
        #expect(result as? String == "true|true|true", "高于视口的当前变更仍应到达文件边界：\(mode)")
    }
}

@Test @MainActor func diffArrowKeysRequestNavigationButLeaveModifierKeysAndCodeEditorsAlone() async throws {
    let steps = Locked<[String]>([])
    let keys = """
    (() => {
      const dispatch = options => document.dispatchEvent(new KeyboardEvent('keydown', {bubbles: true, cancelable: true, ...options}));
      return [dispatch({key: 'ArrowDown'}), dispatch({key: 'ArrowUp', shiftKey: true}), dispatch({key: 'ArrowDown', metaKey: true}), dispatch({key: 'ArrowUp'})].join('|');
    })()
    """
    let diff = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .unified, emptyReason: nil,
                            edit: DiffEdit(oldText: "old", newText: "new", filePath: "/x/a.txt"))),
        prepare: "window.__keys = \(keys)",
        waitFor: "window.__received == 2",
        configure: { renderer in
            renderer.onDiffNavigate = { [weak renderer] step, path in
                steps.value.append(step.rawValue + ":" + path)
                renderer?.webView.evaluateJavaScript("window.__received = (window.__received || 0) + 1")
            }
        },
        inspect: "window.__keys"
    )
    #expect(diff as? String == "false|true|true|false")
    #expect(steps.value == ["next:a.txt", "previous:a.txt"])
    let code = try await renderAndInspect(RenderPayload(.code(path: "/x/a.txt", text: "one\ntwo", language: nil, editable: true)), inspect: keys)
    #expect(code as? String == "true|true|true|true")
}

/// 浅色主题：`setTheme` 之后根元素带上 light、CSS 变量与语法色换成浅色那一套，正文重画出来还在。
/// 只起一个 WebView：切换前后的值在同一页里前后读两次（多起几个 WKWebView 会把主线程占住，
/// 并行跑的其它 `@MainActor` 测试会跟着超时）。
@Test @MainActor func lightThemeSwapsTheStylesheetVariables() async throws {
    let readBackground = "getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()"
    let result = try await renderAndInspect(
        RenderPayload(.markdown(path: "/x/a.md", markdown: "# 标题\n\n```swift\nlet answer = 42\n```\n",
                                documentDirectory: URL(fileURLWithPath: "/x/"), view: .preview)),
        snapshotName: "markdown-light",
        prepare: "window.__before = \(readBackground); window.ide.setTheme('light')",
        settle: 0.4,
        inspect: """
        [window.__before, \(readBackground), document.documentElement.className,
         getComputedStyle(document.querySelector('.hljs-keyword')).color,
         document.querySelectorAll('article.md pre').length].join('|')
        """
    ) as? String
    let parts = (result ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    try #require(parts.count == 5, "拿到的是 \(result ?? "nil")")
    #expect(parts[0].uppercased() == "#1E1F22", "默认是深色")
    #expect(parts[1].uppercased() == "#FFFFFF", "切完是浅色的底")
    #expect(parts[2] == "light", "根元素挂上 light")
    #expect(parts[3] == "rgb(0, 51, 179)", "语法色也换成浅色那一套（IntelliJ Light 的关键字深蓝）")
    #expect(parts[4] == "1", "切主题之后正文得还在")
}

/// 跳到行与复制引用（编辑器）：payload 的 revealLine 在渲染完把光标放过去、滚到正中，用过即清（切主题重画不再跳）；
/// window.ide.revealLine 夹到首尾、列夹到行长；reference 报选区 / 光标，整行选到下一行行首时那一行不算。
@Test @MainActor func editorRevealsLinesCentredAndReportsTheSelectionForReferences() async throws {
    let text = (1...300).map { "line \($0) text" }.joined(separator: "\n")
    var captured: ContentRenderer?
    let result = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.txt", text: text, language: nil, editable: true), revealLine: EditorCursor(line: 199, ch: 5)),
        size: CGSize(width: 700, height: 400),
        configure: { captured = $0 },
        inspect: """
        (() => {
          const cm = document.querySelector('.CodeMirror').CodeMirror;
          const info = cm.getScrollInfo();
          const offset = cm.heightAtLine(199, 'local') - info.top;
          const centred = Math.abs(offset - info.clientHeight / 2) < cm.defaultTextHeight() * 2;
          const first = cm.getCursor().line + ':' + cm.getCursor().ch;
          cm.setCursor({line: 3, ch: 0});
          window.ide.setTheme('light');
          const afterTheme = document.querySelector('.CodeMirror').CodeMirror.getCursor().line;
          const clamped = [window.ide.revealLine({line: 100000, ch: 99}), document.querySelector('.CodeMirror').CodeMirror.getCursor().line,
            document.querySelector('.CodeMirror').CodeMirror.getCursor().ch].join(':');
          const cm2 = document.querySelector('.CodeMirror').CodeMirror;
          cm2.setSelection({line: 11, ch: 2}, {line: 19, ch: 0});
          const selected = JSON.stringify(window.ide.reference());
          return [first, centred, afterTheme, clamped, selected].join('|');
        })()
        """
    )
    #expect(result as? String == #"199:5|true|3|true:299:13|{"from":{"line":11,"ch":2},"to":{"line":19,"ch":0}}"#)
    let renderer = try #require(captured)
    // Swift 侧换算成从 1 数的行范围：选到第 20 行（从 0 数的 19）行首，那一行不算
    let lines = Locked<ClosedRange<Int>?>(nil)
    let done = Locked(false)
    renderer.referenceLines { lines.value = $0; done.value = true }
    let deadline = Date().addingTimeInterval(10)
    while !done.value, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    #expect(lines.value == 12...19)
}

/// 只读代码视图没有光标：跳到行给那一行标底色、滚到正中，并把 DOM 选区放过去（之后复制引用就是这一行）；
/// 两种 DOM（换行 / 不换行）都认。格式化显示过的单行 JSON 行号对不上原文：不跳、不报行号。
@Test @MainActor func readOnlyCodeRevealsLinesAndReportsDomSelections() async throws {
    let text = (1...300).map { "line \($0)" }.joined(separator: "\n")
    for wrap in [false, true] {
        let result = try await renderAndInspect(
            RenderPayload(.code(path: "/x/a.txt", text: text, language: nil), wrap: wrap, revealLine: EditorCursor(line: 150, ch: 2)),
            size: CGSize(width: 700, height: 400),
            inspect: """
            (() => {
              const lines = [...document.querySelectorAll('.code-view .line')];
              const marked = lines.indexOf(document.querySelector('.code-view .line.current-line'));
              const rect = lines[150].getBoundingClientRect();
              const centred = Math.abs(rect.top + rect.height / 2 - innerHeight / 2) < rect.height * 2;
              const caret = JSON.stringify(window.ide.reference());
              const source = node => node.querySelector('.src') || node;
              const range = document.createRange();
              range.setStart(source(lines[3]).firstChild, 1);
              range.setEnd(source(lines[5]).firstChild, 2);
              getSelection().removeAllRanges(); getSelection().addRange(range);
              const selected = JSON.stringify(window.ide.reference());
              const clamped = window.ide.revealLine({line: 99999, ch: 0}) && lines.indexOf(document.querySelector('.code-view .line.current-line'));
              return [marked, centred, caret, selected, clamped].join('|');
            })()
            """
        )
        #expect(result as? String == #"150|true|{"from":{"line":150,"ch":2},"to":{"line":150,"ch":2}}|{"from":{"line":3,"ch":1},"to":{"line":5,"ch":2}}|299"#, "wrap=\(wrap)")
    }
    let json = "{" + (1...20).map { "\"key\($0)\": \($0)" }.joined(separator: ", ") + "}"
    let formatted = try await renderAndInspect(
        RenderPayload(.code(path: "/x/a.json", text: json, language: "json")),
        inspect: "[window.ide.revealLine({line: 3, ch: 0}), window.ide.reference()].join('|')"
    )
    #expect(formatted as? String == "false|")
}

/// diff 的行号按新版本：只读补丁表格跳到不早于目标的第一行，选在删除行上报下一行；
/// 并排全文 diff 只跳右边，选区在左边（旧版本）时按差异换算到右边。
@Test @MainActor func diffRevealsAndReferencesTheNewSide() async throws {
    let diff = UnifiedDiffParser.parse("""
    --- a/a.txt
    +++ b/a.txt
    @@ -10,3 +10,3 @@
     ten
    -old eleven
    +new eleven
     twelve
    @@ -40,2 +40,3 @@
     forty
    +inserted
     forty-one
    """)
    for mode in DiffViewMode.allCases {
        let result = try await renderAndInspect(
            RenderPayload(.diff(path: "a.txt", language: nil, diff: diff, mode: mode, emptyReason: nil), revealLine: EditorCursor(line: 19, ch: 0)),
            inspect: """
            (() => {
              const marked = document.querySelector('table.diff tr.current-line').dataset.line;
              const reference = JSON.stringify(window.ide.reference());
              const deleted = [...document.querySelectorAll('table.diff tr')].find(row => row.textContent.includes('old eleven') && !row.dataset.line)
                || [...document.querySelectorAll('table.diff tr')].find(row => row.textContent.includes('old eleven'));
              const range = document.createRange(); range.selectNodeContents(deleted.querySelector('td.src'));
              getSelection().removeAllRanges(); getSelection().addRange(range);
              return [marked, reference, window.ide.reference().from.line].join('|');
            })()
            """
        )
        // 第 20 行不在补丁里：落到第 40 行；删除行（单列）报它后面的新行 11，并排里同一行右边就是新行 11
        #expect(result as? String == #"40|{"from":{"line":39,"ch":0},"to":{"line":39,"ch":0}}|10"#, "\(mode)")
    }

    let old = (1...30).map { "line \($0)" }.joined(separator: "\n")
    let new = "new a\nnew b\nnew c\n" + old
    let side = try await renderAndInspect(
        RenderPayload(.diff(path: "a.txt", language: nil, diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: .sideBySide, emptyReason: nil,
                            edit: DiffEdit(oldText: old, newText: new, filePath: "/x/a.txt")), revealLine: EditorCursor(line: 20, ch: 1)),
        inspect: """
        (() => {
          const right = document.querySelector('.CodeMirror-merge-editor .CodeMirror').CodeMirror;
          const left = [...document.querySelectorAll('.CodeMirror')].map(node => node.CodeMirror).find(cm => cm !== right);
          const jumped = right.getCursor().line + ':' + right.getCursor().ch;
          left.setSelection({line: 4, ch: 0}, {line: 6, ch: 3});
          CodeMirror.signal(left, 'focus', left);
          const fromLeft = JSON.stringify(window.ide.reference());
          CodeMirror.signal(right, 'focus', right);
          right.setCursor({line: 2, ch: 1});
          return [jumped, fromLeft, JSON.stringify(window.ide.reference())].join('|');
        })()
        """
    )
    #expect(side as? String == #"20:1|{"from":{"line":7,"ch":0},"to":{"line":9,"ch":3}}|{"from":{"line":2,"ch":1},"to":{"line":2,"ch":1}}"#)
}
