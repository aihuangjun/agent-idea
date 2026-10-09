import AppKit
import Core
import DesignSystem
import SwiftUI

/// 应用的整个界面。这是 `Workbench` 对外唯一的 public 场景：可执行 target 只负责 `@main` 那一层壳。
public struct AgentIDEARootScene: Scene {
    @StateObject private var workbench = WorkbenchModel()
    @StateObject private var updater = Updater()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {}

    private static var defaultWindowSize: CGSize {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: max(1100, available.width * 0.75), height: max(720, available.height * 0.8))
    }

    public var body: some Scene {
        // 单窗口：渲染器的 WKWebView 是一个 NSView 实例，多窗口会互相抢。
        Window("Agent IDEA", id: "main") {
            WorkbenchView()
                .frame(minWidth: 900, minHeight: 560)
                .background(Theme.editorBackground)
                .tint(Theme.accent)
                .modifier(UpdateDialog())
                // 必须排在 UpdateDialog 之后（包在它外面）：修饰符由内往外套，写在前面的 environmentObject 喂不到外层。
                .environmentObject(updater)
                .environmentObject(workbench)
                .environmentObject(workbench.preferences)
                .onAppear {
                    workbench.preferences.applyAppearance()
                    updater.checkInBackgroundIfDue()
                    workbench.restoreOpenProjects()
                    delegate.workbench = workbench
                    delegate.flushPendingOpens()
                }
        }
        // 用系统标准标题栏：第一行是红黄绿按钮与项目名，第二行才是我们的项目标签，从最左边开始。
        .windowStyle(.titleBar)
        .defaultSize(Self.defaultWindowSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Agent IDEA") { AboutPanel.show(build: updater.build) }
            }
            CommandGroup(after: .appInfo) {
                Button("当前版本 \(updater.build.display)") {}.disabled(true)
                Button("检查更新…") { updater.check() }
                Button("显示日志…") { Self.revealLogs() }
            }
            CommandGroup(replacing: .newItem) {
                Button("打开项目…") { NotificationCenter.default.post(name: .agentIDEAOpenProject, object: nil) }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("最近项目") {
                    ForEach(workbench.recentProjects) { recent in
                        Button(recent.displayPath) { workbench.openProject(recent.url) }
                    }
                }
                Divider()
                Button("保存") { workbench.active?.saveActiveTab() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!(workbench.active.flatMap { session in session.activeTab.map(session.isModified) } ?? false))
                Button("全部保存") { workbench.saveAll() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(workbench.sessions.allSatisfy { $0.drafts.isEmpty })
                Divider()
                Button("关闭标签") { workbench.active?.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(workbench.active?.activeTab == nil)
                Button("关闭全部标签") { workbench.active?.closeAllTabs() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(workbench.active?.tabs.isEmpty ?? true)
                Button("关闭项目") { workbench.closeProject() }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                    .disabled(workbench.active == nil)
            }
            // 撤销 / 重做按焦点分发（UndoDispatcher）。焦点在编辑器里时 ⌘Z 由 CodeMirror 处理、不会到这里；
            // 标题显示的是文件操作栈顶那一步（「撤销重命名 a.txt」）
            CommandGroup(replacing: .undoRedo) {
                Button(workbench.active?.undoTitle ?? "撤销") { UndoDispatcher.undo(workbench) }
                    .keyboardShortcut("z", modifiers: .command)
                Button(workbench.active?.redoTitle ?? "重做") { UndoDispatcher.redo(workbench) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("视图") {
                Button("项目") { workbench.toolWindow = workbench.toolWindow == .project ? nil : .project }
                    .keyboardShortcut("1", modifiers: .command)
                Button("提交") { workbench.toolWindow = workbench.toolWindow == .commit ? nil : .commit }
                    .keyboardShortcut("0", modifiers: .command)
                Button("提交历史") { workbench.toolWindow = workbench.toolWindow == .history ? nil : .history }
                    .keyboardShortcut("9", modifiers: .command)
                Button(workbench.isRunWindowShown ? "收起运行窗口" : "运行窗口") { workbench.isRunWindowShown.toggle() }
                    .keyboardShortcut("4", modifiers: .command)
                    .disabled(workbench.active == nil)
                Divider()
                Button("查找文件…") {
                    workbench.toolWindow = .project
                    workbench.active?.search.activate()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workbench.active == nil)
                Button("在项目视图中定位当前文件") { workbench.active?.revealActiveTab() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(workbench.active?.activeTab == nil)
                Divider()
                Button("后退") { workbench.active?.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                    .disabled(!(workbench.active?.canGoBack ?? false))
                Button("前进") { workbench.active?.goForward() }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                    .disabled(!(workbench.active?.canGoForward ?? false))
                Divider()
                // IDEA 的 F7 / ⇧F7。焦点在 WebView 里时页面自己处理（render.js），这里管焦点在别处的情况
                Button("下一处变更") { workbench.active?.navigateChange(.next) }
                    .keyboardShortcut(.f7, modifiers: [])
                    .disabled(!(workbench.active.map { $0.canNavigateChanges && $0.changePosition.hasNext } ?? false))
                Button("上一处变更") { workbench.active?.navigateChange(.previous) }
                    .keyboardShortcut(.f7, modifiers: .shift)
                    .disabled(!(workbench.active.map { $0.canNavigateChanges && $0.changePosition.hasPrevious } ?? false))
                Divider()
                Button("刷新") { workbench.active?.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(workbench.active == nil)
                Divider()
                Picker("外观", selection: Binding(
                    get: { workbench.preferences.theme },
                    set: { workbench.preferences.theme = $0 }
                )) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Divider()
                Button("放大") { workbench.preferences.zoomIn() }.keyboardShortcut("=", modifiers: .command)
                Button("缩小") { workbench.preferences.zoomOut() }.keyboardShortcut("-", modifiers: .command)
                Button("实际大小") { workbench.preferences.resetZoom() }.keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button("下一个标签") { workbench.active?.selectNextTab(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("上一个标签") { workbench.active?.selectNextTab(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("下一个项目") { workbench.selectNextProject(offset: 1) }
                    .keyboardShortcut("`", modifiers: .command)
                    .disabled(workbench.sessions.count < 2)
                Divider()
                Button(workbench.preferences.diffMode == .sideBySide ? "diff：切到单列视图" : "diff：切到并排视图") {
                    workbench.preferences.diffMode = workbench.preferences.diffMode == .sideBySide ? .unified : .sideBySide
                }
                Button("Markdown：预览 / 源码 / 分栏") { workbench.active?.cycleMarkdownView() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            // 键位照 IDEA 的 macOS 方案：⌃⇧R 运行当前文件、⌃R 重新运行、⌘F2 停止
            CommandMenu("运行") {
                Button(workbench.active?.runnableActiveFile.map { "运行 '\($0.lastPathComponent)'" } ?? "运行当前文件") {
                    if let session = workbench.active, let url = session.runnableActiveFile { session.runScript(url) }
                }
                .keyboardShortcut("r", modifiers: [.control, .shift])
                .disabled(workbench.active?.runnableActiveFile == nil)
                Button(workbench.active?.run.script.map { "重新运行 '\($0.lastPathComponent)'" } ?? "重新运行") {
                    if let session = workbench.active, let url = session.run.script { session.runScript(url) }
                }
                .keyboardShortcut("r", modifiers: .control)
                .disabled(!(workbench.active?.run.canRerun ?? false))
                Button("停止") { workbench.active?.run.stop() }
                    .keyboardShortcut(.f2, modifiers: .command)
                    .disabled(!(workbench.active?.run.isRunning ?? false))
            }
            CommandMenu("Git") {
                Button("提交…") { workbench.toolWindow = .commit }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!(workbench.active?.hasGit ?? false))
                Button("推送") { workbench.active?.commit?.pushCurrentBranch() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!(workbench.active?.commit?.canPush ?? false))
                Divider()
                // IDEA 的 Update Project 也是 ⌘T
                // 没有上游时也能点：弹出选择（跟踪 origin/master，或推送并建立上游）
                Button("与远程同步（fetch + rebase）") { workbench.active?.requestSync() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!(workbench.active?.canRequestSync ?? false))
                Button("分支…") { workbench.active?.showBranches() }
                    .disabled(!(workbench.active?.hasGit ?? false))
                Button("刷新 git 状态") { workbench.active?.refreshGit() }
                    .disabled(!(workbench.active?.hasGit ?? false))
            }
        }
    }

    private static func revealLogs() {
        let directory = AppPaths.logDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let file = Log.fileURL, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }
}

extension Notification.Name {
    /// 菜单里的「打开项目…」：菜单命令拿不到 `WorkbenchView` 里的选目录函数，用通知递过去。
    static let agentIDEAOpenProject = Notification.Name("agentidea.openProject")
}

/// 应用生命周期：启动时的一次性准备，以及接系统递过来的「打开」
/// （访达「打开方式」、拖到 Dock 图标、`open -a AgentIDEA <目录>`）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var workbench: WorkbenchModel?
    /// 窗口还没建好之前到达的打开请求。
    @MainActor private var pending: [URL] = []

    /// 启动时的一次性准备放在 init 里，**不放 `applicationWillFinishLaunching`**：macOS 27 起
    /// `@NSApplicationDelegateAdaptor` 照样建出这个对象，却一个回调都不转给它（willFinish / didFinish /
    /// shouldTerminate 实测全都不来）。1.2.3 之前日志因此一行不写、登录 shell 的环境没载入——
    /// 运行窗口里拿不到 `.zshrc` 里的环境变量，git 也找不到 ssh-agent。
    /// SwiftUI 不承诺 Scene 值只构造一次，所以副作用不放 Scene 的 init，这里再用 `didPrepare` 兜一层。
    override init() {
        super.init()
        MainActor.assumeIsolated { Self.prepareOnce() }
        // 自动保存的时机（切到别的应用、退出）改听通知：通知系统总会发，不靠 delegate 转发
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(saveAllDrafts), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(saveAllDrafts), name: NSApplication.willTerminateNotification, object: nil)
    }

    @MainActor private static var didPrepare = false

    @MainActor private static func prepareOnce() {
        guard !didPrepare else { return }
        didPrepare = true
        let build = BuildIdentity.current
        Log.start(banner: "Agent IDEA \(build.display) 启动，配置目录 \(AppPaths.configurationDirectory.path)")
        // 外观由用户选（视图 → 外观），窗口起来之前先按存下来的值定好，
        // 免得深色偏好的用户先看见一帧浅色。跟随系统时不设，交给系统。
        NSApplication.shared.appearance = (AppTheme(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark).appearance
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 800])
        // 抓一份登录 shell 的环境：git push 要 SSH_AUTH_SOCK 和 PATH 里的凭据助手，「运行」的脚本要 .zshrc 里的变量
        Task.detached(priority: .utility) { await LoginShellEnvironment.load() }
    }

    /// 切到别的应用、退出：把没保存的都写回去（IDEA 的自动保存时机）。
    @objc private func saveAllDrafts() {
        MainActor.assumeIsolated { workbench?.saveAll() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let workbench else {
                pending.append(contentsOf: urls)
                return
            }
            for url in urls { workbench.openProject(url) }
        }
    }

    @MainActor
    func flushPendingOpens() {
        guard let workbench, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        for url in urls { workbench.openProject(url) }
    }

    /// 自己回答「能不能退出」：交给 SwiftUI 的默认实现时，更新后「立即重启」调 `NSApp.terminate` 会石沉大海——
    /// 既不退出也不返回（它答 terminateLater 之后没了下文；sheet 挂着时则直接取消）。这个应用没有文档要问，
    /// 没保存的草稿在 willTerminate 通知里写盘，可以直接答应（0.6.2 修的）。macOS 27 上这个回调同样不来（见 init），
    /// 退出走 SwiftUI 的默认处理，实测「退出」请求照样能退。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
