import DesignSystem
import SwiftUI

/// 工具窗口顶上的标题条。
struct ToolWindowHeader<Actions: View>: View {
    let title: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            actions()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// 工具窗口标题条上按钮的图标名：同一个动作在哪个窗口都得长成同一个样子，所以名字只写在这里一处。
enum ToolWindowIcon {
    /// 与远程同步（`git fetch` + `rebase`）。项目工具窗口的同步按钮、提交历史能同步时的刷新按钮做的是同一件事。
    static let syncWithRemote = "arrow.down.backward"
    /// 只重列本地的状态，不联网。
    static let refresh = "arrow.clockwise"
}

/// 工具窗口里的空态，几个窗口共用。
struct ToolWindowEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            Text(detail).font(Theme.smallFont).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}
