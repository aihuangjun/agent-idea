import Core
import DesignSystem
import SwiftUI

struct JavaRenameSheet: View {
    let session: ProjectSession
    let request: JavaRenameRequest
    @State private var name = ""
    @State private var preview: JavaSemanticSearch.RenamePreview?
    @State private var problem: String?
    @State private var preparing = false
    @State private var applying = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("重命名代码 · \(request.result.title ?? request.name)").font(.headline).lineLimit(2)
            HStack {
                FocusedTextField(text: $name, placeholder: "新的 Java 标识符", focusRequests: 1) { key in
                    switch key {
                    case .submit: prepare(); return true
                    case .cancel: if !applying { session.javaRename = nil }; return true
                    default: return false
                    }
                }.disabled(applying)
                Button("预览", action: prepare).disabled(preparing || applying || name.isEmpty || name == request.name)
            }
            if preparing || applying { ProgressView().controlSize(.small) }
            if let problem { Text(problem).foregroundStyle(Theme.danger).textSelection(.enabled) }
            if let preview {
                List(preview.files) { file in
                    Section {
                        ForEach(file.previewLines()) { row in
                            Text("第 \(row.line) 行 · \(row.before) → \(row.after)").font(.system(size: 12, design: .monospaced))
                        }
                    } header: {
                        if let path = preview.changes.first(where: { $0.path == file.path })?.newPath { Text("\(file.path) → \(path)") }
                        else { Text(file.path) }
                    }
                }
            } else {
                Text("将验证 \(request.result.hits.count) 处声明和引用").foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            HStack {
                Spacer()
                Button("取消") { session.javaRename = nil }.keyboardShortcut(.cancelAction).disabled(applying)
                Button("应用重命名", action: apply).disabled(preview == nil || preparing || applying)
            }
        }
        .padding(16).frame(width: 600, height: 410)
        .onChange(of: name) {
            task?.cancel()
            preparing = false
            preview = nil
            problem = nil
        }
        .onDisappear { task?.cancel() }
    }

    private func prepare() {
        guard !preparing, !applying, !name.isEmpty, name != request.name else { return }
        preparing = true
        problem = nil
        let proposed = name
        task = Task {
            do {
                let result = try await JavaSemanticSearch.prepareRename(request.result, to: proposed, snapshot: request.snapshot, script: request.script)
                guard !Task.isCancelled else { return }
                preview = result
            } catch {
                guard !Task.isCancelled else { return }
                problem = error.localizedDescription
            }
            preparing = false
        }
    }

    private func apply() {
        guard let preview, !applying else { return }
        applying = true
        Task {
            if let failure = await session.applyJavaRename(preview) {
                problem = failure
                applying = false
            } else {
                session.javaRename = nil
            }
        }
    }
}
