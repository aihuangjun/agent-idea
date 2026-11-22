import Core
import DesignSystem
import SwiftUI

struct ProjectReplaceSheet: View {
    let session: ProjectSession
    let request: ProjectReplaceRequest
    @State private var replacement = ""
    @State private var files: [FileReplacement] = []
    @State private var selected: [String: Set<Int>] = [:]
    @State private var truncated = false
    @State private var prepared = false
    @State private var working = false
    @State private var applying = false
    @State private var problem: String?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在项目中替换").font(.headline)
            Text("查找「\(request.query.text)」 · \(request.paths.count) 个文件").lineLimit(2)
            HStack {
                TextField("替换为（留空表示删除匹配）", text: $replacement).onSubmit(prepare).disabled(applying)
                Button("预览", action: prepare).disabled(working)
            }
            if truncated || request.limited {
                Text("匹配较多，仅列出部分结果。可以缩小查找范围后再替换。")
                    .foregroundStyle(Theme.warning)
            }
            if let problem { Text(problem).foregroundStyle(Theme.danger).textSelection(.enabled) }
            if working { ProgressView().controlSize(.small) }
            if prepared && files.isEmpty { Text("没有可替换的匹配").foregroundStyle(Theme.secondaryText) }
            List {
                ForEach(files) { file in
                    Section {
                        ForEach(file.previewLines()) { row in
                            Toggle(isOn: Binding(
                                get: { selected[file.path, default: []].contains(row.index) },
                                set: { enabled in
                                    if enabled { selected[file.path, default: []].insert(row.index) }
                                    else { selected[file.path, default: []].remove(row.index) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("第 \(row.line) 行，第 \(row.column) 列").font(Theme.smallFont).foregroundStyle(Theme.secondaryText)
                                    Text(verbatim: "− " + row.before).foregroundStyle(Theme.danger)
                                    Text(verbatim: "+ " + row.after).foregroundStyle(Theme.success)
                                }.font(.system(size: 12, design: .monospaced)).lineLimit(3)
                            }.toggleStyle(.checkbox)
                        }
                    } header: {
                        Toggle(file.path, isOn: Binding(
                            get: { selected[file.path, default: []].count == file.edits.count },
                            set: { selected[file.path] = $0 ? Set(file.edits.indices) : [] }
                        )).toggleStyle(.checkbox).help(file.path)
                    }
                }
            }
            HStack {
                Text("已选 \(selected.values.reduce(0) { $0 + $1.count }) 处").foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("取消") { session.projectReplace = nil }.keyboardShortcut(.cancelAction).disabled(applying)
                Button("应用所选", action: apply)
                    .disabled(working || selected.values.allSatisfy(\.isEmpty))
            }
        }
        .padding(16).frame(width: 620, height: 500)
        .onChange(of: replacement) {
            previewTask?.cancel()
            working = false
            prepared = false
            selected = [:]
            files = []
            problem = nil
        }
        .onDisappear { previewTask?.cancel() }
    }

    private func prepare() {
        guard !working else { return }
        working = true
        problem = nil
        let query = request.query, root = session.project.root, paths = request.paths, template = replacement
        previewTask = Task {
            do {
                let matcher = try TextSearchMatcher(query)
                let worker = Task.detached(priority: .userInitiated) {
                    FileReplacement.preview(root: root, paths: paths, query: query, matcher: matcher,
                        template: template, limit: 1_000, shouldStop: { Task.isCancelled })
                }
                let preview = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                files = preview.files
                selected = Dictionary(uniqueKeysWithValues: files.map { ($0.path, Set($0.edits.indices)) })
                truncated = preview.truncated
                prepared = true
            } catch { problem = error.localizedDescription }
            working = false
        }
    }

    private func apply() {
        let changes = files.compactMap { $0.change(selecting: selected[$0.path, default: []]) }
        guard !changes.isEmpty else { return }
        working = true
        applying = true
        Task {
            if let failure = await session.applyTextChanges(changes, title: "跨文件替换") {
                problem = failure
                working = false
                applying = false
            } else { session.projectReplace = nil }
        }
    }
}
