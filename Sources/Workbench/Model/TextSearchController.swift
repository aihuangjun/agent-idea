import Core
import Foundation

/// 「查找」工具窗口：全项目文本搜索（IDEA 的 Find in Path，⌃⇧F）。
///
/// 输入停手 `debounce` 秒再搜，新的一次取消上一次（取消不当失败）。git 仓库里用 `git grep`（含未跟踪、不含被忽略的），
/// 不在仓库里退回逐个读文件。搜的是**磁盘上**的内容：编辑器里还没保存的草稿搜不到。
/// 结果按文件分组；选中是「哪个文件的哪一行」，↑ ↓ 只在没折叠的文件里走。
@MainActor
final class TextSearchController: ObservableObject {
    /// 最多收这么多处匹配，再多就提示「只显示前 N 处」。
    nonisolated static let resultLimit = 1000

    @Published var text = "" { didSet { if text != oldValue { scheduleSearch() } } }
    @Published var caseSensitive = false { didSet { if caseSensitive != oldValue { scheduleSearch() } } }
    @Published var wholeWords = false { didSet { if wholeWords != oldValue { scheduleSearch() } } }
    @Published var isRegex = false { didSet { if isRegex != oldValue { scheduleSearch() } } }
    @Published var fileMask = "" { didSet { if fileMask != oldValue { scheduleSearch() } } }

    /// 最近一次搜完的结果；查询为空、出错时为 nil。
    @Published private(set) var result: TextSearchResult?
    @Published private(set) var isSearching = false
    /// 给人看的错误（正则写错了、git 出错了）。
    @Published private(set) var error: String?
    @Published private(set) var selected: Hit?
    @Published private(set) var collapsedFiles: Set<String> = []
    /// 每次「把焦点给输入框」加一（⌃⇧F 在窗口已经开着时也要回到输入框）。
    @Published private(set) var focusRequests = 0

    /// 一处结果：哪个文件（相对项目根）的哪一行。
    struct Hit: Hashable {
        let path: String
        let line: Int
    }

    let root: URL
    /// 由会话注入；为 nil（本机没有 git）或 git 说不在仓库里时逐个读文件。
    var git: GitClient?
    /// git 说过一次「不在仓库里」就记住，之后直接逐个读文件，不再每次先起一个 git。
    private var isOutsideRepository = false
    private let debounce: TimeInterval
    private let limit: Int
    private var searchTask: Task<Void, Never>?

    init(root: URL, git: GitClient? = nil, debounce: TimeInterval = 0.3, limit: Int = TextSearchController.resultLimit) {
        self.root = root
        self.git = git
        self.debounce = debounce
        self.limit = limit
    }

    var query: TextSearchQuery {
        TextSearchQuery(text: text, caseSensitive: caseSensitive, wholeWords: wholeWords, isRegex: isRegex, fileMask: fileMask)
    }

    func url(for path: String) -> URL { root.appendingPathComponent(path) }

    /// 打开窗口时：有能用的选中文字就预填（会重新搜），然后把焦点给输入框。
    func activate(prefill selection: String? = nil) {
        if let prefill = TextSearchQuery.prefill(fromSelection: selection, isRegex: isRegex) { text = prefill }
        focusRequests += 1
    }

    /// 不等去抖、马上按当前条件再搜一次（标题条的刷新：Agent 又改了文件）。
    func refresh() { scheduleSearch(immediately: true) }

    /// 项目关掉：正在跑的停掉。
    func cancel() {
        searchTask?.cancel()
        searchTask = nil
    }

    // MARK: - 选中与折叠

    func line(for hit: Hit) -> TextSearchLine? {
        result?.files.first { $0.path == hit.path }?.lines.first { $0.line == hit.line }
    }

    func select(_ hit: Hit) { selected = hit }

    /// 全部结果，按列表顺序。
    private var allHits: [Hit] {
        (result?.files ?? []).flatMap { file in file.lines.map { Hit(path: file.path, line: $0.line) } }
    }

    /// ↑ ↓：在没折叠的文件里走；还没选中时 ↓ 选第一处、↑ 选最后一处。到头不动。
    func moveSelection(by offset: Int) {
        let hits = allHits
        let visible = hits.filter { !collapsedFiles.contains($0.path) }
        guard !visible.isEmpty, offset != 0 else { return }
        guard let selected, let index = hits.firstIndex(of: selected) else {
            self.selected = offset > 0 ? visible.first : visible.last
            return
        }
        let step = offset > 0 ? 1 : -1
        var cursor = index, remaining = abs(offset)
        var landed = selected
        while remaining > 0 {
            cursor += step
            guard hits.indices.contains(cursor) else { break }
            if collapsedFiles.contains(hits[cursor].path) { continue }
            landed = hits[cursor]
            remaining -= 1
        }
        self.selected = landed
    }

    func toggleCollapsed(_ path: String) {
        if !collapsedFiles.insert(path).inserted { collapsedFiles.remove(path) }
    }

    func collapseAll() { collapsedFiles = Set(result?.files.map(\.path) ?? []) }
    func expandAll() { collapsedFiles = [] }

    // MARK: - 搜索

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        searchTask = nil
        let query = self.query
        guard !query.isEmpty else {
            result = nil
            error = nil
            selected = nil
            isSearching = false
            return
        }
        // 先校验：正则写错了马上说，不等去抖，也不去问 git
        let matcher: TextSearchMatcher
        do {
            matcher = try TextSearchMatcher(query)
        } catch {
            self.error = error.localizedDescription
            result = nil
            selected = nil
            isSearching = false
            return
        }
        isSearching = true
        let delay = immediately ? 0 : debounce
        searchTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            do {
                let found = try await self.search(query, matcher: matcher)
                guard !Task.isCancelled else { return }
                self.apply(found)
            } catch is CancellationError {
                // 被下一次顶掉：不是失败，转圈由最新那次关
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.result = nil
                self.selected = nil
                self.isSearching = false
            }
        }
    }

    private func search(_ query: TextSearchQuery, matcher: TextSearchMatcher) async throws -> TextSearchResult {
        let root = self.root, limit = self.limit
        if let git, !isOutsideRepository {
            do {
                return try await git.grep(query, matcher: matcher, in: root, limit: limit)
            } catch TextSearchError.notARepository {
                // 不在仓库里：落到下面逐个读，以后也直接读
                isOutsideRepository = true
            }
        }
        return try await Self.scan(root: root, query: query, matcher: matcher, limit: limit)
    }

    /// 不在 git 仓库里：列出项目里的文件，逐个读。在协作线程上跑，取消了就停。
    nonisolated private static func scan(root: URL, query: TextSearchQuery, matcher: TextSearchMatcher, limit: Int) async throws -> TextSearchResult {
        let files = FileIndexer.index(root: root, shouldStop: { Task.isCancelled }, isExcluded: { path, isDirectory in
            isDirectory && TextSearchScanner.skipsDirectory(path)
        }).map(\.path)
        try Task.checkCancellation()
        let result = TextSearchScanner.search(files: files, root: root, query: query, matcher: matcher, limit: limit, shouldStop: { Task.isCancelled })
        try Task.checkCancellation()
        return result
    }

    private func apply(_ found: TextSearchResult) {
        result = found
        error = nil
        isSearching = false
        let paths = Set(found.files.map(\.path))
        collapsedFiles = collapsedFiles.intersection(paths)
        // 选中的那一处还在就留着（刷新之后接着往下看），否则选第一处：回车就能打开
        if let selected, line(for: selected) != nil { return }
        selected = found.files.first.flatMap { file in file.lines.first.map { Hit(path: file.path, line: $0.line) } }
    }
}
