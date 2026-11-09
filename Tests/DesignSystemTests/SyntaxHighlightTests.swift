import AppKit
import Core
import DesignSystem
import Foundation
import Testing
@preconcurrency import WebKit

/// tree-sitter 着色（web/syntax.js）的真渲染核对：真起 WKWebView，经 agentidea-asset: 协议加载 WASM 与查询，
/// 看关键 token 拿到的 class。一条用例一个 WebView，多种语言在同一个页面里依次渲染（别为一种语言多起一个 WebView）。
@MainActor
private final class SyntaxPage {
    let renderer = ContentRenderer()
    let window: NSWindow
    var renderedMilliseconds: [Int] = []

    init(size: CGSize = CGSize(width: 1000, height: 900)) {
        let webView = renderer.webView
        webView.frame = CGRect(origin: .zero, size: size)
        // 离屏视图要挂到窗口上才会真正排版
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        renderer.onRendered = { [weak self] _, ms in self?.renderedMilliseconds.append(ms) }
    }

    func evaluate(_ script: String) async -> Any? {
        try? await renderer.webView.evaluateJavaScript("(() => { try { return \(script) } catch (e) { return 'JS 异常：' + String(e) } })()")
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
        let before = renderedMilliseconds.count
        renderer.render(payload)
        await wait(for: "window.ide && document.getElementById('root').children.length > 0")
        // render.js 画完会 post rendered（含毫秒数），等它到了再往下走
        let deadline = Date().addingTimeInterval(10)
        while renderedMilliseconds.count == before, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        await installProbe()
    }

    func string(_ script: String) async -> String { await evaluate(script) as? String ?? "nil" }

    /// 页面里装一个取 token class 的小函数：编辑器（第 n 行里第 nth 个文字等于 text 的 span）与只读代码视图都认。
    func installProbe() async {
        _ = await evaluate("""
        window.__tokenClass = (scope, line, text, nth) => {
          const host = scope ? document.querySelector(scope) : document;
          let element;
          const cmNode = host.querySelector('.CodeMirror');
          if (cmNode) {
            const cm = cmNode.CodeMirror;
            const entry = cm.display.view.find(view => cm.getLineNumber(view.line) === line);
            element = entry && entry.node;
          } else {
            element = host.querySelectorAll('.code-view .line')[line];
          }
          if (!element) return 'no line ' + line;
          const spans = [...element.querySelectorAll('span')].filter(span => !span.children.length && span.textContent === text);
          const span = spans[nth || 0];
          return span ? span.className : 'no token ' + text;
        };
        true
        """)
    }

    /// 期望表：(行, 文字, 第几个, 期望的 cm-ts-* 类)。回不符合的条目（空就是全对）。
    func mismatches(_ expectations: [(Int, String, Int, String)], scope: String? = nil) async -> [String] {
        var wrong: [String] = []
        for (line, text, nth, expected) in expectations {
            let scopeJS = scope.map { "'\($0)'" } ?? "null"
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let actual = await evaluate("window.__tokenClass(\(scopeJS), \(line), '\(escaped)', \(nth))") as? String ?? "nil"
            if !actual.split(separator: " ").contains(Substring("cm-ts-" + expected)) {
                wrong.append("第 \(line) 行 \(text)#\(nth)：期望 \(expected)，实际 \(actual)")
            }
        }
        return wrong
    }
}

private func code(_ path: String, _ language: String?, _ text: String, editable: Bool = true) -> RenderPayload {
    RenderPayload(.code(path: path, text: text, language: language, editable: editable))
}

private let javaSample = """
package demo;

/** Doc comment. */
@Service
public class Counter<T> {
    private static final int MAX_COUNT = 10;
    static int instances = 0;
    private int count;

    public Counter(int start) {
        this.count = start;
    }

    public void run(int by) {
        int local = count + MAX_COUNT + by;
        System.out.println(local);
        instances++;
    }
}
"""

private let pythonSample = """
MAX_SIZE = 100
registry = {}


class Point:
    def __init__(self, x, y=0):
        self.x = x
        total = x + y + MAX_SIZE
        print(str(total), registry)


def walk(root):
    return walk(root)
"""

