import Core
import DesignSystem
import Foundation

struct DefinitionTarget: Hashable, Identifiable {
    let url: URL
    let line: Int
    let column: Int
    var symbol: SourceSymbol? = nil
    var id: Self { self }
}

struct DefinitionChoices: Identifiable {
    let id = UUID()
    let name: String
    let targets: [DefinitionTarget]
    let truncated: Bool
    var title: String? = nil
}

extension ProjectSession {
    var definitionSource: URL? {
        guard let tab = activeTab, let url = documentURL(for: tab),
              !DefinitionSearch.extensions(for: url).isEmpty else { return nil }
        switch activeContent {
        case .code, .editableDiff: return url
        default: return nil
        }
    }

    func cancelDefinitionNavigation() {
        definitionTask?.cancel()
        definitionTask = nil
        if definitionChoices != nil { definitionChoices = nil }
    }

    func goToDefinition(path: String? = nil, point: CGPoint? = nil) {
        guard isActive, let source = definitionSource, path == nil || path == source.path else { return }
        cancelDefinitionNavigation()
        definitionTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.definitionTask = nil } }
            do {
                let reference = try await renderer.definitionReference(path: source.path, point: point)
                try Task.checkCancellation()
                guard let reference else {
                    notify("请将光标放在符号上，或选中一个符号")
                    return
                }
                if !reference.local.isEmpty {
                    showDefinitions(reference.name, targets: reference.local.map {
                        DefinitionTarget(url: source, line: $0.line, column: $0.ch)
                    })
                    return
                }

                let input = try await DefinitionSearch.input(
                    name: reference.name, preferredFileStem: reference.preferredFileStem, source: source, root: project.root, git: git,
                    drafts: draftsByPath, isExcluded: sourceSearchExclusion
                )
                var hits: [ContentRenderer.DefinitionHit] = []
                for offset in stride(from: 0, to: input.sources.count, by: 12) {
                    try Task.checkCancellation()
                    let batch = Array(input.sources.dropFirst(offset).prefix(12))
                    hits += try await renderer.findDefinitions(reference, in: batch)
                }
                try Task.checkCancellation()
                let preferred = hits.filter(\.preferred)
                let localCandidates = (reference.sameFileCandidates ?? []).map {
                    DefinitionTarget(url: source, line: $0.line, column: $0.ch)
                }
                let targets = localCandidates + (preferred.isEmpty ? hits : preferred).map {
                    DefinitionTarget(url: URL(fileURLWithPath: $0.path), line: $0.line, column: $0.ch)
                }
                showDefinitions(reference.name, targets: targets, truncated: input.truncated, uncertain: reference.uncertain == true)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                Log.warn("navigation", "定义查找失败：\(error)")
                notify("无法查找定义")
            }
        }
    }

    func showJavaImplementations(path: String, point: CGPoint) {
        guard isActive, definitionSource?.path == path else { return }
        cancelDefinitionNavigation()
        definitionTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.definitionTask = nil } }
            do {
                let reference = try await renderer.javaTypeReference(path: path, point: point)
                try Task.checkCancellation()
                guard let reference else {
                    notify("请将光标放在 Java 接口名上，或选中接口名")
                    return
                }
                await collectDraftForProjectSearch()
                try Task.checkCancellation()
                let snapshot = try await projectSearch.snapshot()
                let result = await Task.detached(priority: .userInitiated) {
                    JavaImplementations.find(reference, in: snapshot.outlines)
                }.value
                try Task.checkCancellation()
                guard let result else {
                    notify("在项目源码中未找到接口「\(reference.name)」")
                    return
                }
                guard !result.matches.isEmpty else {
                    notify(snapshot.incomplete ? "已索引的源码中没有找到实现类" : "项目中没有找到实现类")
                    return
                }
                let targets = result.matches.map { match in
                    DefinitionTarget(url: project.root.appendingPathComponent(match.path), line: match.symbol.line,
                                     column: match.symbol.ch, symbol: match.symbol)
                }
                definitionChoices = DefinitionChoices(name: reference.name, targets: targets, truncated: snapshot.incomplete,
                                                      title: "「\(result.interfaceName)」的实现类 · \(targets.count)")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                Log.warn("navigation", "实现类查找失败：\(error)")
                notify("无法查找实现类")
            }
        }
    }

    private func showDefinitions(_ name: String, targets: [DefinitionTarget], truncated: Bool = false, uncertain: Bool = false) {
        var seen: Set<DefinitionTarget> = []
        let unique = targets.filter { seen.insert($0).inserted }
        switch unique.count {
        case 0:
            notify(truncated ? "在已扫描的文件中找不到「\(name)」的定义" : "在项目中找不到「\(name)」的定义")
        case 1 where !truncated && !uncertain:
            if let target = unique.first { openDefinition(target, name: name) }
        default:
            definitionChoices = DefinitionChoices(name: name, targets: unique, truncated: truncated)
        }
    }

    func openDefinition(_ target: DefinitionTarget, name: String) {
        definitionChoices = nil
        guard isActive else { return }
        let location = SourceLocation(line: target.line + 1, column: target.column + 1)
        let length = (target.symbol?.name ?? name).utf16.count
        if target.url == definitionSource {
            goToLine(location, selecting: length)
        } else {
            guard fileManager.fileExists(atPath: target.url.path) else {
                notify("定义所在的文件已移除")
                return
            }
            openFile(target.url, pinned: true, at: location, selecting: length)
        }
        renderer.focusContent()
    }
}
