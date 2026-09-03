import AppKit
import Combine
import Core
import DesignSystem
import Foundation

/// 阅读偏好，所有项目共用。改了就落到 UserDefaults。
@MainActor
final class ReadingPreferences: ObservableObject {
    @Published var diffMode: DiffViewMode { didSet { defaults.set(diffMode.rawValue, forKey: "diff.mode") } }
    @Published var wordWrap: Bool { didSet { defaults.set(wordWrap, forKey: "editor.wrap") } }
    @Published private(set) var zoom: Double { didSet { defaults.set(zoom, forKey: "editor.zoom") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        diffMode = DiffViewMode(rawValue: defaults.string(forKey: "diff.mode") ?? "") ?? .sideBySide
        wordWrap = defaults.bool(forKey: "editor.wrap")
        let saved = defaults.double(forKey: "editor.zoom")
        zoom = saved > 0 ? saved : 1
    }

    func zoomIn() { zoom = min(3, (zoom * 10).rounded() / 10 + 0.1) }
    func zoomOut() { zoom = max(0.5, (zoom * 10).rounded() / 10 - 0.1) }
    func resetZoom() { zoom = 1 }
}

/// 整个窗口的状态：打开着的几个项目、当前是哪个、最近项目、工具窗口。
///
/// 正文 WebView 只有一个，所有项目共用；切项目时告诉新旧会话各自 `setActive`。
@MainActor
final class WorkbenchModel: ObservableObject {
    @Published private(set) var sessions: [ProjectSession] = []
    @Published private(set) var activeSessionID: String?
    @Published private(set) var recentProjects: [RecentProject] = []
    @Published var toolWindow: ToolWindow? = .project {
        didSet { defaults.set(toolWindow?.rawValue ?? "", forKey: "toolWindow") }
    }
    @Published var toolWindowWidth: CGFloat {
        didSet { defaults.set(Double(toolWindowWidth), forKey: "toolWindow.width") }
    }

    let preferences: ReadingPreferences
    let renderer = ContentRenderer()
    private let git: GitClient?
    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let recentStore: JSONFileStore<[RecentProject]>
    private var preferenceObservation: Task<Void, Never>?
    /// 当前会话一变（草稿、标签、导航）就把 workbench 的变化也发出去：菜单项的启用状态只观察 workbench。
    private var activeSessionObservation: AnyCancellable?

    var active: ProjectSession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    init(git: GitClient? = GitClient.locate(), defaults: UserDefaults = .standard, recentFile: URL = AppPaths.recentProjectsFile) {
        self.git = git
        self.defaults = defaults
        self.recentStore = JSONFileStore(url: recentFile)
        self.preferences = ReadingPreferences(defaults: defaults)

        let savedWidth = defaults.double(forKey: "toolWindow.width")
        toolWindowWidth = savedWidth > 0 ? CGFloat(savedWidth) : 280
        if let saved = defaults.string(forKey: "toolWindow") {
            toolWindow = saved.isEmpty ? nil : ToolWindow(rawValue: saved)
        }
        recentProjects = RecentProjects.pruningMissing(recentStore.load() ?? [], fileManager: fileManager)

        self.renderer.setZoom(preferences.zoom)
        self.renderer.setWrap(preferences.wordWrap)
        self.renderer.onOpenExternal = { url in NSWorkspace.shared.open(url) }
        self.renderer.onOpenPath = { [weak self] path in
            self?.active?.openFile(URL(fileURLWithPath: path), pinned: false)
        }
        // 编辑器只画当前项目的标签，改动也只可能是它的
        self.renderer.onEdited = { [weak self] path, text in
            self?.active?.applyEdit(path: path, text: text)
        }
        self.renderer.onShellReloaded = { [weak self] in self?.active?.renderActiveTab() }
        self.renderer.onChangePosition = { [weak self] position in self?.active?.setChangePosition(position) }
        self.renderer.onNavigate = { [weak self] direction in
            switch direction {
            case .back: self?.active?.goBack()
            case .forward: self?.active?.goForward()
            }
        }
        observePreferences()
    }

