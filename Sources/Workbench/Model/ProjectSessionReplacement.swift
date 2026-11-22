import Core
import DesignSystem
import Foundation

@MainActor
final class FileReplaceSession: ObservableObject {
    let tabID: String
    let path: String
    @Published var query: String
    @Published var replacement = ""
    @Published var caseSensitive: Bool
    @Published var wholeWords = false
    @Published var regex = false
    @Published var inSelection = false
    @Published var status: String?
    @Published var working = false
    @Published var focusRequests = 1
    @Published private(set) var selection: Range<Int>?
    private var selectionText: String?
    private var lastReplacement: (text: String, range: Range<Int>, query: TextSearchQuery, replacement: String)?

    init(tabID: String, path: String, query: String, caseSensitive: Bool) {
        self.tabID = tabID
        self.path = path
        self.query = query
        self.caseSensitive = caseSensitive
    }

    func rememberSelection(_ snapshot: ContentRenderer.EditableSnapshot) {
        guard snapshot.end > snapshot.start else { return }
        selection = snapshot.start..<snapshot.end
        selectionText = snapshot.text
        inSelection = true
    }

    func replace(all: Bool, using renderer: ContentRenderer) async {
        guard !working, !query.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            let search = TextSearchQuery(text: query, caseSensitive: caseSensitive, wholeWords: wholeWords, isRegex: regex)
            let replacement = self.replacement
            let matcher = try TextSearchMatcher(search)
            guard let snapshot = try await renderer.editableSnapshot(path: path) else { return }
            if inSelection && selectionText != snapshot.text {
                status = "正文已变化，请重新选中范围并打开替换"
                return
            }
            let bounds = inSelection ? selection : nil
            let hits = matcher.replacements(in: snapshot.text, template: replacement, interpretingGroups: search.isRegex, within: bounds)
            let visible = hits.filter { edit in
                (snapshot.text as NSString).substring(with: NSRange(location: edit.start, length: edit.length)) != edit.text
            }
            let range = snapshot.start..<snapshot.end
            let followsReplacement = lastReplacement?.text == snapshot.text && lastReplacement?.range == range
                && lastReplacement?.query == search && lastReplacement?.replacement == replacement
            let available = followsReplacement && !all ? visible.filter { edit in
                !(edit.start..<edit.start + edit.length).overlaps(range)
            } : visible
            let next = available.first { $0.start >= (followsReplacement ? snapshot.end : snapshot.start) } ?? available.first
            let edits = all ? visible : next.map { [$0] } ?? []
            guard !edits.isEmpty else { status = "没有可替换的匹配"; return }
            let target = all ? nil : next.map { $0.start..<($0.start + $0.text.utf16.count) }
            guard try await renderer.applyTextEdits(edits, path: path, expected: snapshot.text, selecting: target) else {
                status = "正文已变化，请重试"
                return
            }
            let modified = TextReplacement.apply(edits, to: snapshot.text)
            lastReplacement = target.flatMap { selection in modified.map { ($0, selection, search, replacement) } }
            if let bounds {
                let delta = edits.reduce(0) { $0 + $1.text.utf16.count - $1.length }
                selection = bounds.lowerBound..<(bounds.upperBound + delta)
                selectionText = modified
            }
            status = "已替换 \(edits.count) 处"
        } catch { status = error.localizedDescription }
    }
}

struct ProjectReplaceRequest: Identifiable {
    let id = UUID()
    let query: TextSearchQuery
    let paths: [String]
    let limited: Bool
}

extension ProjectSession {
    var canReplaceInFile: Bool {
        guard let tab = activeTab, isEditable(tab) else { return false }
        if case .markdown = activeContent { return tab.markdownView != .preview }
        if let file = tab.fileURL, FileCategory.isHTML(named: file.lastPathComponent) { return tab.htmlView != .preview }
        return true
    }

    func editSource(_ command: ContentRenderer.SourceEditCommand) {
        guard canReplaceInFile, let tab = activeTab, let url = documentURL(for: tab) else { return }
        Task {
            do {
                if try await renderer.editSource(command, path: url.path) { renderer.focusContent() }
                else if command == .commentLine { notify("此处无法切换行注释") }
            } catch { notify("无法执行编辑操作") }
        }
    }

    func showFileReplace() {
        guard canReplaceInFile, let tab = activeTab, let url = documentURL(for: tab) else { return }
        if let fileReplace, fileReplace.tabID == tab.id {
            fileReplace.focusRequests += 1
            return
        }
        closeFind()
        let replace = FileReplaceSession(tabID: tab.id, path: url.path, query: findQuery, caseSensitive: findCaseSensitive)
        fileReplace = replace
        Task { [weak self, weak replace] in
            guard let self, let replace, let snapshot = try? await renderer.editableSnapshot(path: url.path), fileReplace === replace else { return }
            replace.rememberSelection(snapshot)
        }
    }

    func showProjectReplace() {
        guard let result = textSearch.replacementResult, !result.files.isEmpty else { return }
        projectReplace = ProjectReplaceRequest(query: textSearch.query, paths: result.files.map(\.path), limited: result.isTruncated)
    }

    func applyTextChanges(_ changes: [FileTextTransaction.Change], title: String) async -> String? {
        guard !isUndoing else { return "正在处理另一批改动" }
        isUndoing = true
        defer { isUndoing = false }
        if let failure = await writeTextChanges(changes) { return failure }
        let entry = recordUndo(title, .textChanges(changes))
        notify("已\(title) · \(changes.count) 个文件", action: BannerAction(title: "撤销") { [weak self] in
            self?.undo(expecting: entry.id)
        })
        return nil
    }

    func writeTextChanges(_ changes: [FileTextTransaction.Change], reversing: Bool = false) async -> String? {
        guard !changes.isEmpty else { return "没有已选择的变更" }
        guard !isRollingBack, !isSwitchingBranch, !isSyncingRemote, commit?.isCommitting != true else { return "另一项 Git 操作正在进行" }
        await collectDraftForProjectSearch()
        let drafts = draftsByPath
        if let conflict = changes.first(where: {
            let source = reversing ? ($0.newPath ?? $0.path) : $0.path
            return drafts[project.root.appendingPathComponent(source).path] != nil
        }) {
            return "\(conflict.path) 有未保存的编辑，请保存后重新预览"
        }
        do {
            try FileTextTransaction.write(changes, under: project.root, reversing: reversing)
        } catch { return error.localizedDescription }
        for change in changes {
            if let newPath = change.newPath {
                let old = project.root.appendingPathComponent(change.path), new = project.root.appendingPathComponent(newPath)
                didRename(reversing ? new : old, to: reversing ? old : new)
            }
        }
        refreshAll()
        textSearch.refresh()
        return nil
    }
}