private let goSample = """
package main

var cache = map[string]int{}

func (s *Server) Handle(req string, n int) int {
\ttotal := n + len(req)
\ts.count += total
\tfmt.Println(cache)
\treturn total
}
"""

private let typeScriptSample = """
let globalCount = 0;

class Service {
  name: string;
  run(input: string): void {
    const local = this.name + input;
    console.log(local, globalCount);
  }
}

function compute(a: number): number {
  return Math.max(a, globalCount);
}
"""

private let javaScriptSample = """
let counter = 0;
function main(argv) {
  const w = new Widget(argv);
  return w.render(counter);
}
"""

private let cppSample = """
static int g_count = 0;

class Buffer {
public:
    int size() const { return size_; }
private:
    int size_;
};

int compute(int a, const int *ptr) {
    int local = a + *ptr + g_count;
    printf("%d", local);
    return local;
}
"""

private let tsxSample = """
export function App({ title }: Props) {
  return <div className="app">{title}</div>;
}
"""

/// 每种核心语言一段样例：函数声明 vs 调用、参数（声明与函数体里的引用）、字段、常量 / 静态、局部 vs 全局、类型参数、注解、self。
@Test @MainActor func treeSitterColorsCoreLanguagesLikeIDEA() async throws {
    let page = SyntaxPage()
    let cases: [(RenderPayload, [(Int, String, Int, String)])] = [
        (code("/p/Counter.java", "java", javaSample), [
            (2, "/** Doc comment. */", 0, "doc"), (3, "@Service", 0, "annotation"), (4, "class", 0, "keyword"), (4, "T", 0, "type-param"),
            (5, "MAX_COUNT", 0, "constant"), (6, "instances", 0, "static"), (7, "count", 0, "field"),
            (9, "Counter", 0, "decl"), (9, "start", 0, "param"), (10, "count", 0, "field"), (10, "start", 0, "param"),
            (13, "run", 0, "decl"), (13, "by", 0, "param"),
            (14, "local", 0, "local"), (14, "count", 0, "field"), (14, "MAX_COUNT", 0, "constant"), (14, "by", 0, "param"),
            (15, "println", 0, "call"), (15, "local", 0, "local"), (16, "instances", 0, "static"),
        ]),
        (code("/p/point.py", "python", pythonSample), [
            (0, "MAX_SIZE", 0, "constant"), (1, "registry", 0, "global"), (4, "Point", 0, "type"),
            (5, "__init__", 0, "decl"), (5, "self", 0, "self"), (5, "x", 0, "param"),
            (6, "x", 0, "field"), (6, "x", 1, "param"), (7, "total", 0, "local"), (7, "y", 0, "param"),
            (8, "print", 0, "builtin"), (8, "str", 0, "builtin"), (8, "registry", 0, "global"),
            (11, "walk", 0, "decl"), (12, "walk", 0, "call"), (12, "root", 0, "param"),
        ]),
        (code("/p/server.go", "go", goSample), [
            (2, "cache", 0, "global"), (4, "s", 0, "param"), (4, "Handle", 0, "decl"), (4, "n", 0, "param"), (4, "string", 0, "keyword"),
            (5, "total", 0, "local"), (5, "n", 0, "param"), (5, "len", 0, "builtin"), (6, "count", 0, "field"),
            (7, "Println", 0, "call"), (7, "cache", 0, "global"),
        ]),
        (code("/p/service.ts", "typescript", typeScriptSample), [
            (0, "globalCount", 0, "global"), (3, "name", 0, "field"), (4, "run", 0, "decl"), (4, "input", 0, "param"),
            (5, "local", 0, "local"), (5, "name", 0, "field"), (5, "input", 0, "param"),
            (6, "log", 0, "call"), (6, "globalCount", 0, "global"),
            (10, "compute", 0, "decl"), (10, "a", 0, "param"), (11, "max", 0, "call"), (11, "a", 0, "param"),
        ]),
        (code("/p/main.js", "javascript", javaScriptSample), [
            (0, "counter", 0, "global"), (1, "main", 0, "decl"), (1, "argv", 0, "param"), (2, "w", 0, "local"),
            (2, "Widget", 0, "type"), (3, "render", 0, "call"), (3, "counter", 0, "global"),
        ]),
        (code("/p/buffer.cpp", "cpp", cppSample), [
            (0, "g_count", 0, "global"), (4, "size", 0, "decl"), (4, "size_", 0, "field"), (6, "size_", 0, "field"),
            (9, "compute", 0, "decl"), (9, "a", 0, "param"), (9, "ptr", 0, "param"),
            (10, "local", 0, "local"), (10, "ptr", 0, "param"), (10, "g_count", 0, "global"), (11, "printf", 0, "call"),
        ]),
        (code("/p/package.json", "json", "{\n  \"name\": \"demo\",\n  \"count\": 1\n}\n"), [
            (1, "\"name\"", 0, "field"), (1, "\"demo\"", 0, "string"), (2, "1", 0, "number"),
        ]),
        (code("/p/app.tsx", "typescript", tsxSample), [
            (0, "App", 0, "decl"), (0, "title", 0, "param"), (1, "div", 0, "tag"), (1, "title", 0, "param"),
        ]),
    ]
    for (payload, expectations) in cases {
        await page.render(payload)
        let ready = await page.wait(for: "document.querySelector('.CodeMirror[data-syntax=\"tree-sitter\"]')")
        #expect(ready, "\(payload.kindName) 没换上 tree-sitter 着色")
        let wrong = await page.mismatches(expectations)
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
    }

    // 只读代码视图：同一套 class。语法包已经加载过，这一次同步画出来
    await page.render(code("/p/Counter.java", "java", javaSample, editable: false))
    let staticSyntax = await page.string("document.querySelector('.code-view').dataset.syntax")
    #expect(staticSyntax == "tree-sitter")
    let staticWrong = await page.mismatches([(9, "Counter", 0, "decl"), (10, "start", 0, "param"), (14, "count", 0, "field"), (6, "instances", 0, "static")])
    #expect(staticWrong.isEmpty, "\(staticWrong.joined(separator: "\n"))")
}

