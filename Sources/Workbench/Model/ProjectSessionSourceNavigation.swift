import Core
import DesignSystem
import Foundation

struct NavigationPoint: Equatable {
    let tabID: String
    let position: EditorCursor?

    var location: SourceLocation? {
        position.map { SourceLocation(line: $0.line + 1, column: $0.ch + 1) }
    }
}

struct SourceNavigationEntry: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let point: NavigationPoint
}

struct SourceNavigationRequest: Identifiable {
    let id = UUID()
    let title: String
    let placeholder: String
    let entries: [SourceNavigationEntry]
    var preferredIndex: Int?

    static func locations(_ points: [NavigationPoint], root: URL) -> Self {
        Self(title: "最近的位置", placeholder: "按文件名或路径筛选", entries: points.compactMap { point in
            guard let url = EditorTab.fileURL(fromID: point.tabID), let location = point.location else { return nil }
            let path = FileReference.relativePath(of: url.path, root: root.path) ?? url.path
            return SourceNavigationEntry(title: url.lastPathComponent,
                detail: "\(path):\(location.line):\(location.column ?? 1)", point: point)
        })
    }
}

extension ProjectSession {
    func showFileStructure() {
        guard isActive, let url = definitionSource, let tab = activeTab else { return }
        cancelDefinitionNavigation()
        definitionTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { definitionTask = nil } }
            let state = await withCheckedContinuation { continuation in
                renderer.currentState { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled, activeTabID == tab.id else { return }
            let document = documentID(for: tab)
            guard let text = state.text ?? document.flatMap({ drafts[$0] ?? contents[$0]?.text }) else { return }
            do {
                let path = referencePath(of: url)
                let outline = try await renderer.sourceOutlines(in: [.init(path: path, text: text)]).first
                try Task.checkCancellation()
                let symbols = (outline?.symbols ?? []).sorted { ($0.line, $0.ch) < ($1.line, $1.ch) }
                let entries = symbols.map { symbol in
                    let owner = symbol.qualifiedName.split(separator: ".").dropLast().joined(separator: ".")
                    return SourceNavigationEntry(title: symbol.name,
                        detail: owner.isEmpty ? "第 \(symbol.line + 1) 行" : "\(owner) · 第 \(symbol.line + 1) 行",
                        point: NavigationPoint(tabID: tab.id, position: EditorCursor(line: symbol.line, ch: symbol.ch)))
                }
                let current = state.cursor.flatMap { cursor in symbols.lastIndex { $0.line <= cursor.line } }
                sourceNavigation = SourceNavigationRequest(title: "文件结构 · \(url.lastPathComponent)",
                    placeholder: "按类、方法、函数或字段名筛选", entries: entries, preferredIndex: current)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { notify("无法读取文件结构") }
            }
        }
    }
}
