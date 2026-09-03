import AppKit
import Core
import DesignSystem
import SwiftUI

/// 项目目录树（IDEA 的 Project 工具窗口），顶上可以拉出一条文件搜索（IDEA 的 Go to File）。
struct ProjectTreeView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var search: FileSearchController
    @FocusState private var isFocused: Bool
    @State private var scrollOnSelection = false
    /// 双击判定是输入层的事，放在视图里；一棵树共用一个，跨行才能判「同一行点了两下」。
    @State private var clicks = DoubleClickDetector(interval: NSEvent.doubleClickInterval)
    /// 等确认的删除（右键菜单或 ⌫）。
    @State private var pendingDelete: DestructiveConfirmation?

    init(session: ProjectSession) {
        self.session = session
        self.search = session.search
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowHeader(title: "项目") {
                IconButton("magnifyingglass", help: "查找文件（⌘F）", isActive: search.isActive, size: 22) {
                    if search.isActive { closeSearch() } else { search.activate() }
                }
                IconButton("scope", help: "定位当前打开的文件（⌥⌘L）", size: 22) {
                    scrollOnSelection = true
                    search.isActive = false
                    session.revealActiveTab()
                }
                    .disabled(session.activeTab == nil)
                IconButton("arrow.down.right.and.arrow.up.left", help: "全部折叠", size: 22) { session.collapseAll() }
            }
            if search.isActive {
                FileSearchBar(search: search, open: openResult, close: closeSearch)
            }
            // 结果盖在树上面而不是替换它：树留在视图树里，滚动位置、定位时的 onChange 才不会丢
            ZStack {
                tree
                if search.isActive, !search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    FileSearchResults(search: search, open: openResult).background(Theme.panel)
                }
            }
        }
        .background(Theme.panel)
    }

    /// 打开一条搜索结果：固定标签、关掉搜索、在树上定位——照 IDEA 的 Go to File。
    private func openResult(_ match: FileSearchMatch) {
        let url = search.url(for: match)
        session.openFile(url, pinned: true)
        closeSearch()
        scrollOnSelection = true
        session.reveal(url)
    }

    private func closeSearch() {
        search.isActive = false
        isFocused = true
    }

    private var tree: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        RootRow(name: session.project.name, path: session.project.root.path)
                        ForEach(session.rows) { row in
                            TreeRow(
                                session: session,
                                clicks: clicks,
                                row: row,
                                status: session.gitStatus(for: row.node),
                                isSelected: session.selectedPath == row.id,
                                isFocused: isFocused,
                                onPress: { isFocused = true },
                                onDelete: { requestDelete($0) }
                            )
                            .id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: session.selectedPath) { _, path in
                    // 只有键盘导航才滚动定位：鼠标点到的行本来就在视野里，每次都 scrollTo 白白多一轮布局
                    guard let path, scrollOnSelection else { return }
                    scrollOnSelection = false
                    proxy.scrollTo(path)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onMoveCommand { direction in
                scrollOnSelection = true
                switch direction {
                case .up: session.moveSelection(by: -1)
                case .down: session.moveSelection(by: 1)
                case .right: session.perform(.expand)
                case .left: session.perform(.collapseOrAscend)
                default: break
                }
            }
            .onKeyPress(.return) {
                session.perform(.toggle)
                return .handled
            }
            // ⌫ / fn⌫ 删除选中项（IDEA 的 Delete），先确认
            .onKeyPress(.delete) { requestDeleteOfSelection() }
            .onKeyPress(.deleteForward) { requestDeleteOfSelection() }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .onChange(of: session.revealRequests) { _, _ in scrollOnSelection = true }
            .destructiveConfirmation($pendingDelete)
        }
    }

    private func requestDelete(_ node: FileNode) {
        pendingDelete = DestructiveConfirmation(
            id: "delete:" + node.id,
            title: "删除 \(node.name)？",
            message: node.isDirectory ? "目录和里面的全部内容会移到废纸篓。" : "文件会移到废纸篓。",
            buttonTitle: "删除"
        ) { session.delete(node) }
    }

    private func requestDeleteOfSelection() -> KeyPress.Result {
        guard let node = session.selectedNode else { return .ignored }
        requestDelete(node)
        return .handled
    }
}

