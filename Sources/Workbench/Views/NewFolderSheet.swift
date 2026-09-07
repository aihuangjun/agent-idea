import Core
import DesignSystem
import SwiftUI

/// 新建文件夹对话框（IDEA 的 New → Directory）：边敲边校验，回车确认、Esc 取消。
struct NewFolderSheet: View {
    /// 建在哪个目录下；`location` 是给用户看的相对路径（根目录显示「项目根目录」）。
    let directory: URL
    let location: String
    let validate: (String) -> FileRename.Problem?
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var problem: FileRename.Problem? { validate(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建文件夹").font(.system(size: 15, weight: .semibold))
            Text("在 \(location) 下新建文件夹：").foregroundStyle(Theme.secondaryText)
            FocusedTextField(text: $name, placeholder: "文件夹名") { key in
                switch key {
                case .submit: submit()
                case .cancel: dismiss()
                default: return false
                }
                return true
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBackground))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent, lineWidth: 1))
            // 还没敲字不算错，按钮灰掉就够了
            Text(problem.flatMap { $0 == .empty ? nil : $0.message } ?? " ")
                .font(Theme.smallFont).foregroundStyle(Theme.danger)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建") { submit() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
    }

    private func submit() {
        guard problem == nil else { return }
        dismiss()
        commit(name)
    }
}

/// 「在哪个目录下新建」——`sheet(item:)` 要一个 Identifiable。
struct NewFolderRequest: Identifiable {
    let directory: URL
    var id: String { directory.path }
}
