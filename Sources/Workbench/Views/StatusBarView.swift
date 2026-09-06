import Core
import DesignSystem
import SwiftUI

/// 底部状态栏：分支、变更数、当前文件信息。
struct StatusBarView: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    @EnvironmentObject private var preferences: ReadingPreferences
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
                .toolTip("当前分支。点击打开提交视图")
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
                // 出错的提示黄色；带「撤销」这种动作的是普通通知，用正文色
                Text(banner).foregroundStyle(session.bannerAction == nil ? Theme.warning : Theme.text).lineLimit(1)
                if let action = session.bannerAction {
                    Button(action.title) { action.perform() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                Button { session.dismissBanner() } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
            }
            Spacer()
            ForEach(Array(session.activeStatusSummary.enumerated()), id: \.offset) { _, item in
                Text(item)
            }
            if preferences.zoom != 1 {
                Button { preferences.resetZoom() } label: { Text("\(Int((preferences.zoom * 100).rounded()))%") }
                    .buttonStyle(.plain).toolTip("点击恢复 100%")
            }
            // 外观的快捷入口：点一下在「跟随系统 → 浅色 → 深色」之间转，图标就是当前这一档
            Button { preferences.theme = preferences.theme.next } label: {
                Image(systemName: preferences.theme.symbolName).font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .toolTip("外观：\(preferences.theme.title)。点击切到\(preferences.theme.next.title)（也在「视图 → 外观」里）")
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
