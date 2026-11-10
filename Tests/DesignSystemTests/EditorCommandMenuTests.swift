import Core
import DesignSystem
import Foundation
import Testing

/// 送出去的内容会画成哪一种编辑器：与 render.js 的分支一致（「代码」菜单据此灰掉）。
@Test func payloadsReportWhichEditorTheyMount() {
    let directory = URL(fileURLWithPath: "/p/")
    let diff = UnifiedDiffParser.parse("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
    let cases: [(RenderPayload.Content, EditorKind?, String)] = [
        (.code(path: "/p/a.swift", text: "x", language: "swift", editable: true), .plain, "可编辑的代码"),
        (.code(path: "/p/big.swift", text: "x", language: "swift", editable: false), nil, "只读的大文件是静态视图"),
        (.markdown(path: "/p/a.md", markdown: "# x", documentDirectory: directory, view: .source, editable: true), .plain, "Markdown 源码"),
        (.markdown(path: "/p/a.md", markdown: "# x", documentDirectory: directory, view: .split, editable: true), .plain, "Markdown 分栏"),
        (.markdown(path: "/p/a.md", markdown: "# x", documentDirectory: directory, view: .preview, editable: true), nil, "Markdown 预览没有编辑器"),
        (.markdown(path: "/p/a.md", markdown: "# x", documentDirectory: directory, view: .split, editable: false), nil, "只读的分栏退回预览"),
        (.markdown(path: "/p/a.md", markdown: "# x", documentDirectory: directory, view: .source, editable: false), nil, "只读的源码是静态视图"),
        (.diff(path: "x", language: nil, diff: diff, mode: .unified, emptyReason: nil,
               edit: DiffEdit(oldText: "a\n", newText: "b\n", filePath: "/p/x")), .diff, "可编辑的全文 diff"),
        (.diff(path: "x", language: nil, diff: diff, mode: .sideBySide, emptyReason: nil,
               edit: DiffEdit(oldText: "a\n", newText: "b\n", filePath: "/p/x", readOnly: true)), .diff, "只读的版本对比也是编辑器（能选、能多光标）"),
        (.diff(path: "x", language: nil, diff: diff, mode: .sideBySide, emptyReason: nil), nil, "补丁表格"),
        (.html(path: "/p/a.html", text: "<p>", documentDirectory: directory), nil, "HTML 预览"),
        (.image(path: "/p/a.png", url: URL(fileURLWithPath: "/p/a.png"), sizeText: "1×1"), nil, "图片"),
        (.message(title: "", detail: ""), nil, "提示页"),
    ]
    for (content, expected, label) in cases {
        #expect(content.editorKind == expected, "\(label)")
    }
}

/// 规矩「每个快捷键都要有菜单入口」的守卫：render.js 里 extraKeys 绑的每个键，要么是 `EditorCommand` 的一项（「代码」菜单），
/// 要么在下面的清单里写明入口在哪；页面的 `EDITOR_COMMANDS` 与 `EditorCommand` 一一对应（菜单调进去的名字都认得）。
@Test func editorShortcutsAllHaveMenuEntries() throws {
    let shell = try #require(WebResources.shellURL)
    let script = try String(contentsOf: shell.deletingLastPathComponent().appendingPathComponent("render.js"), encoding: .utf8)
    let lines = script.components(separatedBy: "\n")

    /// 从 `<marker> {` 那一行起到同一缩进的 `}` 为止，每一行开头的键名（`Tab:`、`"Shift-Tab":`）。
    func keys(inBlocksStartingWith marker: String) -> [String] {
        var result: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasSuffix(marker + " {") || line.trimmingCharacters(in: .whitespaces).hasPrefix(marker + " {"),
                  let indent = line.firstIndex(where: { $0 != " " }) else { index += 1; continue }
            let prefix = String(line[..<indent])
            index += 1
            while index < lines.count, !(lines[index].hasPrefix(prefix + "}")) {
                if let match = lines[index].firstMatch(of: #/^\s*(?:"([^"]+)"|([A-Za-z][\w-]*))\s*:/#) {
                    result.append(String(match.1 ?? match.2 ?? ""))
                }
                index += 1
            }
        }
        return result
    }

    let bound = keys(inBlocksStartingWith: "extraKeys:")
    #expect(bound.contains("Ctrl-G") && bound.contains("Cmd--"), "没解析出 extraKeys：\(bound)")
    // 不归「代码」菜单的：通用的缩进键，与「视图」菜单里的后退 / 前进（⌥← / ⌥→）
    let coveredElsewhere: Set<String> = ["Tab", "Shift-Tab", "Alt-Left", "Alt-Right"]
    let commandKeys = Set(EditorCommand.allCases.map(\.codeMirrorKey))
    let orphans = Set(bound).subtracting(commandKeys).subtracting(coveredElsewhere)
    #expect(orphans.isEmpty, "这些键只有快捷键、没有菜单入口：\(orphans.sorted())。在 Core/EditorCommand 加一项并挂进「代码」菜单")

    let pageCommands = Set(keys(inBlocksStartingWith: "const EDITOR_COMMANDS ="))
    #expect(pageCommands == Set(EditorCommand.allCases.map(\.rawValue)), "render.js 的 EDITOR_COMMANDS 与 Core/EditorCommand 不一致：\(pageCommands)")
    #expect(script.contains("editorCommand(name)"), "render.js 缺 window.ide.editorCommand")
}
