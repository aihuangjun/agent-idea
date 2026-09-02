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
