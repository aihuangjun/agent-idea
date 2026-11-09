import Core
import Foundation

/// 最近的文件（⌘E，IDEA 的 Recent Files）：记下这个项目打开过哪些文件（关掉的也算），弹窗里输入即过滤、回车打开。
///
/// 列表规则在 `Core/RecentFiles`；这里管持久化（UserDefaults，键 `recentFiles:<项目根>`，照目录树展开状态的写法）、
/// 磁盘上已经没有的剔掉、弹窗的输入与选中。打开文件是会话的事（`ProjectSession.openRecentFile`）。
@MainActor
final class RecentFilesController: ObservableObject {
    @Published private(set) var isShown = false
    @Published var query = "" {
        didSet { if query != oldValue { refilter() } }
    }
    @Published private(set) var results: [FileSearchMatch] = []
    @Published private(set) var selectedIndex = 0
    /// 每次「请把焦点给输入框」加一（弹窗已经开着时再按 ⌘E 也要回到输入框）。
    @Published private(set) var focusRequests = 0

    private(set) var store: RecentFiles
    /// 弹窗打开那一刻的候选（已去掉当前文件和磁盘上没有的）；输入只在它里面过滤。
    private var candidates: [RecentFiles.Entry] = []
    /// 解析过符号链接的项目根：标签里的 URL 也是解析过的（`openFile`），/var 与 /private/var 才对得上。
    private let root: URL
    private let defaults: UserDefaults
    private let key: String
    private let fileExists: (URL) -> Bool

    init(root: URL, defaults: UserDefaults, fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.defaults = defaults
        // 键用调用方给的项目根（与 `tree.expanded:<根目录>` 同一种写法），不用解析过的
        self.key = "recentFiles:" + root.path
        self.fileExists = fileExists
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([RecentFiles.Entry].self, from: $0) } ?? []
        self.store = RecentFiles(entries: saved)
    }

    var selectedResult: FileSearchMatch? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    func url(for match: FileSearchMatch) -> URL {
        root.appendingPathComponent(match.entry.path)
    }

    /// 打开 / 切到了一个文件。项目外的（符号链接指出去的）不记。
    func record(_ url: URL, at date: Date = Date()) {
        guard let relative = relativePath(of: url), !relative.isEmpty else { return }
        store.record(relative, at: date)
        save()
    }

    /// 文件或目录改名 / 移动。传**已经解析过符号链接**的绝对路径（`didRename` 只解析父目录再拼回名字）：
    /// 旧路径此时已经不在磁盘上，再解析一遍会得到 /private/var 这种与项目根对不上的前缀。
    func rename(fromPath oldPath: String, toPath newPath: String) {
        guard let old = FileReference.relativePath(of: oldPath, root: root.path),
              let new = FileReference.relativePath(of: newPath, root: root.path), !old.isEmpty, !new.isEmpty,
              store.rename(from: old, to: new) else { return }
        save()
    }

    /// 弹出来。`current` 是当前标签的文件，不列它（第一项就是上一个文件，回车就切回去）。
    func show(current: URL?) {
        // 磁盘上已经没有的（Agent 删了、在终端里挪走了）这时剔掉，存档也跟着瘦下来
        if store.removeAll(where: { !fileExists(root.appendingPathComponent($0.path)) }) { save() }
        candidates = store.candidates(excluding: current.flatMap(relativePath(of:)))
        query = ""
        refilter()
        isShown = true
        focusRequests += 1
    }

    func close() {
        isShown = false
        query = ""
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(results.count - 1, max(0, selectedIndex + offset))
    }

    func select(_ index: Int) {
        if results.indices.contains(index) { selectedIndex = index }
    }

    private func refilter() {
        results = RecentFiles.filter(candidates, query: query)
        selectedIndex = 0
    }

    private func relativePath(of url: URL) -> String? {
        FileReference.relativePath(of: url.resolvingSymlinksInPath().standardizedFileURL.path, root: root.path)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store.entries) else { return }
        defaults.set(data, forKey: key)
    }
}
