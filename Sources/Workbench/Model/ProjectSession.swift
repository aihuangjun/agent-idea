import AppKit
import Core
import DesignSystem
import Foundation

/// 一个打开着的项目：目录树、git、标签页、提交草稿。
///
/// 阅读偏好（diff 模式、缩放、自动换行）和正文 WebView 归 `WorkbenchModel`，所有项目共用。
@MainActor
public final class ProjectSession: ObservableObject, Identifiable {
    public let id: String
    @Published public private(set) var project: Project

    // MARK: - 目录树

    @Published public private(set) var tree = FlattenedTree()
    @Published public private(set) var rows: [FlattenedTree.Row] = []
    @Published public var selectedPath: String?

    // MARK: - Git

    @Published public private(set) var gitSnapshot: GitSnapshot = .empty
    @Published public private(set) var gitIndex: GitStatusIndex = .empty
    @Published public private(set) var changeGroups = ChangeGroups(changes: [])
    @Published public private(set) var isRefreshingGit = false
    @Published public private(set) var gitError: String?
    public var hasGit: Bool { project.repositoryRoot != nil && workbench.git != nil }

    // MARK: - 提交草稿

    @Published public var commitMessage = ""
    /// 不勾选（不提交）的路径。默认全选，新出现的变更自动算勾上。
    @Published public private(set) var excludedFromCommit: Set<String> = []
    @Published public private(set) var isCommitting = false
    @Published public private(set) var isPushing = false
    /// 最近一次提交/推送的结果或错误，显示在提交面板底部。
    @Published public var commitStatus: CommitStatus?

    public enum CommitStatus: Equatable {
        case success(String)
        case failure(String)
    }

    // MARK: - 编辑区

    @Published public private(set) var tabs: [EditorTab] = []
    @Published public var activeTabID: String?
    @Published public private(set) var contents: [String: TabContent] = [:]
    /// 顶部一条可关闭的提示。
    @Published public var banner: String?

    unowned let workbench: WorkbenchModel
    private var renderer: ContentRenderer { workbench.renderer }
    private var git: GitClient? { workbench.git }
    private var fileManager: FileManager { workbench.fileManager }
    private var isActiveSession: Bool { workbench.active === self }

    private var watcher: DirectoryWatcher?
    private let refreshDebouncer = Debouncer(delay: 0.35)
    private var gitTask: Task<Void, Never>?
    private var pendingChangedPaths: Set<String> = []

    public var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    public var activeContent: TabContent? {
        guard let activeTabID else { return nil }
        return contents[activeTabID]
    }

    init(root: URL, workbench: WorkbenchModel) {
        self.workbench = workbench
        let project = Project(root: root)
        self.project = project
        self.id = project.root.path
        Log.info("project", "打开 \(project.root.path)")

        loadChildren(of: project.root.path)
        recomputeRows()
        startWatching(project.root)

        Task { [weak self] in
            guard let self, let git = workbench.git else { return }
            let repositoryRoot = await git.repositoryRoot(containing: project.root)
            self.project.repositoryRoot = repositoryRoot
            if repositoryRoot == nil {
                Log.info("git", "\(project.name) 不在 git 仓库里")
            }
            self.refreshGit()
        }
    }

    /// 项目被关掉：停监听、停任务。
    func tearDown() {
        gitTask?.cancel()
        watcher?.stop()
        watcher = nil
    }

    // MARK: - 目录树

    private func loadChildren(of path: String) {
        let nodes = DirectoryLister.list(URL(fileURLWithPath: path, isDirectory: true), fileManager: fileManager)
        tree.setChildren(nodes, for: path)
    }

    private func recomputeRows() {
        for pending in tree.needsLoading(root: project.root.path) {
            loadChildren(of: pending)
        }
        rows = tree.rows(root: project.root.path)
    }

    public func toggleExpanded(_ path: String) {
        tree.toggle(path)
        recomputeRows()
    }

    public func expand(_ path: String) {
        guard !tree.isExpanded(path) else { return }
        tree.expand(path)
        recomputeRows()
    }

    public func collapse(_ path: String) {
        guard tree.isExpanded(path) else { return }
        tree.collapse(path)
        recomputeRows()
    }

