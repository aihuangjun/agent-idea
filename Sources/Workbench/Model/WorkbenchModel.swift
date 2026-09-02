import AppKit
import Core
import DesignSystem
import Foundation

/// 整个窗口的状态：打开着的几个项目（`ProjectSession`）、当前是哪个、最近项目、阅读偏好。
///
/// 正文 WebView 只有一个，所有项目共用；切项目时把当前项目的活动标签重新送进去。
@MainActor
public final class WorkbenchModel: ObservableObject {
    @Published public private(set) var sessions: [ProjectSession] = []
    @Published public private(set) var activeSessionID: String?
    @Published public private(set) var recentProjects: [RecentProject] = []

    // MARK: - 阅读偏好（全局）

    @Published public var diffMode: DiffMode {
        didSet {
            defaults.set(diffMode.rawValue, forKey: "diff.mode")
            active?.renderActiveTab()
        }
    }
    @Published public var ignoreWhitespace = false {
        didSet { active?.reloadActiveDiff() }
    }
    @Published public var wordWrap: Bool {
        didSet {
            defaults.set(wordWrap, forKey: "editor.wrap")
            renderer.setWrap(wordWrap)
        }
    }
    @Published public private(set) var zoom: Double {
        didSet {
            defaults.set(zoom, forKey: "editor.zoom")
            renderer.setZoom(zoom)
        }
    }
    @Published public var toolWindow: ToolWindow? = .project {
        didSet { defaults.set(toolWindow?.rawValue ?? "", forKey: "toolWindow") }
    }
    @Published public var toolWindowWidth: CGFloat {
        didSet { defaults.set(Double(toolWindowWidth), forKey: "toolWindow.width") }
    }

    public let renderer: ContentRenderer
    let git: GitClient?
    let fileManager: FileManager
    let defaults: UserDefaults
    private let recentStore: JSONFileStore<[RecentProject]>

    public var active: ProjectSession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    public init(
        git: GitClient? = GitClient.locate(),
        renderer: ContentRenderer? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        recentFile: URL = AppPaths.recentProjectsFile
    ) {
        self.git = git
        self.fileManager = fileManager
        self.defaults = defaults
        self.recentStore = JSONFileStore(url: recentFile)
        self.renderer = renderer ?? ContentRenderer()

        diffMode = DiffMode(rawValue: defaults.string(forKey: "diff.mode") ?? "") ?? .sideBySide
        wordWrap = defaults.bool(forKey: "editor.wrap")
        let savedZoom = defaults.double(forKey: "editor.zoom")
        zoom = savedZoom > 0 ? savedZoom : 1
        let savedWidth = defaults.double(forKey: "toolWindow.width")
        toolWindowWidth = savedWidth > 0 ? CGFloat(savedWidth) : 280
        if let saved = defaults.string(forKey: "toolWindow") {
            toolWindow = saved.isEmpty ? nil : ToolWindow(rawValue: saved)
        }
        recentProjects = RecentProjects.pruningMissing(recentStore.load() ?? [], fileManager: fileManager)

        self.renderer.setZoom(zoom)
        self.renderer.setWrap(wordWrap)
        self.renderer.onOpenExternal = { url in NSWorkspace.shared.open(url) }
        self.renderer.onOpenPath = { [weak self] path in
            self?.active?.openFile(URL(fileURLWithPath: path), pinned: false)
        }
    }

    // MARK: - 项目

    /// 打开一个目录。已经开着的直接切过去。传进来的是文件的话，打开所在目录并顺手打开那个文件。
    public func openProject(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            active?.banner = "目录不存在：\(url.path)"
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
            let session = ProjectSession(root: chosen, workbench: self)
            sessions.append(session)
            activate(session.id)
            recentProjects = RecentProjects.adding(root, to: recentProjects)
            saveRecent()
            if toolWindow == nil { toolWindow = .project }
        }
        if let fileToOpen { active?.openFile(fileToOpen, pinned: true) }
        saveOpenProjects()
    }

    public func activate(_ sessionID: String) {
        guard sessionID != activeSessionID, sessions.contains(where: { $0.id == sessionID }) else { return }
        active?.rememberScrollOfActiveTab()
        activeSessionID = sessionID
        active?.renderActiveTab()
        saveOpenProjects()
    }

    public func closeProject(_ sessionID: String? = nil) {
        guard let id = sessionID ?? activeSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.tearDown()
        if activeSessionID == id {
            let next = sessions.indices.contains(index) ? sessions[index] : sessions.last
            activeSessionID = next?.id
            active?.renderActiveTab()
        }
        saveOpenProjects()
    }

    public func selectNextProject(offset: Int) {
        guard sessions.count > 1, let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        activate(sessions[(index + offset + sessions.count) % sessions.count].id)
    }

    public func removeRecent(_ recent: RecentProject) {
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
    public func restoreOpenProjects() {
        let paths = defaults.stringArray(forKey: Self.openProjectsKey) ?? []
        let activePath = defaults.string(forKey: Self.activeProjectKey)
        for path in paths where fileManager.fileExists(atPath: path) {
            openProject(URL(fileURLWithPath: path, isDirectory: true))
        }
        if let activePath, let session = sessions.first(where: { $0.project.root.path == activePath }) {
            activate(session.id)
        }
    }

    // MARK: - 缩放

    public func zoomIn() { zoom = min(3, (zoom * 10).rounded() / 10 + 0.1) }
    public func zoomOut() { zoom = max(0.5, (zoom * 10).rounded() / 10 - 0.1) }
    public func resetZoom() { zoom = 1 }
}
