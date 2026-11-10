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

/// 标题条 + 正文。转圈、刷新按钮看历史控制器与会话两边的状态（拉 log 与同步远程各转各的），所以标题条也放在同时观察它俩的这一层。
private struct HistoryBody: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var history: HistoryController

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowHeader(title: "提交历史") {
                if history.isLoading || session.isSyncingRemote {
                    ProgressView().controlSize(.mini).padding(.trailing, 4)
                }
                // 刷新 = 与远程同步后再重拉：只重列本地的 log 看不到别人刚推上去的提交。
                // 同步不了的仓库（没上游、还没有提交）退回本地刷新，按钮照样能用。
                // 图标跟着实际做的事走：真去拉远程时用项目工具窗口那个同步图标，退回本地刷新时才是转圈箭头。
                // 看的是 hasRemoteUpstream 而不是 canSyncWithRemote：后者在同步进行中是 false，
                // 按它画的话同步那几秒按钮会变成另一个图标 + 另一套说明（按钮此时只该灰着）
                IconButton(session.hasRemoteUpstream ? ToolWindowIcon.syncWithRemote : ToolWindowIcon.refresh,
                           help: session.hasRemoteUpstream ? "与远程同步并刷新：git fetch + rebase（⌘T）" : "刷新（当前分支没有跟踪远程分支，只重列本地提交）",
                           size: 22) {
                    if session.hasRemoteUpstream { session.syncWithRemote() } else { history.refresh() }
                }
                    .disabled(session.isSyncingRemote)
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if history.comparedBranch != nil {
            ComparisonBanner(history: history)
        }
        if let filter = history.pathFilter {
            PathHistoryBanner(history: history, filter: filter)
        }
        if let error = history.error {
            ToolWindowEmptyState(title: history.comparedBranch == nil ? "git 出错了" : "无法比较", detail: error)
        } else if history.commits.isEmpty {
            if history.isLoading {
                Spacer()
            } else if let comparison = history.comparison {
                ToolWindowEmptyState(title: "没有可比较的提交", detail: comparison.note ?? "")
            } else if let filter = history.pathFilter {
                ToolWindowEmptyState(title: "没有动过它的提交",
                                     detail: "\(filter.displayPath) 还没有被提交过（新建的、未跟踪的），或者当前分支上没有改过它。")
            } else {
                ToolWindowEmptyState(title: "还没有提交", detail: "第一次提交之后这里会列出历史。")
            }
        } else {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    CommitList(history: history)
                    if let detail = history.detail {
                        HistoryDetails(session: session, history: history, detail: detail)
                            .frame(height: max(160, geometry.size.height * 0.45))
                    }
                }
            }
        }
    }
}

// MARK: - 比较模式

/// 比较模式顶上那一条（IDEA 的 Compare with Branch）：在比什么、几个提交几个文件；点它回到整段比较，✕ 退出回普通历史。
private struct ComparisonBanner: View {
    @ObservedObject var history: HistoryController

