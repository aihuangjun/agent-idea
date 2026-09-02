import AppKit
import Core
import DesignSystem
import SwiftUI

/// 变更列表 + 提交面板（IDEA 的 Commit 工具窗口）。
struct ChangesView: View {
    @ObservedObject var session: ProjectSession
    @State private var trackedCollapsed = false
    @State private var untrackedCollapsed = false
    @State private var clicks = DoubleClickDetector(interval: NSEvent.doubleClickInterval)

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowHeader(title: "提交") {
                if session.isRefreshingGit {
                    ProgressView().controlSize(.mini).padding(.trailing, 4)
                }
                IconButton("arrow.clockwise", help: "刷新（⌘R）", size: 22) { session.refreshGit() }
            }
            if let commit = session.commit {
                if let error = session.gitError {
                    ToolWindowEmptyState(title: "git 出错了", detail: error)
                } else if session.changeGroups.total == 0 {
                    ToolWindowEmptyState(title: "没有变更", detail: "工作区与 HEAD 一致。Agent 改了东西之后这里会自动出现。")
                } else {
                    changeList(commit: commit)
                }
                CommitPanel(commit: commit, branch: session.gitSnapshot.branch)
            } else {
                ToolWindowEmptyState(title: "没有 git 仓库", detail: "这个目录不在 git 仓库里，或者本机没有安装 git。")
            }
        }
        .background(Theme.panel)
    }

    private func changeList(commit: CommitController) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !session.changeGroups.tracked.isEmpty {
                    GroupHeader(title: "变更", changes: session.changeGroups.tracked, commit: commit, isCollapsed: $trackedCollapsed)
                    if !trackedCollapsed {
                        ForEach(session.changeGroups.tracked) { change in
                            ChangeRow(session: session, commit: commit, clicks: clicks, change: change)
                        }
                    }
                }
                if !session.changeGroups.untracked.isEmpty {
                    GroupHeader(title: "未跟踪文件", changes: session.changeGroups.untracked, commit: commit, isCollapsed: $untrackedCollapsed)
                    if !untrackedCollapsed {
                        ForEach(session.changeGroups.untracked) { change in
                            ChangeRow(session: session, commit: commit, clicks: clicks, change: change)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// 分组标题，带一个「全选/全不选」勾选框。
private struct GroupHeader: View {
    let title: String
    let changes: [GitChange]
    @ObservedObject var commit: CommitController
    @Binding var isCollapsed: Bool

    private var includedCount: Int { changes.filter { commit.isIncluded($0) }.count }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondaryText).frame(width: 12)
                .contentShape(Rectangle())
                .onTapGesture { isCollapsed.toggle() }
            Toggle("", isOn: Binding(
                get: { includedCount == changes.count },
                set: { on in for change in changes { commit.setIncluded(on, for: change) } }
            ))
            .toggleStyle(.checkbox).controlSize(.small).labelsHidden()
            // 点标题折叠/展开；勾选框在外面，免得一点全选就把分组收起来
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(includedCount == changes.count ? "\(changes.count)" : "\(includedCount) / \(changes.count)")
                    .font(Theme.smallFont).foregroundStyle(Theme.mutedText)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { isCollapsed.toggle() }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.treeRowHeight)
    }
}

private struct ChangeRow: View {
    let session: ProjectSession
    @ObservedObject var commit: CommitController
    let clicks: DoubleClickDetector
    let change: GitChange
    @State private var isHovering = false
    @State private var pendingAction: PendingAction?

    private var isActive: Bool { session.activeTab?.change?.path == change.path }

