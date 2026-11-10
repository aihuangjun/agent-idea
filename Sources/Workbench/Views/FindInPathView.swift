import AppKit
import Core
import DesignSystem
import SwiftUI

/// 「查找」工具窗口（IDEA 的 Find in Path，⌃⇧F）：输入框 + 选项（区分大小写 / 全词 / 正则）+ 文件掩码，
/// 下面是按文件分组的结果。照现有列表的交互：按下即选中并用预览标签打开、跳到那一行并选中命中，双击固定标签；
/// ↑ ↓ 在结果间移动、回车用固定标签打开（照 IDEA 的 Find 窗口）；右键「复制路径和行号」。
struct FindInPathView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var search: TextSearchController
    @State private var clicks = DoubleClickDetector(interval: NSEvent.doubleClickInterval)
    @FocusState private var isListFocused: Bool
    @State private var isFieldFocused = false

    init(session: ProjectSession) {
        self.session = session
        self.search = session.textSearch
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowHeader(title: "查找") {
                if search.isSearching {
                    ProgressView().controlSize(.mini).padding(.trailing, 4)
                }
                IconButton(ToolWindowIcon.refresh, help: "重新搜索：磁盘上的文件又变了（Agent 改过）之后", size: 22) { search.refresh() }
                    .disabled(search.text.isEmpty)
                IconButton(ToolWindowIcon.expandAll, help: "全部展开", size: 22) { search.expandAll() }
                    .disabled(search.collapsedFiles.isEmpty)
                IconButton(ToolWindowIcon.collapseAll, help: "全部折叠", size: 22) { search.collapseAll() }
                    .disabled(search.result?.files.isEmpty ?? true)
            }
            queryBar
            statusLine
            results
        }
        .background(Theme.panel)
    }

    // MARK: - 输入

    private var queryBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                // NSTextField 直包：⌃⇧F 时要从 WebView 手里把焦点抢过来，SwiftUI 的 FocusState 做不到
                FocusedTextField(text: $search.text, placeholder: "在项目中查找文字", focusRequests: search.focusRequests) { key in
                    switch key {
                    case .up: search.moveSelection(by: -1)
                    case .down: search.moveSelection(by: 1)
                    case .submit: openSelected(pinned: true)
                    case .cancel: session.focusContent()
                    }
                    return true
                } onFocusChange: { isFieldFocused = $0 }
                if !search.text.isEmpty {
                    Button { search.text = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                    }
                    .buttonStyle(.plain)
                    .toolTip("清空")
                }
                OptionToggle(label: "Cc", help: "区分大小写", isOn: $search.caseSensitive)
                OptionToggle(label: "W", help: "全词匹配", isOn: $search.wholeWords)
                OptionToggle(label: ".*", help: "正则表达式（PCRE 语法）", isOn: $search.isRegex)
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBackground))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isFieldFocused ? Theme.accent : Theme.border, lineWidth: 1))
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(Theme.mutedText)
                    .toolTip("文件掩码：逗号分隔，! 开头是排除；不带 / 的按文件名匹配，带 / 的按相对路径（支持 **）")
                TextField("", text: $search.fileMask, prompt: Text("文件掩码，如 *.swift, !*Tests.swift").foregroundColor(Theme.mutedText))
                    .textFieldStyle(.plain)
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.text)
                if !search.fileMask.isEmpty {
                    Button { search.fileMask = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.mutedText)
                    }
                    .buttonStyle(.plain)
                    .toolTip("清除掩码")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBackground))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// 「N 处匹配，M 个文件」/ 结果过多 / 出错。
    @ViewBuilder private var statusLine: some View {
        let text: String? = {
            if let error = search.error { return error }
            guard let result = search.result else { return search.isSearching ? "正在搜索…" : nil }
            if result.files.isEmpty { return "没有找到" }
            let summary = "\(result.matchCount) 处匹配，\(result.files.count) 个文件"
            return result.isTruncated ? "结果过多，只显示前 \(result.matchCount) 处 · \(result.files.count) 个文件" : summary
        }()
        if let text {
            Text(text)
                .font(Theme.smallFont)
                .foregroundStyle(search.error != nil ? Theme.danger : (search.result?.isTruncated == true ? Theme.warning : Theme.secondaryText))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
                .textSelection(.enabled)
        }
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    // MARK: - 结果

    @ViewBuilder private var results: some View {
        if let result = search.result, !result.files.isEmpty {
            list(result)
        } else if search.text.isEmpty {
            ToolWindowEmptyState(
                title: "在项目中查找",
                detail: "输入要找的文字（⌃⇧F；编辑器里选中一段再按会自动填上）。git 仓库里包括还没 add 的新文件，不含被 .gitignore 忽略的；搜的是磁盘上的内容，没保存的改动不算。"
            )
        } else {
            Spacer()
        }
    }

    private func list(_ result: TextSearchResult) -> some View {
        let selected = search.selected
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(result.files) { file in
                        let isCollapsed = search.collapsedFiles.contains(file.path)
                        SearchFileRow(file: file, isCollapsed: isCollapsed) {
                            isListFocused = true
                            search.toggleCollapsed(file.path)
                        } copyPath: {
                            copy(file.path)
                        }
                        .id(Self.rowID(file.path, nil))
                        if !isCollapsed {
                            ForEach(file.lines) { line in
                                let hit = TextSearchController.Hit(path: file.path, line: line.line)
                                SearchLineRow(line: line, isSelected: hit == selected) {
                                    isListFocused = true
                                    search.select(hit)
                                    session.openSearchResult(path: file.path, line: line, pinned: false)
                                } release: { isClick in
                                    if isClick, clicks.registerClick(on: Self.rowID(file.path, line.line)) {
                                        session.openSearchResult(path: file.path, line: line, pinned: true)
                                    }
                                } copyReference: {
                                    copy(FileReference.format(path: file.path, lines: line.line...line.line))
                                }
                                .id(Self.rowID(file.path, line.line))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isListFocused)
            .onKeyPress(.upArrow) { search.moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { search.moveSelection(by: 1); return .handled }
            .onKeyPress(.return) { openSelected(pinned: true); return .handled }
            .onChange(of: search.selected) { _, hit in
                guard let hit else { return }
                proxy.scrollTo(Self.rowID(hit.path, hit.line))
            }
        }
    }

    private static func rowID(_ path: String, _ line: Int?) -> String {
        line.map { "line:\($0):\(path)" } ?? "file:" + path
    }

    private func openSelected(pinned: Bool) {
        guard let hit = search.selected, let line = search.line(for: hit) else { return }
        session.openSearchResult(path: hit.path, line: line, pinned: pinned)
    }

    private func copy(_ text: String) {
        Desktop.copyToClipboard(text)
        session.notify("已复制 \(text)")
    }
}

/// 输入框右边的选项开关（Cc / W / .*），照 IDEA 的样子：开着的有底色。
private struct OptionToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? Theme.text : Theme.secondaryText)
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? Theme.selection : (isHovering ? Theme.hover : .clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .toolTip(isOn ? "\(help)：开" : "\(help)：关")
    }
}

