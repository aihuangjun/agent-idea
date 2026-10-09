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
    /// 树上选中的东西：单击一个，⌘ / ⇧点击多选；`selectedPath` 是锚点（键盘导航、重命名这些只看它）。
    @Published private(set) var selection = TreeSelection()
    var selectedPath: String? {
        get { selection.anchor }
        set {
            selection.select(newValue)
            // 选中挪到别处了，还没滚完的那次定位就作废：否则很久之后打开项目视图，会莫名其妙滚到一个旧位置
            if let pendingReveal, pendingReveal != newValue { self.pendingReveal = nil }
        }
    }
    /// 等着树滚过去让它露出来的路径（定位、跨目录移动、新建文件夹之后）。树视图滚完调 `didScrollToReveal` 清掉。
    /// 放在会话里而不是树视图的 `@State` 里：从变更列表「在项目视图中显示」时树视图此刻还不在界面上，
    /// 切过去它才被建出来——那时它得知道还欠着一次滚动（1.2.0 前切过去是选中了，但滚动条不动，要自己找）。
    @Published private(set) var pendingReveal: String?

    // MARK: - Git

    @Published private(set) var gitSnapshot: GitSnapshot = .empty
    @Published private(set) var gitIndex: GitStatusIndex = .empty
    @Published private(set) var changeGroups = ChangeGroups(changes: [])
    /// 变更列表里选中的变更（按 `GitChange.path`）：单击选一个，⌘ / ⇧点击多选，多选之后右键一起回滚、删除（IDEA 的提交窗口）。
    /// 放在会话里：切到别的工具窗口再切回来，选中还在。
    @Published private(set) var changeSelection = TreeSelection()
    @Published private(set) var isRefreshingGit = false
    /// 正在跟远程同步（fetch + rebase，或者没有上游时「推送并建立上游」）。要走网络，比 status 慢得多，所以单独一个状态。
    @Published var isSyncingRemote = false
    /// 正在切分支 / 新建分支。与同步互斥：两个都在动 HEAD 和工作区。
    @Published var isSwitchingBranch = false
    /// 分支弹窗里列的分支（打开弹窗时读一次，切完再读）。见 `ProjectSessionBranches.swift`。
    @Published var branchList: GitBranchList?
    /// 状态栏的分支弹窗开着没有（状态栏的分支名、Git → 分支… 都开它）。
    @Published var isBranchPopupShown = false
    /// 正在新建分支（对话框）。
    @Published var newBranchRequest: NewBranchRequest?
    /// 当前分支没有上游、用户点了同步：问他从哪儿同步。
    @Published var upstreamPrompt: UpstreamPrompt?
    @Published private(set) var gitError: String?
    /// 仓库确定之后才有；没有 git 的项目为 nil。
    @Published private(set) var commit: CommitController?
    @Published private(set) var history: HistoryController?
    var hasGit: Bool { commit != nil }
    /// 项目视图里的文件搜索。
    let search: FileSearchController
    /// 底部「运行」工具窗口的内容。
    let run: RunController

    // MARK: - 编辑区

    @Published private(set) var tabs: [EditorTab] = []
    @Published private(set) var activeTabID: String?
    @Published private(set) var contents: [String: TabContent] = [:]
    /// 改了还没保存的文本，按标签 id（规则见 `DraftStore`）。
    @Published private(set) var draftStore = DraftStore()
    /// 开着的文件在 HEAD 里的内容，按标签 id；编辑器据此画行号旁的变更标记。HEAD 里没有的不在这里。
    private(set) var baseTexts: [String: String] = [:]
    /// 基线是按哪个 HEAD 取的；HEAD 变了整个重取。
    private var baseTextsHead = ""
    /// 后退 / 前进的历史，元素是标签 id。
    @Published private(set) var navigation = NavigationHistory<String>()
    /// 文件操作的撤销 / 重做栈（重命名、移动、删除、回滚）。编辑器里的撤销是 CodeMirror 自己的，见 `UndoDispatcher`。
    @Published var undoHistory = UndoHistory<UndoableOperation>()
    /// 一次撤销 / 重做正在跑（搬文件、git 都是异步的），跑完之前再按 ⌘Z 不响应。
    var isUndoing = false
    /// 状态栏里一条可关闭的提示。换了内容就把附带的动作清掉（动作只属于设它时的那条）。
    @Published private(set) var banner: String? {
        didSet { if banner != oldValue { bannerAction = nil } }
    }
    /// 提示旁边的一个动作（「撤销」）。
    @Published private(set) var bannerAction: BannerAction?
    private var bannerTimeout: Task<Void, Never>?

    struct BannerAction {
        let title: String
        let perform: @MainActor () -> Void
    }
    /// 当前正文里前面 / 后面还有没有变更可跳（页面报上来的，见 `setChangePosition`）。
    @Published private(set) var changePosition = ContentRenderer.ChangePosition()

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
    /// 需要壳把底部的「运行」窗口亮出来（开始运行脚本时）。
    var onRequestRunWindow: (@MainActor () -> Void)?

    let git: GitClient?
    private let renderer: ContentRenderer
    let fileManager = FileManager.default
    /// 目录树的展开状态记在这里（按项目根目录分键），下次打开同一个项目原样展开。
    private let defaults: UserDefaults
    private var savedExpanded: Set<String> = []
    private let preferences: ReadingPreferences
    /// 由 `WorkbenchModel.activate` 写入。只有当前项目才往共用的 WebView 里画。
    private(set) var isActive = false
    private var watcher: ChangeWatcher?
    private var gitTask: Task<Void, Never>?
    /// 正在按历史后退/前进：这次切换不再记进历史。
    private var isNavigating = false

    var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var activeContent: TabContent? {
        guard let activeTabID else { return nil }
        return contents[activeTabID]
    }

    init(root: URL, git: GitClient?, renderer: ContentRenderer, preferences: ReadingPreferences, defaults: UserDefaults = .standard,
         run: RunController? = nil) {
        self.git = git
        self.run = run ?? RunController()
        self.renderer = renderer
        self.preferences = preferences
        self.defaults = defaults
        let project = Project(root: root)
        self.project = project
        self.id = project.root.path
        self.search = FileSearchController(root: project.root)
        Log.info("project", "打开 \(project.root.path)")

        loadChildren(of: project.root.path)
        restoreExpandedDirectories()
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
                    guard let self else { return }
                    for change in affected {
                        // 文件被删掉了（删除、回滚新增）：先把编辑它的标签（文件标签、可编辑的 diff 标签）连草稿一起丢掉，
                        // 再关剩下的 diff 标签——顺序反了的话关 diff 标签会把草稿写回去，文件就从废纸篓外面复活了
                        if let url = self.url(for: change), !self.fileExists(url) { self.closeTabs(under: url) }
                        self.closeTab(EditorTab.id(forDiff: change))
                    }
                    self.refreshAll()
                }
                self.commit = controller
                let history = HistoryController(git: git, repositoryRoot: repositoryRoot)
                history.onRepositoryChanged = { [weak self] in self?.refreshAll() }
                self.history = history
                self.refreshGit()
            } else {
                Log.info("git", "\(project.name) 不在 git 仓库里")
            }
        }
    }

    /// 项目被关掉：没保存的写回去，停监听、停任务。
    func tearDown() {
        saveAll()
        gitTask?.cancel()
        history?.cancel()
        search.cancel()
        // 脚本要停掉：不像同步那样故意留着跑完，它没有半截状态要收拾，关了项目也没处看输出了
        run.tearDown()
        watcher?.stop()
        watcher = nil
    }

    /// 成为 / 不再是当前项目。成为当前时把活动标签画出来。
    func setActive(_ active: Bool) {
        if !active, isActive { rememberScrollOfActiveTab() }
        isActive = active
        if active { renderActiveTab() }
    }

    func dismissBanner() {
        bannerTimeout?.cancel()
        banner = nil
    }

    /// 出错的提示：不自动消失，用户自己关。
    func showError(_ text: String) {
        bannerTimeout?.cancel()
        banner = text
    }

    /// 一条过一会儿自己消失的提示，可带一个动作。出错的提示不走这里，那些要用户自己关。
    func notify(_ text: String, action: BannerAction? = nil, timeout: TimeInterval = 8) {
        bannerTimeout?.cancel()
        banner = text
        bannerAction = action
        bannerTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.banner == text else { return }
            self.banner = nil
        }
    }

    // MARK: - 目录树

    private func loadChildren(of path: String) {
        tree.setChildren(DirectoryLister.list(URL(fileURLWithPath: path, isDirectory: true), fileManager: fileManager), for: path)
    }

    /// 某个目录里多了 / 少了东西：重列它（已经列过的话），行跟着变。
    func refreshTree(directoryContaining url: URL) {
        let directory = url.deletingLastPathComponent().path
        if tree.hasLoaded(directory) { loadChildren(of: directory) }
        recomputeRows()
    }

    private func recomputeRows() {
        for pending in tree.needsLoading(root: project.root.path) {
            loadChildren(of: pending)
        }
        rows = tree.rows(root: project.root.path)
        saveExpandedDirectoriesIfChanged()
    }

    // MARK: - 展开状态的记忆

    private var expandedDirectoriesKey: String { "tree.expanded:" + project.root.path }

    /// 展开了哪些目录，每次行重算时比一下，变了就写（相对项目根的路径，项目搬家也还认）。
    private func saveExpandedDirectoriesIfChanged() {
        guard tree.expanded != savedExpanded else { return }
        savedExpanded = tree.expanded
        let relative = tree.expanded.compactMap { path -> String? in
            let components = project.projectRelativeComponents(of: URL(fileURLWithPath: path, isDirectory: true))
            return components.isEmpty ? nil : components.joined(separator: "/")
        }
        defaults.set(relative.sorted(), forKey: expandedDirectoriesKey)
    }

    /// 打开项目时把上次展开的目录展开回来（已经不存在的跳过）。
    private func restoreExpandedDirectories() {
        for relative in defaults.stringArray(forKey: expandedDirectoriesKey) ?? [] {
            let path = project.root.appendingPathComponent(relative, isDirectory: true).path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            tree.expand(path)
        }
        savedExpanded = tree.expanded
    }

    func select(_ path: String?) { selectedPath = path }
    /// ⌘点击：加进 / 移出多选。
    func toggleSelection(_ path: String) { selection.toggle(path, order: rows.map(\.id)) }
    /// ⇧点击：从锚点连选到这一行。
    func extendSelection(to path: String) { selection.extend(to: path, order: rows.map(\.id)) }

    /// 选中的节点，按行序；多选拖拽、删除用 `TreeSelection.roots` 去掉祖先也选中的那些。
    var selectedNodes: [FileNode] { rows.filter { selection.contains($0.id) }.map(\.node) }

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

    /// 在树上定位并选中一个文件（IDEA 的 Select Opened File），并切到项目工具窗口。
    func reveal(_ url: URL) {
        revealInTree(url)
        onRequestToolWindow?(.project)
    }

    /// 只在树上露出并选中，不切工具窗口（撤销删除之后把回来的文件指出来）。
    func revealInTree(_ url: URL) {
        tree.reveal(url.path, root: project.root.path)
        recomputeRows()
        selectedPath = url.path
        pendingReveal = url.path
    }

    /// 树视图已经把 `path` 滚进视野了。
    func didScrollToReveal(_ path: String) {
        if pendingReveal == path { pendingReveal = nil }
    }

    /// 定位当前标签对应的文件。
    func revealActiveTab() {
        guard let tab = activeTab else { return }
        if let url = tab.fileURL ?? tab.diffChange.flatMap({ self.url(for: $0) }) { reveal(url) }
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

    /// 选中某个路径的父目录（根目录就清掉选中）：删掉选中的东西之后用。
    func select(parentOf url: URL) {
        selectedPath = parentPath(of: url.path)
    }

    private func parentPath(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == project.root.path ? nil : parent
    }

    /// 树上选中的节点（⌫ 删除、菜单操作用）。
    var selectedNode: FileNode? {
        guard let selectedPath else { return nil }
        return rows.first { $0.id == selectedPath }?.node
    }

    /// 删除一个文件或目录：进废纸篓（不是 rm，删错了能找回来），关掉它（以及目录下）开着的标签，选中挪到父节点。
    /// 目录树与 FSEvents 会随后自己刷新；这里立刻刷一次，不用等去抖。
    func delete(_ node: FileNode) {
        guard let trashed = performDelete(node) else { return }
        recordUndo("删除 \(node.name)", .delete(original: node.url, trashed: trashed, isDirectory: node.isDirectory))
    }

    /// 真正删（进废纸篓）、关标签、挪选中、刷新；不记撤销栈（重做时也走这里）。返回它在废纸篓里的位置，删不成 nil。
    func performDelete(_ node: FileNode) -> URL? {
        guard node.url.path != project.root.path else { return nil }
        let trashed: URL
        do {
            trashed = try Trash.move(node.url)
            Log.info("project", "已删除 \(node.url.path)")
        } catch {
            banner = "删除失败：\(error.userFacingDescription)"
            Log.warn("project", "删除 \(node.url.path) 失败：\(error)")
            return nil
        }
        closeTabs(under: node.url)
        if selectedPath == node.id || (selectedPath?.hasPrefix(node.url.path + "/") ?? false) {
            selectedPath = parentPath(of: node.id)
        }
        refreshAll()
        return trashed
    }

    // MARK: - 重命名

    /// 一个新名字能不能用（对话框边敲边检查）。`.unchanged` 也算不能用：对话框把按钮灰掉就行，不必报错。
    func renameProblem(for node: FileNode, newName: String) -> FileRename.Problem? {
        let parent = node.url.deletingLastPathComponent()
        return FileRename.validate(newName, currentName: node.name) { name in entryExists(parent.appendingPathComponent(name).path) }
    }

    /// 目录里有没有这个名字的条目。用 lstat 语义（`attributesOfItem`）而不是 `fileExists`：后者会跟着符号链接走，
    /// 一个目标失效的链接会被当成不存在，搬过去才报「已存在」。
    func entryExists(_ path: String) -> Bool {
        (try? fileManager.attributesOfItem(atPath: path)) != nil
    }

    /// 重命名文件或目录（IDEA 的 Rename，⇧F6）。先把没保存的都写盘（IDEA 重构前也先保存所有文档），
    /// 在仓库里的走 `git mv`（status 显示成一条「重命名」，而不是「删除 + 未跟踪」），git 不认的（未跟踪、被忽略）直接搬；
    /// 然后开着的标签、后退/前进历史、选中项、展开状态都换成新路径，最后刷 git。
    func rename(_ node: FileNode, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard node.url.path != project.root.path else { return }
        if let problem = renameProblem(for: node, newName: name) {
            if problem != .unchanged { banner = "重命名失败：\(problem.message)" }
            return
        }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: node.isDirectory)
        saveAll { [weak self] in
            Task { [weak self] in
                guard let self, let failure = await self.move(node, to: destination, verb: "重命名") else { return }
                self.showError(failure)
            }
        }
    }

    /// 能不能把一个节点拖进某个目录（拖动经过时光标就据此变成「不允许」）。
    func moveProblem(for node: FileNode, into directory: URL) -> FileRename.MoveProblem? {
        guard node.url.path != project.root.path else { return .intoItself }
        if let problem = FileRename.validateMove(node.url.path, into: directory.path, destinationExists: entryExists) { return problem }
        // 目标目录可能是个符号链接，指到源目录里面去了：按真实路径再查一次自包含。搬的是链接本身时源不解析（只解析它的父目录）
        let realSource = node.url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(node.name).path
        let realDestination = directory.resolvingSymlinksInPath().path
        if realDestination == realSource || realDestination.hasPrefix(realSource + "/") { return .intoItself }
        return nil
    }

    /// 把文件或目录搬进另一个目录（IDEA 的 Move：目录树里拖拽）。搬法与重命名一样（先保存、git mv 或 moveItem、界面换路径）。
    /// 不弹确认：像访达一样松手就搬，状态栏给一条「已移动 … 撤销」。
    func move(_ node: FileNode, into directory: URL) {
        if let problem = moveProblem(for: node, into: directory) {
            if problem != .sameDirectory { banner = "移动失败：\(problem.message)" }
            return
        }
        let destination = directory.appendingPathComponent(node.name, isDirectory: node.isDirectory)
        saveAll { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                if let failure = await self.move(node, to: destination, verb: "移动") {
                    self.showError(failure)
                    return
                }
                // 搬完在状态栏给一条带「撤销」的提示（与 ⌘Z 撤的是同一步：只在它还是栈顶时才撤）
                let target = self.project.projectRelativeComponents(of: directory).joined(separator: "/")
                let recorded = self.undoHistory.nextUndo?.id
                self.notify("已移动 \(node.name) 到 \(target.isEmpty ? "项目根目录" : target + "/")", action: BannerAction(title: "撤销") { [weak self] in
                    self?.dismissBanner()
                    self?.undo(expecting: recorded)
                })
            }
        }
    }

    /// 一个目录项的身份（设备号 + inode），lstat 语义。不存在返回 nil。
    func fileIdentity(_ path: String) -> [Int]? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let device = attributes[.systemNumber] as? Int, let inode = attributes[.systemFileNumber] as? Int else { return nil }
        return [device, inode]
    }

    /// 树上某个路径对应的节点（拖放时剪贴板上只有路径）。
    func node(atPath path: String) -> FileNode? {
        rows.first { $0.id == path }?.node
    }

    /// 变更列表里一条变更对应的文件节点（右键「重命名…」用）。不从树上找：变更的文件所在目录多半还没展开，
    /// `rows` 里根本没有它。已删除的变更、磁盘上已经不在的路径没有节点，菜单项也就不出现。
    func node(for change: GitChange) -> FileNode? {
        guard change.kind != .deleted, let url = url(for: change), entryExists(url.path) else { return nil }
        let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return FileNode(url: url, name: change.fileName, isDirectory: false, isSymlink: type == .typeSymbolicLink)
    }

    /// 真正搬。搬成了返回 nil 并记进撤销栈（`recording` 为 false 时不记：撤销 / 重做本身走的也是这里），
    /// 搬不成返回给用户看的原因（「重命名失败：…」）。
    func move(_ node: FileNode, to destination: URL, verb: String, recording: Bool = true) async -> String? {
        // 未跟踪的文件 git mv 一定拒绝，不用白跑一趟；目录不看聚合状态（里面可能既有已跟踪的又有未跟踪的），交给 git 试
        let isUntrackedFile = !node.isDirectory && gitStatus(for: node) == .change(.untracked)
        var moved = false
        if let git, let repositoryRoot = project.repositoryRoot, !isUntrackedFile, gitStatus(for: node) != .ignored,
           let oldRelative = project.repositoryRelativePath(of: node.url), let newRelative = project.repositoryRelativePath(of: destination) {
            do {
                try await git.move(from: oldRelative, to: newRelative, repositoryRoot: repositoryRoot)
                moved = true
            } catch {
                // git 不认这个路径（未跟踪、目录里没有已跟踪文件）：退回普通的搬文件。git mv 搬之前把源和目标都检查过，不会搬到一半。
                // 别的失败（Agent 正在跑 git、index.lock 被占）不能退回：文件搬了索引没动，status 会变成「删除 + 未跟踪」
                guard GitClient.refusedBecauseUntracked(error) else {
                    Log.warn("project", "git mv \(oldRelative) 失败：\(error)")
                    return "\(verb)失败：\(error.userFacingDescription)"
                }
                Log.info("project", "git mv \(oldRelative) 未成功，改为直接移动：\(error)")
            }
        }
        if !moved {
            do {
                try fileManager.moveItem(at: node.url, to: destination)
            } catch {
                Log.warn("project", "\(verb) \(node.url.path) 失败：\(error)")
                return "\(verb)失败：\(error.userFacingDescription)"
            }
        }
        didRename(node.url, to: destination)
        if recording {
            recordUndo("\(verb) \(node.name)", .move(from: node.url, to: destination, isDirectory: node.isDirectory, isSymlink: node.isSymlink, identity: fileIdentity(destination.path)))
        }
        return nil
    }

    /// 磁盘上已经搬好了：界面上所有指着旧路径的东西换到新路径。
    private func didRename(_ oldURL: URL, to newURL: URL) {
        Log.info("project", "已重命名 \(oldURL.path) → \(newURL.path)")
        // 标签里的 URL 是解析过符号链接的（openFile），这里同样解析一遍再比，/var 与 /private/var 才对得上。
        // 只解析父目录再把名字拼回去：磁盘已经搬完了，解析整条旧路径在不分大小写的文件系统上会得到新名字
        // （a.txt → A.txt 时旧路径解析出来也是 A.txt），新旧一样就一个标签都换不到
        let oldParent = oldURL.deletingLastPathComponent(), newParent = newURL.deletingLastPathComponent()
        let resolvedOld = oldParent.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(oldURL.lastPathComponent).path
        let resolvedNew = newParent.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(newURL.lastPathComponent).path
        // 文件标签换成新路径的标签：基线、草稿、滚动位置、光标都带过去；内容重读（扩展名变了语言也会变）。
        // 草稿刚才已经写盘了，还留着的是写盘失败的，跟着换 id 别丢
        var renamedTabIDs: [String: String] = [:]
        for (index, tab) in tabs.enumerated() {
            guard let url = tab.fileURL, let moved = FileRename.rewrite(url.path, from: resolvedOld, to: resolvedNew) else { continue }
            var replaced = EditorTab(kind: .file(URL(fileURLWithPath: moved)), isPreview: tab.isPreview)
            replaced.scrollTop = tab.scrollTop
            replaced.cursor = tab.cursor
            replaced.history = tab.history
            replaced.markdownView = tab.markdownView
            tabs[index] = replaced
            renamedTabIDs[tab.id] = replaced.id
            contents[tab.id] = nil
            baseTexts[replaced.id] = baseTexts.removeValue(forKey: tab.id)
            draftStore.move(tab.id, to: replaced.id)
            navigation.replace(tab.id, with: replaced.id)
        }
        if let activeTabID, let moved = renamedTabIDs[activeTabID] { self.activeTabID = moved }
        // 工作区 diff 标签：变更的路径变了，git 刷新后会是另一条变更，直接关掉（草稿已经挪走，这里不会写回旧路径）
        for tab in tabs {
            guard let change = tab.change, let url = url(for: change),
                  FileRename.rewrite(url.resolvingSymlinksInPath().standardizedFileURL.path, from: resolvedOld, to: resolvedNew) != nil else { continue }
            finishClosing(tab.id)
        }
        if let selectedPath, let moved = FileRename.rewrite(selectedPath, from: oldURL.path, to: newURL.path) { self.selectedPath = moved }
        tree.rename(oldURL.path, to: newURL.path)
        if oldParent.path != newParent.path {
            // 搬到别的目录：像 IDEA 那样在新位置露出来（展开目标目录、滚过去），选中它
            tree.reveal(newURL.path, root: project.root.path)
            selectedPath = newURL.path
            pendingReveal = newURL.path
        }
        recomputeRows()
        search.applyChanges([oldURL.path, newURL.path])
        if let tab = activeTab, tab.fileURL != nil, contents[tab.id] == nil { loadFile(for: tab) }
        refreshGit()
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

    /// 某次历史提交里一个文件的 diff。
    func openCommitDiff(_ change: GitChange, in commit: GitCommit, pinned: Bool = false) {
        let tab = EditorTab(kind: .commitDiff(commit, change), isPreview: !pinned)
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
            // 预览标签被顶掉。它不会有草稿：一改就固定了（见 applyEdit）
            let replaced = tabs[previewIndex].id
            contents[replaced] = nil
            navigation.remove(replaced)
            tabs[previewIndex] = incoming
        } else if let activeIndex = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(incoming, at: activeIndex + 1)
        } else {
            tabs.append(incoming)
        }
        activeTabID = incoming.id
        recordNavigation(incoming.id)
        selectChange(of: incoming)
        renderActiveTab()
    }

    func activate(_ tabID: String) {
        guard tabID != activeTabID, tabs.contains(where: { $0.id == tabID }) else { return }
        rememberScrollOfActiveTab()
        activeTabID = tabID
        recordNavigation(tabID)
        if let tab = activeTab {
            if let url = tab.fileURL { selectedPath = url.path }
            selectChange(of: tab)
            if contents[tab.id] == nil { tab.isDiff ? loadDiff(for: tab) : loadFile(for: tab) }
        }
        renderActiveTab()
    }

    // MARK: - 变更列表的选中

    /// 单击：只选这一条。
    func selectChange(_ path: String) { changeSelection.select(path) }
    /// ⌘点击：加进 / 移出多选。`order` 是列表里看得见的行序（折叠的分组不算）。
    func toggleChangeSelection(_ path: String, order: [String]) { changeSelection.toggle(path, order: order) }
    /// ⇧点击：从锚点连选到这一条。
    func extendChangeSelection(to path: String, order: [String]) { changeSelection.extend(to: path, order: order) }

    /// 选中的变更，按列表顺序（变更在前、未跟踪在后）。
    var selectedChanges: [GitChange] {
        (changeGroups.tracked + changeGroups.untracked).filter { changeSelection.contains($0.path) }
    }

    /// 右键点在哪一条上，操作的是哪几条：点在多选里就是整个多选（IDEA、访达都这样），否则只是它。
    func changesForAction(on change: GitChange) -> [GitChange] {
        changeSelection.count > 1 && changeSelection.contains(change.path) ? selectedChanges : [change]
    }

    /// 标签切到某条工作区变更的 diff 上（F7、⌘⇥、目录树里「显示 diff」……）：变更列表的选中跟过去，
    /// 已经在多选里的不动（不把用户挑好的多选收成一条）。
    private func selectChange(of tab: EditorTab) {
        guard let change = tab.change, !changeSelection.contains(change.path) else { return }
        changeSelection.select(change.path)
    }

    // MARK: - 后退 / 前进

    private func recordNavigation(_ tabID: String) {
        if !isNavigating { navigation.visit(tabID) }
    }

    var canGoBack: Bool { navigation.canGoBack }
    var canGoForward: Bool { navigation.canGoForward }

    func goBack() { navigate { $0.goBack() } }
    func goForward() { navigate { $0.goForward() } }

    private func navigate(_ step: (inout NavigationHistory<String>) -> String?) {
        guard let target = step(&navigation), tabs.contains(where: { $0.id == target }) else { return }
        isNavigating = true
        activate(target)
        isNavigating = false
    }

    // MARK: - 上一处 / 下一处变更

    /// 当前标签里有可以跳的变更点：任一种 diff 标签，或者有工作区变更、且在编辑器里打开（行号旁有标记）的文本标签。
    /// Markdown 预览没有行；超过 2MB 的只读代码视图没有标记，也没有。
    var canNavigateChanges: Bool {
        guard let tab = activeTab else { return false }
        if tab.isDiff { return true }
        guard let url = tab.fileURL, change(for: url) != nil, isEditable(tab), let content = contents[tab.id] else { return false }
        if case .markdown = content, tab.markdownView == .preview { return false }
        return true
    }

    /// F7 / ⇧F7、标题条的上下箭头：让 WebView 跳到下一处 / 上一处变更。
    func navigateChange(_ step: ContentRenderer.ChangeStep) {
        guard isActive, canNavigateChanges else { return }
        renderer.navigateChange(step)
    }

    /// 页面报上来的：前面 / 后面还有没有变更可跳。到头的方向箭头与菜单项灰掉（IDEA 一样）。
    func setChangePosition(_ position: ContentRenderer.ChangePosition) {
        if position != changePosition { changePosition = position }
    }

    func pin(_ tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isPreview = false
    }

    /// 关标签。改过的先写回磁盘（IDEA 关编辑器不问、直接保存）；当前正在编辑的先把编辑器里最新的文字要过来。
    func closeTab(_ tabID: String) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if tabID == activeTabID, isActive, isEditable(tab) {
            rememberScroll(of: tabID) { [weak self] _ in self?.finishClosing(tabID) }
        } else {
            finishClosing(tabID)
        }
    }

    /// `discardingDraft`：文件已经被删了，草稿不能再写回去——写了文件就从废纸篓外面复活了。
    /// 文档（内容、基线、草稿）只在最后一个用它的标签关掉时才释放：文件标签与 diff 标签可能同时开着同一个文件。
    private func finishClosing(_ tabID: String, discardingDraft: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let documentID = documentID(for: tabs[index])
        if let documentID {
            // 文件已经不在磁盘上（外部删了）：关标签的自动保存不能凭空把它创建回来；显式 ⌘S 不受此限
            let fileExists = EditorTab.fileURL(fromID: documentID).map { fileManager.fileExists(atPath: $0.path) } ?? false
            if discardingDraft || !fileExists { draftStore.discard(documentID) } else { writeDraft(documentID) }
        }
        let document = documentID.flatMap { contents[$0] }
        tabs.remove(at: index)
        contents[tabID] = nil
        navigation.remove(tabID)
        if let documentID {
            if tabs.contains(where: { self.documentID(for: $0) == documentID }) {
                contents[documentID] = document
            } else {
                contents[documentID] = nil
                baseTexts[documentID] = nil
                draftStore.discard(documentID)
            }
        }
        if activeTabID == tabID {
            activeTabID = (tabs.indices.contains(index) ? tabs[index] : tabs.last)?.id
            renderActiveTab()
        }
    }

    func closeActiveTab() {
        if let activeTabID { closeTab(activeTabID) }
    }

    /// 文件或目录被删了：关掉编辑它（以及目录下文件）的标签——文件标签和可编辑的 diff 标签，草稿一并丢弃（不能写回去）。
    func closeTabs(under url: URL) {
        // 标签里的 URL 是解析过符号链接的（openFile），这里也解析一遍再比，/var 与 /private/var 才对得上
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = path + "/"
        for tab in tabs {
            guard let file = documentURL(for: tab)?.path else { continue }
            if file == path || file.hasPrefix(prefix) { finishClosing(tab.id, discardingDraft: true) }
        }
    }

    func closeOtherTabs(_ tabID: String) {
        // 走 closeTab 而不是直接 finishClosing：当前正在编辑的那个要先把编辑器里的最后几笔要回来再写盘
        for tab in tabs where tab.id != tabID { closeTab(tab.id) }
        if activeTabID != tabID { activate(tabID) }
    }

    func closeAllTabs() {
        for tab in tabs { closeTab(tab.id) }
    }

    func selectNextTab(offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        activate(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    /// Markdown 标签换一种看法（预览 → 源码 → 分栏）。先把编辑器里的文字要回来再重画，否则改动会丢。
    func cycleMarkdownView() {
        guard let tab = activeTab else { return }
        setMarkdownView(tab.markdownView.next)
    }

    func setMarkdownView(_ view: MarkdownView) {
        guard let id = activeTabID else { return }
        rememberScroll(of: id) { [weak self] _ in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            self.tabs[index].markdownView = view
            self.tabs[index].scrollTop = 0
            self.renderActiveTab()
        }
    }

    private func rememberScrollOfActiveTab() {
        guard isActive, let id = activeTabID else { return }
        rememberScroll(of: id)
    }

    /// 问 WebView 当前的状态（滚到哪、编辑器里的文字与光标），记到那个标签上；记完之后可以接着做点别的（比如重读文件）。
    /// **重画当前标签之前必须先走这里**，不然编辑器里还没送过来的那几笔就没了。
    private func rememberScroll(of tabID: String, then continuation: @escaping @MainActor (EditorTab) -> Void = { _ in }) {
        renderer.currentState { [weak self] state in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            self.tabs[index].scrollTop = state.scrollTop
            if let cursor = state.cursor { self.tabs[index].cursor = cursor }
            // 编辑器的撤销历史跟着标签走（连同它对应的文本），切回来 ⌘Z 还能撤；只读视图没有编辑器，别把上次记的清掉
            if let text = state.text, let history = state.history { self.tabs[index].history = EditorHistory(json: history, text: text) }
            if let text = state.text, let url = self.documentURL(for: self.tabs[index]) { self.applyEdit(path: url.path, text: text) }
            continuation(self.tabs[index])
        }
    }

    // MARK: - 编辑与保存

    /// 草稿与写盘的规则在 `DraftStore`；这里只管时机：什么时候向编辑器要最新文字、写完刷 git。
    /// 键是**文档 id**（= 文件标签的 id）：同一个文件的文件标签与 diff 标签共用一份草稿。
    var drafts: [String: String] { draftStore.drafts }

    /// 一个标签编辑的是哪个文档：文件标签就是自己；工作区 diff 标签是那条变更对应的文件（已删除的没有）。历史 diff 不可编辑。
    func documentID(for tab: EditorTab) -> String? {
        switch tab.kind {
        case .file: return tab.id
        case .diff(let change):
            guard change.kind != .deleted, let url = url(for: change) else { return nil }
            return EditorTab.id(forFile: url.resolvingSymlinksInPath().standardizedFileURL)
        case .commitDiff: return nil
        }
    }

    func documentURL(for tab: EditorTab) -> URL? {
        documentID(for: tab).flatMap(EditorTab.fileURL(fromID:))
    }

    func isEditable(_ tab: EditorTab) -> Bool {
        guard let documentID = documentID(for: tab) else { return false }
        return DraftStore.isEditable(contents[documentID])
    }

    func isModified(_ tab: EditorTab) -> Bool {
        documentID(for: tab).map(draftStore.isModified) ?? false
    }

    /// 磁盘上的文件比读进来时新（别人改过了）。改过还没保存的标签上要提醒一句。
    func isDiskNewer(_ tab: EditorTab) -> Bool {
        guard let documentID = documentID(for: tab), let url = EditorTab.fileURL(fromID: documentID) else { return false }
        return DraftStore.isDiskNewer(at: url, than: contents[documentID]?.modificationDate, fileManager: fileManager)
    }

    /// 编辑器里的文字变了。只认开着的、可编辑的文档；一改预览标签就固定下来（IDEA 也这样），免得被下一次单击顶掉。
    func applyEdit(path: String, text: String) {
        let id = EditorTab.id(forFile: URL(fileURLWithPath: path))
        let users = tabs.filter { documentID(for: $0) == id }
        guard !users.isEmpty, DraftStore.isEditable(contents[id]), let saved = contents[id]?.text else { return }
        if draftStore.apply(text: text, to: id, saved: saved) {
            for tab in users { pin(tab.id) }
        }
    }

    /// 保存当前标签（⌘S）。先把编辑器里最新的文字要过来再写。
    func saveActiveTab() {
        guard let id = activeTabID, let tab = activeTab, let documentID = documentID(for: tab) else { return }
        if isActive {
            rememberScroll(of: id) { [weak self] _ in self?.writeDraft(documentID) }
        } else {
            writeDraft(documentID)
        }
    }

    /// 「运行」一个脚本，输出进底部的运行窗口。先把没保存的写盘：跑的得是编辑器里看到的那份。
    func runScript(_ url: URL) {
        saveAll { [weak self] in
            guard let self else { return }
            run.run(url)
            onRequestRunWindow?()
        }
    }

    /// 当前标签能不能「运行」（菜单的「运行当前文件」）：文件标签，且是 shell / Python。
    var runnableActiveFile: URL? {
        guard let url = activeTab?.fileURL, ScriptRunner.kind(forFileNamed: url.lastPathComponent) != nil else { return nil }
        return url
    }

    /// 保存所有改过的标签：手头已有的草稿立刻落盘；正在编辑的那个再向编辑器要一次最新文字补写，写完调 `completion`
    /// （比如「在终端中运行」要等文件真的落盘再跑）。退出时只有同步那一段来得及跑，停手不到 300ms 的最后几笔可能不在。
    func saveAll(then completion: @escaping @MainActor () -> Void = {}) {
        writeAllDrafts()
        guard isActive, let id = activeTabID, let tab = activeTab, isEditable(tab) else {
            completion()
            return
        }
        // 强引用自己：关项目时会话已经从列表里摘掉了，弱引用会在编辑器把文字送回来之前被释放
        renderer.currentState { state in
            if let index = self.tabs.firstIndex(where: { $0.id == id }) {
                self.tabs[index].scrollTop = state.scrollTop
                if let cursor = state.cursor { self.tabs[index].cursor = cursor }
                // 重命名 / 移动之后编辑器会重建（内容重读），历史也得是此刻的这份
                if let text = state.text, let history = state.history { self.tabs[index].history = EditorHistory(json: history, text: text) }
            }
            if let text = state.text, let url = self.documentURL(for: tab) { self.applyEdit(path: url.path, text: text) }
            self.writeAllDrafts()
            completion()
        }
    }

    private func writeAllDrafts() {
        for id in draftStore.drafts.keys { writeDraft(id) }
    }

    /// 把一个文档的草稿写回磁盘。没有草稿就什么都不做。
    @discardableResult
    func writeDraft(_ documentID: String) -> Bool {
        guard let url = EditorTab.fileURL(fromID: documentID), let content = contents[documentID] else { return false }
        do {
            guard let saved = try draftStore.write(documentID, to: url, content: content, fileManager: fileManager) else { return false }
            contents[documentID] = saved
        } catch {
            banner = "保存 \(url.lastPathComponent) 失败：\(error.userFacingDescription)"
            Log.warn("editor", "保存 \(url.path) 失败：\(error)")
            return false
        }
        Log.info("editor", "已保存 \(url.path)")
        refreshGit()
        return true
    }

    // MARK: - 内容加载

    /// 同步读的上限。这个体积以内读盘加解码不到几毫秒，直接在点击的同一回合里读完、画出来，
    /// 省掉「先摆一个加载中、两次线程跳转、再画」的三步——那三步加起来有几十毫秒，肉眼能看出顿一下。
    static let synchronousReadLimit = 512 * 1024

    private func loadFile(for tab: EditorTab) {
        guard let url = tab.fileURL else { return }
        // 已有基线（重读、重命名后）不再取：HEAD 变了 apply(snapshot) 会整个重取
        if baseTexts[tab.id] == nil { fetchBaseText(documentID: tab.id) }
        let fileManager = self.fileManager
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size <= Self.synchronousReadLimit {
            contents[tab.id] = FileContentLoader.load(url, fileManager: fileManager)
            if activeTabID == tab.id { renderActiveTab() }
            return
        }
        contents[tab.id] = .loading
        Task { [weak self] in
            // 大文件读盘放到后台：几 MB 的文件同步读会卡一下主线程
            let content = await Task.detached(priority: .userInitiated) { FileContentLoader.load(url, fileManager: fileManager) }.value
            self?.store(content, for: tab.id)
        }
    }

    /// 取一个文档的 HEAD 内容。到了以后当前正显示它的话直接送进编辑器（不重画）。
    private func fetchBaseText(documentID: String) {
        guard let git, let repositoryRoot = project.repositoryRoot, let url = EditorTab.fileURL(fromID: documentID),
              let relative = project.repositoryRelativePath(of: url) else { return }
        // 重命名过的文件 HEAD 里是原来的路径
        let headPath = change(for: url)?.originalPath ?? relative
        Task { [weak self] in
            let base = await git.headContent(path: headPath, repositoryRoot: repositoryRoot)
            guard let self, self.tabs.contains(where: { self.documentID(for: $0) == documentID }) else { return }
            self.baseTexts[documentID] = base
            if self.isActive, let tab = self.activeTab, self.documentID(for: tab) == documentID { self.renderer.setBase(path: url.path, text: base) }
        }
    }

    /// 文档（文件的内容）没加载就同步读进来。只给不太大的文件用（可编辑上限之内）。
    @discardableResult
    private func ensureDocument(_ documentID: String) -> TabContent? {
        if let existing = contents[documentID], existing != .loading { return existing }
        guard let url = EditorTab.fileURL(fromID: documentID) else { return nil }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= DraftStore.editableLimit else { return nil }
        let loaded = FileContentLoader.load(url, fileManager: fileManager)
        contents[documentID] = loaded
        return loaded
    }

    /// 加载完成后回填。标签在加载期间被关掉了就丢弃；是当前标签就立刻画。
    private func store(_ content: TabContent, for tabID: String) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        contents[tabID] = content
        if activeTabID == tabID { renderActiveTab() }
    }

    /// 两种 diff 标签（工作区变更、历史提交）都从这里加载。
    /// 工作区变更且文件还在、是文本、不太大 → 可编辑的 diff（文档 + HEAD 基线）；否则静态的 git diff。
    private func loadDiff(for tab: EditorTab) {
        guard let change = tab.diffChange, let git, let repositoryRoot = project.repositoryRoot else {
            contents[tab.id] = .message(title: "没有 git", detail: "这个项目不在 git 仓库里，或者本机没有 git。")
            return
        }
        if let documentID = documentID(for: tab), DraftStore.isEditable(ensureDocument(documentID)) {
            contents[tab.id] = .loading
            Task { [weak self] in
                // 先等基线到了再画，免得先闪一下「整个文件都是新增」
                guard let self, let url = EditorTab.fileURL(fromID: documentID), let relative = self.project.repositoryRelativePath(of: url) else { return }
                if self.baseTexts[documentID] == nil {
                    // 重命名过的变更 HEAD 里是原来的路径
                    self.baseTexts[documentID] = await git.headContent(path: change.originalPath ?? relative, repositoryRoot: repositoryRoot)
                }
                self.store(.editableDiff(documentID: documentID), for: tab.id)
            }
            return
        }
        let commit = tab.commitDiff?.commit
        contents[tab.id] = .loading
        Task { [weak self] in
            let content = await FileContentLoader.loadDiff(change, in: commit, git: git, repositoryRoot: repositoryRoot)
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
        let documentID = documentID(for: tab)
        let rendered: RenderPayload.Content
        if case .editableDiff(let documentID) = content, let change = tab.change, let url = EditorTab.fileURL(fromID: documentID),
           let document = ensureDocument(documentID) {
            rendered = FileContentLoader.editableDiff(
                change: change, document: document, draft: draftStore[documentID], base: baseTexts[documentID],
                filePath: url.path, cursor: tab.cursor, history: tab.history, mode: preferences.diffMode
            )
        } else {
            rendered = content.renderContent(
                for: tab, diffMode: preferences.diffMode,
                draft: documentID.flatMap { draftStore[$0] }, editable: isEditable(tab), base: documentID.flatMap { baseTexts[$0] }
            )
        }
        renderer.render(RenderPayload(rendered, scrollTop: tab.scrollTop, wrap: preferences.wordWrap))
    }

    /// 状态栏右侧那几格。可编辑的 diff 显示的是它编辑的那个文档的（行数、编码、语言）。
    var activeStatusSummary: [String] {
        guard let tab = activeTab, let content = contents[tab.id] else { return [] }
        if case .editableDiff(let documentID) = content { return contents[documentID]?.statusSummary ?? [] }
        return content.statusSummary
    }

    /// 重画当前标签但先把编辑器里的状态要回来（切 diff 并排/单列这种「同一标签换个画法」的场合）。
    func rerenderActiveTab() {
        guard isActive, let id = activeTabID else { return }
        rememberScroll(of: id) { [weak self] _ in self?.renderActiveTab() }
    }

    // MARK: - Git 状态

    func refreshGit() {
        guard let git, let repositoryRoot = project.repositoryRoot else { return }
        gitTask?.cancel()
        let task = Task { [weak self] in
            // 转圈延迟出现：status 通常几十毫秒就回来，每次都闪一下转圈反而显得卡
            let spinner = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                self?.isRefreshingGit = true
            }
            defer { spinner.cancel() }
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
            if let self, self.gitTask?.isCancelled == false, self.isRefreshingGit { self.isRefreshingGit = false }
        }
        gitTask = task
    }

    private func apply(_ snapshot: GitSnapshot) {
        gitError = nil
        let ignoredChanged = snapshot.ignored != gitSnapshot.ignored
        gitSnapshot = snapshot
        gitIndex = GitStatusIndex(snapshot: snapshot)
        changeGroups = ChangeGroups(changes: snapshot.changes)
        // 被提交 / 回滚 / 删掉的变更从选中里去掉
        var selection = changeSelection
        selection.retain(Set(snapshot.changes.map(\.path)), order: (changeGroups.tracked + changeGroups.untracked).map(\.path))
        if selection != changeSelection { changeSelection = selection }
        commit?.update(snapshot: snapshot)
        // 有了新提交（或切了分支）才重拉历史；工作区文件改动不影响 log。控制器自己比对 HEAD 去重
        history?.currentHead = snapshot.branch.headOID
        history?.refreshIfLoaded()
        // HEAD 变了，编辑器的变更标记 / 可编辑 diff 的基线也要换
        if baseTextsHead != snapshot.branch.headOID {
            baseTextsHead = snapshot.branch.headOID
            for documentID in Set(tabs.compactMap(documentID(for:))) { fetchBaseText(documentID: documentID) }
        }
        // 搜索索引跳过 git 忽略的路径。闭包里只放值类型，能拿到后台去跑；忽略集变了已建的索引作废
        if let prefix = project.repositoryRelativePath(of: project.root) {
            let index = gitIndex
            search.isExcluded = { path, isDirectory in
                index.isIgnored(prefix.isEmpty ? path : prefix + "/" + path, isDirectory: isDirectory)
            }
            if ignoredChanged { search.markStale() }
        }

        // 开着的 diff 标签：变更已经不在了的关掉（比如被提交了），其余重新算
        let stillChanged = Dictionary(uniqueKeysWithValues: snapshot.changes.map { ($0.path, $0) })
        for tab in tabs {
            guard let change = tab.change else { continue }
            guard let fresh = stillChanged[change.path] else {
                closeTab(tab.id)
                continue
            }
            // 可编辑的 diff 不靠 git 的 diff 文本，变更种类没变就不用重载（重载会把编辑器整个重建）
            if fresh == change, case .editableDiff = contents[tab.id] { continue }
            if fresh != change, let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                var replaced = EditorTab(kind: .diff(fresh), isPreview: tab.isPreview)
                replaced.scrollTop = tab.scrollTop
                replaced.cursor = tab.cursor
                tabs[index] = replaced
            }
            contents[tab.id] = nil
            if activeTabID == tab.id, let current = tabs.first(where: { $0.id == tab.id }) { loadDiff(for: current) }
        }
    }

    // MARK: - 添加到 git

    /// git 认不认识这个节点：未跟踪的、被 `.gitignore` 挡着的都还没纳入版本管理，右键才给「添加到 git」。
    func canAddToGit(_ node: FileNode) -> Bool {
        switch gitStatus(for: node) {
        case .change(.untracked), .ignored: return true
        default: return false
        }
    }

    func isIgnoredByGit(_ node: FileNode) -> Bool { gitStatus(for: node) == .ignored }

    /// 目录树右键「添加到 git」（IDEA 的 Add to VCS）：把未跟踪 / 被忽略的路径纳入版本管理，
    /// 之后它们出现在提交列表里、能跟着一起提交。只动索引，磁盘上的文件一个字节都不碰。
    ///
    /// 两处讲究：
    /// - **先把目录展开成它下面的具体文件再 add**（`ls-files --others`）：撤销时才能精确地把这几个文件从索引里撤下来。
    ///   直接 `rm --cached -r <目录>` 会把目录里本来就跟踪着的文件也一起摘出版本管理——未跟踪的目录里完全可能有已跟踪的文件
    ///   （目录的颜色只反映它下面变更里优先级最高的那一种）。
    /// - **被忽略的与未跟踪的分成两次 add**：前者非 `--force` 不可（不加 git 直接拒绝整条命令），
    ///   而 `--force` 用在未跟踪的目录上会把它里面本该忽略的东西（`node_modules`、构建产物）一起拖进来。
    func addToGit(_ nodes: [FileNode]) {
        guard let commit else { return }
        let targets = TreeSelection.roots(nodes.filter(canAddToGit))
        guard !targets.isEmpty else { return }
        let ignoredPaths = targets.filter(isIgnoredByGit).compactMap { project.repositoryRelativePath(of: $0.url) }
        let untrackedPaths = targets.filter { !isIgnoredByGit($0) }.compactMap { project.repositoryRelativePath(of: $0.url) }
        let title = targets.count == 1 ? "添加 \(targets[0].name) 到 git" : "添加 \(targets.count) 个项目到 git"
        Task { [weak self] in
            guard let self else { return }
            do {
                let untracked = untrackedPaths.isEmpty ? [] : try await commit.untrackedFiles(under: untrackedPaths, ignored: false)
                let ignored = ignoredPaths.isEmpty ? [] : try await commit.untrackedFiles(under: ignoredPaths, ignored: true)
                guard !untracked.isEmpty || !ignored.isEmpty else {
                    // git 只记文件：空目录（或里面只剩空目录）没有东西可加
                    self.notify("没有可添加的文件：git 记不住空目录")
                    return
                }
                if !untracked.isEmpty { try await commit.add(paths: untracked, force: false) }
                if !ignored.isEmpty { try await commit.add(paths: ignored, force: true) }
                let count = untracked.count + ignored.count
                Log.info("git", "添加到 git：\(count) 个文件（其中被忽略的 \(ignored.count) 个）")
                let recorded = self.recordUndo(title, .addToGit(untracked: untracked, ignored: ignored))
                self.notify("已添加 \(count) 个文件到 git", action: BannerAction(title: "撤销") { [weak self] in
                    self?.dismissBanner()
                    self?.undo(expecting: recorded.id)
                })
                self.refreshAll()
            } catch {
                Log.warn("git", "添加到 git 失败：\(error)")
                self.showError("添加到 git 失败：\(error.userFacingDescription)")
                self.refreshAll()
            }
        }
    }

    /// 这个项目**够得着远程**：有仓库、有提交、当前分支有上游。与「此刻能不能点」分开——
    /// 提交历史的刷新按钮按它决定自己是「同步」还是「只重列本地」（图标与提示都跟着走），
    /// 同步进行中按钮只是灰着，不该在那两三秒里变成另一个按钮。
    var hasRemoteUpstream: Bool {
        hasGit && !gitSnapshot.branch.isUnborn && gitSnapshot.branch.upstream != nil
    }

    /// 能不能跟远程同步：够得着远程，而且没在同步。
    /// 没有上游的仓库（还没 push 过、游离 HEAD）按钮直接灰掉，提交历史的刷新退回本地刷新，
    /// 不要点一下弹一条要用户手动关掉的错误。
    var canSyncWithRemote: Bool { hasRemoteUpstream && !isSyncingRemote && !isSwitchingBranch }

    /// 第一次 git status 回来了没有。回来之前 `gitSnapshot` 是 `.empty`（看着像「还没有提交」），同步按钮灰着的原因得另说。
    var hasLoadedGitStatus: Bool { gitSnapshot != .empty }

    /// 与远程同步（IDEA 的 Update Project）：`git fetch` 之后把上游的新提交 rebase 到本地分支下面，
    /// 完了整体刷新（目录树、开着的文件、git 状态、已经打开的提交历史）。
    ///
    /// 结果与失败都报在状态栏：成功的提示自己消失，失败的留着等用户看完关掉。
    func syncWithRemote() {
        guard let git, let repositoryRoot = project.repositoryRoot, !isSyncingRemote, !isSwitchingBranch else { return }
        // rebase 会重写工作区里的文件，先把没保存的写盘：留在编辑器里的草稿不在 git 眼里，
        // 既进不了 --autostash，拉下来之后 reloadOpenFilesIfChanged 也不会碰改过的文档，
        // 下一次 ⌘S 就会把同事的改动覆盖掉。IDEA 的 Update Project 同样先保存。
        saveAll()
        isSyncingRemote = true
        // 开始也记一笔：同步卡住时日志里只会有开始、没有结束，一眼看得出是卡在这儿了
        let started = Date()
        Log.info("git", "同步远程：开始（\(project.name)，\(gitSnapshot.branch.upstream ?? "?")）")
        // 刻意不在 tearDown 里取消：rebase 跑到一半被 SIGTERM 打断可能把仓库停在 rebase 中途，
        // 而这个应用没有解冲突的界面。任务只捕获弱引用，项目关了它自己会安静地跑完。
        Task { [weak self] in
            do {
                let result = try await git.syncWithRemote(repositoryRoot: repositoryRoot)
                Log.info("git", "同步远程：\(result.summary)（\(String(format: "%.1f", Date().timeIntervalSince(started))) 秒）")
                guard let self else { return }
                self.isSyncingRemote = false
                // autostash 没能放回去时改动只剩在 stash 里，这条提示不能几秒后自己溜走
                if result.autostashConflicted {
                    self.banner = result.summary
                } else {
                    self.notify(result.summary)
                }
            } catch is CancellationError {
                self?.isSyncingRemote = false
                return
            } catch {
                Log.warn("git", "同步远程失败（\(String(format: "%.1f", Date().timeIntervalSince(started))) 秒）：\(error)")
                guard let self else { return }
                self.isSyncingRemote = false
                // 出错的提示不自动消失，用户自己关
                self.banner = "同步失败：\(error.userFacingDescription)"
            }
            guard let self else { return }
            self.refreshAll()
            // HEAD 没变时 apply(snapshot) 不会重拉历史，但用户是点了刷新按钮才到这儿的，打开着的历史照拉一次
            self.history?.reloadIfLoaded()
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
        search.applyChanges(paths)
    }

    /// 开着的文件在磁盘上变了就重读；当前显示的那个重渲染但保持滚动位置——Agent 正在改的文件用户多半正盯着看。
    /// 改过还没保存的不动它（用户的改动优先），标题条上会提示磁盘上的已经不一样了。
    private func reloadOpenFilesIfChanged() {
        let activeDocument = activeTab.flatMap(documentID(for:))
        for documentID in Set(tabs.compactMap(documentID(for:))) where !draftStore.isModified(documentID) {
            guard let url = EditorTab.fileURL(fromID: documentID), let content = contents[documentID], content != .loading else { continue }
            let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard FileContentLoader.isStale(content, modifiedOnDisk: modified, exists: fileManager.fileExists(atPath: url.path)) else { continue }
            if documentID == activeDocument, isActive, let activeTabID {
                // 先问编辑器：刚敲的几笔可能还没送过来，问完要是有草稿就不重读了
                rememberScroll(of: activeTabID) { [weak self] current in
                    guard let self, !self.draftStore.isModified(documentID) else { return }
                    // 内容要从磁盘重读了：编辑器的撤销历史指的是旧内容里的位置，作废
                    self.forgetEditorHistory(of: documentID)
                    if current.fileURL != nil {
                        // 文件标签：走 loadFile，大文件（只读）也能异步重读；ensureDocument 只管可编辑上限之内的
                        self.loadFile(for: current)
                    } else {
                        self.contents[documentID] = nil
                        self.ensureDocument(documentID)
                        if self.activeTabID == activeTabID { self.renderActiveTab() }
                    }
                }
            } else {
                forgetEditorHistory(of: documentID)
                contents[documentID] = nil
            }
        }
    }

    private func forgetEditorHistory(of documentID: String) {
        for index in tabs.indices where self.documentID(for: tabs[index]) == documentID { tabs[index].history = nil }
    }

    // MARK: - 杂项

    func url(for change: GitChange) -> URL? { project.url(forRepositoryPath: change.path) }

    func fileExists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    func change(for url: URL) -> GitChange? {
        guard let relative = project.repositoryRelativePath(of: url) else { return nil }
        return gitSnapshot.changes.first { $0.path == relative }
    }
}
