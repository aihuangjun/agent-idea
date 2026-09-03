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
                            ChangeRow(session: session, commit: commit, clicks: clicks, change: change, isActive: isActive(change))
                        }
                    }
                }
                if !session.changeGroups.untracked.isEmpty {
                    GroupHeader(title: "未跟踪文件", changes: session.changeGroups.untracked, commit: commit, isCollapsed: $untrackedCollapsed)
                    if !untrackedCollapsed {
                        ForEach(session.changeGroups.untracked) { change in
                            ChangeRow(session: session, commit: commit, clicks: clicks, change: change, isActive: isActive(change))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// 当前标签就是这条变更的 diff。由这里算好再传给行：行视图只按传进去的值重画，
    /// 自己去读 `session.activeTab` 的话 SwiftUI 看不出行有变化，切到别的文件时上一行的高亮不会消失（0.3.0 的 bug）。
    private func isActive(_ change: GitChange) -> Bool {
        session.activeTab?.change?.path == change.path
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
    let isActive: Bool
    @State private var isHovering = false
    @State private var pendingAction: DestructiveConfirmation?

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
            ChangeFileLabel(change: change)
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
            if change.kind != .untracked {
                Button("回滚…") {
                    pendingAction = DestructiveConfirmation(
                        id: "rollback:" + change.path,
                        title: "回滚 \(change.fileName)？",
                        message: change.kind == .added
                            ? "这是一个新增的文件，回滚会把它从 git 和磁盘上一起删掉。"
                            : "会把它恢复到 HEAD 的样子，本地改动会丢失。",
                        buttonTitle: "回滚"
                    ) { commit.rollback(change) }
                }
            }
            if commit.canDelete(change) {
                Button("删除…") {
                    pendingAction = DestructiveConfirmation(
                        id: "delete:" + change.path,
                        title: "删除 \(change.fileName)？",
                        message: change.kind == .untracked
                            ? "文件会移到废纸篓。"
                            : "文件会移到废纸篓，git 里会显示为已删除；要不要提交这次删除由你决定。",
                        buttonTitle: "删除"
                    ) { commit.delete(change) }
                }
            }
        }
        .destructiveConfirmation($pendingAction)
    }
}

/// 底部：提交信息 + 提交 / 提交并推送。
private struct CommitPanel: View {
    @ObservedObject var commit: CommitController
    let branch: GitBranch
    @State private var messageFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 占位符由编辑框自己画在第一行文字的位置上，光标与提示对齐（见 PlainTextEditor）
            PlainTextEditor(text: $commit.message, placeholder: "提交信息", isFocused: $messageFocused)
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
                StatusLine(status: status) { commit.dismissStatus() }
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