/// 文件行：折叠箭头 + 图标 + 文件名 + 相对目录 + 匹配数。点一下折叠 / 展开。
private struct SearchFileRow: View {
    let file: TextSearchFile
    let isCollapsed: Bool
    let toggle: () -> Void
    let copyPath: () -> Void
    @State private var isHovering = false

    var body: some View {
        let icon = FileIcon.file(named: file.name)
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondaryText).frame(width: 12)
            Image(systemName: icon.systemName).font(.system(size: 12)).foregroundStyle(icon.color).frame(width: 16)
            Text(file.name).font(Theme.uiFont).foregroundStyle(Theme.text).lineLimit(1).layoutPriority(1)
            if !file.directory.isEmpty {
                Text(file.directory).font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1).truncationMode(.head)
            }
            Text("\(file.matchCount)").font(Theme.smallFont).foregroundStyle(Theme.mutedText).layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.treeRowHeight)
        .background(Rectangle().fill(isHovering ? Theme.hover.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onPress(modifiers: { _, modifiers in if !modifiers.contains(.control) { toggle() } })
        .toolTip(file.path)
        .contextMenu {
            Button("复制路径") { copyPath() }
        }
    }
}

/// 匹配行：行号 + 这一行的文字（去掉缩进，过长的以命中为中心截一段），命中部分高亮。
private struct SearchLineRow: View {
    let line: TextSearchLine
    let isSelected: Bool
    let press: () -> Void
    let release: (Bool) -> Void
    let copyReference: () -> Void
    @State private var isHovering = false
    @State private var isPlainPress = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(line.line)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.mutedText)
                .frame(minWidth: 28, alignment: .trailing)
            Text(Self.highlighted(TextSearchSnippet.make(line)))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
        .padding(.trailing, 10)
        .frame(height: Theme.treeRowHeight)
        .background(Rectangle().fill(isSelected ? Theme.selection : (isHovering ? Theme.hover.opacity(0.5) : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // ⌃点击是右键菜单：不选中、不打开（与变更列表一个规矩）
        .onPress(modifiers: { _, modifiers in
            isPlainPress = !modifiers.contains(.control)
            if isPlainPress { press() }
        }, release: { isClick in
            if isPlainPress { release(isClick) }
        })
        .contextMenu {
            Button("复制路径和行号") { copyReference() }
        }
    }

    /// 按 UTF-16 下标切出命中的那几段上色。不用 `AttributedString.index(_:offsetByCharacters:)`：范围是 UTF-16 的，emoji 会错位。
    static func highlighted(_ snippet: TextSearchSnippet) -> AttributedString {
        let text = snippet.text
        let length = text.utf16.count
        func slice(_ from: Int, _ to: Int) -> AttributedString {
            let start = String.Index(utf16Offset: from, in: text), end = String.Index(utf16Offset: to, in: text)
            return AttributedString(String(text[start..<end]))
        }
        var result = AttributedString()
        var cursor = 0
        for range in snippet.ranges where range.lowerBound >= cursor && range.upperBound <= length {
            result += slice(cursor, range.lowerBound)
            var hit = slice(range.lowerBound, range.upperBound)
            hit.foregroundColor = Theme.accent
            hit.backgroundColor = Theme.accent.opacity(0.18)
            hit.font = .system(size: 12, weight: .bold, design: .monospaced)
            result += hit
            cursor = range.upperBound
        }
        result += slice(cursor, length)
        return result
    }
}
