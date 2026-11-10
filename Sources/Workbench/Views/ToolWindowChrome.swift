import DesignSystem
import SwiftUI

/// 工具窗口顶上的标题条。
///
/// 外壳经环境值 `hideToolWindow` 递进来「收起这个工具窗口」时，最右边多一个「—」按钮（照 IDEA 标题条右侧的 Hide）。
/// 走环境值而不是 `@EnvironmentObject`：单独挂一个工具窗口的测试不给 WorkbenchModel 也不会崩，只是没有这个按钮。
struct ToolWindowHeader<Detail: View, Actions: View>: View {
    let title: String
    /// 标题后面跟的东西。
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let actions: () -> Actions
    @Environment(\.hideToolWindow) private var hideToolWindow

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
            if let hideToolWindow {
                IconButton(ToolWindowIcon.hide, help: ToolWindowIcon.hideHelp, size: 22, action: hideToolWindow)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

private struct HideToolWindowKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// 收起左侧当前的工具窗口。`ProjectContent` 给左边那一组设。
    var hideToolWindow: (() -> Void)? {
        get { self[HideToolWindowKey.self] }
        set { self[HideToolWindowKey.self] = newValue }
    }
}

extension ToolWindowHeader where Detail == EmptyView {
    init(title: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, detail: { EmptyView() }, actions: actions)
    }
}

/// 工具窗口标题条上按钮的图标名：同一个动作在哪个窗口都得长成同一个样子，所以名字只写在这里一处。
enum ToolWindowIcon {
    /// 拉取最新（`git fetch` + `rebase`，Git 菜单的 ⌘T）。项目工具窗口的按钮、提交历史能拉取时的刷新按钮做的是同一件事。
    static let syncWithRemote = "arrow.down.backward"
    /// 只重列本地的状态，不联网。
    static let refresh = "arrow.clockwise"
    /// 「运行」窗口：重新运行、停止、清空输出、收起。
    static let rerun = "play.fill"
    static let stop = "stop.fill"
    static let clear = "trash"
    static let hide = "minus"
    /// 左侧工具窗口标题条上「—」按钮的提示（照 IDEA）。⇧Esc 是菜单「显示 → 工具窗口 → 隐藏工具窗口」的键。
    static let hideHelp = "隐藏（⇧Esc）"
    /// 提交历史：退出比较模式，回到普通历史列表。
    static let exitComparison = "xmark"
    /// 提交历史：退出文件历史（显示历史），回到全部提交。
    static let exitPathHistory = "xmark"
    /// 「查找」工具窗口（在项目中查找）：工具条上的开关，以及全部折叠 / 全部展开。
    static let findInPath = "text.magnifyingglass"
    static let collapseAll = "arrow.down.right.and.arrow.up.left"
    static let expandAll = "arrow.up.left.and.arrow.down.right"
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
