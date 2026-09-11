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
    /// 等确认的操作：删除（右键菜单或 ⌫），或者把被 .gitignore 忽略的东西添加到 git
    /// （`git add --force` 很容易一下子把 node_modules 拖进来，动手前问一句）。
    /// 两者共用一个状态、一个弹窗：同一时刻只可能有一个在等确认，两个 alert 挂在同一个视图上是自找麻烦。
    @State private var pending: DestructiveConfirmation?
    /// 正在重命名的节点（右键菜单或 ⇧F6），对话框以 sheet 弹出。
    @State private var renaming: FileNode?
    /// 正在往哪个目录下新建文件夹（右键菜单）。
    @State private var newFolder: NewFolderRequest?
    /// 拖拽正经过哪一行、那一行会把东西交给哪个目录：接收目录那一行画高亮。
    @State private var dropTarget = DropTargetState()

    init(session: ProjectSession) {
        self.session = session
        self.search = session.search
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowHeader(title: "项目") {
                if session.isSyncingRemote {
                    ProgressView().controlSize(.mini).padding(.trailing, 4)
                }
                IconButton(ToolWindowIcon.syncWithRemote, help: syncHelp, size: 22) { session.requestSync() }
                    .disabled(!session.canRequestSync)
                IconButton("magnifyingglass", help: "查找文件（⌘F）", isActive: search.isActive, size: 22) {
                    if search.isActive { closeSearch() } else { search.activate() }
                }
                IconButton("scope", help: "定位当前打开的文件（⌥⌘L）", size: 22) {
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

    /// 同步按钮的提示。不能同步时说清楚是为什么——按钮灰着，用户总得知道差什么（1.2.0 前同步中、状态没读回来、
    /// 游离 HEAD 这几种灰法都没说，或者说错成「没有上游」「还没有提交」）。
    private var syncHelp: String {
        guard session.hasGit else { return "这个项目不在 git 仓库里" }
        let branch = session.gitSnapshot.branch
        if session.isSyncingRemote {
            return "正在与\(branch.upstream.map { " \($0) " } ?? "远程")同步…（连续 \(Int(GitClient.networkStallTimeout)) 秒没动静会自动放弃）"
        }
        if session.isSwitchingBranch { return "正在切换分支…" }
        guard session.hasLoadedGitStatus else {
            return session.gitError.map { "git 出错了：\($0)" } ?? "正在读取 git 状态…"
        }
        if branch.isUnborn { return "仓库还没有提交，没有可同步的分支" }
        if branch.isDetached {
            return "HEAD 没有停在分支上（游离在 \(branch.name)，多半是正在 rebase / 切到了某个提交），没有分支可同步"
        }
        guard let upstream = branch.upstream else {
            return "\(branch.name) 没有跟踪远程分支。点一下选择：跟踪远程的默认分支（origin/master），或者推送并建立上游"
        }
        return "与 \(upstream) 同步：git fetch + rebase（⌘T）"
    }

    /// 打开一条搜索结果：固定标签、关掉搜索、在树上定位——照 IDEA 的 Go to File。
    private func openResult(_ match: FileSearchMatch) {
        let url = search.url(for: match)
        session.openFile(url, pinned: true)
        closeSearch()
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
                        RootRow(
                            name: session.project.name, path: session.project.root.path,
                            isDropTarget: dropTarget.directory == session.project.root.path,
                            dropTarget: dropTarget(row: session.project.root.path, into: session.project.root),
                            onNewFolder: { newFolder = NewFolderRequest(directory: session.project.root) }
                        )
                        ForEach(session.rows) { row in
                            TreeRow(
                                session: session,
                                clicks: clicks,
                                row: row,
                                status: session.gitStatus(for: row.node),
                                isSelected: session.selection.contains(row.id),
                                isFocused: isFocused,
                                onPress: { isFocused = true },
                                onDelete: { requestDelete($0) },
                                onRename: { renaming = $0 },
                                onAddToGit: { requestAddToGit($0) },
                                onNewFolder: { newFolder = NewFolderRequest(directory: $0) },
                                isDropTarget: row.node.isDirectory && dropTarget.directory == row.id,
                                dropTarget: dropTarget(row: row.id, into: row.node.isDirectory ? row.node.url : row.node.url.deletingLastPathComponent())
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
                // 定位（⌥⌘L、搜索结果、跨目录移动……）：滚到视野中间。树此刻可能刚被建出来（从变更列表「在项目视图中显示」
                // 切过来），出现时也要把欠着的那次滚完
                .onChange(of: session.pendingReveal) { _, path in scrollToReveal(path, proxy: proxy) }
                .onAppear { scrollToReveal(session.pendingReveal, proxy: proxy) }
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
            // ⇧F6 重命名选中项（IDEA 的 Rename）
            .onKeyPress(phases: .down) { press in
                guard press.key == .f6, press.modifiers.contains(.shift), let node = session.selectedNode else { return .ignored }
                renaming = node
                return .handled
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .destructiveConfirmation($pending)
            .sheet(item: $renaming) { node in
                RenameSheet(node: node) { session.renameProblem(for: node, newName: $0) } commit: { session.rename(node, to: $0) }
            }
            .sheet(item: $newFolder) { request in
                NewFolderSheet(directory: request.directory, location: locationText(for: request.directory)) {
                    session.newFolderProblem(in: request.directory, name: $0)
                } commit: {
                    session.createFolder(named: $0, in: request.directory)
                }
            }
        }
    }

    /// 把要定位的那一行滚到视野中间。推到下一轮再滚：刚出现（或行刚展开）的 LazyVStack 这一轮还没排版，
    /// 这时 `scrollTo` 找不到行、什么都不做。
    private func scrollToReveal(_ path: String?, proxy: ScrollViewProxy) {
        guard let path else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(path, anchor: .center)
            session.didScrollToReveal(path)
        }
    }

    /// 一行作为拖放目标：拖到目录上进那个目录，拖到文件上进文件所在的目录（IDEA 一样）。
    /// 松手就搬，不弹确认（访达也不问），状态栏给「撤销」。
    private func dropTarget(row: String, into directory: URL) -> TreeDropTarget {
        TreeDropTarget(
            check: { paths in
                let nodes = paths.compactMap(session.node(atPath:))
                return nodes.count == paths.count && session.canMove(nodes, into: directory)
            },
            drop: { paths in
                dropTarget.clear(row: row)
                session.move(paths.compactMap(session.node(atPath:)), into: directory)
            },
            targeted: { isTargeted in
                if isTargeted { dropTarget.enter(row: row, directory: directory.path) } else { dropTarget.clear(row: row) }
            }
        )
    }

    /// 对话框里「在 … 下」那一段：项目内的相对路径，根目录说「项目根目录」。
    private func locationText(for directory: URL) -> String {
        let relative = session.project.projectRelativeComponents(of: directory).joined(separator: "/")
        return relative.isEmpty ? "项目根目录" : "“\(relative)/”"
    }

    /// 右键「删除…」/ ⌫：点的那一行在多选里就删整个多选（IDEA 一样），否则只删它。
    private func requestDelete(_ node: FileNode) {
        let nodes = session.selection.contains(node.id) && session.selection.count > 1 ? TreeSelection.roots(session.selectedNodes) : [node]
        if nodes.count == 1, let only = nodes.first {
            pending = DestructiveConfirmation(
                id: "delete:" + only.id,
                title: "删除 \(only.name)？",
                message: only.isDirectory ? "目录和里面的全部内容会移到废纸篓。" : "文件会移到废纸篓。",
                buttonTitle: "删除"
            ) { session.delete(only) }
        } else {
            pending = DestructiveConfirmation(
                id: "delete:" + nodes.map(\.id).joined(separator: "\n"),
                title: "删除 \(nodes.count) 个项目？",
                message: "它们（目录连同里面的全部内容）会移到废纸篓。",
                buttonTitle: "删除"
            ) { session.delete(nodes) }
        }
    }

    /// 右键「添加到 git」：点的那一行在多选里就添加整个多选（与删除一样），否则只添加它。
    /// 里面有被 .gitignore 忽略的先弹一句确认——`add --force` 一不留神就是几万个文件。
    private func requestAddToGit(_ node: FileNode) {
        let nodes = session.selection.contains(node.id) && session.selection.count > 1 ? TreeSelection.roots(session.selectedNodes) : [node]
        let targets = nodes.filter(session.canAddToGit)
        guard !targets.isEmpty else { return }
        let ignored = targets.filter(session.isIgnoredByGit)
        guard !ignored.isEmpty else {
            session.addToGit(targets)
            return
        }
        pending = DestructiveConfirmation(
            id: "add:" + targets.map(\.id).joined(separator: "\n"),
            title: ignored.count == 1 ? "“\(ignored[0].name)”被 .gitignore 忽略，仍然添加？" : "有 \(ignored.count) 个被 .gitignore 忽略，仍然添加？",
            message: "会用 git add --force 把它们纳入版本管理；目录会连同里面被忽略的文件一起添加。",
            buttonTitle: "添加",
            isDestructive: false
        ) { session.addToGit(targets) }
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
    @State private var isFieldFocused = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
            // NSTextField 直包：⌘F / 点放大镜时要从 WebView 手里把焦点抢过来，SwiftUI 的 FocusState 做不到
            FocusedTextField(text: $search.query, placeholder: "查找文件名或路径", focusRequests: search.focusRequests) { key in
                switch key {
                case .up: search.moveSelection(by: -1)
                case .down: search.moveSelection(by: 1)
                case .submit: if let match = search.selectedResult { open(match) }
                case .cancel: close()
                }
                return true
            } onFocusChange: { isFieldFocused = $0 }
            if search.isIndexing {
                ProgressView().controlSize(.mini).toolTip("正在建索引…")
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

/// 拖拽正经过哪一行、要交给哪个目录。
///
/// 「离开」只能撤掉自己那一行建立的状态：两个相邻文件行代表同一个父目录时，AppKit 可能先报新行进入、再报旧行离开，
/// 只按目录比对的话旧行的离开会把新行刚点亮的高亮清掉。
struct DropTargetState: Equatable {
    private(set) var row: String?
    private(set) var directory: String?

    mutating func enter(row: String, directory: String) {
        self.row = row
        self.directory = directory
    }

    mutating func clear(row: String) {
        guard self.row == row else { return }
        self.row = nil
        directory = nil
    }
}

/// 一行作为拖放目标要知道的事：来源能不能放、放了怎么办、拖着经过时告诉树高亮哪个目录。
struct TreeDropTarget {
    let check: ([String]) -> Bool
    let drop: ([String]) -> Void
    let targeted: (Bool) -> Void
}

/// 拖着东西经过时接收目录那一行的样子：访达式的圆角描边加淡淡的底色。
private struct DropTargetHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Theme.accent, lineWidth: 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.18)))
            .padding(.horizontal, 3)
            .padding(.vertical, 0.5)
    }
}

/// 树最上面那一行：项目名。往上面拖东西 = 移到项目根目录。
private struct RootRow: View {
    let name: String
    let path: String
    let isDropTarget: Bool
    let dropTarget: TreeDropTarget
    let onNewFolder: () -> Void

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
        .overlay { if isDropTarget { DropTargetHighlight() } }
        .overlay(TreeRowInteraction(dropCheck: dropTarget.check, drop: dropTarget.drop, onTargetChange: dropTarget.targeted))
        .contextMenu {
            Button("新建文件夹…") { onNewFolder() }
        }
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
    /// 右键「重命名…」：交给树弹对话框。
    var onRename: (FileNode) -> Void = { _ in }
    /// 右键「添加到 git」：交给树处理多选与确认。
    var onAddToGit: (FileNode) -> Void = { _ in }

    /// 往这个目录下新建文件夹（文件行给的是它所在的目录）。
    var onNewFolder: (URL) -> Void = { _ in }
    /// 拖着东西经过时这一行（目录）会接收：画高亮。由树算好传进来（文件行代表的是它所在的目录，高亮的是那个目录的行）。
    let isDropTarget: Bool
    /// 拖放到这一行上。
    let dropTarget: TreeDropTarget
    @State private var isHovering = false
    @State private var press: Press?

    /// 一次按下的去向。`selectedRow`：按在已经在多选里的行上——先不动选中（拖起来要带着整个多选），松开算一次点击才收成只选它。
    private enum Press { case chevron, row, selectedRow }

    private var node: FileNode { row.node }
    private var indent: CGFloat { CGFloat(row.depth) * 16 + 8 }
    private var icon: FileIcon.Descriptor { node.isDirectory ? FileIcon.folder : FileIcon.file(named: node.name) }

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
        .overlay { if isDropTarget { DropTargetHighlight() } }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .overlay(TreeRowInteraction(
            press: { press = pressed(at: $0, modifiers: $1) },
            release: { isClick in
                if isClick, press == .selectedRow { session.select(node.id) }
                if isClick, press == .row || press == .selectedRow { released() }
                press = nil
            },
            dragPath: node.id,
            // 在多选里的行拖起来带上整个多选；不在多选里的只拖自己
            dragPaths: { session.selection.contains(node.id) ? TreeSelection.roots(session.selectedNodes).map(\.id) : [node.id] },
            dragPreview: { count in
                count > 1
                    ? TreeRowInteraction.DragPreview(title: "\(count) 个项目", systemImage: "doc.on.doc", tint: NSColor(Theme.secondaryText), leadingInset: indent + 4 + 12 + 4)
                    : TreeRowInteraction.DragPreview(
                        title: node.name, systemImage: icon.systemName,
                        tint: NSColor(status == .ignored ? Theme.vcsIgnored : icon.color), leadingInset: indent + 4 + 12 + 4
                    )
            },
            dropCheck: dropTarget.check,
            drop: dropTarget.drop,
            onTargetChange: dropTarget.targeted,
            // 折叠的目录：拖着东西在上面停一会儿就展开，好往里面的子目录放
            springLoad: node.isDirectory && !row.isExpanded ? { session.expand(node.id) } : nil
        ))
        .contextMenu {
            TreeContextMenu(session: session, node: node, requestDelete: onDelete, requestRename: onRename,
                            requestNewFolder: onNewFolder, requestAddToGit: onAddToGit)
        }
    }

    /// 按下：箭头区域直接展开/折叠；⌘点击加减多选、⇧点击连选；其余位置选中。
    private func pressed(at location: CGPoint, modifiers: NSEvent.ModifierFlags) -> Press {
        onPress()
        // 箭头占 indent 之后的 12pt，左右各留 3pt 好点中
        if node.isDirectory, modifiers.isEmpty, location.x >= indent - 3, location.x <= indent + 4 + 12 + 3 {
            session.toggleExpanded(node.id)
            return .chevron
        }
        if modifiers.contains(.command) {
            session.toggleSelection(node.id)
            return .chevron   // 加减选中不算点击：松开时不打开、不展开
        }
        if modifiers.contains(.shift) {
            session.extendSelection(to: node.id)
            return .chevron
        }
        if session.selection.contains(node.id), session.selection.count > 1 { return .selectedRow }
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
    let requestRename: (FileNode) -> Void
    let requestNewFolder: (URL) -> Void
    let requestAddToGit: (FileNode) -> Void

    var body: some View {
        // IDEA 的 New：在目录上就建在它下面，在文件上建在它旁边
        Button("新建文件夹…") { requestNewFolder(node.isDirectory ? node.url : node.url.deletingLastPathComponent()) }
        Divider()
        if !node.isDirectory {
            Button("打开") { session.openFile(node.url, pinned: true) }
            if let change = session.change(for: node.url) {
                Button("显示 diff") { session.openDiff(change, pinned: true) }
            }
            Divider()
        }
        // git 还不认识的（未跟踪、被忽略）才有：IDEA 的 Add to VCS。被忽略的要弹确认，标题带省略号
        if session.canAddToGit(node) {
            Button(session.isIgnoredByGit(node) ? "添加到 git…" : "添加到 git") { requestAddToGit(node) }
            Divider()
        }
        // 常用的放上面；「用默认应用打开」只给文件（目录交给访达就够了）
        Button("重命名…") { requestRename(node) }
        Button("删除…") { requestDelete(node) }
        Divider()
        Button("在访达中显示") { Desktop.revealInFinder(node.url) }
        if !node.isDirectory {
            Button("用默认应用打开") { Desktop.openWithDefaultApp(node.url) }
            if TerminalLauncher.canRun(fileNamed: node.name) {
                Button("在终端中运行") { session.saveAll { Desktop.runInTerminal(node.url) } }
            }
        }
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