/// 编辑后增量更新：tree.edit + 带旧树重解析，新加的局部变量、参数引用、跨行注释都要跟上；中文在前面也不能错位（UTF-16 列）。
@Test @MainActor func treeSitterFollowsEditsIncrementally() async throws {
    let page = SyntaxPage()
    await page.render(code("/p/Counter.java", "java", javaSample))
    let ready = await page.wait(for: "document.querySelector('.CodeMirror[data-syntax=\"tree-sitter\"]')")
    #expect(ready)
    _ = await page.evaluate("""
    (() => {
      const cm = document.querySelector('.CodeMirror').CodeMirror;
      cm.replaceRange('        int fresh = start; // 中文注释 count\\n', {line: 11, ch: 0});
      cm.replaceRange('/* 注释 */ ', {line: 15, ch: 8});
      return true;
    })()
    """)
    var wrong = await page.mismatches([
        (11, "fresh", 0, "local"), (11, "start", 0, "param"), (11, "// 中文注释 count", 0, "comment"),
        (15, "/* 注释 */", 0, "comment"), (15, "local", 0, "local"), (15, "count", 0, "field"), (15, "by", 0, "param"),
        (16, "println", 0, "call"),
    ])
    #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")

    // 在空行上敲开一段块注释：它一直延到下面那个 */，改动之外的那一行也得重新着色成注释
    _ = await page.evaluate("document.querySelector('.CodeMirror').CodeMirror.replaceRange('/*', {line: 13, ch: 0}); true")
    // （编辑器里 overlay 不改底下 mode 的 token 边界：行首缩进与后面的注释正文是两个 span，各自带 cm-ts-comment）
    wrong = await page.mismatches([(14, "    ", 0, "comment"), (14, "public void run(int by) {", 0, "comment")])
    #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
    // 撤销回来，着色恢复
    _ = await page.evaluate("document.querySelector('.CodeMirror').CodeMirror.undo(); true")
    wrong = await page.mismatches([(14, "run", 0, "decl"), (15, "by", 0, "param"), (16, "println", 0, "call")])
    #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
    // 底下 CodeMirror mode 的 token 类型还在（overlay 不改它）：括号匹配、自动闭合引号看的是它
    let baseType = await page.string("document.querySelector('.CodeMirror').CodeMirror.getTokenTypeAt({line: 4, ch: 2})")
    #expect(baseType == "keyword")
}

