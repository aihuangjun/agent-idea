import AppKit
import Core
import DesignSystem
import SwiftUI

/// 提交历史工具窗口（IDEA 的 Git → Log）：上面是提交列表，选中一条后下面列出它改了哪些文件。
struct HistoryView: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        Group {
            if let history = session.history {
                HistoryBody(session: session, history: history)
                    .onAppear { history.loadIfNeeded() }
            } else {
                VStack(spacing: 0) {
                    ToolWindowHeader(title: "提交历史") {}
                    ToolWindowEmptyState(title: "没有 git 仓库", detail: "这个目录不在 git 仓库里，或者本机没有安装 git。")
                }
            }
        }
        .background(Theme.panel)
    }
}

/// 标题条 + 正文。转圈、刷新按钮都看 `HistoryController` 的状态，所以标题条也放在观察它的这一层。
private struct HistoryBody: View {
    let session: ProjectSession
    @ObservedObject var history: HistoryController

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowHeader(title: "提交历史") {
                if history.isLoading {
                    ProgressView().controlSize(.mini).padding(.trailing, 4)
                }
                IconButton("arrow.clockwise", help: "刷新", size: 22) { history.refresh() }
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = history.error {
            ToolWindowEmptyState(title: "git 出错了", detail: error)
        } else if history.commits.isEmpty {
            if history.isLoading {
                Spacer()
            } else {
                ToolWindowEmptyState(title: "还没有提交", detail: "第一次提交之后这里会列出历史。")
            }
        } else {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    CommitList(history: history)
                    if let commit = history.selectedCommit {
                        CommitDetails(session: session, history: history, commit: commit)
                            .frame(height: max(160, geometry.size.height * 0.45))
                    }
                }
            }
        }
    }
}

// MARK: - 提交列表

private struct CommitList: View {
    @ObservedObject var history: HistoryController
    @FocusState private var isFocused: Bool
    @State private var scrollOnSelection = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(history.commits) { commit in
                        CommitRow(commit: commit, isSelected: history.selectedCommitID == commit.id, isFocused: isFocused) {
                            isFocused = true
                            history.select(commit)
                        }
                        .id(commit.id)
                    }
                    if history.hasMore {
                        Button {
                            history.loadMore()
                        } label: {
                            HStack(spacing: 6) {
                                if history.isLoading { ProgressView().controlSize(.mini) }
                                Text(history.isLoading ? "加载中…" : "加载更多").font(Theme.smallFont)
                            }
                            .frame(maxWidth: .infinity).frame(height: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondaryText)
                        .disabled(history.isLoading)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: history.selectedCommitID) { _, id in
                guard let id, scrollOnSelection else { return }
                scrollOnSelection = false
                proxy.scrollTo(id)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onMoveCommand { direction in
            scrollOnSelection = true
            switch direction {
            case .up: history.moveSelection(by: -1)
            case .down: history.moveSelection(by: 1)
            default: break
            }
        }
    }
}

/// 一条提交，两行：主题 + 短 hash；作者 · 时间。不观察任何对象，状态由父视图传入。
private struct CommitRow: View {
    let commit: GitCommit
    let isSelected: Bool
    let isFocused: Bool
    let select: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if commit.isMerge {
                    Image(systemName: "arrow.triangle.merge").font(.system(size: 10)).foregroundStyle(Theme.mutedText)
                }
                Text(commit.subject.isEmpty ? "（无提交信息）" : commit.subject)
                    .font(Theme.uiFont).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(commit.shortHash)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.mutedText).fixedSize()
            }
            HStack(spacing: 4) {
                Text(commit.authorName).lineLimit(1)
                Text("·")
                Text(DateText.relative(commit.date)).fixedSize()
                Spacer(minLength: 0)
            }
            .font(Theme.smallFont).foregroundStyle(Theme.mutedText)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Rectangle().fill(isSelected ? (isFocused ? Theme.selection : Theme.inactiveSelection) : (isHovering ? Theme.hover.opacity(0.5) : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onPress { _ in select() }
        .help(commit.subject)
    }
}