/// 搜索框。回车打开选中的结果，↑↓ 换选中，Esc 关掉搜索。
private struct FileSearchBar: View {
    @ObservedObject var search: FileSearchController
    let open: (FileSearchMatch) -> Void
    let close: () -> Void
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
            TextField("查找文件名或路径", text: $search.query)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .focused($isFieldFocused)
                .onSubmit { if let match = search.selectedResult { open(match) } }
                .onKeyPress(.upArrow) { search.moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { search.moveSelection(by: 1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
            if search.isIndexing {
                ProgressView().controlSize(.mini).help("正在建索引…")
            } else if !search.query.isEmpty {
                Button { search.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBackground))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isFieldFocused ? Theme.accent : Theme.border, lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .onAppear { isFieldFocused = true }
        .onChange(of: search.focusRequests) { _, _ in isFieldFocused = true }
    }
}

/// 搜索结果列表。单击打开。
private struct FileSearchResults: View {
    @ObservedObject var search: FileSearchController
    let open: (FileSearchMatch) -> Void

    var body: some View {
        if search.results.isEmpty {
            ToolWindowEmptyState(
                title: search.isIndexing ? "正在建索引…" : "没有匹配的文件",
                detail: search.isIndexing ? "第一次搜索要先扫一遍项目目录。" : "已索引 \(search.indexedCount) 个文件（git 忽略的不算）。试试文件名的一部分，或带 / 的路径。"
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(search.results.enumerated()), id: \.element.entry.path) { index, match in
                            FileSearchRow(match: match, isSelected: index == search.selectedIndex) {
                                search.select(index)
                            } open: {
                                open(match)
                            }
                            .id(match.entry.path)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: search.selectedIndex) { _, index in
                    if search.results.indices.contains(index) { proxy.scrollTo(search.results[index].entry.path) }
                }
            }
        }
    }
}

private struct FileSearchRow: View {
    let match: FileSearchMatch
    let isSelected: Bool
    let select: () -> Void
    let open: () -> Void
    @State private var isHovering = false

    /// 文件名，命中的字符加粗、用强调色。
    private var highlightedName: AttributedString {
        var text = AttributedString(match.entry.name)
        let characters = Array(match.entry.name)
        for index in match.matchedNameIndices where index < characters.count {
            let start = text.index(text.startIndex, offsetByCharacters: index)
            let end = text.index(start, offsetByCharacters: 1)
            text[start..<end].foregroundColor = Theme.accent
            text[start..<end].font = .system(size: 13, weight: .semibold)
        }
        return text
    }

    var body: some View {
        let icon = FileIcon.file(named: match.entry.name)
        HStack(spacing: 6) {
            Image(systemName: icon.systemName).font(.system(size: 12)).foregroundStyle(icon.color).frame(width: 16)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(highlightedName).font(Theme.uiFont).foregroundStyle(Theme.text).lineLimit(1)
                    if !match.entry.directory.isEmpty {
                        Text(match.entry.directory).font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1).fixedSize()
                    }
                }
                Text(highlightedName).font(Theme.uiFont).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.treeRowHeight)
        .background(Rectangle().fill(isSelected ? Theme.selection : (isHovering ? Theme.hover.opacity(0.5) : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onPress { _ in select() } release: { isClick in if isClick { open() } }
        .help(match.entry.path)
    }
}

/// 树最上面那一行：项目名。
private struct RootRow: View {
    let name: String
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill.badge.gearshape")
                .font(.system(size: 12))
                .foregroundStyle(Theme.folderIcon)
            Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            Text(path.abbreviatingHomeDirectory)
                .font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.treeRowHeight)
    }
}

/// 一行。IDEA 习惯：单击只选中；双击文件打开、双击目录展开/折叠；箭头单击也能展开/折叠。
///
/// **性能上三条规矩：**
/// - 选中在**鼠标按下**时就生效（见 `PressGesture`），不等松开。
/// - 双击靠 `DoubleClickDetector` 按时间间隔判定，在松开时结算。SwiftUI 的 `TapGesture(count: 2)` 在 macOS 上
///   会拖住同一视图的单击，选中要迟几百毫秒才亮。
/// - 这里**不**用 `@ObservedObject` 观察 session：几百行每一行都订阅整个 session 的话，
///   git 刷新、文件加载这些与树无关的变化都会让所有行重算。需要的状态由父视图算好传进来。
///
/// 整行只挂一个手势：箭头区域按横坐标判断，不再给箭头单独套手势（嵌套手势会互相等待）。
struct TreeRow: View {
    let session: ProjectSession
    let clicks: DoubleClickDetector
    let row: FlattenedTree.Row
    let status: GitStatusIndex.Status?
    let isSelected: Bool
    let isFocused: Bool
    /// 行被按下：树把键盘焦点收回来。
    let onPress: () -> Void
    /// 右键「删除…」：交给树去确认。
    var onDelete: (FileNode) -> Void = { _ in }
    @State private var isHovering = false
    @State private var press: Press?

