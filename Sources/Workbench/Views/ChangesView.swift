import AppKit
import Core
import DesignSystem
import SwiftUI

/// 变更列表 + 提交面板（IDEA 的 Commit 工具窗口）。
///
/// 列表能多选（照 IDEA）：单击选一条并看它的 diff，⌘点击加减、⇧点击连选；右键点在多选里就对整个多选回滚 / 删除，
/// ⌫ 删除选中的。选中放在会话里（`ProjectSession.changeSelection`），切走工具窗口再回来还在。
struct ChangesView: View {
    @ObservedObject var session: ProjectSession
    @State private var trackedCollapsed = false
    @State private var untrackedCollapsed = false
    @State private var clicks = DoubleClickDetector(interval: NSEvent.doubleClickInterval)
    @FocusState private var isFocused: Bool
    /// 正在重命名的文件。对话框挂在整个面板上而不是行上：行在 LazyVStack 里，git 一刷新就可能被回收，
    /// 挂在行上的 sheet 会跟着消失。
    @State private var renaming: FileNode?
    /// 等确认的回滚 / 删除。同样挂在面板上而不是行上（理由同上）。
    @State private var pending: DestructiveConfirmation?

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowHeader(title: "提交") {
                if session.isRefreshingGit {
                    ProgressView().controlSize(.mini).padding(.trailing, 4)
                }
                IconButton(ToolWindowIcon.refresh, help: "刷新（⌘R）：重列工作区的改动，不联网", size: 22) { session.refreshGit() }
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
        .sheet(item: $renaming) { node in
            RenameSheet(node: node) { session.renameProblem(for: node, newName: $0) } commit: { session.rename(node, to: $0) }
        }
        .destructiveConfirmation($pending)
    }

