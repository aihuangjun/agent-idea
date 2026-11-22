import Core
import DesignSystem
import Foundation

struct JavaHierarchyRequest: Identifiable {
    let id = UUID()
    let title: String
    let root: JavaSemanticSearch.Location
    let nodes: [String: JavaSemanticSearch.Location]
    let incoming: [String: [JavaSemanticSearch.Edge]]
    let outgoing: [String: [JavaSemanticSearch.Edge]]
    let incomplete: Bool
}

struct JavaRenameRequest: Identifiable {
    let id = UUID()
    let name: String
    let result: JavaSemanticSearch.Result
    let snapshot: JavaSemanticSearch.Snapshot
    let script: URL
}

extension ProjectSession {
    var javaDefinitionSource: URL? {
        guard let source = definitionSource, source.pathExtension.lowercased() == "java" else { return nil }
        return source
    }

    func runJavaSemanticAction(_ action: JavaSemanticSearch.Action, path: String? = nil, point: CGPoint? = nil) {
        guard isActive, let source = javaDefinitionSource, path == nil || path == source.path,
              let relative = FileReference.relativePath(of: source.path, root: project.root.path) else { return }
        guard let script = WebResources.javaAnalyzerURL else { notify("找不到 Java 分析组件"); return }
        cancelDefinitionNavigation()
        isAnalyzingJava = true
        definitionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled {
                    definitionTask = nil
                    isAnalyzingJava = false
                }
            }
            do {
                guard let selection = try await renderer.javaSelection(path: source.path, point: point) else {
                    notify("请将光标放在 Java 标识符上")
                    return
                }
                await collectDraftForProjectSearch()
                try Task.checkCancellation()
                let snapshot = try await JavaSemanticSearch.snapshot(root: project.root, drafts: draftsByPath, isExcluded: sourceSearchExclusion)
                let result = try await JavaSemanticSearch.analyze(action, path: relative, selection: selection, in: snapshot, using: script)
                try Task.checkCancellation()
                guard let name = result.name else {
                    notify("无法解析光标处的 Java 引用")
                    return
                }
                let incomplete = result.incomplete || result.errors > 0
                switch action {
                case .usages, .implementations:
                    let isUsages = action == .usages
                    guard !result.hits.isEmpty else {
                        let scope = incomplete ? "已解析的项目源码中" : "项目源码中"
                        notify("\(scope)没有找到\(isUsages ? "用法" : "方法实现")")
                        return
                    }
                    definitionChoices = DefinitionChoices(name: name, targets: result.hits.map(javaTarget), truncated: incomplete,
                        title: "「\(result.title ?? name)」的\(isUsages ? "用法" : "方法实现") · \(result.hits.count)",
                        preview: true, groupByFile: isUsages,
                        coverageMessage: "部分源码或依赖未能解析，以下是已确认的结果。")
                case .hierarchy:
                    guard let declaration = result.declaration, !result.nodes.isEmpty else {
                        notify("请选择项目源码中的 Java 方法")
                        return
                    }
                    let nodes = Dictionary(result.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    javaHierarchy = JavaHierarchyRequest(title: result.title ?? name, root: declaration, nodes: nodes,
                        incoming: Dictionary(grouping: result.edges, by: \.to), outgoing: Dictionary(grouping: result.edges, by: \.from),
                        incomplete: incomplete)
                case .rename:
                    guard result.declaration != nil, !result.hits.isEmpty else {
                        notify("这个声明不在可重命名的项目源码中")
                        return
                    }
                    if incomplete || result.externalOverride {
                        showError(result.externalOverride ? "该方法覆盖了项目外的声明，无法一起重命名" : "项目依赖或引用未能完整解析，无法安全重命名")
                        return
                    }
                    javaRename = JavaRenameRequest(name: name, result: result, snapshot: snapshot, script: script)
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { showError(error.localizedDescription) }
            }
        }
    }

    func javaTarget(_ location: JavaSemanticSearch.Location) -> DefinitionTarget {
        DefinitionTarget(url: project.root.appendingPathComponent(location.path), line: location.line,
                         column: location.column, label: location.title, length: location.length)
    }

    func applyJavaRename(_ preview: JavaSemanticSearch.RenamePreview) async -> String? {
        await collectDraftForProjectSearch()
        let source: JavaSemanticSearch.Snapshot
        do {
            source = try await JavaSemanticSearch.snapshot(root: project.root, drafts: draftsByPath, isExcluded: sourceSearchExclusion)
        } catch { return error.localizedDescription }
        guard !source.incomplete,
              source.sources.count == preview.sourceSnapshot.sources.count,
              zip(source.sources, preview.sourceSnapshot.sources).allSatisfy({ $0.path == $1.path && $0.data == $1.data && $0.text == $1.text }) else {
            return "Java 源码已变化，请重新预览重命名"
        }
        return await applyTextChanges(preview.changes, title: "重命名代码")
    }
}
