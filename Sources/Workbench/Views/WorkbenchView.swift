import AppKit
import Core
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// 窗口内容：顶栏（项目标签）+ 左侧工具条 + 工具窗口 + 编辑区 + 状态栏。没打开项目时是欢迎页。
struct WorkbenchView: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    @State private var isDropTargeted = false
    /// 外壳的颜色由 `NSApp.appearance` + `Theme` 的动态色自动跟着走；WebView 里的正文得我们自己告诉它。
    /// 观察 `colorScheme` 而不是偏好：选「跟随系统」时系统换深浅也要跟上。
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(openProject: chooseProject)
            if let session = workbench.active {
                ProjectContent(session: session)
                    .id(session.id)
            } else {
                WelcomeView(openProject: chooseProject)
            }
        }
        .background(Theme.editorBackground)
        .foregroundStyle(Theme.text)
        .background(WindowConfigurator().frame(width: 0, height: 0))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.08)))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in workbench.openProject(url) }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentIDEAOpenProject)) { _ in chooseProject() }
        .onAppear { workbench.renderer.setTheme(light: colorScheme == .light) }
        .onChange(of: colorScheme) { _, scheme in workbench.renderer.setTheme(light: scheme == .light) }
        .navigationTitle("Agent IDEA")
    }

    /// 选目录。`NSOpenPanel` 是纯入口、没有分支，不包替身。
    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择一个项目目录（Agent 的工作区）"
        if let root = workbench.active?.project.root { panel.directoryURL = root.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workbench.openProject(url)
    }
}

/// 一个项目的主体。
private struct ProjectContent: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(spacing: 0) {
            ToolStrip(session: session)
            if let toolWindow = workbench.toolWindow {
                Group {
                    switch toolWindow {
                    case .project: ProjectTreeView(session: session)
                    case .commit: ChangesView(session: session)
                    case .history: HistoryView(session: session)
                    }
                }
                .frame(width: workbench.toolWindowWidth)
                ResizeHandle(width: $workbench.toolWindowWidth, range: 180...700)
            }
            EditorAreaView(session: session)
        }
        StatusBarView(session: session)
    }
}

/// 项目标签行。窗口用的是系统标准标题栏（红黄绿按钮在那一行），这一行紧贴其下、从最左边开始。
///
/// 标签能拖着换顺序（顺序会存下来，下次启动照这个顺序开回来）；空白处双击 = 打开项目，
/// 照浏览器标签栏的习惯——那片空白本来什么也不做，正好给最常用的那件事。
struct HeaderBar: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    /// 双击空白要做的事。由壳传进来而不是自己弹面板：`NSOpenPanel.runModal` 只许待在 `WorkbenchView` 里，
    /// 这里不认识它，测试才能把这一行单独挂进离屏窗口点。
    let openProject: () -> Void
    /// 每个标签量出来的宽度（标签宽窄不一，算「拖到哪一格」要用）。
    @State private var widths: [String: Double] = [:]
    @State private var drag: TabDrag?

    /// 拖动中的那个标签：`left` 是它此刻的左边缘，按标签栏内容的左边缘算。
    struct TabDrag {
        let id: String
        let startLeft: Double
        var left: Double
    }

    var body: some View {
        Group {
            if workbench.sessions.isEmpty {
                HStack(spacing: 0) {
                    Text("Agent IDEA").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 10)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: openProject)
            } else {
                tabs
            }
        }
        .frame(height: 28)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var tabs: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(workbench.sessions.enumerated()), id: \.element.id) { index, session in
                        ProjectTab(session: session, isActive: session.id == workbench.activeSessionID, isDragging: drag?.id == session.id)
                            .offset(x: offset(of: session.id, at: index))
                            // 拖着的那个盖在别人上面
                            .zIndex(drag?.id == session.id ? 1 : 0)
                            .gesture(
                                DragGesture(minimumDistance: 4)
                                    .onChanged { dragChanged(session.id, translation: $0.translation.width) }
                                    .onEnded { _ in drag = nil }
                            )
                    }
                    // 标签排完剩下的那片空白，双击 = 打开项目。它得是一个自己占着地方的视图：
                    // 双击挂在整行上的话，标签自己的单击会被它抢走（切项目就点不动了），
                    // 挂在 ScrollView 的底上又不行——那片底不是我们的视图。
                    Color.clear
                        .frame(width: blankWidth(in: geometry.size.width))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: openProject)
                }
            }
        }
        .onPreferenceChange(TabWidthKey.self) { widths = $0 }
    }

    private var orderedWidths: [Double] { workbench.sessions.map { widths[$0.id] ?? 0 } }

    /// 标签占完之后还剩多宽。宽度还没量到（第一帧）时按 0 算，别撑出一条多余的横向滚动。
    private func blankWidth(in rowWidth: Double) -> Double {
        let total = orderedWidths.reduce(0, +)
        return total > 0 ? max(0, rowWidth - total) : 0
    }

    /// 拖动中的标签画在哪：让它跟着光标走，别的标签让位之后它自己的位置变了，这里补回来。
    private func offset(of id: String, at index: Int) -> Double {
        guard let drag, drag.id == id else { return 0 }
        return drag.left - TabReorder.origin(of: index, widths: orderedWidths)
    }

    private func dragChanged(_ id: String, translation: Double) {
        guard let index = workbench.sessions.firstIndex(where: { $0.id == id }) else { return }
        let widths = orderedWidths
        guard widths.allSatisfy({ $0 > 0 }) else { return }     // 还没量到宽度，这一拍先不动
        let start: Double
        if let drag, drag.id == id {
            start = drag.startLeft
        } else {
            start = TabReorder.origin(of: index, widths: widths)
            workbench.activate(id)      // 拖之前先切过去，跟点一下一样
        }
        let left = start + translation
        drag = TabDrag(id: id, startLeft: start, left: left)
        let destination = TabReorder.destination(of: index, movedTo: left, widths: widths)
        // 故意不加动画：让位的位移和上面那句「补回来」得在同一帧里发生，否则拖着的标签会跟着抖一下
        if destination != index { workbench.moveProject(from: index, to: destination) }
    }
}