    private func changeList(commit: CommitController) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !session.changeGroups.tracked.isEmpty {
                    GroupHeader(title: "变更", changes: session.changeGroups.tracked, commit: commit, isCollapsed: $trackedCollapsed)
                    if !trackedCollapsed {
                        ForEach(session.changeGroups.tracked) { change in row(change, commit: commit) }
                    }
                }
                if !session.changeGroups.untracked.isEmpty {
                    GroupHeader(title: "未跟踪文件", changes: session.changeGroups.untracked, commit: commit, isCollapsed: $untrackedCollapsed)
                    if !untrackedCollapsed {
                        ForEach(session.changeGroups.untracked) { change in row(change, commit: commit) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        // ⌫ / fn⌫ 删除选中的（IDEA 的 Delete），先确认
        .onKeyPress(.delete) { requestDeleteOfSelection(commit: commit) }
        .onKeyPress(.deleteForward) { requestDeleteOfSelection(commit: commit) }
    }

    /// 行的「选中」由这里算好再传进去：行视图只按传进去的值重画，自己去读会话的话 SwiftUI 看不出行有变化，
    /// 选中挪走了上一行的高亮也不会消失（0.3.0 的 bug）。
    private func row(_ change: GitChange, commit: CommitController) -> some View {
        ChangeRow(
            session: session, commit: commit, change: change,
            isSelected: session.changeSelection.contains(change.path),
            press: { press(change, modifiers: $0) },
            release: { if $0, clicks.registerClick(on: change.path) { session.openDiff(change, pinned: true) } },
            onRename: { renaming = $0 },
            onRollback: { requestRollback(visible($0)) },
            onDelete: { requestDelete(visible($0), commit: commit) }
        )
    }

    /// 看得见的行，按列表顺序（⇧点击连选按它；折叠起来的分组不算）。
    private var visibleOrder: [String] {
        ((trackedCollapsed ? [] : session.changeGroups.tracked) + (untrackedCollapsed ? [] : session.changeGroups.untracked)).map(\.path)
    }

    /// 按下一行。返回这是不是一次「普通单击」（松开时才参与双击判定，双击固定标签）。
    private func press(_ change: GitChange, modifiers: NSEvent.ModifierFlags) -> Bool {
        isFocused = true
        // ⌃点击是右键菜单，不动选中
        if modifiers.contains(.control) { return false }
        if modifiers.contains(.command) {
            session.toggleChangeSelection(change.path, order: visibleOrder)
            return false
        }
        if modifiers.contains(.shift) {
            session.extendChangeSelection(to: change.path, order: visibleOrder)
            return false
        }
        // 按下立刻出预览 diff，双击间隔内的第二下把它固定
        session.selectChange(change.path)
        session.openDiff(change, pinned: false)
        return true
    }

    /// 只留看得见的：折叠起来的分组里残留的选中不该被一起删掉 / 回滚——用户根本看不见它们。
    private func visible(_ changes: [GitChange]) -> [GitChange] {
        let shown = Set(visibleOrder)
        return changes.filter { shown.contains($0.path) }
    }

    private func requestDeleteOfSelection(commit: CommitController) -> KeyPress.Result {
        let selected = visible(session.selectedChanges)
        guard selected.contains(where: commit.canDelete) else { return .ignored }
        requestDelete(selected, commit: commit)
        return .handled
    }

    /// 回滚一条或几条。未跟踪的不在 git 里、没有可回滚的目标，跳过（弹窗里说一声）。
    private func requestRollback(_ changes: [GitChange]) {
        let targets = changes.filter { $0.kind != .untracked }
        guard let first = targets.first else { return }
        let added = targets.filter { $0.kind == .added }.count
        var message: String
        if targets.count == 1 {
            message = first.kind == .added
                ? "这是一个新增的文件，回滚会把它从 git 和磁盘上一起删掉。"
                : "会把它恢复到 HEAD 的样子，本地改动会丢失。"
        } else {
            message = "会把它们恢复到 HEAD 的样子，本地改动会丢失。"
            if added > 0 { message += "其中 \(added) 个是新增的文件，会从 git 和磁盘上一起删掉。" }
        }
        let skipped = changes.count - targets.count
        if skipped > 0 { message += "选中的 \(skipped) 个未跟踪文件不在 git 里，不受影响（要删掉它们用「删除」）。" }
        pending = DestructiveConfirmation(
            id: "rollback:" + targets.map(\.path).joined(separator: "\n"),
            title: targets.count == 1 ? "回滚 \(first.fileName)？" : "回滚 \(targets.count) 个文件？",
            message: message,
            buttonTitle: "回滚"
        ) { session.rollback(targets) }
    }

    /// 删除一条或几条（进废纸篓）。「已删除」的变更磁盘上没有东西可删，跳过。
    private func requestDelete(_ changes: [GitChange], commit: CommitController) {
        let targets = changes.filter(commit.canDelete)
        guard let first = targets.first else { return }
        let allUntracked = targets.allSatisfy { $0.kind == .untracked }
        var message: String
        if targets.count == 1 {
            message = allUntracked ? "文件会移到废纸篓。" : "文件会移到废纸篓，git 里会显示为已删除；要不要提交这次删除由你决定。"
        } else {
            message = allUntracked ? "它们会移到废纸篓。" : "它们会移到废纸篓；已跟踪的在 git 里会显示为已删除，要不要提交这次删除由你决定。"
        }
        let skipped = changes.count - targets.count
        if skipped > 0 { message += "另外 \(skipped) 个是已删除的变更，磁盘上已经没有文件，跳过。" }
        pending = DestructiveConfirmation(
            id: "delete:" + targets.map(\.path).joined(separator: "\n"),
            title: targets.count == 1 ? "删除 \(first.fileName)？" : "删除 \(targets.count) 个文件？",
            message: message,
            buttonTitle: "删除"
        ) { session.delete(targets) }
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
    let change: GitChange
    let isSelected: Bool
    /// 按下：返回这是不是一次普通单击（⌘ / ⇧点击只改选中，不算）。
    let press: (NSEvent.ModifierFlags) -> Bool
    /// 松开：参数是「没拖动、算一次点击」。只在按下时是普通单击才会调。
    let release: (Bool) -> Void
    let onRename: (FileNode) -> Void
    let onRollback: ([GitChange]) -> Void
    let onDelete: ([GitChange]) -> Void
    @State private var isHovering = false
    @State private var isPlainPress = false

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
        .background(Rectangle().fill(isSelected ? Theme.selection : (isHovering ? Theme.hover.opacity(0.5) : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onPress(modifiers: { _, modifiers in
            isPlainPress = press(modifiers)
        }, release: { isClick in
            if isPlainPress { release(isClick) }
            isPlainPress = false
        })
        // 没有「显示 diff」：点这一行本来就是看 diff
        .contextMenu { menu }
    }

    /// 右键点在多选里：对整个多选回滚 / 删除（只对一条才有意义的打开、定位、重命名不出现）；否则只对这一条。
    @ViewBuilder private var menu: some View {
        let targets = session.changesForAction(on: change)
        if targets.count > 1 {
            let rollbackable = targets.filter { $0.kind != .untracked }.count
            let deletable = targets.filter(commit.canDelete).count
            if rollbackable > 0 { Button("回滚 \(rollbackable) 个文件…") { onRollback(targets) } }
            if deletable > 0 { Button("删除 \(deletable) 个文件…") { onDelete(targets) } }
        } else {
            // 分隔线跟着这一组走：已删除的变更这一组整个没有，菜单第一项就不该是一条线
            if change.kind != .deleted, let url = session.url(for: change) {
                Button("打开文件") { session.openFile(url, pinned: true) }
                Button("在项目视图中显示") { session.reveal(url) }
                Divider()
            }
            if change.kind != .untracked {
                Button("回滚…") { onRollback([change]) }
            }
            if let node = session.node(for: change) {
                Button("重命名…") { onRename(node) }
            }
            if commit.canDelete(change) {
                Button("删除…") { onDelete([change]) }
            }
        }
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
                // 两个都是蓝色主按钮、悬停反馈一样：它们是同一件事的两种收尾，不该一个蓝一个灰分出主次
                Button("提交") { commit.commit(push: false) }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!commit.canCommit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .toolTip("提交勾选的变更（⌘⏎）")
                Button("提交并推送") { commit.commit(push: true) }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!commit.canCommit)
                    .toolTip("提交勾选的变更，然后推送到远端")
                Spacer()
                if commit.isCommitting || commit.isPushing {
                    ProgressView().controlSize(.small)
                    Text(commit.isPushing ? "推送中…" : "提交中…").font(Theme.smallFont).foregroundStyle(Theme.secondaryText)
                } else if branch.ahead > 0 {
                    pushButton("推送 ↑\(branch.ahead)", color: Theme.accent)
                        .toolTip("把本地领先的 \(branch.ahead) 个提交推到远端")
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
