import AppKit
import Core
import DesignSystem
import SwiftUI

/// 应用的整个界面。这是 `Workbench` 对外唯一的 public 场景：可执行 target 只负责 `@main` 那一层壳。
public struct AgentIDEARootScene: Scene {
    @StateObject private var workbench = WorkbenchModel()
    @StateObject private var updater = Updater()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {
        let build = BuildIdentity.current
        Log.start(banner: "Agent IDEA \(build.display) 启动，配置目录 \(AppPaths.configurationDirectory.path)")
        // 整个应用固定深色：标题栏、菜单、弹窗跟着走，不然窗口内容是深的、系统控件是浅的。
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 800])
        // 抓一份登录 shell 的环境给 git 用（push 要靠 SSH_AUTH_SOCK 和 PATH 里的凭据助手）
        Task.detached(priority: .utility) { await LoginShellEnvironment.load() }
    }

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
                .onAppear {
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
            CommandMenu("视图") {
                Button("项目") { workbench.toolWindow = workbench.toolWindow == .project ? nil : .project }
                    .keyboardShortcut("1", modifiers: .command)
                Button("提交") { workbench.toolWindow = workbench.toolWindow == .commit ? nil : .commit }
                    .keyboardShortcut("0", modifiers: .command)
                Button("在项目视图中定位当前文件") { workbench.active?.revealActiveTab() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(workbench.active?.activeTab == nil)
                Divider()
                Button("刷新") { workbench.active?.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(workbench.active == nil)
                Divider()
                Button("放大") { workbench.zoomIn() }.keyboardShortcut("=", modifiers: .command)
                Button("缩小") { workbench.zoomOut() }.keyboardShortcut("-", modifiers: .command)
                Button("实际大小") { workbench.resetZoom() }.keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button("下一个标签") { workbench.active?.selectNextTab(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("上一个标签") { workbench.active?.selectNextTab(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("下一个项目") { workbench.selectNextProject(offset: 1) }
                    .keyboardShortcut("`", modifiers: .command)
                    .disabled(workbench.sessions.count < 2)
                Divider()
                Button(workbench.diffMode == .sideBySide ? "diff：切到单列视图" : "diff：切到并排视图") {
                    workbench.diffMode = workbench.diffMode == .sideBySide ? .unified : .sideBySide
                }
                Button("Markdown：预览 / 源码") { workbench.active?.toggleMarkdownSource() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            CommandMenu("Git") {
                Button("提交…") { workbench.toolWindow = .commit }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!(workbench.active?.hasGit ?? false))
                Button("推送") { workbench.active?.pushCurrentBranch() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!(workbench.active?.canPush ?? false))
                Divider()
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

/// 接系统递过来的「打开」：访达「打开方式」、拖到 Dock 图标、`open -a AgentIDEA <目录>`。
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var workbench: WorkbenchModel?
    /// 窗口还没建好之前到达的打开请求。
    @MainActor private var pending: [URL] = []

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
