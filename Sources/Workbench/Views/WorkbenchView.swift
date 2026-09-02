import AppKit
import Core
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// 窗口内容：顶栏（项目标签）+ 左侧工具条 + 工具窗口 + 编辑区 + 状态栏。没打开项目时是欢迎页。
struct WorkbenchView: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
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
private struct HeaderBar: View {
    @EnvironmentObject private var workbench: WorkbenchModel

    var body: some View {
        HStack(spacing: 0) {
            if workbench.sessions.isEmpty {
                Text("Agent IDEA").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(workbench.sessions) { session in
                            ProjectTab(session: session, isActive: session.id == workbench.activeSessionID)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(height: 28)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// 一个项目标签：小圆角块，选中只高亮自己，不占整行——它坐在标题栏里，不能看起来像把标题栏吞了。
private struct ProjectTab: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    @ObservedObject var session: ProjectSession
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill").foregroundStyle(Color(hex: 0x8C9CB8)).font(.system(size: 10.5))
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
            .help("关闭项目")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 28)
        // 方角、撑满整行高度。选中的用比标签栏**浅**的底色，是凸起来的那种；用内容区的深色会像陷下去。
        .background(isActive ? Theme.hover : (isHovering ? Theme.hover.opacity(0.35) : Theme.panel))
        .overlay(alignment: .bottom) { Rectangle().fill(isActive ? Theme.accent : .clear).frame(height: 2) }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { workbench.activate(session.id) }
        .help(session.project.root.path)
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
