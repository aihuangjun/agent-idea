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
                    .disabled(search.text.isEmpty || search.visiblePin != nil)
                IconButton("arrow.left.arrow.right", help: "在项目中替换", size: 22) { session.showProjectReplace() }
                    .disabled(search.replacementResult?.files.isEmpty != false)
                IconButton(ToolWindowIcon.expandAll, help: "全部展开", size: 22) { search.expandAll() }
                    .disabled(!search.hasCollapsedGroups)
                IconButton(ToolWindowIcon.collapseAll, help: "全部折叠", size: 22) { search.collapseAll() }
                    .disabled(search.displayedResult?.files.isEmpty ?? true)
            }
            if !search.pinnedResults.isEmpty { resultTabs }
            if search.visiblePin == nil { queryBar }
            statusLine
            if search.displayedResult?.files.isEmpty == false { resultControls }
            results
        }
        .background(Theme.panel)
    }

    // MARK: - 输入

    private var resultTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Button(search.visiblePin == nil ? "当前查找" : "继续查找") { search.resumeSearch() }.buttonStyle(.plain)
                    .foregroundStyle(search.visiblePin == nil ? Theme.accent : Theme.text)
                ForEach(search.pinnedResults) { pin in
                    HStack(spacing: 4) {
                        Button(pin.query.text) { search.selectPin(pin.id) }.buttonStyle(.plain).lineLimit(1)
                            .foregroundStyle(search.visiblePin == pin.id ? Theme.accent : Theme.text)
                            .toolTip(scopeTitle(pin.scope) + " · " + pin.query.text)
                            .accessibilityAddTraits(search.visiblePin == pin.id ? .isSelected : [])
                        IconButton("xmark", help: "关闭这组结果", size: 16) { search.closePin(pin.id) }
                    }
                }
            }.padding(.horizontal, 8).padding(.vertical, 3)
        }.scrollIndicators(.hidden).font(Theme.smallFont)
    }

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
                Menu("文件筛选") {
                    Button("所有文件") { search.fileMask = "" }
                    Button("Java（*.java）") { search.fileMask = "*.java" }
                    Button("Swift（*.swift）") { search.fileMask = "*.swift" }
                    Button("Markdown（*.md）") { search.fileMask = "*.md" }
                    Button("网页（*.html, *.css, *.js）") { search.fileMask = "*.html, *.css, *.js" }
                }
                .menuStyle(.borderlessButton).fixedSize().font(Theme.smallFont)
                .toolTip("选择常见文件类型，或在右边输入文件名或路径规则")
                TextField("文件名或路径规则", text: $search.fileMask,
                          prompt: Text("例如 *.java").foregroundColor(Theme.mutedText))
                    .textFieldStyle(.plain)
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.text)
                    .toolTip("留空搜索所有文件。*.java 只搜 Java，src/** 只搜 src 目录，! 开头的规则用于排除。多条规则用逗号分隔")
                if !search.fileMask.isEmpty {
                    Button { search.fileMask = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.mutedText)
                    }
                    .buttonStyle(.plain)
                    .toolTip("清除文件筛选")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBackground))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
            HStack {
                Menu {
                    Button("整个项目") { search.scope = .project }
                    Button("当前目录") {
                        if let path = session.selectedSearchDirectory { search.scope = .directory(path) }
                    }.disabled(session.selectedSearchDirectory == nil)
                    Button("已打开文件") { search.scope = .openFiles }
                    Button("Git 已变更文件") { search.scope = .changedFiles }.disabled(!session.hasGit)
                } label: {
                    Text(scopeTitle(search.scope)).lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.font(Theme.smallFont)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var resultControls: some View {
        HStack(spacing: 6) {
            Menu {
                Button("按目录") { search.grouping = .directories }
                Button("按文件") { search.grouping = .files }
            } label: {
                Text(search.grouping == .directories ? "按目录分组" : "按文件分组")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
            if search.visiblePin == nil {
                Button("保留结果") { search.pinCurrent() }
                    .controlSize(.small)
                    .disabled(search.replacementResult?.files.isEmpty != false)
                    .toolTip("把这组结果保存为独立标签，继续查找时仍可切回来查看")
            }
        }
        .font(Theme.smallFont)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func scopeTitle(_ scope: TextSearchScope) -> String {
        switch scope {
        case .project: return "整个项目"
        case .directory(let path): return "目录 · \(path.isEmpty ? "./" : path)"
        case .openFiles: return "已打开文件"
        case .changedFiles: return "Git 已变更文件"
        }
    }

    /// 「N 处匹配，M 个文件」/ 结果过多 / 出错。
    @ViewBuilder private var statusLine: some View {
        let text: String? = {
            if search.visiblePin == nil, let error = search.error { return error }
            guard let result = search.displayedResult else { return search.isSearching ? "正在搜索…" : nil }
            if result.files.isEmpty { return "没有找到" }
            let summary = "\(result.matchCount) 处匹配，\(result.files.count) 个文件"
            return result.isTruncated ? "结果过多，只显示前 \(result.matchCount) 处 · \(result.files.count) 个文件" : summary
        }()
        if let text {
            Text(text)
                .font(Theme.smallFont)
                .foregroundStyle(search.visiblePin == nil && search.error != nil ? Theme.danger : (search.displayedResult?.isTruncated == true ? Theme.warning : Theme.secondaryText))
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
        if let result = search.displayedResult, !result.files.isEmpty {
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
                    if search.grouping == .directories {
                        ForEach(result.directories) { group in
                            let isCollapsed = search.collapsedDirectories.contains(group.path)
                            SearchGroupRow(title: group.path.isEmpty ? "根目录" : group.path,
                                detail: "\(group.files.count) 个文件 · \(group.matchCount) 处", icon: "folder",
                                iconColor: Theme.secondaryText, isCollapsed: isCollapsed, indentation: 0) {
                                isListFocused = true
                                search.toggleDirectory(group.path)
                            }
                            if !isCollapsed { fileRows(group.files, grouped: true, selected: selected) }
                        }
                    } else {
                        fileRows(result.files, grouped: false, selected: selected)
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

    @ViewBuilder private func fileRows(_ files: [TextSearchFile], grouped: Bool, selected: TextSearchController.Hit?) -> some View {
        ForEach(files) { file in
            let isCollapsed = search.collapsedFiles.contains(file.path)
            let icon = FileIcon.file(named: file.name)
            let title = grouped || file.directory.isEmpty ? file.name : "\(file.name) · \(file.directory)"
            SearchGroupRow(title: title, detail: "\(file.matchCount) 处", icon: icon.systemName, iconColor: icon.color,
                           isCollapsed: isCollapsed, indentation: grouped ? 14 : 0) {
                isListFocused = true
                search.toggleCollapsed(file.path)
            }
            .toolTip(file.path)
            .id(Self.rowID(file.path, nil))
            if !isCollapsed {
                ForEach(file.lines) { line in
                    let hit = TextSearchController.Hit(path: file.path, line: line.line)
                    SearchLineRow(line: line, isSelected: hit == selected, indentation: grouped ? 14 : 0) {
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

    private static func rowID(_ path: String, _ line: Int?) -> String {
        line.map { "line:\($0):\(path)" } ?? "file:" + path
    }

    private func openSelected(pinned: Bool) {
        guard let hit = search.selectForOpening(), let line = search.line(for: hit) else { return }
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

private struct SearchGroupRow: View {
    let title: String
    let detail: String
    let icon: String
    let iconColor: Color
    let isCollapsed: Bool
    let indentation: CGFloat
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondaryText).frame(width: 12)
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(iconColor).frame(width: 16)
            Text(title).font(Theme.uiFont).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(detail).font(Theme.smallFont).foregroundStyle(Theme.mutedText).fixedSize()
        }
        .padding(.leading, 10 + indentation).padding(.trailing, 10)
        .frame(height: Theme.treeRowHeight)
        .background(Rectangle().fill(isHovering ? Theme.hover.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onPress(modifiers: { _, modifiers in if !modifiers.contains(.control) { toggle() } })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(detail)，\(isCollapsed ? "已折叠" : "已展开")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        // 文件行不挂右键菜单：「复制路径」与匹配行的「复制路径和行号」重复（1.7.1 用户定的，只留后者）
    }
}

/// 匹配行：行号 + 这一行的文字（去掉缩进，过长的以命中为中心截一段），命中部分高亮。
private struct SearchLineRow: View {
    let line: TextSearchLine
    let isSelected: Bool
    let indentation: CGFloat
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
        .padding(.leading, 26 + indentation)
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
