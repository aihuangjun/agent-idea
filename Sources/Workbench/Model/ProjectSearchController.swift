import Core
import DesignSystem
import Foundation

/// 侧栏搜索、全局搜索和 Java 实现类共用一个项目索引。单次解析只发送少量文件，切项目时停止解析。
@MainActor
final class ProjectSearchController: ObservableObject {
    enum Presentation { case sidebar, popup }

    struct Inputs: Sendable {
        let drafts: [String: String]
        let isExcluded: @Sendable (String, Bool) -> Bool
    }

    struct Snapshot: Sendable {
        let outlines: [SourceOutline]
        let incomplete: Bool
    }

    @Published private(set) var presentation: Presentation?
    @Published var query = "" { didSet { if oldValue != query { refreshResults(reset: true) } } }
    @Published var scope: ProjectSearch.Scope = .all { didSet { if oldValue != scope { refreshResults(reset: true) } } }
    @Published private(set) var results: [ProjectSearch.Result] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var focusRequests = 0
    @Published private(set) var isIndexing = false
    @Published private(set) var incomplete = false

    private let root: URL
    private let renderer: ContentRenderer
    private let debouncer = Debouncer(delay: 0.25)
    private var recent: [String] = []
    private var files: [FileSearchEntry] = []
    private var symbols: [ProjectSearch.IndexedSymbol] = []
    private var versions: [String: ProjectSourceFiles.Version] = [:]
    private var outlines: [String: SourceOutline] = [:]
    private var revision = 0
    private var indexedRevision: Int?
    private var indexTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    var inputs: (() -> Inputs)?

    init(root: URL, renderer: ContentRenderer) {
        self.root = root
        self.renderer = renderer
    }

    var isShown: Bool { presentation != nil }
    var location: SourceLocation? { FileReference.parseQuery(query, projectRoot: root.path).location }
    var selected: ProjectSearch.Result? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }

    func show(_ presentation: Presentation, recent: [String] = []) {
        self.recent = recent
        if self.presentation != presentation {
            scope = .all
            query = ""
            self.presentation = presentation
            refreshResults(reset: true)
        }
        focusRequests += 1
        startIndexIfNeeded()
    }

    func close() {
        presentation = nil
        queryTask?.cancel()
        query = ""
        results = []
        selectedIndex = 0
    }

    func select(_ index: Int) {
        if results.indices.contains(index) { selectedIndex = index }
    }

    func moveSelection(by amount: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(results.count - 1, max(0, selectedIndex + amount))
    }

    func cycleScope(backwards: Bool) {
        let scopes = ProjectSearch.Scope.allCases
        guard let index = scopes.firstIndex(of: scope) else { return }
        scope = scopes[(index + (backwards ? scopes.count - 1 : 1)) % scopes.count]
    }

    func invalidate() {
        revision += 1
        if isShown { debouncer.call { [weak self] in self?.startIndexIfNeeded() } }
    }

    func suspend() {
        close()
        debouncer.cancel()
        indexTask?.cancel()
        indexTask = nil
        isIndexing = false
    }

    func snapshot() async throws -> Snapshot {
        repeat {
            try Task.checkCancellation()
            startIndexIfNeeded()
            guard let task = indexTask else { break }
            await task.value
        } while indexedRevision != revision
        try Task.checkCancellation()
        return Snapshot(outlines: Array(outlines.values), incomplete: incomplete)
    }

    private func startIndexIfNeeded() {
        guard indexTask == nil, indexedRevision != revision, let input = inputs?() else { return }
        isIndexing = true
        let revision = self.revision
        indexTask = Task { [weak self] in
            guard let self else { return }
            await buildIndex(input: input, revision: revision)
            guard !Task.isCancelled else { return }
            indexTask = nil
            isIndexing = false
            if isShown, indexedRevision != self.revision { startIndexIfNeeded() }
        }
    }

    private func buildIndex(input: Inputs, revision: Int) async {
        let root = self.root
        let scanned = await runOnWorker {
            FileIndexer.index(root: root, shouldStop: { Task.isCancelled }, isExcluded: input.isExcluded)
        }
        guard !Task.isCancelled else { return }
        files = scanned
        refreshResults()
        let sources = await runOnWorker {
            scanned.filter { !DefinitionSearch.extensions(for: root.appendingPathComponent($0.path)).isEmpty }
        }
        let oldVersions = versions
        var nextVersions: [String: ProjectSourceFiles.Version] = [:]
        var nextOutlines: [String: SourceOutline] = [:]
        var skipped = scanned.count >= FileIndexer.defaultLimit
        for offset in stride(from: 0, to: sources.count, by: 12) {
            guard !Task.isCancelled else { return }
            let fileBatch = Array(sources[offset..<min(offset + 12, sources.count)])
            let batch = await runOnWorker {
                ProjectSourceFiles.prepare(fileBatch, root: root, drafts: input.drafts, cached: oldVersions, shouldStop: { Task.isCancelled })
            }
            guard !Task.isCancelled else { return }
            skipped = skipped || batch.skipped > 0
            for (path, version) in batch.versions where oldVersions[path] == version {
                nextVersions[path] = version
                nextOutlines[path] = outlines[path]
            }
            guard !batch.changed.isEmpty else { continue }
            do {
                let parsed = try await renderer.sourceOutlines(in: batch.changed)
                guard !Task.isCancelled else { return }
                skipped = skipped || parsed.count != batch.changed.count
                for outline in parsed {
                    nextVersions[outline.path] = batch.versions[outline.path]
                    nextOutlines[outline.path] = outline
                }
            } catch {
                guard !Task.isCancelled else { return }
                skipped = true
                Log.warn("search", "符号索引失败：\(error)")
                break
            }
        }
        let completed = nextOutlines
        let indexed = await runOnWorker {
            completed.values.flatMap { outline in
                outline.symbols.map { ProjectSearch.IndexedSymbol(symbol: $0, path: outline.path) }
            }
        }
        guard !Task.isCancelled else { return }
        versions = nextVersions
        outlines = nextOutlines
        symbols = indexed
        indexedRevision = revision
        incomplete = skipped
        refreshResults()
    }

    private func refreshResults(reset: Bool = false) {
        queryTask?.cancel()
        guard isShown else { return }
        if reset {
            results = []
            selectedIndex = 0
        }
        let query = self.query, scope = self.scope
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = scope == .all || scope == .files ? recent.prefix(20).map { ProjectSearch.Result(path: $0) } : []
            selectedIndex = 0
            return
        }
        let files = self.files, symbols = self.symbols, root = root.path
        queryTask = Task { [weak self] in
            let matches = await runOnWorker {
                ProjectSearch.search(query, scope: scope, files: files, symbols: symbols, root: root, shouldStop: { Task.isCancelled })
            }
            guard let self, !Task.isCancelled, isShown else { return }
            let selectedID = selected?.id
            results = matches
            selectedIndex = matches.firstIndex(where: { $0.id == selectedID }) ?? 0
        }
    }
}

private func runOnWorker<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    let task = Task.detached(priority: .userInitiated, operation: work)
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}