    /// 偏好一变就同步到 WebView / 重画当前标签。
    private func observePreferences() {
        preferenceObservation = Task { [weak self] in
            guard let self else { return }
            var lastDiffMode = preferences.diffMode
            var lastWrap = preferences.wordWrap
            var lastZoom = preferences.zoom
            for await _ in preferences.objectWillChange.values {
                await Task.yield()
                guard !Task.isCancelled else { return }
                if preferences.diffMode != lastDiffMode {
                    lastDiffMode = preferences.diffMode
                    // 只有 diff 标签关心这个；先把编辑器里的状态要回来再重画（可编辑的 diff 也是编辑器）
                    if active?.activeTab?.isDiff == true { active?.rerenderActiveTab() }
                }
                if preferences.wordWrap != lastWrap {
                    lastWrap = preferences.wordWrap
                    renderer.setWrap(lastWrap)
                }
                if preferences.zoom != lastZoom {
                    lastZoom = preferences.zoom
                    renderer.setZoom(lastZoom)
                }
            }
        }
    }

    // MARK: - 项目

    /// 打开一个目录。已经开着的直接切过去。传进来的是文件的话，打开所在目录并顺手打开那个文件。
    func openProject(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            recentProjects = RecentProjects.removing(url.path, from: recentProjects)
            saveRecent()
            return
        }
        var fileToOpen: URL?
        var chosen = url.standardizedFileURL
        if !isDirectory.boolValue {
            fileToOpen = chosen
            chosen = chosen.deletingLastPathComponent()
        }
        let root = Project(root: chosen).root

        if let existing = sessions.first(where: { $0.project.root == root }) {
            activate(existing.id)
        } else {
            let session = ProjectSession(root: chosen, git: git, renderer: renderer, preferences: preferences)
            session.onRequestToolWindow = { [weak self] window in self?.toolWindow = window }
            sessions.append(session)
            activate(session.id)
            recentProjects = RecentProjects.adding(root, to: recentProjects)
            saveRecent()
            if toolWindow == nil { toolWindow = .project }
        }
        if let fileToOpen { active?.openFile(fileToOpen, pinned: true) }
        saveOpenProjects()
    }

    func activate(_ sessionID: String) {
        guard sessionID != activeSessionID, let next = sessions.first(where: { $0.id == sessionID }) else { return }
        active?.setActive(false)
        activeSessionID = sessionID
        next.setActive(true)
        activeSessionObservation = next.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        saveOpenProjects()
    }

    func closeProject(_ sessionID: String? = nil) {
        guard let id = sessionID ?? activeSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.tearDown()
        if activeSessionID == id {
            session.setActive(false)
            activeSessionID = nil
            activeSessionObservation = nil
            if let next = sessions.indices.contains(index) ? sessions[index] : sessions.last {
                activate(next.id)
            } else {
                renderer.render(.message("", ""))
            }
        }
        saveOpenProjects()
    }

    /// 所有项目里没保存的都写回磁盘（切到别的应用、退出时调，IDEA 也是这两个时机自动保存）。
    func saveAll() {
        for session in sessions { session.saveAll() }
    }

    func selectNextProject(offset: Int) {
        guard sessions.count > 1, let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        activate(sessions[(index + offset + sessions.count) % sessions.count].id)
    }

    func removeRecent(_ recent: RecentProject) {
        recentProjects = RecentProjects.removing(recent.path, from: recentProjects)
        saveRecent()
    }

    private func saveRecent() {
        do { try recentStore.save(recentProjects) } catch { Log.warn("recent", "保存失败：\(error)") }
    }

    // MARK: - 上次打开的项目

    private static let openProjectsKey = "openProjects"
    private static let activeProjectKey = "activeProject"

    private func saveOpenProjects() {
        defaults.set(sessions.map { $0.project.root.path }, forKey: Self.openProjectsKey)
        defaults.set(active?.project.root.path ?? "", forKey: Self.activeProjectKey)
    }

    /// 启动时把上次开着的项目都开回来（IDEA 也这么做）。
    func restoreOpenProjects() {
        let paths = defaults.stringArray(forKey: Self.openProjectsKey) ?? []
        let activePath = defaults.string(forKey: Self.activeProjectKey)
        for path in paths where fileManager.fileExists(atPath: path) {
            openProject(URL(fileURLWithPath: path, isDirectory: true))
        }
        if let activePath, let session = sessions.first(where: { $0.project.root.path == activePath }) {
            activate(session.id)
        }
    }
}
