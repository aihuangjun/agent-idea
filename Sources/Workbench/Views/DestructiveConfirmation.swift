import SwiftUI

/// 一个要先确认的危险操作（删除、回滚）。目录树、变更列表、提交历史共用同一种弹窗。
struct DestructiveConfirmation: Identifiable {
    let id: String
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void
}

extension View {
    /// `item` 非空时弹确认框：红色的执行按钮 + 取消。点了任一个都把 `item` 清掉。
    func destructiveConfirmation(_ item: Binding<DestructiveConfirmation?>) -> some View {
        alert(
            item.wrappedValue?.title ?? "",
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            presenting: item.wrappedValue
        ) { confirmation in
            Button(confirmation.buttonTitle, role: .destructive) { confirmation.action() }
            Button("取消", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