/// 一个 operation 里有多处改动（后一处在前面、缩进多行、撤销多处改动）：编辑器 overlay 的着色要和对同一份文本
/// 从头解析的结果逐字一致。CodeMirror 的 change 是 operation 结束后才补发的，按 change 逐个 tree.edit 会错位且不自愈。
@Test @MainActor func treeSitterHandlesSeveralChangesInOneOperation() async throws {
    let page = SyntaxPage()
    await page.render(code("/p/Counter.java", "java", javaSample))
    let ready = await page.wait(for: "document.querySelector('.CodeMirror[data-syntax=\"tree-sitter\"]')")
    #expect(ready)
    _ = await page.evaluate("""
    (() => {
      window.__compare = () => {
        const cm = document.querySelector('.CodeMirror').CodeMirror;
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
          if (!entry) { wrong.push(line + ': 没画出来'); continue; }
          const holder = document.createElement('div'); holder.innerHTML = fresh[line];
          const actual = cellsOf(entry.node.querySelector('pre').childNodes).join(','), expected = cellsOf(holder.childNodes).join(',');
          if (actual !== expected) wrong.push(line + ': ' + cm.getLine(line));
        }
        return wrong.join(' / ');
      };
      return true;
    })()
    """)
    // 先改第 14 行再改第 0 行（第二处在前面，第一处的位置跟着变）
    let twoEdits = await page.string("""
    (() => { const cm = document.querySelector('.CodeMirror').CodeMirror;
      cm.operation(() => { cm.replaceRange('int extra = by + count; ', {line: 14, ch: 8}); cm.replaceRange('/* 头 */ import x.Y;\\n', {line: 0, ch: 0}); });
      return window.__compare(); })()
    """)
    #expect(twoEdits == "", "\(twoEdits)")
    // 选中几行按 Tab（indentMore 每行一处改动），再撤销
    let indented = await page.string("""
    (() => { const cm = document.querySelector('.CodeMirror').CodeMirror;
      cm.setSelection({line: 14, ch: 0}, {line: 18, ch: 5}); cm.execCommand('indentMore');
      return window.__compare(); })()
    """)
    #expect(indented == "", "\(indented)")
    let undone = await page.string("""
    (() => { const cm = document.querySelector('.CodeMirror').CodeMirror; cm.undo(); cm.undo(); return window.__compare() + '|' + cm.getValue().startsWith('package'); })()
    """)
    #expect(undone == "|true", "\(undone)")
}

/// 只读视图首次打开某种语言：先用 highlight.js 画、语法包到了再用 tree-sitter 重画。重画不能抹掉刚做的定位
/// （跳到行标出的那一行、全项目搜索打开结果时选中的命中）。
@Test @MainActor func upgradingAStaticViewKeepsTheRevealedSelection() async throws {
    let page = SyntaxPage()
    await page.render(.message("x", "y"))
    await page.render(RenderPayload(.code(path: "/p/Counter.java", text: javaSample, language: "java"),
                                    revealLine: EditorCursor(line: 15, ch: 19), revealLength: 7))
    let upgraded = await page.wait(for: "document.querySelector('.code-view[data-syntax=\"tree-sitter\"]')")
    #expect(upgraded)
    let state = await page.string("""
    [window.getSelection().toString(), [...document.querySelectorAll('.code-view .line')].findIndex(line => line.classList.contains('current-line')),
     document.querySelectorAll('.code-view .cm-ts-call').length > 0].join('|')
    """)
    #expect(state == "println|15|true", "\(state)")
}