    private var fileName: some View {
        Text(change.fileName)
            .font(Theme.uiFont)
            .foregroundStyle(VCSColors.color(for: change.kind))
            .strikethrough(change.kind == .deleted)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var secondaryTexts: some View {
        if !change.directory.isEmpty {
            Text(change.directory).font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1).fixedSize()
        }
        if let original = change.originalPath {
            Text("← \(original)").font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1).fixedSize()
        }
    }

    var body: some View {
        let icon = FileIcon.file(named: change.fileName)
        HStack(spacing: 6) {
            // 缩进到分组标题的文字下面：它们是分组的子级
            Spacer().frame(width: 40)
            Toggle("", isOn: Binding(
                get: { commit.isIncluded(change) },
                set: { commit.setIncluded($0, for: change) }
            ))
            .toggleStyle(.checkbox).controlSize(.small).labelsHidden()
            Image(systemName: icon.systemName).font(.system(size: 12)).foregroundStyle(icon.color).frame(width: 16)
            // 放得下就带目录名（和重命名前的路径），放不下就只留文件名——目录名被截成一两个字母比没有更难看
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    fileName
                    secondaryTexts
                }
                fileName
            }
            Spacer(minLength: 4)
            // 状态字永远完整显示；空间不够时先截目录、再截文件名
            Text(change.kind.label)
                .font(.system(size: 10))
                .foregroundStyle(VCSColors.color(for: change.kind).opacity(0.85))
                .fixedSize()
                .layoutPriority(2)
        }
        .padding(.trailing, 10)
        .frame(height: Theme.treeRowHeight)
        .background(Rectangle().fill(isActive ? Theme.selection : (isHovering ? Theme.hover.opacity(0.5) : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // 按下立刻出预览 diff，双击间隔内的第二下把它固定
        .onPress { _ in
            session.openDiff(change, pinned: false)
        } release: { isClick in
            if isClick, clicks.registerClick(on: change.path) { session.openDiff(change, pinned: true) }
        }
        .contextMenu {
            Button("显示 diff") { session.openDiff(change, pinned: true) }
            if change.kind != .deleted, let url = session.url(for: change) {
                Button("打开文件") { session.openFile(url, pinned: true) }
                Button("在项目视图中显示") { session.reveal(url) }
            }
            Divider()
            if change.kind == .untracked {
                Button("删除…") { pendingAction = .delete(change) }
            } else {
                Button("回滚…") { pendingAction = .rollback(change) }
            }
        }
        .alert(item: $pendingAction) { action in
            switch action {
            case .rollback(let change):
                return Alert(
                    title: Text("回滚 \(change.fileName)？"),
                    message: Text(change.kind == .added
                        ? "这是一个新增的文件，回滚会把它从 git 和磁盘上一起删掉。"
                        : "会把它恢复到 HEAD 的样子，本地改动会丢失。"),
                    primaryButton: .destructive(Text("回滚")) { commit.rollback(change) },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .delete(let change):
                return Alert(
                    title: Text("删除 \(change.fileName)？"),
                    message: Text("文件会移到废纸篓。"),
                    primaryButton: .destructive(Text("删除")) { commit.deleteUntracked(change) },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }
}

/// 右键菜单里要确认的危险操作。
private enum PendingAction: Identifiable {
    case rollback(GitChange)
    case delete(GitChange)

    var id: String {
        switch self {
        case .rollback(let change): return "rollback:" + change.path
        case .delete(let change): return "delete:" + change.path
        }
    }
}

/// 底部：提交信息 + 提交 / 提交并推送。
private struct CommitPanel: View {
    @ObservedObject var commit: CommitController
    let branch: GitBranch
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if commit.message.isEmpty {
                    Text("提交信息").foregroundStyle(Theme.mutedText).padding(.horizontal, 6).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $commit.message)
                    .font(Theme.uiFont)
                    .scrollContentBackground(.hidden)
                    .padding(2)
                    .focused($messageFocused)
            }
            .frame(minHeight: 64, maxHeight: 120)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.editorBackground))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(messageFocused ? Theme.accent : Theme.border, lineWidth: 1))

            HStack(spacing: 8) {
                Button("提交") { commit.commit(push: false) }
                    .disabled(!commit.canCommit)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("提交并推送") { commit.commit(push: true) }
                    .disabled(!commit.canCommit)
                Spacer()
                if commit.isCommitting || commit.isPushing {
                    ProgressView().controlSize(.small)
                    Text(commit.isPushing ? "推送中…" : "提交中…").font(Theme.smallFont).foregroundStyle(Theme.secondaryText)
                } else if branch.ahead > 0 {
                    pushButton("推送 ↑\(branch.ahead)", color: Theme.accent)
                        .help("把本地领先的 \(branch.ahead) 个提交推到远端")
                } else if branch.upstream == nil, !branch.isUnborn {
                    pushButton("推送（建上游）", color: Theme.secondaryText)
                }
            }
            .controlSize(.small)

            if let status = commit.status {
                HStack(alignment: .top, spacing: 6) {
                    switch status {
                    case .success(let text):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        Text(text).foregroundStyle(Theme.secondaryText)
                    case .failure(let text):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                        Text(text).foregroundStyle(Theme.text).textSelection(.enabled)
                    }
                    Spacer()
                    Button { commit.dismissStatus() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.mutedText)
                }
                .font(Theme.smallFont)
                .lineLimit(4)
            }
        }
        .padding(10)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func pushButton(_ title: String, color: Color) -> some View {
        Button {
            commit.pushCurrentBranch()
        } label: {
            Label(title, systemImage: "arrow.up.circle").font(Theme.smallFont)
        }
        .buttonStyle(.plain).foregroundStyle(color)
        .disabled(!commit.canPush)
    }
}