// MARK: - 提交详情

private struct CommitDetails: View {
    let session: ProjectSession
    @ObservedObject var history: HistoryController
    let commit: GitCommit
    @State private var clicks = DoubleClickDetector(interval: NSEvent.doubleClickInterval)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(commit.subject).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).textSelection(.enabled)
                    if !commit.body.isEmpty {
                        Text(commit.body).font(Theme.smallFont).foregroundStyle(Theme.secondaryText).textSelection(.enabled).lineLimit(8)
                    }
                    HStack(spacing: 6) {
                        Text(commit.authorName).help(commit.authorEmail)
                        Text("·")
                        Text(DateText.full(commit.date))
                        Text("·")
                        Text(commit.shortHash).font(.system(size: 11, design: .monospaced)).help(commit.hash).textSelection(.enabled)
                    }
                    .font(Theme.smallFont).foregroundStyle(Theme.mutedText)
                    Divider().overlay(Theme.border).padding(.top, 2)
                    files
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder
    private var files: some View {
        if let files = history.filesByCommit[commit.id] {
            if files.isEmpty {
                Text("这次提交没有文件变化").font(Theme.smallFont).foregroundStyle(Theme.mutedText)
            } else {
                Text("\(files.count) 个文件").font(Theme.smallFont).foregroundStyle(Theme.mutedText)
                LazyVStack(spacing: 0) {
                    ForEach(files) { change in
                        CommitFileRow(session: session, clicks: clicks, commit: commit, change: change,
                                      isActive: session.activeTab?.commitDiff.map { $0.commit.id == commit.id && $0.change.path == change.path } ?? false)
                    }
                }
                .padding(.horizontal, -10)
            }
        } else if let error = history.filesError[commit.id] {
            Text("取不到文件列表：\(error)").font(Theme.smallFont).foregroundStyle(Theme.danger).textSelection(.enabled)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("读取文件列表…").font(Theme.smallFont).foregroundStyle(Theme.mutedText)
            }
        }
    }
}

/// 提交里的一个文件：单击预览 diff，双击固定。
private struct CommitFileRow: View {
    let session: ProjectSession
    let clicks: DoubleClickDetector
    let commit: GitCommit
    let change: GitChange
    let isActive: Bool
    @State private var isHovering = false

    private var fileName: some View {
        Text(change.fileName)
            .font(Theme.uiFont)
            .foregroundStyle(VCSColors.color(for: change.kind))
            .strikethrough(change.kind == .deleted)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        let icon = FileIcon.file(named: change.fileName)
        HStack(spacing: 6) {
            Image(systemName: icon.systemName).font(.system(size: 12)).foregroundStyle(icon.color).frame(width: 16)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    fileName
                    if !change.directory.isEmpty {
                        Text(change.directory).font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1).fixedSize()
                    }
                }
                fileName
            }
            Spacer(minLength: 4)
            Text(change.kind.label)
                .font(.system(size: 10))
                .foregroundStyle(VCSColors.color(for: change.kind).opacity(0.85))
                .fixedSize()
                .layoutPriority(2)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.treeRowHeight)
        .background(Rectangle().fill(isActive ? Theme.selection : (isHovering ? Theme.hover.opacity(0.5) : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onPress { _ in
            session.openCommitDiff(change, in: commit, pinned: false)
        } release: { isClick in
            if isClick, clicks.registerClick(on: commit.hash + change.path) { session.openCommitDiff(change, in: commit, pinned: true) }
        }
        .contextMenu {
            Button("显示 diff") { session.openCommitDiff(change, in: commit, pinned: true) }
            if let url = session.url(for: change), session.fileExists(url) {
                Button("打开文件（当前版本）") { session.openFile(url, pinned: true) }
                Button("在项目视图中显示") { session.reveal(url) }
            }
        }
    }
}
