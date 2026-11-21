import DesignSystem
import SwiftUI

struct DefinitionPicker: View {
    let session: ProjectSession
    let choices: DefinitionChoices
    @State private var selection: DefinitionTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(choices.title ?? "「\(choices.name)」的定义").font(.headline)
            if choices.truncated {
                Text("项目较大，以下是已扫描文件中的结果。")
                    .font(Theme.smallFont).foregroundStyle(Theme.secondaryText)
            }
            List(choices.targets, selection: $selection) { target in
                VStack(alignment: .leading, spacing: 3) {
                    if let symbol = target.symbol {
                        Text(symbol.qualifiedName).font(Theme.uiFont)
                    }
                    Text("\(session.referencePath(of: target.url)):\(target.line + 1):\(target.column + 1)")
                        .font(target.symbol == nil ? Theme.uiFont : Theme.smallFont)
                        .foregroundStyle(target.symbol == nil ? Theme.text : Theme.secondaryText)
                }
                .tag(target)
            }
            .frame(height: min(300, max(80, CGFloat(choices.targets.count) * (choices.title == nil ? 24 : 40) + 8)))
            HStack {
                Spacer()
                Button("取消") { session.definitionChoices = nil }.keyboardShortcut(.cancelAction)
                Button("跳转") {
                    if let selection { session.openDefinition(selection, name: choices.name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 460)
        .onAppear { selection = choices.targets.first }
    }
}
