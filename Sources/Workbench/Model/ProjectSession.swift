import Core
import DesignSystem
import Foundation

/// 一个打开着的项目：目录树、git 状态、标签页，以及把标签内容送进 WebView。
///
/// 提交/回滚归 `CommitController`，目录监听归 `ChangeWatcher`，阅读偏好归 `ReadingPreferences`；
/// 依赖全部由 `WorkbenchModel` 在构造时注入，会话不认识自己的父对象。
@MainActor
final class ProjectSession: ObservableObject, Identifiable {
    let id: String
    @Published private(set) var project: Project

    // MARK: - 目录树

    @Published private(set) var tree = FlattenedTree()
    @Published private(set) var rows: [FlattenedTree.Row] = []
    @Published private(set) var selectedPath: String?
    /// 定位的次数。树视图观察它，据此决定「这次选中要滚动到可见」（鼠标点选不滚）。
    @Published private(set) var revealRequests = 0

    // MARK: - Git

    @Published private(set) var gitSnapshot: GitSnapshot = .empty
    @Published private(set) var gitIndex: GitStatusIndex = .empty
    @Published private(set) var changeGroups = ChangeGroups(changes: [])
    @Published private(set) var isRefreshingGit = false
    @Published private(set) var gitError: String?
    /// 仓库确定之后才有；没有 git 的项目为 nil。
    @Published private(set) var commit: CommitController?
    var hasGit: Bool { commit != nil }

    // MARK: - 编辑区

    @Published private(set) var tabs: [EditorTab] = []
    @Published private(set) var activeTabID: String?
    @Published private(set) var contents: [String: TabContent] = [:]
    /// 顶部一条可关闭的提示。
    @Published private(set) var banner: String?

    /// 树视图里的一次键盘/回车动作。
    enum TreeCommand {
        /// 回车 / 双击：目录切换展开，文件打开。
        case toggle
        /// 右键：展开目录。
        case expand
        /// 左键：折叠目录；已折叠或是文件则跳到父目录。
        case collapseOrAscend
    }

    /// 需要壳切到某个工具窗口（定位文件时切到项目树）。
    var onRequestToolWindow: (@MainActor (ToolWindow) -> Void)?

    private let git: GitClient?
    private let renderer: ContentRenderer
    private let fileManager = FileManager.default
    private let preferences: ReadingPreferences
    /// 由 `WorkbenchModel.activate` 写入。只有当前项目才往共用的 WebView 里画。
    private(set) var isActive = false
    private var watcher: ChangeWatcher?
    private var gitTask: Task<Void, Never>?

    var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var activeContent: TabContent? {
        guard let activeTabID else { return nil }
        return contents[activeTabID]
    }

    init(root: URL, git: GitClient?, renderer: ContentRenderer, preferences: ReadingPreferences) {
        self.git = git
        self.renderer = renderer
        self.preferences = preferences
        let project = Project(root: root)
        self.project = project
        self.id = project.root.path
        Log.info("project", "打开 \(project.root.path)")

        loadChildren(of: project.root.path)
        recomputeRows()
        watcher = ChangeWatcher(root: project.root) { [weak self] paths in self?.handleChanges(paths) }

        Task { [weak self] in
            guard let git else { return }
            let repositoryRoot = await git.repositoryRoot(containing: project.root)
            guard let self else { return }
            self.project.repositoryRoot = repositoryRoot
            if let repositoryRoot = self.project.repositoryRoot {
                let controller = CommitController(git: git, repositoryRoot: repositoryRoot)
                controller.onRepositoryChanged = { [weak self] affected in
                    for change in affected { self?.closeTab(EditorTab.id(forDiff: change)) }
                    self?.refreshAll()
                }
                self.commit = controller
                self.refreshGit()
            } else {
                Log.info("git", "\(project.name) 不在 git 仓库里")
            }
        }
    }

    /// 项目被关掉：停监听、停任务。
    func tearDown() {
        gitTask?.cancel()
        watcher?.stop()
        watcher = nil
    }