    /// 一次按下的去向。
    private enum Press { case chevron, row }

    private var node: FileNode { row.node }
    private var indent: CGFloat { CGFloat(row.depth) * 16 + 8 }

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: indent)
            Group {
                if node.isDirectory {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 12, height: 12)
                } else {
                    Spacer().frame(width: 12)
                }
            }
            let icon = node.isDirectory ? FileIcon.folder : FileIcon.file(named: node.name)
            Image(systemName: icon.systemName)
                .font(.system(size: 12))
                .foregroundStyle(status == .ignored ? Theme.vcsIgnored : icon.color)
                .frame(width: 16)
            Text(node.name)
                .font(Theme.uiFont)
                .foregroundStyle(VCSColors.color(for: status) ?? Theme.text)
                .strikethrough(status == .change(.deleted))
                .lineLimit(1)
                .truncationMode(.middle)
            if node.isSymlink {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(Theme.mutedText)
            }
            Spacer(minLength: 4)
        }
        .padding(.trailing, 6)
        .frame(height: Theme.treeRowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onPress { location in
            press = pressed(at: location)
        } release: { isClick in
            if isClick, press == .row { released() }
            press = nil
        }
        .contextMenu { TreeContextMenu(session: session, node: node, requestDelete: onDelete) }
    }

    /// 按下：箭头区域直接展开/折叠；其余位置选中。
    private func pressed(at location: CGPoint) -> Press {
        onPress()
        // 箭头占 indent 之后的 12pt，左右各留 3pt 好点中
        if node.isDirectory, location.x >= indent - 3, location.x <= indent + 4 + 12 + 3 {
            session.toggleExpanded(node.id)
            return .chevron
        }
        session.select(node.id)
        return .row
    }

    /// 松开：同一行在双击间隔内的第二下才算双击。
    private func released() {
        guard clicks.registerClick(on: node.id) else { return }
        if node.isDirectory {
            session.toggleExpanded(node.id)
        } else {
            session.openFile(node.url, pinned: true)
        }
    }

    private var rowBackground: some View {
        Rectangle().fill(
            isSelected ? (isFocused ? Theme.selection : Theme.inactiveSelection)
                : (isHovering ? Theme.hover.opacity(0.5) : .clear)
        )
    }
}

private struct TreeContextMenu: View {
    let session: ProjectSession
    let node: FileNode
    let requestDelete: (FileNode) -> Void

    var body: some View {
        if !node.isDirectory {
            Button("打开") { session.openFile(node.url, pinned: true) }
            if let change = session.change(for: node.url) {
                Button("显示 diff") { session.openDiff(change, pinned: true) }
            }
            Divider()
        }
        Button("在访达中显示") { Desktop.revealInFinder(node.url) }
        Button("用默认应用打开") { Desktop.openWithDefaultApp(node.url) }
        if !node.isDirectory, TerminalLauncher.canRun(fileNamed: node.name) {
            Button("在终端中运行") { session.saveAll { Desktop.runInTerminal(node.url) } }
        }
        Divider()
        Button("删除…") { requestDelete(node) }
    }
}

/// VCS 状态 → 颜色，树和变更列表共用。
enum VCSColors {
    static func color(for status: GitStatusIndex.Status?) -> Color? {
        switch status {
        case .none: return nil
        case .ignored: return Theme.vcsIgnored
        case .change(let kind): return color(for: kind)
        }
    }

    static func color(for kind: ChangeKind) -> Color {
        switch kind {
        case .added: return Theme.vcsAdded
        case .modified: return Theme.vcsModified
        case .deleted: return Theme.vcsDeleted
        case .renamed: return Theme.vcsRenamed
        case .conflicted: return Theme.vcsConflicted
        case .untracked: return Theme.vcsUntracked
        }
    }
}