    var body: some View {
        let branch = history.comparedBranch ?? ""
        let isShowingWhole = history.selection.isEmpty && history.comparison != nil
        HStack(spacing: 0) {
            // 按下手势只套在文字这一段上，不包住退出按钮：嵌套的手势会互相等待，按钮可能点不动
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text(history.comparison.map { $0.title(fileCount: history.files[$0.id]?.count) } ?? "与 \(branch) 比较…")
                    .font(Theme.smallFont).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.leading, 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // 选了某个提交之后，点这一条回到整段比较
            .onPress { _ in history.select(nil) }
            .toolTip("当前分支比 \(branch) 多改了什么（merge-base → HEAD）。点这里看整段比较的文件列表")
            IconButton(ToolWindowIcon.exitComparison, help: "退出比较，回到提交历史", size: 20) { history.exitComparison() }
                .padding(.trailing, 4)
        }
        .frame(height: 28)
        .background(Rectangle().fill(isShowingWhole ? Theme.selection : Theme.hover.opacity(0.35)))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - 文件历史

/// 文件历史顶上那一条（IDEA 的 Show History）：在看谁的历史；✕ 退出回普通历史。
private struct PathHistoryBanner: View {
    @ObservedObject var history: HistoryController
    let filter: GitPathFilter

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text(filter.title).font(Theme.smallFont).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                if !history.commits.isEmpty {
                    Text("· \(history.commits.count)\(history.hasMore ? "+" : "") 个提交").font(Theme.smallFont).foregroundStyle(Theme.mutedText).fixedSize()
                }
                Spacer(minLength: 4)
            }
            .padding(.leading, 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .toolTip(filter.isDirectory ? "只列动过这个目录下文件的提交" : "只列动过这个文件的提交，改名之前的也跟着找（git log --follow）")
            IconButton(ToolWindowIcon.exitPathHistory, help: "退出，回到全部提交", size: 20) { history.exitPathHistory() }
                .padding(.trailing, 4)
        }
        .frame(height: 28)
        .background(Rectangle().fill(Theme.hover.opacity(0.35)))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
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
                    ForEach(Array(history.commits.enumerated()), id: \.element.id) { index, commit in
                        CommitRow(commit: commit, isSelected: history.selection.contains(commit.id), isFocused: isFocused,
                                  press: { press(commit, modifiers: $0) },
                                  // 文件历史里最上面那个不一定是 HEAD（只是最近一次动过它的），「到 HEAD」说不通，不给
                                  compareToHead: index == 0 || history.pathFilter != nil ? nil : { history.selectThroughHead(from: commit) })
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
            .onChange(of: history.selection.anchor) { _, id in
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

    /// 照变更列表：⌃点击是右键菜单，不动选中；⌘点击加减；⇧点击连选；单击只选它。
    private func press(_ commit: GitCommit, modifiers: NSEvent.ModifierFlags) {
        isFocused = true
        if modifiers.contains(.control) { return }
        if modifiers.contains(.command) {
            history.toggleSelection(commit)
        } else if modifiers.contains(.shift) {
            history.extendSelection(to: commit)
        } else {
            history.select(commit)
        }
    }
}

/// 一条提交，两行：主题 + 短 hash；作者 · 时间。不观察任何对象，状态由父视图传入。
private struct CommitRow: View {
    let commit: GitCommit
    let isSelected: Bool
    let isFocused: Bool
    let press: (NSEvent.ModifierFlags) -> Void
    /// 最上面那个（HEAD）自己没有「到 HEAD」可比，是 nil。
    let compareToHead: (() -> Void)?
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
                Text(DateText.relative(commit.commitDate)).fixedSize()
                Spacer(minLength: 0)
            }
            .font(Theme.smallFont).foregroundStyle(Theme.mutedText)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Rectangle().fill(isSelected ? (isFocused ? Theme.selection : Theme.inactiveSelection) : (isHovering ? Theme.hover.opacity(0.5) : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onPress(modifiers: { _, modifiers in press(modifiers) })
        .contextMenu {
            if let compareToHead {
                Button("比较从这里到 HEAD") { compareToHead() }
                Divider()
            }
            Button("复制提交 hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            }
        }
        .help(commit.subject)
    }
}

// MARK: - 详情

private struct HistoryDetails: View {
    let session: ProjectSession
    @ObservedObject var history: HistoryController
    let detail: HistoryDetail
    @State private var clicks = DoubleClickDetector(interval: NSEvent.doubleClickInterval)
    @FocusState private var filesFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        switch detail {
                        case .commit(let commit): CommitHeader(commit: commit)
                        case .range(let range): RangeHeader(range: range, fileCount: history.files[range.id]?.count)
                        }
                        Divider().overlay(Theme.border).padding(.top, 2)
                        files
                            .focusable()
                            .focusEffectDisabled()
                            .focused($filesFocused)
                            .onKeyPress(.upArrow) { session.navigateChange(.previous); return .handled }
                            .onKeyPress(.downArrow) { session.navigateChange(.next); return .handled }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.activeTab?.id) { _, _ in
                    guard let active = session.activeTab, active.historyFilesKey == detail.key, let change = active.diffChange else { return }
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo("history-file:" + change.path, anchor: .center)
                    }
                }
            }
            if let status = history.status {
                StatusLine(status: status) { history.dismissStatus() }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder
    private var files: some View {
        if let files = history.files(for: detail) {
            if files.isEmpty {
                Text(detail.isRange ? "这一段没有文件变化" : "这次提交没有文件变化").font(Theme.smallFont).foregroundStyle(Theme.mutedText)
            } else {
                Text("\(files.count) 个文件").font(Theme.smallFont).foregroundStyle(Theme.mutedText)
                LazyVStack(spacing: 0) {
                    ForEach(files) { change in
                        HistoryFileRow(session: session, history: history, clicks: clicks, detail: detail, change: change,
                                       isActive: session.activeTab.map { $0.historyFilesKey == detail.key && $0.diffChange?.path == change.path } ?? false,
                                       isFocusedPath: history.isFocused(change, in: detail),
                                       statistics: history.statistics[detail.key]?[change.path],
                                       focus: { filesFocused = true })
                            .id("history-file:" + change.path)
                    }
                }
                .padding(.horizontal, -10)
            }
        } else if let error = history.filesError[detail.key] {
            Text("取不到文件列表：\(error)").font(Theme.smallFont).foregroundStyle(Theme.danger).textSelection(.enabled)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("读取文件列表…").font(Theme.smallFont).foregroundStyle(Theme.mutedText)
            }
        }
    }
}

/// 单个提交：主题、正文、作者 · 时间 · hash。
private struct CommitHeader: View {
    let commit: GitCommit

