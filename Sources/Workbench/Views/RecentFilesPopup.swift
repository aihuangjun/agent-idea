import Core
import DesignSystem
import SwiftUI

/// 最近的文件（⌘E，IDEA 的 Recent Files）：浮在项目主体上方的小弹窗。输入即过滤、↑ ↓ 换、回车打开、Esc 关，点外面也关。
///
/// 挂在 `ProjectContent` 上而不是编辑区的标签栏那一组里：关掉所有标签之后 ⌘E 照样要能用（那时最需要它）。
/// 行沿用查找文件的 `FileSearchRow`；选中状态作为值传进去。
struct RecentFilesPopup: View {
    let session: ProjectSession
    @ObservedObject var recent: RecentFilesController

    var body: some View {
        if recent.isShown {
            ZStack(alignment: .top) {
                // 点弹窗外面：关掉（IDEA 的弹窗一样）。几乎透明但接得住点击
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onPress { _ in recent.close() }
                panel.padding(.top, 48)
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("最近的文件").font(Theme.smallFont.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("回车打开 · Esc 关闭").font(Theme.smallFont).foregroundStyle(Theme.mutedText)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                FocusedTextField(text: $recent.query, placeholder: "输入文件名过滤", focusRequests: recent.focusRequests) { key in
                    switch key {
                    case .up: recent.moveSelection(by: -1)
                    case .down: recent.moveSelection(by: 1)
                    case .submit: if let match = recent.selectedResult { session.openRecentFile(match) }
                    case .cancel: recent.close()
                    }
                    return true
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBackground))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent, lineWidth: 1))
            .padding(.horizontal, 8).padding(.bottom, 6)
            Rectangle().fill(Theme.border).frame(height: 1)
            list
        }
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    @ViewBuilder
    private var list: some View {
        if recent.results.isEmpty {
            Text(recent.query.isEmpty ? "还没有打开过别的文件" : "没有匹配的文件")
                .font(Theme.smallFont).foregroundStyle(Theme.mutedText)
                .frame(maxWidth: .infinity).frame(height: 44)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(recent.results.enumerated()), id: \.element.entry.path) { index, match in
                            FileSearchRow(match: match, isSelected: index == recent.selectedIndex) {
                                recent.select(index)
                            } open: {
                                session.openRecentFile(match)
                            }
                            .id(match.entry.path)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: min(CGFloat(recent.results.count) * Theme.treeRowHeight + 8, 320))
                .onChange(of: recent.selectedIndex) { _, index in
                    if recent.results.indices.contains(index) { proxy.scrollTo(recent.results[index].entry.path) }
                }
            }
        }
    }
}