/// 每个项目标签量出来的宽度，按会话 id 汇总给标签行。
private struct TabWidthKey: PreferenceKey {
    static let defaultValue: [String: Double] = [:]
    static func reduce(value: inout [String: Double], nextValue: () -> [String: Double]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 一个项目标签：小圆角块，选中只高亮自己，不占整行——它坐在标题栏里，不能看起来像把标题栏吞了。
private struct ProjectTab: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    @ObservedObject var session: ProjectSession
    let isActive: Bool
    let isDragging: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.folderIcon).font(.system(size: 10.5))
            Text(session.project.name)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Theme.text : Theme.secondaryText)
                .lineLimit(1)
            if session.hasGit, !session.gitSnapshot.branch.name.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5))
                    Text(session.gitSnapshot.branch.name).lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.mutedText)
            }
            Button {
                workbench.closeProject(session.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(isHovering ? Theme.border : .clear))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isActive ? 1 : 0)
            .toolTip("关闭项目")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 28)
        // 方角、撑满整行高度。选中的用比标签栏**浅**的底色，是凸起来的那种；用内容区的深色会像陷下去。
        .background(isActive ? Theme.hover : (isHovering ? Theme.hover.opacity(0.35) : Theme.panel))
        .overlay(alignment: .bottom) { Rectangle().fill(isActive ? Theme.accent : .clear).frame(height: 2) }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .contentShape(Rectangle())
        // 拖起来的那个抬一层：加个投影、稍微透一点，看得出是拿在手里的
        .shadow(color: .black.opacity(isDragging ? 0.35 : 0), radius: 6, x: 0, y: 1)
        .opacity(isDragging ? 0.9 : 1)
        // 宽度报给标签行：标签宽窄不一，「拖到哪一格」按宽度算
        .background(GeometryReader { geometry in
            Color.clear.preference(key: TabWidthKey.self, value: [session.id: geometry.size.width])
        })
        .onHover { isHovering = $0 }
        .onTapGesture { workbench.activate(session.id) }
        .toolTip(session.project.root.path)
        .contextMenu {
            Button("关闭项目") { workbench.closeProject(session.id) }
            Button("在访达中显示") { Desktop.revealInFinder(session.project.root) }
        }
    }
}

/// 最左边那条工具条：切换工具窗口。
private struct ToolStrip: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    @ObservedObject var session: ProjectSession

    var body: some View {
        VStack(spacing: 6) {
            stripButton(.project, systemName: "folder", help: "项目（⌘1）", badge: 0)
            stripButton(.commit, systemName: "arrow.triangle.branch", help: "提交（⌘0）", badge: session.changeGroups.total)
            stripButton(.history, systemName: "clock.arrow.circlepath", help: "提交历史（⌘9）", badge: 0)
            Spacer()
        }
        .padding(.top, 8)
        .frame(width: Theme.toolStripWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    private func stripButton(_ window: ToolWindow, systemName: String, help: String, badge: Int) -> some View {
        IconButton(systemName, help: help, isActive: workbench.toolWindow == window, size: 30) {
            workbench.toolWindow = workbench.toolWindow == window ? nil : window
        }
        .overlay(alignment: .topTrailing) {
            CountBadge(badge).offset(x: 6, y: -5)
        }
    }
}
