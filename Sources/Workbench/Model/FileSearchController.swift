import Core
import Foundation

/// 项目视图里的文件搜索（IDEA 的 Go to File）：后台建索引，边敲边搜。
///
/// 索引在第一次打开搜索时建；目录有变化就标脏，下一次搜索前重建。忽略规则由会话给（git 的 ignored）。
@MainActor
final class FileSearchController: ObservableObject {
    @Published var isActive = false {
        didSet { if isActive, !oldValue { ensureIndex() } else if !isActive { query = "" } }
    }
    @Published var query = "" {
        didSet { if query != oldValue { search() } }
    }
    @Published private(set) var results: [FileSearchMatch] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var selectedIndex = 0
    /// 索引条数（给空态/提示用）。
    @Published private(set) var indexedCount = 0
    /// 每次「请把焦点给搜索框」加一（菜单 ⇧⌘O 在搜索已经开着时也要能回到输入框）。
    @Published private(set) var focusRequests = 0

    private let root: URL
    /// 由会话给：相对项目根的路径 → 是否跳过（git 忽略的）。要能跨线程跑。
    var isExcluded: @Sendable (_ relativePath: String, _ isDirectory: Bool) -> Bool = { _, _ in false }

    private var entries: [FileSearchEntry] = []
    private var isStale = true
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
    }

    var selectedResult: FileSearchMatch? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    func url(for match: FileSearchMatch) -> URL {
        root.appendingPathComponent(match.entry.path)
    }

    /// 打开搜索并把焦点给输入框。
    func activate() {
        isActive = true
        focusRequests += 1
    }

    /// 忽略规则变了（第一次 git 状态到了、.gitignore 改了）：索引作废，搜索开着就马上重建。
    func markStale() {
        isStale = true
        if isActive { ensureIndex() }
    }

    /// 目录里这些路径变了：增量更新索引，不整棵重扫。新目录重扫那一支，没了的连同子路径一起删。
    /// 索引本来就没建或正在建就不管——建出来的就是新的。
    func applyChanges(_ absolutePaths: Set<String>) {
        guard !isStale, indexTask == nil else { return }
        let rootPath = root.path + "/"
        var current = entries
        var changed = false
        for absolute in absolutePaths.sorted() where absolute.hasPrefix(rootPath) {
            let relative = String(absolute.dropFirst(rootPath.count))
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory)
            let hadEntries = current.contains { $0.path == relative || $0.path.hasPrefix(relative + "/") }
            if !exists {
                guard hadEntries else { continue }
                current.removeAll { $0.path == relative || $0.path.hasPrefix(relative + "/") }
                changed = true
            } else if isDirectory.boolValue {
                guard !isExcluded(relative, true) else { continue }
                let rescanned = FileIndexer.index(root: URL(fileURLWithPath: absolute, isDirectory: true), prefix: relative, isExcluded: isExcluded)
                current.removeAll { $0.path.hasPrefix(relative + "/") }
                current.append(contentsOf: rescanned)
                changed = true
            } else if !hadEntries, !isExcluded(relative, false) {
                current.append(FileSearchEntry(path: relative))
                changed = true
            }
        }
        guard changed else { return }
        entries = current
        indexedCount = current.count
        search()
    }

    /// 项目关掉：正在跑的都停掉。
    func cancel() {
        indexTask?.cancel()
        searchTask?.cancel()
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(results.count - 1, max(0, selectedIndex + offset))
    }

    func select(_ index: Int) { selectedIndex = index }

    private func ensureIndex() {
        guard isStale, indexTask == nil else { return }
        isStale = false
        isIndexing = true
        let root = self.root
        let isExcluded = self.isExcluded
        indexTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                FileIndexer.index(root: root, shouldStop: { Task.isCancelled }, isExcluded: isExcluded)
            }.value
            guard let self, !Task.isCancelled else { return }
            entries = built
            indexedCount = built.count
            isIndexing = false
            indexTask = nil
            if isStale { ensureIndex() } else { search() }
        }
    }

    private func search() {
        searchTask?.cancel()
        let query = self.query
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            selectedIndex = 0
            return
        }
        let entries = self.entries
        searchTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { FileSearch.search(query, in: entries, shouldStop: { Task.isCancelled }) }.value
            guard !Task.isCancelled, let self, self.query == query else { return }
            results = found
            selectedIndex = 0
        }
    }
}