/// WASM / 语法包加载失败：编辑器保留 CodeMirror 的 mode、只读视图用 highlight.js，页面不能空白。
@Test @MainActor func treeSitterFailureFallsBackToTheOldHighlighting() async throws {
    let page = SyntaxPage()
    await page.render(.message("x", "y"))
    _ = await page.evaluate("window.Syntax.resetForTesting({ fail: true }); true")

    await page.render(code("/p/main.js", "javascript", javaScriptSample))
    // 等加载失败落地（loaded 里记下 failed），再看编辑器
    let failed = await page.wait(for: "window.Syntax.whenReady('javascript', '/p/main.js', 'x') === null")
    #expect(failed)
    let editorState = await page.evaluate("""
    [!!document.querySelector('.CodeMirror'), document.querySelector('.CodeMirror').dataset.syntax || 'none',
     document.querySelectorAll('.CodeMirror .cm-keyword').length > 0, document.querySelector('.CodeMirror').CodeMirror.getValue().length > 0].join('|')
    """) as? String
    #expect(editorState == "true|none|true|true", "\(editorState ?? "nil")")

    await page.render(code("/p/Counter.java", "java", javaSample, editable: false))
    let javaFailed = await page.wait(for: "window.Syntax.whenReady('java', '/p/Counter.java', 'x') === null")
    #expect(javaFailed)
    let staticState = await page.evaluate("""
    [document.querySelectorAll('.code-view .line').length, document.querySelector('.code-view').dataset.syntax || 'none',
     document.querySelectorAll('.code-view .hljs-keyword').length > 0].join('|')
    """) as? String
    #expect(staticState == "19|none|true", "\(staticState ?? "nil")")
}

/// 主题：新增的语义色变量深浅两套都在、值不同；token 的颜色跟着变量走，切主题不重新解析（语法树从缓存里拿回来）。
@Test @MainActor func treeSitterColorsFollowTheThemeVariables() async throws {
    let page = SyntaxPage()
    await page.render(code("/p/Counter.java", "java", javaSample))
    let ready = await page.wait(for: "document.querySelector('.CodeMirror[data-syntax=\"tree-sitter\"]')")
    #expect(ready)
    let variables = ["--syn-function-decl", "--syn-function-call", "--syn-parameter", "--syn-local", "--syn-field", "--syn-static",
                     "--syn-type", "--syn-type-param", "--syn-builtin", "--syn-self", "--syn-escape", "--syn-doc-comment", "--syn-operator", "--syn-label"]
    let read = "JSON.stringify(\(variables).map(name => getComputedStyle(document.documentElement).getPropertyValue(name).trim()))"
    let probe = """
    (() => {
      const span = [...document.querySelectorAll('.CodeMirror-line span')].find(s => s.textContent === 'start' && s.className.includes('cm-ts-param'));
      return span ? getComputedStyle(span).color : 'missing';
    })()
    """
    let dark = try JSONDecoder().decode([String].self, from: Data((await page.evaluate(read) as? String ?? "[]").utf8))
    let darkParam = await page.evaluate(probe) as? String
    _ = await page.evaluate("window.__parses = 0; const original = window.TreeSitter.Parser.prototype.parse; window.TreeSitter.Parser.prototype.parse = function (...args) { window.__parses++; return original.apply(this, args); }; true")
    page.renderer.setTheme(light: true)
    let switched = await page.wait(for: "document.documentElement.classList.contains('light') && document.querySelector('.CodeMirror[data-syntax=\"tree-sitter\"]')")
    #expect(switched)
    let light = try JSONDecoder().decode([String].self, from: Data((await page.evaluate(read) as? String ?? "[]").utf8))
    let lightParam = await page.evaluate(probe) as? String
    #expect(dark.count == variables.count && dark.allSatisfy { $0.hasPrefix("#") }, "深色缺变量：\(dark)")
    #expect(light.count == variables.count && light.allSatisfy { $0.hasPrefix("#") }, "浅色缺变量：\(light)")
    #expect(dark != light)
    #expect(darkParam == "rgb(86, 193, 214)", "深色参数色：\(darkParam ?? "nil")")
    #expect(lightParam == "rgb(42, 140, 124)", "浅色参数色：\(lightParam ?? "nil")")
    let parses = await page.evaluate("window.__parses") as? Int
    #expect(parses == 0, "切主题重建编辑器时不该重新解析：\(String(describing: parses))")
}

