import Core
import DesignSystem
import SwiftUI

/// 重命名对话框（IDEA 的 Rename）：名字框一打开就选中扩展名之前那一段，边敲边校验，回车确认、Esc 取消。
struct RenameSheet: View {
    let node: FileNode
    /// 新名字有什么问题（nil 表示能用），由会话按磁盘判断。
    let validate: (String) -> FileRename.Problem?
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(node: FileNode, validate: @escaping (String) -> FileRename.Problem?, commit: @escaping (String) -> Void) {
        self.node = node
        self.validate = validate
        self.commit = commit
        _name = State(initialValue: node.name)
    }

    private var problem: FileRename.Problem? { validate(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名").font(.system(size: 15, weight: .semibold))
            Text("将\(node.isDirectory ? "目录" : "文件")“\(node.name)”重命名为：").foregroundStyle(Theme.secondaryText)
            FocusedTextField(text: $name, initialSelection: FileRename.editableRange(of: node.name, isDirectory: node.isDirectory)) { key in
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
            // 「名字没有变」不算错，按钮灰掉就够了
            Text(problem.flatMap { $0 == .unchanged ? nil : $0.message } ?? " ")
                .font(Theme.smallFont).foregroundStyle(Theme.danger)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("重命名") { submit() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
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