    /// 成为 / 不再是当前项目。成为当前时把活动标签画出来。
    func setActive(_ active: Bool) {
        if !active, isActive { rememberScrollOfActiveTab() }
        isActive = active
        if active { renderActiveTab() }
    }

    func dismissBanner() { banner = nil }

    // MARK: - 目录树

    private func loadChildren(of path: String) {
        tree.setChildren(DirectoryLister.list(URL(fileURLWithPath: path, isDirectory: true), fileManager: fileManager), for: path)
    }

    private func recomputeRows() {
        for pending in tree.needsLoading(root: project.root.path) {
            loadChildren(of: pending)
        }
        rows = tree.rows(root: project.root.path)
    }

    func select(_ path: String?) { selectedPath = path }

    func toggleExpanded(_ path: String) {
        tree.toggle(path)
        recomputeRows()
    }

    func expand(_ path: String) {
        guard !tree.isExpanded(path) else { return }
        tree.expand(path)
        recomputeRows()
    }

    func collapse(_ path: String) {
        guard tree.isExpanded(path) else { return }
        tree.collapse(path)
        recomputeRows()
    }

    func collapseAll() {
        for row in rows where row.isExpanded { tree.collapse(row.id) }
        recomputeRows()
    }

    /// 在树上定位并选中一个文件（IDEA 的 Select Opened File）。
    func reveal(_ url: URL) {
        tree.reveal(url.path, root: project.root.path)
        recomputeRows()
        revealRequests += 1
        selectedPath = url.path
        onRequestToolWindow?(.project)
    }

    /// 定位当前标签对应的文件。
    func revealActiveTab() {
        guard let tab = activeTab else { return }
        if let url = tab.fileURL ?? tab.change.flatMap({ self.url(for: $0) }) { reveal(url) }
    }

    /// 一个节点该用什么 VCS 颜色。
    func gitStatus(for node: FileNode) -> GitStatusIndex.Status? {
        guard let relative = project.repositoryRelativePath(of: node.url) else { return nil }
        return gitIndex.status(of: relative, isDirectory: node.isDirectory)
    }

