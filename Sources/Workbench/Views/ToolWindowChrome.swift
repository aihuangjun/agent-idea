import DesignSystem
import SwiftUI

/// 工具窗口顶上的标题条。
struct ToolWindowHeader<Detail: View, Actions: View>: View {
    let title: String
    /// 标题后面跟的东西（运行窗口：脚本名与状态）。
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let actions: () -> Actions

    init(title: String, @ViewBuilder detail: @escaping () -> Detail, @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            detail().padding(.leading, 8)
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

extension ToolWindowHeader where Detail == EmptyView {
    init(title: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, detail: { EmptyView() }, actions: actions)
    }
}

/// 工具窗口标题条上按钮的图标名：同一个动作在哪个窗口都得长成同一个样子，所以名字只写在这里一处。
enum ToolWindowIcon {
    /// 与远程同步（`git fetch` + `rebase`）。项目工具窗口的同步按钮、提交历史能同步时的刷新按钮做的是同一件事。
    static let syncWithRemote = "arrow.down.backward"
    /// 只重列本地的状态，不联网。
    static let refresh = "arrow.clockwise"
    /// 「运行」窗口：重新运行、停止、清空输出、收起。
    static let rerun = "play.fill"
    static let stop = "stop.fill"
    static let clear = "trash"
    static let hide = "minus"
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
