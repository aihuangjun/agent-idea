import SwiftUI

/// 一个动手之前要先确认的操作（删除、回滚，以及把被 .gitignore 忽略的东西添加到 git）。
/// 目录树、变更列表、提交历史共用同一种弹窗。
struct DestructiveConfirmation: Identifiable {
    let id: String
    let title: String
    let message: String
    let buttonTitle: String
    /// 执行按钮画成红色。删除、回滚这种会丢东西的才是 true；只是「意外容易踩」的（添加被忽略的文件）用普通按钮。
    var isDestructive = true
    let action: () -> Void
}

extension View {
    /// `item` 非空时弹确认框：执行按钮（危险的画红）+ 取消。点了任一个都把 `item` 清掉。
    func destructiveConfirmation(_ item: Binding<DestructiveConfirmation?>) -> some View {
        alert(
            item.wrappedValue?.title ?? "",
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            presenting: item.wrappedValue
        ) { confirmation in
            Button(confirmation.buttonTitle, role: confirmation.isDestructive ? .destructive : nil) { confirmation.action() }
            Button("取消", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