    func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex { $0.id == selectedPath } ?? (offset > 0 ? -1 : rows.count)
        selectedPath = rows[min(rows.count - 1, max(0, currentIndex + offset))].id
    }

    /// 对选中项执行一个键盘动作。
    func perform(_ command: TreeCommand) {
        guard let selectedPath, let row = rows.first(where: { $0.id == selectedPath }) else { return }
        let parent = parentPath(of: selectedPath)
        switch (command, row.node.isDirectory) {
        case (.toggle, true): toggleExpanded(selectedPath)
        case (.toggle, false): openFile(row.node.url, pinned: true)
        case (.expand, true): expand(selectedPath)
        case (.expand, false): break
        case (.collapseOrAscend, true) where tree.isExpanded(selectedPath): collapse(selectedPath)
        case (.collapseOrAscend, _): if let parent { self.selectedPath = parent }
        }
    }

    private func parentPath(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == project.root.path ? nil : parent
    }

    // MARK: - 标签页

    /// 打开一个文件。`pinned == false` 复用预览标签（变更列表单击、Markdown 链接），`true` 固定。
    func openFile(_ url: URL, pinned: Bool) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        selectedPath = url.path
        let tab = EditorTab(kind: .file(url), isPreview: !pinned)
        show(tab)
        if contents[tab.id] == nil { loadFile(for: tab) }
    }

    func openDiff(_ change: GitChange, pinned: Bool = false) {
        let tab = EditorTab(kind: .diff(change), isPreview: !pinned)
        show(tab)
        if contents[tab.id] == nil { loadDiff(for: tab) }
    }

    /// 把标签放进标签栏并激活。已经开着的直接切过去；预览标签只保留一个。**这是标签进栏的唯一入口。**
    private func show(_ incoming: EditorTab) {
        if let index = tabs.firstIndex(where: { $0.id == incoming.id }) {
            if !incoming.isPreview { tabs[index].isPreview = false }
            activate(tabs[index].id)
            return
        }
        rememberScrollOfActiveTab()
        if incoming.isPreview, let previewIndex = tabs.firstIndex(where: { $0.isPreview }) {
            contents[tabs[previewIndex].id] = nil
            tabs[previewIndex] = incoming
        } else if let activeIndex = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(incoming, at: activeIndex + 1)
        } else {
            tabs.append(incoming)
        }
        activeTabID = incoming.id
        renderActiveTab()
    }

    func activate(_ tabID: String) {
        guard tabID != activeTabID, tabs.contains(where: { $0.id == tabID }) else { return }
        rememberScrollOfActiveTab()
        activeTabID = tabID
        if let tab = activeTab {
            if let url = tab.fileURL { selectedPath = url.path }
            if contents[tab.id] == nil { tab.isDiff ? loadDiff(for: tab) : loadFile(for: tab) }
        }
        renderActiveTab()
    }

    func pin(_ tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isPreview = false
    }

    func closeTab(_ tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: index)
        contents[tabID] = nil
        if activeTabID == tabID {
            activeTabID = (tabs.indices.contains(index) ? tabs[index] : tabs.last)?.id
            renderActiveTab()
        }
    }

    func closeActiveTab() {
        if let activeTabID { closeTab(activeTabID) }
    }

    func closeOtherTabs(_ tabID: String) {
        for tab in tabs where tab.id != tabID { contents[tab.id] = nil }
        tabs = tabs.filter { $0.id == tabID }
        activeTabID = tabID
        renderActiveTab()
    }

    func closeAllTabs() {
        tabs = []
        contents = [:]
        activeTabID = nil
        renderActiveTab()
    }

    func selectNextTab(offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        activate(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    func toggleMarkdownSource() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs[index].markdownShowsSource.toggle()
        tabs[index].scrollTop = 0
        renderActiveTab()
    }

    private func rememberScrollOfActiveTab() {
        guard isActive, let id = activeTabID else { return }
        rememberScroll(of: id)
    }

    /// 问 WebView 当前滚到哪，记到那个标签上；记完之后可以接着做点别的（比如重读文件）。
    private func rememberScroll(of tabID: String, then continuation: @escaping @MainActor (EditorTab) -> Void = { _ in }) {
        renderer.currentScrollTop { [weak self] top in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            self.tabs[index].scrollTop = top
            continuation(self.tabs[index])
        }
    }

    // MARK: - 内容加载

    private func loadFile(for tab: EditorTab) {
        guard let url = tab.fileURL else { return }
        contents[tab.id] = .loading
        let fileManager = self.fileManager
        Task { [weak self] in
            // 读盘放到后台：几 MB 的文件同步读会卡一下主线程
            let content = await Task.detached(priority: .userInitiated) { FileContentLoader.load(url, fileManager: fileManager) }.value
            self?.store(content, for: tab.id)
        }
    }

    /// 加载完成后回填。标签在加载期间被关掉了就丢弃；是当前标签就立刻画。
    private func store(_ content: TabContent, for tabID: String) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        contents[tabID] = content
        if activeTabID == tabID { renderActiveTab() }
    }

    private func loadDiff(for tab: EditorTab) {
        guard let change = tab.change, let git, let repositoryRoot = project.repositoryRoot else {
            contents[tab.id] = .message(title: "没有 git", detail: "这个项目不在 git 仓库里，或者本机没有 git。")
            return
        }
        contents[tab.id] = .loading
        Task { [weak self] in
            let content = await FileContentLoader.loadDiff(change, git: git, repositoryRoot: repositoryRoot)
            self?.store(content, for: tab.id)
        }
    }

    // MARK: - 渲染

    /// 把当前标签的内容送进 WebView。只有当前项目的会话才真的画。
    func renderActiveTab() {
        guard isActive else { return }
        guard let tab = activeTab else {
            renderer.render(.message("", ""))
            return
        }
        guard let content = contents[tab.id], content != .loading else { return }
        renderer.render(RenderPayload(
            content.renderContent(for: tab, diffMode: preferences.diffMode),
            scrollTop: tab.scrollTop,
            wrap: preferences.wordWrap
        ))
    }

    // MARK: - Git 状态

    func refreshGit() {
        guard let git, let repositoryRoot = project.repositoryRoot else { return }
        gitTask?.cancel()
        isRefreshingGit = true
        let task = Task { [weak self] in
            do {
                let snapshot = try await git.snapshot(repositoryRoot: repositoryRoot)
                guard !Task.isCancelled, let self else { return }
                self.apply(snapshot)
            } catch {
                // 被更新的一次刷新顶掉了：不是出错，什么都不用做
                guard !Task.isCancelled, let self else { return }
                self.gitError = error.userFacingDescription
                Log.warn("git", "status 失败：\(error)")
            }
            // 只有自己还是「最新的那次刷新」时才关掉转圈，别把后来者的转圈提前关掉
            if let self, self.gitTask?.isCancelled == false { self.isRefreshingGit = false }
        }
        gitTask = task
    }

    private func apply(_ snapshot: GitSnapshot) {
        gitError = nil
        gitSnapshot = snapshot
        gitIndex = GitStatusIndex(snapshot: snapshot)
        changeGroups = ChangeGroups(changes: snapshot.changes)
        commit?.update(snapshot: snapshot)

        // 开着的 diff 标签：变更已经不在了的关掉（比如被提交了），其余重新算
        let stillChanged = Dictionary(uniqueKeysWithValues: snapshot.changes.map { ($0.path, $0) })
        for tab in tabs {
            guard let change = tab.change else { continue }
            guard let fresh = stillChanged[change.path] else {
                closeTab(tab.id)
                continue
            }
            if fresh != change, let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                var replaced = EditorTab(kind: .diff(fresh), isPreview: tab.isPreview)
                replaced.scrollTop = tab.scrollTop
                tabs[index] = replaced
            }
            contents[tab.id] = nil
            if activeTabID == tab.id, let current = tabs.first(where: { $0.id == tab.id }) { loadDiff(for: current) }
        }
    }

    /// 手动刷新（⌘R）：目录树整个重列 + 重读开着的文件 + git。
    func refreshAll() {
        tree.invalidateAll()
        recomputeRows()
        reloadOpenFilesIfChanged()
        refreshGit()
    }

    // MARK: - 目录变化

    private func handleChanges(_ paths: Set<String>) {
        var directories: Set<String> = []
        for path in paths {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue { directories.insert(path) }
            directories.insert((path as NSString).deletingLastPathComponent)
        }
        for directory in directories where tree.hasLoaded(directory) {
            loadChildren(of: directory)
        }
        recomputeRows()
        reloadOpenFilesIfChanged()
        refreshGit()
    }

    /// 开着的文件在磁盘上变了就重读；当前显示的那个重渲染但保持滚动位置——Agent 正在改的文件用户多半正盯着看。
    private func reloadOpenFilesIfChanged() {
        for tab in tabs {
            guard let url = tab.fileURL, let content = contents[tab.id], content != .loading else { continue }
            let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard FileContentLoader.isStale(content, modifiedOnDisk: modified, exists: fileManager.fileExists(atPath: url.path)) else { continue }
            if tab.id == activeTabID, isActive {
                rememberScroll(of: tab.id) { [weak self] current in self?.loadFile(for: current) }
            } else {
                contents[tab.id] = nil
            }
        }
    }

    // MARK: - 杂项

    func url(for change: GitChange) -> URL? { project.url(forRepositoryPath: change.path) }

    func change(for url: URL) -> GitChange? {
        guard let relative = project.repositoryRelativePath(of: url) else { return nil }
        return gitSnapshot.changes.first { $0.path == relative }
    }
}
