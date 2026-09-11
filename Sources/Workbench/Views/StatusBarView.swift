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
                // IDEA 的分支小部件：点一下弹出分支列表，切分支、新建分支都在里面
                Button {
                    if session.isBranchPopupShown { session.isBranchPopupShown = false } else { session.showBranches() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text(branchText).lineLimit(1)
                        if session.isSwitchingBranch { ProgressView().controlSize(.mini) }
                    }
                }
                .buttonStyle(.plain)
                .toolTip("当前分支。点击切换 / 新建分支（Git → 分支…）")
                .popover(isPresented: $session.isBranchPopupShown, arrowEdge: .top) { BranchPopup(session: session) }
                if session.changeGroups.total > 0 {
                    Button { workbench.toolWindow = .commit } label: {
                        Text("\(session.changeGroups.total) 个变更").foregroundStyle(Theme.vcsModified)
                    }
                    .buttonStyle(.plain)
                    .toolTip("点击打开提交视图（⌘0）")
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
        // 新建分支的对话框与「从哪儿同步」的选择挂在状态栏上：它总在界面上（弹窗、项目工具窗口都可能关着），⌘T 也能弹出来
        .sheet(item: $session.newBranchRequest) { request in NewBranchSheet(session: session, base: request.base) }
        .alert(
            session.upstreamPrompt?.title ?? "",
            isPresented: Binding(get: { session.upstreamPrompt != nil }, set: { if !$0 { session.upstreamPrompt = nil } }),
            presenting: session.upstreamPrompt
        ) { prompt in
            if let suggested = prompt.suggested, prompt.remote != nil {
                Button("跟踪 \(suggested) 并同步") { session.trackUpstream(suggested) }
            }
            if let remote = prompt.remote {
                Button("推送并建立上游") { session.pushSettingUpstream(to: remote) }
            }
            Button(prompt.remote == nil ? "好" : "取消", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
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
