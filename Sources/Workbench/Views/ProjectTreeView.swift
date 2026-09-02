import AppKit
import Core
import DesignSystem
import SwiftUI

/// 项目目录树（IDEA 的 Project 工具窗口）。
struct ProjectTreeView: View {
    @ObservedObject var session: ProjectSession
    @FocusState private var isFocused: Bool
    @State private var scrollOnSelection = false
    /// 双击判定是输入层的事，放在视图里；一棵树共用一个，跨行才能判「同一行点了两下」。
    @State private var clicks = DoubleClickDetector(interval: NSEvent.doubleClickInterval)

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowHeader(title: "项目") {
                IconButton("scope", help: "定位当前打开的文件（⌥⌘L）", size: 22) {
                    scrollOnSelection = true
                    session.revealActiveTab()
                }
                    .disabled(session.activeTab == nil)
                IconButton("arrow.down.right.and.arrow.up.left", help: "全部折叠", size: 22) { session.collapseAll() }
            }
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
                                isFocused: isFocused
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
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .onChange(of: session.revealRequests) { _, _ in scrollOnSelection = true }
        }
        .background(Theme.panel)
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
/// **性能上两条规矩：**
/// - 只挂一个 `onTapGesture`，双击靠 `DoubleClickDetector` 按时间间隔判定。
///   SwiftUI 的 `TapGesture(count: 2)` 在 macOS 上会拖住同一视图的单击，选中要迟几百毫秒才亮。
/// - 这里**不**用 `@ObservedObject` 观察 session：几百行每一行都订阅整个 session 的话，
///   git 刷新、文件加载这些与树无关的变化都会让所有行重算。需要的状态由父视图算好传进来。
struct TreeRow: View {
    let session: ProjectSession
    let clicks: DoubleClickDetector
    let row: FlattenedTree.Row
    let status: GitStatusIndex.Status?
    let isSelected: Bool
    let isFocused: Bool
    @State private var isHovering = false

    private var node: FileNode { row.node }

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(row.depth) * 16 + 8)
            Group {
                if node.isDirectory {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                        .onTapGesture { session.toggleExpanded(node.id) }
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
        .onTapGesture {
            // 单击立刻选中；同一行在双击间隔内的第二下才算双击
            session.select(node.id)
            guard clicks.registerClick(on: node.id) else { return }
            if node.isDirectory {
                session.toggleExpanded(node.id)
            } else {
                session.openFile(node.url, pinned: true)
            }
        }
        .contextMenu { TreeContextMenu(session: session, node: node) }
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
    }
}

/// 工具窗口顶上的标题条。
struct ToolWindowHeader<Actions: View>: View {
    let title: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            actions()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
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

/// 交给系统去做的两件事。放在视图层：模型不该 import AppKit 只为了调 NSWorkspace。
enum Desktop {
    static func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    static func openWithDefaultApp(_ url: URL) { NSWorkspace.shared.open(url) }
}
