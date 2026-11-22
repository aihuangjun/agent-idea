import Core
import DesignSystem
import SwiftUI

struct DefinitionPicker: View {
    let session: ProjectSession
    let choices: DefinitionChoices
    @State private var selection: DefinitionTarget?
    @State private var excerpt: [SourceExcerpt.Line] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(choices.title ?? "「\(choices.name)」的定义").font(.headline)
            if choices.truncated {
                Text(choices.coverageMessage ?? "项目较大，以下是已扫描文件中的结果。")
                    .font(Theme.smallFont).foregroundStyle(Theme.secondaryText)
            }
            List(selection: $selection) {
                if choices.groupByFile {
                    let groups = Dictionary(grouping: choices.targets, by: \.url)
                    ForEach(groups.keys.sorted { $0.path < $1.path }, id: \.self) { url in
                        Section(session.referencePath(of: url)) {
                            ForEach(groups[url] ?? []) { target in targetRow(target, showFile: false) }
                        }
                    }
                } else {
                    ForEach(choices.targets) { target in targetRow(target, showFile: true) }
                }
            }
            .frame(height: min(300, max(80, CGFloat(choices.targets.count) * (choices.title == nil ? 24 : 40) + 8)))
            if choices.preview {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        if excerpt.isEmpty { Text("暂无源码预览").foregroundStyle(Theme.secondaryText) }
                        ForEach(excerpt) { line in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(line.id + 1)").foregroundStyle(Theme.mutedText).frame(width: 48, alignment: .trailing)
                                Text(line.text.isEmpty ? " " : line.text)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .background(line.id == selection?.line ? Theme.accent.opacity(0.18) : .clear)
                        }
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }
                .frame(height: 196)
                .background(Theme.editorBackground)
                .task(id: selection) {
                    excerpt = []
                    guard let selection else { return }
                    let lines = await session.definitionPreview(selection)
                    if !Task.isCancelled { excerpt = lines }
                }
            }
            HStack {
                Spacer()
                Button(choices.preview ? "关闭" : "取消") {
                    session.definitionChoices = nil
                    session.focusContent()
                }.keyboardShortcut(.cancelAction)
                Button("跳转") {
                    if let selection { session.openDefinition(selection, name: choices.name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(minWidth: choices.preview ? 620 : 460)
        .onAppear { selection = choices.targets.first }
    }

    private func targetRow(_ target: DefinitionTarget, showFile: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = target.label ?? target.symbol?.qualifiedName { Text(title).font(Theme.uiFont) }
            let position = "\(target.line + 1):\(target.column + 1)"
            Text(showFile ? "\(session.referencePath(of: target.url)):\(position)" : "第 \(position) 行列")
                .font(Theme.smallFont).foregroundStyle(Theme.secondaryText)
        }.tag(target)
    }
}
