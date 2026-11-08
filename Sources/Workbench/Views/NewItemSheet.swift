import Core
import DesignSystem
import SwiftUI

/// 新建文件 / 文件夹共用名字输入、即时校验和键盘操作。
struct NewItemSheet: View {
    /// 建在哪个目录下；`location` 是给用户看的相对路径（根目录显示「项目根目录」）。
    let kind: NewItemKind
    let location: String
    let validate: (String) -> FileRename.Problem?
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var problem: FileRename.Problem? { validate(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).font(.system(size: 15, weight: .semibold))
            Text("位置：\(location)").foregroundStyle(Theme.secondaryText).lineLimit(2).truncationMode(.middle)
            FocusedTextField(text: $name, placeholder: kind == .file ? "文件名（含扩展名），如 notes.md" : "文件夹名") { key in
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
            if kind == .file {
                Text("直接输入完整文件名，支持任意扩展名，也可不带扩展名。")
                    .font(Theme.smallFont).foregroundStyle(Theme.secondaryText)
            }
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

enum NewItemKind {
    case file, folder
    var title: String { self == .file ? "新建文件" : "新建文件夹" }
}

/// 「在哪个目录下新建什么」——`sheet(item:)` 要一个 Identifiable。
struct NewItemRequest: Identifiable {
    let directory: URL
    let kind: NewItemKind
    var id: String { kind.title + ":" + directory.path }
}
