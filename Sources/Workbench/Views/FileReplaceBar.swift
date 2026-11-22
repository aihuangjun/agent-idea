import DesignSystem
import SwiftUI

struct FileReplaceBar: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var replace: FileReplaceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FocusedTextField(text: $replace.query, placeholder: "查找文字", focusRequests: replace.focusRequests) { key in
                    switch key {
                    case .submit: run(false); return true
                    case .cancel: close(); return true
                    default: return false
                    }
                }.frame(minWidth: 100, maxWidth: 300)
                TextField("替换为", text: $replace.replacement).frame(minWidth: 100, maxWidth: 300)
                    .onSubmit { run(false) }
                Button("替换下一处") { run(false) }.disabled(replace.working || replace.query.isEmpty)
                Button("全部替换") { run(true) }.disabled(replace.working || replace.query.isEmpty)
                Spacer(minLength: 0)
                IconButton("xmark", help: "关闭替换（Esc）", size: 22, action: close)
            }
            HStack(spacing: 9) {
                Toggle("区分大小写", isOn: $replace.caseSensitive)
                Toggle("全词", isOn: $replace.wholeWords)
                Toggle("正则", isOn: $replace.regex)
                if replace.selection != nil { Toggle("仅选区", isOn: $replace.inSelection) }
                if let status = replace.status { Text(status).foregroundStyle(Theme.secondaryText).lineLimit(1) }
            }.toggleStyle(.checkbox).font(Theme.smallFont)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.panel)
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func run(_ all: Bool) { Task { await replace.replace(all: all, using: session.renderer) } }

    private func close() {
        session.fileReplace = nil
        session.focusContent()
    }
}