    var body: some View {
        Text(commit.subject).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).textSelection(.enabled)
        if !commit.body.isEmpty {
            Text(commit.body).font(Theme.smallFont).foregroundStyle(Theme.secondaryText).textSelection(.enabled).lineLimit(8)
        }
        HStack(spacing: 6) {
            Text(commit.authorName).help(commit.authorEmail)
            Text("·")
            Text(DateText.full(commit.commitDate))
            if commit.authorDateDiffers {
                // rebase / cherry-pick 过的提交，作者时间和落库时间对不上：两个都给出来，省得看着像排错了序
                Text("（编写于 \(DateText.full(commit.authorDate))）")
            }
            Text("·")
            Text(commit.shortHash).font(.system(size: 11, design: .monospaced)).help(commit.hash).textSelection(.enabled)
        }
        .font(Theme.smallFont).foregroundStyle(Theme.mutedText)
    }
}

/// 一段提交合起来：「3 个提交 · 12 个文件」、比的是哪两版，不连续 / 没有提交时补一句。
private struct RangeHeader: View {
    let range: GitCommitRange
    let fileCount: Int?

    var body: some View {
        Text(range.title(fileCount: fileCount)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
        HStack(spacing: 6) {
            Text(range.summary)
            Text("·")
            Text(Self.short(range.base) + " → " + Self.short(range.target))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .help(range.base + " → " + range.target)
        }
        .font(Theme.smallFont).foregroundStyle(Theme.mutedText)
        if let note = range.note {
            Text(note).font(Theme.smallFont).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 空树（从根提交之前开始比）写成「空」，其余取前 7 位。
    private static func short(_ hash: String) -> String {
        hash == GitClient.emptyTree ? "（空）" : String(hash.prefix(7))
    }
}

/// 提交 / 区间里的一个文件：单击预览 diff，双击固定，右键可以把这个变更回滚到工作区。
private struct HistoryFileRow: View {
    let session: ProjectSession
    let history: HistoryController
    let clicks: DoubleClickDetector
    let detail: HistoryDetail
    let change: GitChange
    let isActive: Bool
    /// 文件历史模式下，这一条就是在看历史的那个文件（或那个目录下的）：左边一道强调色的竖条。
    let isFocusedPath: Bool
    let statistics: DiffLineCounts?
    let focus: () -> Void
    @State private var isHovering = false

    var body: some View {
        let icon = FileIcon.file(named: change.fileName)
        HStack(spacing: 6) {
            Image(systemName: icon.systemName).font(.system(size: 12)).foregroundStyle(icon.color).frame(width: 16)
            ChangeFileLabel(change: change, statistics: statistics)
        }
        .overlay(alignment: .leading) {
            if isFocusedPath { Rectangle().fill(Theme.accent).frame(width: 2).padding(.leading, -8) }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.treeRowHeight)
        .background(Rectangle().fill(isActive ? Theme.selection : (isHovering ? Theme.hover.opacity(0.5) : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onPress { _ in
            focus()
            session.openHistoryDiff(change, in: detail, pinned: false)
        } release: { isClick in
            if isClick, clicks.registerClick(on: detail.key + ":" + change.path) { session.openHistoryDiff(change, in: detail, pinned: true) }
        }
        .contextMenu {
            Button("显示 diff") { session.openHistoryDiff(change, in: detail, pinned: true) }
            if let url = session.url(for: change), session.fileExists(url) {
                Button("打开文件（当前版本）") { session.openFile(url, pinned: true) }
                Button("在项目视图中显示") { session.reveal(url) }
            }
            Divider()
            Button("回滚这个变更（Revert）") { history.revert(change, in: detail) }
        }
    }
}
