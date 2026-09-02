import AppKit
import Core
import DesignSystem
import SwiftUI

/// 编辑区：标签栏 + 面包屑/工具条 + 正文。
struct EditorAreaView: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    @ObservedObject var session: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            if !session.tabs.isEmpty {
                TabBar(session: session)
                EditorHeader(session: session)
            }
            // WebView 常驻：没有标签时盖一层空态，而不是把它从视图树里拿掉——
            // WKWebView 挂上/摘下一次要几十毫秒，第一次打开文件、关掉最后一个标签都会顿一下。
            ZStack {
                ContentWebView(renderer: workbench.renderer)
                if session.tabs.isEmpty {
                    EmptyEditorView()
                } else if session.activeContent == .loading {
                    DelayedProgressView()
                }
            }
        }
        .background(Theme.editorBackground)
    }
}

/// 过了一小会儿还没加载完才转圈：小文件几毫秒就好，转圈一闪而过只会显得卡。
private struct DelayedProgressView: View {
    @State private var isShown = false

    var body: some View {
        ProgressView().controlSize(.small)
            .opacity(isShown ? 1 : 0)
            .task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                isShown = true
            }
    }
}

/// 没有标签时的空态：照 IDEA 列几条快捷键。
private struct EmptyEditorView: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("在左侧选择一个文件").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                shortcut("双击文件打开", "")
                shortcut("项目视图", "⌘1")
                shortcut("提交视图", "⌘0")
                shortcut("提交历史", "⌘9")
                shortcut("查找文件", "⇧⌘O")
                shortcut("定位当前文件", "⌥⌘L")
                shortcut("打开项目", "⌘O")
                shortcut("关闭标签", "⌘W")
            }
            .font(Theme.smallFont)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.editorBackground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func shortcut(_ label: String, _ keys: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.mutedText)
            Text(keys).foregroundStyle(Theme.secondaryText).font(.system(size: 11, weight: .medium, design: .rounded))
        }
    }
}

// MARK: - 标签栏

private struct TabBar: View {
    @ObservedObject var session: ProjectSession
    @State private var clicks = DoubleClickDetector(interval: NSEvent.doubleClickInterval)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(session.tabs) { tab in
                        TabItem(session: session, clicks: clicks, tab: tab, isActive: tab.id == session.activeTabID).id(tab.id)
                    }
                }
            }
            .onChange(of: session.activeTabID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
        .frame(height: Theme.tabHeight)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

private struct TabItem: View {
    let session: ProjectSession
    let clicks: DoubleClickDetector
    let tab: EditorTab
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
        let icon = tab.isDiff ? FileIcon.Descriptor(systemName: "plus.forwardslash.minus", color: Theme.vcsModified) : FileIcon.file(named: tab.title)
        HStack(spacing: 6) {
            Image(systemName: icon.systemName).font(.system(size: 11)).foregroundStyle(icon.color)
            Text(tab.title)
                .font(.system(size: 12.5))
                .italic(tab.isPreview)
                .foregroundStyle(isActive ? Theme.text : Theme.secondaryText)
                .lineLimit(1)
            if tab.isDiff {
                // 工作区 diff 标「diff」，历史提交的标它的短 hash，一眼分得清看的是哪一份
                Text(tab.commitDiff?.commit.shortHash ?? "diff")
                    .font(.system(size: 9, weight: .semibold, design: tab.commitDiff == nil ? .default : .monospaced))
                    .foregroundStyle(Theme.vcsModified)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.vcsModified.opacity(0.15)))
            }
            Button {
                session.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(isHovering ? Theme.hover : .clear))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isActive ? 1 : 0)
            .help("关闭（⌘W）")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: Theme.tabHeight)
        .background(isActive ? Theme.editorBackground : (isHovering ? Theme.hover.opacity(0.4) : Theme.panel))
        .overlay(alignment: .bottom) {
            Rectangle().fill(isActive ? Theme.accent : .clear).frame(height: 2)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            session.activate(tab.id)
            if clicks.registerClick(on: tab.id) { session.pin(tab.id) }
        }
        .contextMenu {
            Button("关闭") { session.closeTab(tab.id) }
            Button("关闭其他") { session.closeOtherTabs(tab.id) }
            Button("关闭全部") { session.closeAllTabs() }
            Divider()
            if tab.isPreview { Button("固定标签") { session.pin(tab.id) } }
            if let url = tab.fileURL ?? tab.diffChange.flatMap({ session.url(for: $0) }) {
                Button("在项目视图中显示") { session.reveal(url) }
                Button("在访达中显示") { Desktop.revealInFinder(url) }
                Button("用默认应用打开") { Desktop.openWithDefaultApp(url) }
            }
        }
    }
}

// MARK: - 面包屑与工具条

private struct EditorHeader: View {
    @EnvironmentObject private var preferences: ReadingPreferences
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(spacing: 8) {
            if let tab = session.activeTab {
                Breadcrumb(session: session, tab: tab)
                Spacer()
                controls(for: tab)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.editorBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder
    private func controls(for tab: EditorTab) -> some View {
        if tab.isDiff {
            Picker("", selection: $preferences.diffMode) {
                ForEach(DiffViewMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 110)
            if let change = tab.diffChange, change.kind != .deleted, let url = session.url(for: change), session.fileExists(url) {
                IconButton("doc.text", help: "打开文件（当前版本）", size: 22) { session.openFile(url, pinned: true) }
            }
        } else if case .markdown = session.activeContent {
            Picker("", selection: Binding(
                get: { tab.markdownShowsSource ? 1 : 0 },
                set: { _ in session.toggleMarkdownSource() }
            )) {
                Text("预览").tag(0)
                Text("源码").tag(1)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 110)
        } else if case .code = session.activeContent {
            Toggle("自动换行", isOn: $preferences.wordWrap)
                .toggleStyle(.checkbox).controlSize(.small).font(Theme.smallFont)
            if let url = tab.fileURL, let change = session.change(for: url) {
                Button {
                    session.openDiff(change, pinned: true)
                } label: {
                    Label("查看变更", systemImage: "plus.forwardslash.minus").font(Theme.smallFont)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.vcsModified)
            }
        }
    }
}

private struct Breadcrumb: View {
    @ObservedObject var session: ProjectSession
    let tab: EditorTab

    private var components: [String] {
        if let url = tab.fileURL {
            return session.project.projectRelativeComponents(of: url)
        }
        if let change = tab.diffChange {
            return change.path.split(separator: "/").map(String.init)
        }
        return [tab.title]
    }

    var body: some View {
        let parts = components
        HStack(spacing: 4) {
            if let commitDiff = tab.commitDiff {
                Text(commitDiff.commit.shortHash).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.vcsModified)
                Text(commitDiff.commit.subject).font(Theme.smallFont).foregroundStyle(Theme.secondaryText).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.mutedText)
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.mutedText)
                }
                Text(part)
                    .font(Theme.smallFont)
                    .foregroundStyle(index == parts.count - 1 ? Theme.text : Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .truncationMode(.middle)
    }
}