/// 并排 / 单列的可编辑 diff：两侧编辑器都换上 tree-sitter；diff 的行底色与词级高亮照旧。
@Test @MainActor func treeSitterColorsBothSidesOfAnEditableDiff() async throws {
    let page = SyntaxPage()
    let old = pythonSample
    let new = pythonSample.replacingOccurrences(of: "total = x + y + MAX_SIZE", with: "total = x * y + MAX_SIZE")
    for mode in DiffViewMode.allCases {
        await page.render(RenderPayload(.diff(path: "point.py", language: "python", diff: FileDiff(oldPath: nil, newPath: nil, isBinary: false, hunks: []), mode: mode, emptyReason: nil,
                                              edit: DiffEdit(oldText: old, newText: new, filePath: "/p/point.py"))))
        let panes = mode == .sideBySide ? 2 : 1
        let colored = await page.wait(for: "document.querySelectorAll('.CodeMirror[data-syntax=\"tree-sitter\"]').length === \(panes)")
        #expect(colored, "\(mode)")
        let scope = mode == .sideBySide ? ".CodeMirror-merge-editor" : ".diff-host"
        let wrong = await page.mismatches([(7, "total", 0, "local"), (7, "y", 0, "param"), (5, "__init__", 0, "decl")], scope: scope)
        #expect(wrong.isEmpty, "\(mode): \(wrong.joined(separator: "\n"))")
        let decoration = mode == .sideBySide ? ".CodeMirror-merge-l-inserted" : ".cm-diff-added"
        let decorated = await page.wait(for: "document.querySelector('\(decoration)')")
        #expect(decorated, "\(mode)：diff 的词级高亮 / 行底色没了")
    }
}

/// 5000 行的 Java：语法包没加载时先用 CodeMirror 的 mode 画（打开不变慢），加载完换上；已加载时同步解析。
/// 毫秒数打到 stdout（render.js 自报的 rendered），给报告用；断言只卡一个很宽的上限。
@Test @MainActor func treeSitterOpensFiveThousandLinesQuickly() async throws {
    let method = """
        public int increment(int by) {
            int local = count + by;
            System.out.println(local);
            return Math.max(count, by);
        }

    """
    var text = "package demo;\npublic class Big {\n    private int count;\n"
    while text.split(separator: "\n", omittingEmptySubsequences: false).count < 5000 { text += method }
    text += "}\n"
    let page = SyntaxPage()
    await page.render(.message("x", "y"))
    let started = Date()
    await page.render(code("/p/Big.java", "java", text))
    let firstRender = page.renderedMilliseconds.last ?? -1
    let swapped = await page.wait(for: "document.querySelector('.CodeMirror[data-syntax=\"tree-sitter\"]')", timeout: 15)
    #expect(swapped)
    let colored = Int(Date().timeIntervalSince(started) * 1000)
    // 换一个文件再回来：这次语法包已就绪，同步解析
    await page.render(.message("x", "y"))
    await page.render(code("/p/Big2.java", "java", text + "// 2\n"))
    let warmRender = page.renderedMilliseconds.last ?? -1
    let warmSyntax = await page.string("document.querySelector('.CodeMirror').dataset.syntax")
    #expect(warmSyntax == "tree-sitter", "语法包已就绪时应同步换上 tree-sitter")
    // 编辑一笔的耗时（增量解析 + 作用域 + 视口重着色）
    let editMs = await page.evaluate("""
    (() => { const cm = document.querySelector('.CodeMirror').CodeMirror; const t = performance.now();
      cm.replaceRange('x', {line: 2500, ch: 8}); cm.refresh(); return Math.round(performance.now() - t); })()
    """) as? Int ?? -1
    await page.render(code("/p/Big3.java", "java", text + "// 3\n", editable: false))
    let staticRender = page.renderedMilliseconds.last ?? -1
    print("tree-sitter 5000 行 Java：首次打开 rendered \(firstRender)ms（CodeMirror mode 先画）、到换上 tree-sitter 共 \(colored)ms；" +
          "语法包已就绪时打开 rendered \(warmRender)ms；编辑一笔 \(editMs)ms；只读视图 rendered \(staticRender)ms")
    #expect(firstRender >= 0 && firstRender < 3000)
    #expect(warmRender >= 0 && warmRender < 3000)
}