    public func collapseAll() {
        for row in rows where row.isExpanded { tree.collapse(row.id) }
        recomputeRows()
    }

    /// 定位的次数。树视图观察它，据此决定「这次选中要滚动到可见」（鼠标点选不滚）。
    @Published public private(set) var revealRequests = 0

    /// 在树上定位并选中一个文件（IDEA 的 Select Opened File）。
    public func reveal(_ url: URL) {
        tree.reveal(url.path, root: project.root.path)
        recomputeRows()
        revealRequests += 1
        selectedPath = url.path
        workbench.toolWindow = .project
    }

    /// 定位当前标签对应的文件。
    public func revealActiveTab() {
        guard let tab = activeTab else { return }
        if let url = tab.fileURL {
            reveal(url)
        } else if let change = tab.change, let url = self.url(for: change) {
            reveal(url)
        }
    }

    /// 一个节点该用什么 VCS 颜色。
    public func gitStatus(for node: FileNode) -> GitStatusIndex.Status? {
        guard let relative = project.repositoryRelativePath(of: node.url) else { return nil }
        return gitIndex.status(of: relative, isDirectory: node.isDirectory)
    }

    public func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex { $0.id == selectedPath } ?? (offset > 0 ? -1 : rows.count)
        let next = min(rows.count - 1, max(0, currentIndex + offset))
        selectedPath = rows[next].id
    }

    /// 选中的目录：展开/折叠；选中的文件：打开。回车与左右键都走这里。
    public func activateSelection(expandOnly: Bool? = nil) {
        guard let selectedPath, let row = rows.first(where: { $0.id == selectedPath }) else { return }
        if row.node.isDirectory {
            switch expandOnly {
            case .some(true): expand(selectedPath)
            case .some(false):
                if tree.isExpanded(selectedPath) {
                    collapse(selectedPath)
                } else if let parent = parentPath(of: selectedPath) {
                    self.selectedPath = parent
                }
            case .none: toggleExpanded(selectedPath)
            }
        } else if expandOnly == false, let parent = parentPath(of: selectedPath) {
            self.selectedPath = parent
        } else if expandOnly != true {
            openFile(row.node.url, pinned: true)
        }
    }

    private func parentPath(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == project.root.path ? nil : parent
    }

    // MARK: - 标签页

    /// 打开一个文件。`pinned == false` 复用预览标签（变更列表单击、Markdown 链接），`true` 固定。
    public func openFile(_ url: URL, pinned: Bool) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        selectedPath = url.path
        let tab = EditorTab(kind: .file(url), isPreview: !pinned)
        show(tab)
        if contents[tab.id] == nil { loadFile(for: tab) }
    }

    public func openDiff(_ change: GitChange, pinned: Bool = false) {
        let tab = EditorTab(kind: .diff(change), isPreview: !pinned)
        show(tab)
        if contents[tab.id] == nil { loadDiff(for: tab) }
    }

    private func show(_ incoming: EditorTab) {
        if let index = tabs.firstIndex(where: { $0.id == incoming.id }) {
            if !incoming.isPreview { tabs[index].isPreview = false }
            activate(tabs[index].id)
            return
        }
        rememberScrollOfActiveTab()
        if incoming.isPreview, let previewIndex = tabs.firstIndex(where: { $0.isPreview }) {
            let old = tabs[previewIndex]
            contents[old.id] = nil
            tabs[previewIndex] = incoming
        } else if let activeIndex = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(incoming, at: activeIndex + 1)
        } else {
            tabs.append(incoming)
        }
        activeTabID = incoming.id
        renderActiveTab()
    }

    public func activate(_ tabID: String) {
        guard tabID != activeTabID else { return }
        rememberScrollOfActiveTab()
        activeTabID = tabID
        if let tab = activeTab, let url = tab.fileURL { selectedPath = url.path }
        if let tab = activeTab, contents[tab.id] == nil {
            tab.isDiff ? loadDiff(for: tab) : loadFile(for: tab)
        }
        renderActiveTab()
    }

    public func pin(_ tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isPreview = false
    }

    public func closeTab(_ tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: index)
        contents[tabID] = nil
        if activeTabID == tabID {
            let next = tabs.indices.contains(index) ? tabs[index] : tabs.last
            activeTabID = next?.id
            renderActiveTab()
        }
    }

    public func closeActiveTab() {
        if let activeTabID { closeTab(activeTabID) }
    }

    public func closeOtherTabs(_ tabID: String) {
        for tab in tabs where tab.id != tabID { contents[tab.id] = nil }
        tabs = tabs.filter { $0.id == tabID }
        activeTabID = tabID
        renderActiveTab()
    }

    public func closeAllTabs() {
        tabs = []
        contents = [:]
        activeTabID = nil
        renderActiveTab()
    }

    public func selectNextTab(offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        activate(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    public func toggleMarkdownSource() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs[index].markdownShowsSource.toggle()
        tabs[index].scrollTop = 0
        renderActiveTab()
    }

    func rememberScrollOfActiveTab() {
        guard isActiveSession, let id = activeTabID else { return }
        renderer.currentScrollTop { [weak self] top in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            self.tabs[index].scrollTop = top
        }
    }

    // MARK: - 内容加载

    private func loadFile(for tab: EditorTab) {
        guard let url = tab.fileURL else { return }
        contents[tab.id] = .loading
        let fileManager = self.fileManager
        Task { [weak self] in
            let content = await Task.detached(priority: .userInitiated) { Self.load(url, fileManager: fileManager) }.value
            guard let self, self.tabs.contains(where: { $0.id == tab.id }) else { return }
            self.contents[tab.id] = content
            if self.activeTabID == tab.id { self.renderActiveTab() }
        }
    }

    nonisolated static func load(_ url: URL, fileManager: FileManager) -> TabContent {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard fileManager.fileExists(atPath: url.path) else {
            return .message(title: "文件不存在", detail: url.path)
        }
        switch FileCategory.forFile(named: url.lastPathComponent) {
        case .image:
            return .image(url: url, sizeBytes: size)
        case .pdf:
            return .message(title: "PDF 暂不支持预览", detail: "用系统预览打开：右键标签 → 用默认应用打开")
        case .markdown:
            switch TextFileLoader.load(url, fileManager: fileManager) {
            case .text(let text, let encoding, let lines): return .markdown(text: text, encoding: encoding, lineCount: lines, modified: modified)
            case .binary(let size): return .binary(sizeBytes: size)
            case .tooLarge(let size, let limit): return .tooLarge(sizeBytes: size, limit: limit)
            case .unreadable(let reason): return .message(title: "读不出文件", detail: reason)
            }
        case .code(let language):
            switch TextFileLoader.load(url, fileManager: fileManager) {
            case .text(let text, let encoding, let lines): return .code(text: text, language: language, encoding: encoding, lineCount: lines, modified: modified)
            case .binary(let size): return .binary(sizeBytes: size)
            case .tooLarge(let size, let limit): return .tooLarge(sizeBytes: size, limit: limit)
            case .unreadable(let reason): return .message(title: "读不出文件", detail: reason)
            }
        }
    }

    private func loadDiff(for tab: EditorTab) {
        guard let change = tab.change, let git, let repositoryRoot = project.repositoryRoot else {
            contents[tab.id] = .message(title: "没有 git", detail: "这个项目不在 git 仓库里，或者本机没有 git。")
            return
        }
        contents[tab.id] = .loading
        let ignoreWhitespace = workbench.ignoreWhitespace
        Task { [weak self] in
            let content = await Self.computeDiff(change, git: git, repositoryRoot: repositoryRoot, ignoreWhitespace: ignoreWhitespace)
            guard let self, self.tabs.contains(where: { $0.id == tab.id }) else { return }
            self.contents[tab.id] = content
            if self.activeTabID == tab.id { self.renderActiveTab() }
        }
    }

    nonisolated private static func computeDiff(_ change: GitChange, git: GitClient, repositoryRoot: URL, ignoreWhitespace: Bool) async -> TabContent {
        do {
            let raw = try await git.diff(change: change, repositoryRoot: repositoryRoot, ignoreWhitespace: ignoreWhitespace)
            return .diff(UnifiedDiffParser.parse(raw), language: Language.forFile(named: change.fileName))
        } catch {
            return .message(title: "取不到 diff", detail: describe(error))
        }
    }

    func reloadActiveDiff() {
        guard let tab = activeTab, tab.isDiff else { return }
        loadDiff(for: tab)
    }

    // MARK: - 渲染

    /// 把当前标签的内容送进 WebView。只有当前项目的会话才真的画。
    public func renderActiveTab() {
        guard isActiveSession else { return }
        guard let tab = activeTab else {
            renderer.render(["kind": "message", "title": "", "detail": ""])
            return
        }
        guard let content = contents[tab.id] else { return }
        var payload: [String: Any] = ["scrollTop": tab.scrollTop, "wrap": workbench.wordWrap]
        switch content {
        case .loading:
            return
        case .code(let text, let language, _, _, _):
            payload["kind"] = "code"
            payload["path"] = tab.fileURL?.path ?? ""
            payload["text"] = text
            if let id = language.highlightID { payload["language"] = id }
        case .markdown(let text, _, _, _):
            payload["kind"] = "markdown"
            payload["path"] = tab.fileURL?.path ?? ""
            payload["markdown"] = text
            payload["docDir"] = tab.fileURL?.deletingLastPathComponent().absoluteString ?? ""
            payload["view"] = tab.markdownShowsSource ? "source" : "preview"
        case .image(let url, let size):
            payload["kind"] = "image"
            payload["path"] = url.path
            payload["url"] = url.absoluteString
            payload["sizeText"] = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        case .binary(let size):
            payload["kind"] = "message"
            payload["title"] = "二进制文件"
            payload["detail"] = "\(tab.title) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))\n这个阅读器只显示文本。"
        case .tooLarge(let size, let limit):
            payload["kind"] = "message"
            payload["title"] = "文件太大"
            payload["detail"] = "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))，超过 \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) 的阅读上限。"
        case .diff(let diff, let language):
            payload["kind"] = "diff"
            payload["path"] = tab.change?.path ?? ""
            if let id = language.highlightID { payload["language"] = id }
            payload["mode"] = workbench.diffMode.rawValue
            payload["binary"] = diff.isBinary
            payload["empty"] = diff.isEmpty
            payload["added"] = diff.addedCount
            payload["removed"] = diff.removedCount
            if diff.isEmpty, tab.change?.kind == .untracked { payload["emptyReason"] = "这是一个空文件。" }
            payload["rows"] = Self.encodeRows(diff, mode: workbench.diffMode)
        case .message(let title, let detail):
            payload["kind"] = "message"
            payload["title"] = title
            payload["detail"] = detail
        }
        renderer.render(payload)
    }

    private static func encodeRows(_ diff: FileDiff, mode: DiffMode) -> [Any] {
        let data: Data?
        switch mode {
        case .sideBySide: data = try? JSONEncoder().encode(DiffLayout.sideBySide(diff))
        case .unified: data = try? JSONEncoder().encode(DiffLayout.unified(diff))
        }
        guard let data, let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return rows
    }

    // MARK: - Git 状态

    public func refreshGit() {
        guard let git, let repositoryRoot = project.repositoryRoot else {
            gitSnapshot = .empty
            gitIndex = .empty
            changeGroups = ChangeGroups(changes: [])
            return
        }
        gitTask?.cancel()
        isRefreshingGit = true
        gitTask = Task { [weak self] in
            defer { self?.isRefreshingGit = false }
            do {
                let snapshot = try await git.snapshot(repositoryRoot: repositoryRoot)
                guard !Task.isCancelled, let self, self.project.repositoryRoot == repositoryRoot else { return }
                self.apply(snapshot)
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.gitError = Self.describe(error)
                Log.warn("git", "status 失败：\(error)")
            }
        }
    }

    private func apply(_ snapshot: GitSnapshot) {
        gitError = nil
        gitSnapshot = snapshot
        gitIndex = GitStatusIndex(snapshot: snapshot)
        changeGroups = ChangeGroups(changes: snapshot.changes)
        // 已经不存在的变更从「不勾选」集合里清掉，免得它越积越大
        let paths = Set(snapshot.changes.map(\.path))
        excludedFromCommit = excludedFromCommit.intersection(paths)

        let stillChanged = Dictionary(uniqueKeysWithValues: snapshot.changes.map { ($0.path, $0) })
        for tab in tabs {
            guard let change = tab.change else { continue }
            if let fresh = stillChanged[change.path] {
                if fresh != change, let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                    var replaced = EditorTab(kind: .diff(fresh), isPreview: tab.isPreview)
                    replaced.scrollTop = tab.scrollTop
                    tabs[index] = replaced
                }
                contents[tab.id] = nil
                if activeTabID == tab.id { loadDiff(for: tabs.first { $0.id == tab.id } ?? tab) }
            } else {
                closeTab(tab.id)
            }
        }
    }

    /// 手动刷新（⌘R）：目录树整个重列 + git。
    public func refreshAll() {
        tree.invalidateAll()
        recomputeRows()
        reloadOpenFilesIfChanged()
        refreshGit()
    }

    // MARK: - 提交与推送

    public func isIncludedInCommit(_ change: GitChange) -> Bool {
        !excludedFromCommit.contains(change.path)
    }

    public func setIncluded(_ included: Bool, for change: GitChange) {
        if included { excludedFromCommit.remove(change.path) } else { excludedFromCommit.insert(change.path) }
    }

    public func setAllIncluded(_ included: Bool) {
        excludedFromCommit = included ? [] : Set(gitSnapshot.changes.map(\.path))
    }

    public var includedChanges: [GitChange] {
        gitSnapshot.changes.filter { !excludedFromCommit.contains($0.path) }
    }

    public var canCommit: Bool {
        hasGit && !isCommitting && !isPushing && !includedChanges.isEmpty
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canPush: Bool {
        hasGit && !isCommitting && !isPushing && !gitSnapshot.branch.isUnborn
    }

    /// 提交勾选的变更；`push` 为 true 时接着推送。
    public func commit(push: Bool) {
        guard canCommit, let git, let repositoryRoot = project.repositoryRoot else { return }
        let changes = includedChanges
        var paths = changes.map(\.path)
        paths += changes.compactMap(\.originalPath)
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        isCommitting = true
        commitStatus = nil
        Task { [weak self] in
            do {
                let result = try await git.commit(paths: paths, message: message, repositoryRoot: repositoryRoot)
                guard let self else { return }
                self.commitMessage = ""
                self.isCommitting = false
                self.commitStatus = .success("已提交 \(result.shortHash)（\(result.fileCount) 个文件）")
                Log.info("git", "提交 \(result.shortHash)：\(result.fileCount) 个文件")
                self.refreshGit()
                if push { self.pushCurrentBranch() }
            } catch {
                guard let self else { return }
                self.isCommitting = false
                self.commitStatus = .failure("提交失败：\(Self.describe(error))")
                Log.warn("git", "提交失败：\(error)")
                self.refreshGit()
            }
        }
    }

    public func pushCurrentBranch() {
        guard canPush, let git, let repositoryRoot = project.repositoryRoot else { return }
        let hasUpstream = gitSnapshot.branch.upstream != nil
        isPushing = true
        Task { [weak self] in
            do {
                let output = try await git.push(repositoryRoot: repositoryRoot, hasUpstream: hasUpstream)
                guard let self else { return }
                self.isPushing = false
                let summary = output.split(separator: "\n").last.map(String.init) ?? ""
                self.commitStatus = .success(summary.isEmpty ? "已推送" : "已推送：\(summary)")
                Log.info("git", "推送完成：\(output)")
                self.refreshGit()
            } catch {
                guard let self else { return }
                self.isPushing = false
                self.commitStatus = .failure("推送失败：\(Self.describe(error))")
                Log.warn("git", "推送失败：\(error)")
                self.refreshGit()
            }
        }
    }

    // MARK: - 回滚与删除

    /// 回滚一条变更到 HEAD。修改/删除/重命名/冲突 → restore；新增（已在索引）→ 连文件一起删；未跟踪 → 走 `deleteUntracked`。
    public func rollback(_ change: GitChange) {
        guard let git, let repositoryRoot = project.repositoryRoot else { return }
        Task { [weak self] in
            do {
                switch change.kind {
                case .untracked:
                    try Self.trash(repositoryRoot.appendingPathComponent(change.path))
                case .added:
                    try await git.removeAdded(path: change.path, repositoryRoot: repositoryRoot)
                default:
                    var paths = [change.path]
                    if let original = change.originalPath { paths.append(original) }
                    try await git.restoreToHead(paths: paths, repositoryRoot: repositoryRoot)
                }
                Log.info("git", "已回滚 \(change.path)")
            } catch {
                self?.commitStatus = .failure("回滚失败：\(Self.describe(error))")
                Log.warn("git", "回滚 \(change.path) 失败：\(error)")
            }
            self?.closeTab(EditorTab(kind: .diff(change), isPreview: true).id)
            self?.refreshAll()
        }
    }

    /// 删除一个未跟踪文件：进废纸篓，不是 rm——IDEA 的删除也能从本地历史找回来，这里用废纸篓兜底。
    public func deleteUntracked(_ change: GitChange) {
        guard let repositoryRoot = project.repositoryRoot else { return }
        do {
            try Self.trash(repositoryRoot.appendingPathComponent(change.path))
            closeTab(EditorTab(kind: .diff(change), isPreview: true).id)
            refreshAll()
        } catch {
            commitStatus = .failure("删除失败：\(Self.describe(error))")
        }
    }

    nonisolated private static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - 双击判定

    private var lastClick: (id: String, time: TimeInterval)?

    /// 记录一次单击，返回它是不是双击的第二下。
    ///
    /// 不用 SwiftUI 的 `TapGesture(count: 2)`：在 macOS 上它会让同一视图上的单击等到双击超时
    /// 之后才被判定，表现是「点了要过一会儿才选中」。这里单击立即生效，只额外记一下时间。
    public func registerClick(on id: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, last.id == id, now - last.time <= NSEvent.doubleClickInterval {
            lastClick = nil
            return true
        }
        lastClick = (id, now)
        return false
    }

    // MARK: - 文件监听

    private func startWatching(_ root: URL) {
        let watcher = DirectoryWatcher(url: root) { [weak self] paths in
            let relevant = paths.filter(DirectoryWatcher.isRelevant)
            guard !relevant.isEmpty else { return }
            Task { @MainActor [weak self] in self?.noteChanges(relevant) }
        }
        if watcher.start() {
            self.watcher = watcher
        } else {
            Log.warn("watch", "FSEvents 启动失败，改动需要手动刷新（⌘R）")
        }
    }

    private func noteChanges(_ paths: [String]) {
        pendingChangedPaths.formUnion(paths)
        refreshDebouncer.call { [weak self] in
            guard let self else { return }
            let changed = self.pendingChangedPaths
            self.pendingChangedPaths = []
            self.handleChanges(changed)
        }
    }

    private func handleChanges(_ paths: Set<String>) {
        var directories: Set<String> = []
        for path in paths {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            directories.insert(exists && isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent)
            directories.insert((path as NSString).deletingLastPathComponent)
        }
        for directory in directories where tree.hasLoaded(directory) {
            loadChildren(of: directory)
        }
        recomputeRows()
        reloadOpenFilesIfChanged()
        refreshGit()
    }

    private func reloadOpenFilesIfChanged() {
        for tab in tabs {
            guard let url = tab.fileURL, let content = contents[tab.id], content != .loading else { continue }
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let modified = attributes?[.modificationDate] as? Date
            let exists = fileManager.fileExists(atPath: url.path)
            let changed: Bool
            switch content {
            case .message: changed = exists
            case .code, .markdown: changed = !exists || modified != content.modificationDate
            default: changed = !exists || modified != nil
            }
            guard changed else { continue }
            if tab.id == activeTabID, isActiveSession {
                renderer.currentScrollTop { [weak self] top in
                    guard let self, let index = self.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                    self.tabs[index].scrollTop = top
                    self.loadFile(for: self.tabs[index])
                }
            } else {
                contents[tab.id] = nil
            }
        }
    }

    // MARK: - 杂项

    public func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    public func openWithDefaultApp(_ url: URL) { NSWorkspace.shared.open(url) }

    public func url(for change: GitChange) -> URL? { project.url(forRepositoryPath: change.path) }

    public func change(for url: URL) -> GitChange? {
        guard let relative = project.repositoryRelativePath(of: url) else { return nil }
        return gitSnapshot.changes.first { $0.path == relative }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let failure = error as? ShellCommandError {
            return failure.message.isEmpty ? "\(failure.command) 退出码 \(failure.status)" : failure.message
        }
        return error.localizedDescription
    }
}
