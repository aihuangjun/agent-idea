import Core
import DesignSystem
import SwiftUI

/// 底部状态栏：分支、变更数、当前文件信息。
struct StatusBarView: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(spacing: 14) {
            if session.hasGit {
                Button {
                    workbench.toolWindow = .commit
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text(branchText).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("当前分支。点击打开提交视图")
                if session.changeGroups.total > 0 {
                    Text("\(session.changeGroups.total) 个变更").foregroundStyle(Theme.vcsModified)
                }
                if session.isRefreshingGit {
                    ProgressView().controlSize(.mini)
                }
            } else {
                Text("无 git").foregroundStyle(Theme.mutedText)
            }
            if let banner = session.banner {
                Text(banner).foregroundStyle(Theme.warning).lineLimit(1)
                Button { session.banner = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
            }
            Spacer()
            if let content = session.activeContent {
                ForEach(Array(content.statusSummary.enumerated()), id: \.offset) { _, item in
                    Text(item)
                }
            }
            if workbench.zoom != 1 {
                Button { workbench.resetZoom() } label: { Text("\(Int((workbench.zoom * 100).rounded()))%") }
                    .buttonStyle(.plain).help("点击恢复 100%")
            }
        }
        .font(Theme.smallFont)
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: Theme.statusBarHeight)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var branchText: String {
        let branch = session.gitSnapshot.branch
        if branch.isUnborn && branch.name.isEmpty { return "（无提交）" }
        var text = branch.name.isEmpty ? "HEAD" : branch.name
        if branch.ahead > 0 { text += " ↑\(branch.ahead)" }
        if branch.behind > 0 { text += " ↓\(branch.behind)" }
        return text
    }
}
