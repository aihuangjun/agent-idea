import AppKit
import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@preconcurrency import WebKit

/// 编辑器的代码折叠、同名高亮、只有一个光标（render.js）：真起 WKWebView 核对。一条用例一个 WebView，
/// 同一条用例里的几种情形在同一个页面里依次渲染（别为一种情形多起一个 WebView）。
@MainActor
private final class EditorPage {
    let renderer = ContentRenderer()
    let window: NSWindow
    var renderedCount = 0

    init(size: CGSize = CGSize(width: 900, height: 700)) {
        let webView = renderer.webView
        webView.frame = CGRect(origin: .zero, size: size)
        // 离屏视图要挂到窗口上才会真正排版
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        renderer.onRendered = { [weak self] _, _ in self?.renderedCount += 1 }
    }

    func evaluate(_ script: String) async -> Any? {
        try? await renderer.webView.evaluateJavaScript("(() => { try { return \(script) } catch (e) { return 'JS 异常：' + String(e) } })()")
    }

    func string(_ script: String) async -> String {
        let value = await evaluate(script)
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return "nil"
    }

    /// 等 JS 条件成立，最多 `timeout` 秒；成立就立刻返回。
    @discardableResult
    func wait(for condition: String, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (await evaluate("!!(\(condition))")) as? Bool == true { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func render(_ payload: RenderPayload) async {
        let before = renderedCount
        renderer.render(payload)
        let deadline = Date().addingTimeInterval(10)
        while renderedCount == before, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        await installHelpers()
    }

    /// 页面里的小工具：取编辑器、合成按键（CodeMirror 按 keyCode 认键）、点折叠三角、列出折起的区间。
    func installHelpers() async {
        _ = await evaluate("""
        (() => {
          window.__cm = () => document.querySelector('.CodeMirror').CodeMirror;
          window.__key = (keyCode, mods) => {
            const e = new KeyboardEvent('keydown', Object.assign({bubbles: true, cancelable: true}, mods || {}));
            Object.defineProperty(e, 'keyCode', {value: keyCode});
            window.__cm().triggerOnKeyDown(e);
            return e.defaultPrevented;
          };
          // 点行号旁的折叠三角：CodeMirror 把 gutter 上的 mousedown 转成 gutterClick，foldgutter 插件听的就是它
          window.__gutter = (line) => { const cm = window.__cm(); window.CodeMirror.signal(cm, 'gutterClick', cm, line, 'CodeMirror-foldgutter', new MouseEvent('mousedown')); };
          window.__folds = () => window.__cm().getAllMarks().filter(m => m.__isFold && m.find()).map(m => m.find().from.line + '-' + m.find().to.line).sort().join(',');
          return true;
        })()
        """)
    }
}

private func code(_ path: String, _ language: String?, _ text: String, foldState: String? = nil) -> RenderPayload {
    RenderPayload(.code(path: path, text: text, language: language, editable: true), foldState: foldState)
}

private let sample = """
package demo;

public class Counter {
    private int count;

    public Counter(int start) {
        this.count = start;
    }

    public void run(int by) {
        int local = count + by;
        System.out.println(local);
        count++;
    }
}
"""

/// 折叠：点行号旁的三角折起 / 展开（没有快捷键，⌘- / ⌘= 留给应用的缩小 / 放大）；全部折起 / 展开的区块范围；箭头排在变更条右边；
/// 切主题（重建编辑器）后折叠还在；经 Swift 的 payload 往返恢复，文本变了就丢弃；Markdown 源码同样往返。
@Test @MainActor func foldingFollowsIDEAKeysAndSurvivesRebuilds() async throws {
    let page = EditorPage()
    await page.render(code("/p/Counter.java", "java", sample))
    // tree-sitter 的 overlay 装上之后再折：brace-fold 靠 getTokenTypeAt 配对括号，overlay 不能干扰它
    #expect(await page.wait(for: "document.querySelector('.CodeMirror[data-syntax=\"tree-sitter\"]')"))
    #expect(await page.string("JSON.stringify(__cm().getOption('gutters'))") == #"["CodeMirror-linenumbers","cm-changes","CodeMirror-foldgutter"]"#)
    #expect(await page.wait(for: "document.querySelectorAll('.CodeMirror-foldgutter-open').length >= 3"), "类、构造器、方法三处都有折叠箭头")

    // ⌘- / ⌘= / ⇧⌘- / ⇧⌘= 编辑器不处理（交给应用菜单缩放）；点 run 那一行（第 9 行）的三角折起整个 run（9–13）
    let collapsed = await page.string("(() => { const cm = __cm(); cm.setCursor({line: 10, ch: 8}); const handled = [__key(189, {metaKey: true}), __key(187, {metaKey: true}), __key(189, {metaKey: true, shiftKey: true}), __key(187, {metaKey: true, shiftKey: true})].some(Boolean); const before = __folds() || 'none'; __gutter(9); return [handled, before, __folds(), cm.isFolded({line: 10, ch: 0}) === true].join('|'); })()")
    #expect(collapsed == "false|none|9-13|true", "\(collapsed)")
    #expect(await page.wait(for: "document.querySelector('.CodeMirror-foldgutter-folded')"), "折起的区块箭头换成朝右的")
    #expect(await page.string("document.querySelector('.CodeMirror-foldmarker').textContent") == "...")

    // 切主题会重建编辑器：折叠随 getState 带过去
    let state = await page.string("window.ide.getState().foldState")
    #expect(state != "nil" && state.contains("hash"))
    _ = await page.evaluate("window.ide.setTheme('light')")
    await page.installHelpers()
    #expect(await page.string("__folds()") == "9-13", "切主题之后折叠还在")
    _ = await page.evaluate("window.ide.setTheme('dark')")
    await page.installHelpers()

    // 再点一次三角展开；全部折起（类、构造器、方法都折，类在最外层）/ 全部展开的区块范围
    let expanded = await page.string("(() => { __gutter(9); return __folds() || 'none'; })()")
    #expect(expanded == "none")
    let all = await page.string("(() => { const cm = __cm(); cm.execCommand('foldAll'); const folded = __folds(); cm.execCommand('unfoldAll'); return folded + '|' + (__folds() || 'none'); })()")
    #expect(all == "2-14,5-7,9-13|none", "\(all)")

    // 经 Swift 契约往返：同一份文字恢复折叠；文字变了（行号对不上）整份丢弃
    await page.render(code("/p/Counter.java", "java", sample, foldState: state))
    #expect(await page.string("__folds()") == "9-13")
    await page.render(code("/p/Counter.java", "java", "// 新的一行\n" + sample, foldState: state))
    #expect(await page.string("__folds() || 'none'") == "none")

    // Markdown 源码：标题折叠，切主题后还在（source 分支是新拼的 payload，要把 foldState 带上）
    await page.render(RenderPayload(.markdown(path: "/p/a.md", markdown: "# 一\n正文\n更多\n# 二\n尾巴\n", documentDirectory: URL(fileURLWithPath: "/p/"), view: .source, editable: true)))
    let markdown = await page.string("(() => { __gutter(0); const folded = __folds(); window.ide.setTheme('light'); return folded + '|' + window.__folds(); })()")
    #expect(markdown == "0-2|0-2", "\(markdown)")
    _ = await page.evaluate("window.ide.setTheme('dark')")
}

/// 跳到行、查找、F7 落进折起的区块时自动展开，光标落在目标上。
@Test @MainActor func revealingIntoAFoldUnfoldsIt() async throws {
    let page = EditorPage()
    let edited = sample.replacingOccurrences(of: "System.out.println(local);", with: "System.out.println(local + 1);")
    await page.render(RenderPayload(.code(path: "/p/Counter.java", text: edited, language: "java", editable: true, base: sample)))
    let fold = "(() => { const cm = __cm(); __gutter(9); cm.setCursor({line: 0, ch: 0}); return __folds(); })()"
    #expect(await page.string(fold) == "9-13")
    let reveal = await page.string("(() => { window.ide.revealLine({line: 12, ch: 8}); return [__folds() || 'none', __cm().getCursor().line, __cm().getCursor().ch].join('|'); })()")
    #expect(reveal == "none|12|8", "\(reveal)")

    #expect(await page.string(fold) == "9-13")
    let found = await page.string("(() => { window.ide.find({query: 'println', caseSensitive: true}); return [__folds() || 'none', __cm().getCursor('from').line, __cm().getSelection()].join('|'); })()")
    #expect(found == "none|11|println", "\(found)")

    #expect(await page.string(fold) == "9-13")
    let navigated = await page.string("(() => { const step = window.ide.navigateChange('next'); return [__folds() || 'none', __cm().getCursor().line, step && step.moved].join('|'); })()")
    #expect(navigated == "none|11|true", "\(navigated)")
}

/// 同名高亮：光标停在标识符上，同名的整词都标上底色（不透明的主题色，深浅两套），前景色仍是 tree-sitter 的；
/// 关键字上不标；有选区时选中的那几处不画（别盖掉选区色）；超过行数上限不标。
@Test @MainActor func identifierUnderCaretHighlightsOccurrences() async throws {
    let page = EditorPage()
    await page.render(code("/p/Counter.java", "java", sample))
    #expect(await page.wait(for: "document.querySelector('.CodeMirror[data-syntax=\"tree-sitter\"]')"))
    // count：字段声明、this.count、count + by、count++ 四处（Counter 里的 Count 大小写不同、不算）
    _ = await page.evaluate("__cm().setCursor({line: 10, ch: 21}); true")
    let four = await page.wait(for: "document.querySelectorAll('.cm-matchhighlight').length === 4")
    #expect(four)
    let lines = await page.string("[...document.querySelectorAll('.cm-matchhighlight')].map(span => __cm().getLineNumber(__cm().display.view.find(v => v.node.contains(span)).line) + ':' + span.textContent).join(',')")
    #expect(lines == "3:count,6:count,10:count,12:count", "\(lines)")
    // 底色是主题色、前景仍是 tree-sitter 给字段的颜色（两个类在同一个 span 上，各管各的属性）
    let style = await page.string("(() => { const span = [...document.querySelectorAll('.cm-matchhighlight')].find(s => /cm-ts-field/.test(s.className)); const cs = getComputedStyle(span); return cs.backgroundColor + '|' + cs.color; })()")
    #expect(style == "rgb(52, 65, 52)|rgb(199, 125, 187)", "\(style)")
    _ = await page.evaluate("window.ide.setTheme('light'); true")
    await page.installHelpers()
    _ = await page.evaluate("__cm().setCursor({line: 10, ch: 21}); true")
    #expect(await page.wait(for: "document.querySelector('.cm-matchhighlight') && getComputedStyle(document.querySelector('.cm-matchhighlight')).backgroundColor === 'rgb(237, 235, 252)'"))
    _ = await page.evaluate("window.ide.setTheme('dark'); true")
    await page.installHelpers()

    // 关键字上不标（先确认标着 count，再挪到 public 上，标记要撤掉）
    _ = await page.evaluate("__cm().setCursor({line: 10, ch: 21}); true")
    #expect(await page.wait(for: "document.querySelectorAll('.cm-matchhighlight').length === 4"))
    _ = await page.evaluate("__cm().setCursor({line: 9, ch: 6}); true")
    #expect(await page.wait(for: "document.querySelectorAll('.cm-matchhighlight').length === 0"))
    // 选中 count（双击 / 拖选出来的）：选中的那处不画，其余三处画
    _ = await page.evaluate("(() => { const cm = __cm(); const at = cm.getLine(10).search(/\\bcount\\b/); cm.setSelection({line: 10, ch: at}, {line: 10, ch: at + 5}); return true; })()")
    #expect(await page.wait(for: "__cm().getSelection() === 'count' && document.querySelectorAll('.cm-matchhighlight').length === 3"))

    // 超过行数上限不标
    let big = (0..<20_050).map { "value\($0 % 7) = value\($0 % 7) + 1" }.joined(separator: "\n")
    await page.render(code("/p/big.txt", nil, big))
    // 不等去抖的定时器：直接同步跑一次更新，看它没有装 overlay
    let bigResult = await page.string("(() => { const cm = __cm(); cm.setCursor({line: 3, ch: 2}); cm.state.occurrences.update(); return [cm.state.occurrences.overlay === null, document.querySelectorAll('.cm-matchhighlight').length].join('|'); })()")
    #expect(bigResult == "true|0", "\(bigResult)")
}

/// 没有多光标（1.7.1 用户定的，删掉了）：⌃G、⌥⇧点击、⌘点击都不加光标，⌥拖动不是列选择；⌥← 仍是导航。
/// 一次操作多处改动（程序里 setSelections 造出来，撤销多处改动也会这样）时，tree-sitter 着色与整份重新解析一致、一次撤销撤掉全部。
@Test @MainActor func editorHasOnlyOneCursor() async throws {
    let page = EditorPage()
    let edits = Locked<[String]>([])
    let navigation = Locked<[String]>([])
    page.renderer.onEdited = { _, text in edits.value.append(text) }
    page.renderer.onNavigate = { direction in navigation.value.append(direction.rawValue) }
    await page.render(code("/p/Counter.java", "java", sample))
    #expect(await page.wait(for: "document.querySelector('.CodeMirror[data-syntax=\"tree-sitter\"]')"))

    let keys = await page.string("(() => { const cm = __cm(); cm.setCursor({line: 3, ch: 17}); __key(71, {ctrlKey: true}); __key(71, {ctrlKey: true}); return String(cm.listSelections().length); })()")
    #expect(keys == "1", "⌃G 不再加选区：\(keys)")

    _ = await page.evaluate("__key(37, {altKey: true}); true")
    let navigationDeadline = Date().addingTimeInterval(10)
    while navigation.value.isEmpty, Date() < navigationDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    #expect(navigation.value == ["back"])

    let mouse = await page.string("""
    (() => { const cm = __cm(); cm.setCursor({line: 6, ch: 4});
      const click = (line, ch, mods) => {
        const at = cm.charCoords({line, ch}, 'window');
        const options = Object.assign({bubbles: true, cancelable: true, button: 0, buttons: 1, clientX: at.left + 1, clientY: (at.top + at.bottom) / 2, detail: 1}, mods);
        cm.display.scroller.dispatchEvent(new MouseEvent('mousedown', options));
        document.dispatchEvent(new MouseEvent('mouseup', Object.assign({}, options, {buttons: 0})));
      };
      click(10, 8, {altKey: true, shiftKey: true});
      const altShift = cm.listSelections().length;
      click(11, 8, {metaKey: true});
      const plain = cm.listSelections().length + ':' + cm.getCursor().line;
      const behavior = cm.getOption('configureMouse');
      return [altShift, plain, behavior(cm, 'single', {altKey: true}).unit, behavior(cm, 'single', {metaKey: true}).addNew].join('|'); })()
    """)
    #expect(mouse == "1|1:11|char|false", "\(mouse)")

    // 三处一起改成 total：一次操作多处改动，tree-sitter 增量路径（changes 批处理）要与整份重新解析一致
    let typed = await page.string("""
    (() => { const cm = __cm();
      const ranges = []; cm.getValue().split('\\n').forEach((text, line) => { const at = text.search(/\\bcount\\b/); if (at >= 0 && ranges.length < 3) ranges.push({anchor: {line, ch: at}, head: {line, ch: at + 5}}); });
      cm.setSelections(ranges);
      cm.replaceSelection('total', 'end', '+input');
      cm.refresh();
      const fresh = window.Syntax.highlightLines('java', '/p/Fresh.java', cm.getValue() + '\\n// fresh');
      const cellsOf = (nodes) => { const out = []; for (const node of nodes) {
        if (node.nodeType === 1 && node.children.length) { out.push(...cellsOf(node.childNodes)); continue; }
        const cls = node.nodeType === 1 ? ((node.className.match(/cm-ts-[a-z-]+/) || ['cm-ts-plain'])[0]) : 'cm-ts-plain';
        for (const ch of node.textContent) out.push(cls); } return out; };
      const wrong = [];
      for (let line = 0; line < cm.lineCount(); line++) {
        if (!cm.getLine(line).trim()) continue;
        const entry = cm.display.view.find(view => cm.getLineNumber(view.line) === line);
        const holder = document.createElement('div'); holder.innerHTML = fresh[line];
        if (!entry || cellsOf(entry.node.querySelector('pre').childNodes).join(',') !== cellsOf(holder.childNodes).join(',')) wrong.push(line);
      }
      return [ranges.length, cm.getValue().split('total').length - 1, wrong.join(' ')].join('|'); })()
    """)
    #expect(typed == "3|3|", "三处改了、着色与整份解析一致：\(typed)")
    let deadline = Date().addingTimeInterval(10)
    while edits.value.last.map({ !$0.contains("total") }) ?? true, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    #expect(edits.value.last?.components(separatedBy: "total").count == 4, "edited 消息带上三处都改过的全文")

    let undone = await page.string("(() => { const cm = __cm(); cm.undo(); return [cm.getValue() === \(String(reflecting: sample)), cm.historySize().undo].join('|'); })()")
    #expect(undone == "true|0", "一次撤销撤掉三处：\(undone)")
}
