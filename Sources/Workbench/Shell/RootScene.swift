import AppKit
import Core
import DesignSystem
import SwiftUI

/// 应用的整个界面。这是 `Workbench` 对外唯一的 public 场景：可执行 target 只负责 `@main` 那一层壳。
public struct AgentIDEARootScene: Scene {
    @StateObject private var workbench = WorkbenchModel(editorHistories: EditorHistoryStore(directory: AppPaths.editorHistoryDirectory))
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
                // 访达「打开方式」、拖到 Dock 图标、`open -a AgentIDEA <目录>`：macOS 27 起不再转成
                // AppDelegate 的 application(_:open:)（见 AppDelegate.init），启动时带进来的与运行中交过来的都从这里到。
                // 老系统上两边都来也无妨：openProject 遇到已经开着的项目只是切过去
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    workbench.openProject(url)
                }
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
            // 菜单结构照 IDEA 归类：应用 / 文件 / 编辑 / 显示（系统的 View 菜单）/ 导航 / 运行 / Git / 窗口 / 帮助。
            // 系统菜单（File / Edit / View / Window / Help 及其中的系统项）的中文名靠应用包声明中文本地化
            //（build_app.sh 写的 CFBundleDevelopmentRegion / CFBundleLocalizations + zh-Hans.lproj），不在这里写死。
            CommandGroup(replacing: .appInfo) {
                Button("关于 Agent IDEA") { AboutPanel.show(build: updater.build) }
            }
            CommandGroup(after: .appInfo) {
                Button("当前版本 \(updater.build.display)") {}.disabled(true)
                Button("检查更新…") { updater.check() }
                Button("显示日志…") { Self.revealLogs() }
            }
            fileCommands
            editCommands
            viewCommands
            navigateCommands
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
                // 最常用的放第一项。IDEA 的 Update Project 也是 ⌘T；行为是 fetch + rebase（项目工具窗口、提交历史上那个按钮）。
                // 没有上游时也能点：弹出选择（跟踪 origin/master，或推送并建立上游）
                Button("拉取最新") { workbench.active?.requestSync() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!(workbench.active?.canRequestSync ?? false))
                Button("提交…") { workbench.toolWindow = .commit }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!(workbench.active?.hasGit ?? false))
                Button("推送") { workbench.active?.commit?.pushCurrentBranch() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!(workbench.active?.commit?.canPush ?? false))
                Divider()
                Button("分支…") { workbench.active?.showBranches() }
                    .disabled(!(workbench.active?.hasGit ?? false))
                Button("刷新 git 状态") { workbench.active?.refreshAll() }
                    .disabled(!(workbench.active?.hasGit ?? false))
            }
        }
    }

    /// 文件：打开 / 最近项目、保存、从磁盘重新加载、关闭。
    @CommandsBuilder private var fileCommands: some Commands {
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
            // IDEA 的 Reload All from Disk：重读开着的文件（磁盘上被 Agent 改过的）并刷新目录树与 git 状态
            Button("从磁盘重新加载") { workbench.active?.refreshAll() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(workbench.active == nil)
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
        // 系统的「关闭」⌘W /「全部关闭」⌥⌘W 与上面的关闭标签 / 关闭项目抢同一个键，单窗口应用也用不着它们
        CommandGroup(replacing: .saveItem) {}
    }

    /// 编辑：撤销 / 重做、系统的剪切拷贝粘贴、复制路径和行号、查找 ▸（IDEA 的 Edit → Find）。
    @CommandsBuilder private var editCommands: some Commands {
        // 撤销 / 重做按焦点分发（UndoDispatcher）。焦点在编辑器里时 ⌘Z 由 CodeMirror 处理、不会到这里；
        // 标题显示的是文件操作栈顶那一步（「撤销重命名 a.txt」）
        CommandGroup(replacing: .undoRedo) {
            Button(workbench.active?.undoTitle ?? "撤销") { UndoDispatcher.undo(workbench) }
                .keyboardShortcut("z", modifiers: .command)
            Button(workbench.active?.redoTitle ?? "重做") { UndoDispatcher.redo(workbench) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        // IDEA 的 Copy Reference（⌥⇧⌘C）：相对项目根的路径加行号（`src/a.py:150`、`:12-20`），粘给 Agent 用
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("复制路径和行号") {
                guard let session = workbench.active, let id = session.activeTabID else { return }
                session.reference(of: id) { text in
                    Desktop.copyToClipboard(text)
                    session.notify("已复制 \(text)")
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            .disabled(workbench.active?.activeTab == nil)
        }
        // 换掉系统的文字编辑组（它若带「查找」子菜单就会出现两个「查找」），放我们自己的查找子菜单
        CommandGroup(replacing: .textEditing) {
            Divider()
            Menu("查找") {
                // Ctrl+F 是同一个功能的第二个键位，不另占菜单项：焦点在哪儿都由 CursorRestoringWebView.performKeyEquivalent
                // 截下来（窗口的键位分发会走遍整个视图层级，正文 WebView 总挂在窗口里）
                Button("文件内查找…") { workbench.active?.showFind() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(workbench.active?.activeTab == nil)
                Button("查找下一个") { workbench.active?.findInFile() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(!(workbench.active?.isFindShown ?? false))
                Button("查找上一个") { workbench.active?.findInFile(backwards: true) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!(workbench.active?.isFindShown ?? false))
                Divider()
                // IDEA Windows 键位的 Find in Path（用户定的）。焦点在正文里时 CodeMirror 会吞掉这个键，
                // 由 CursorRestoringWebView 先截下来（ContentRenderer.onFindInPath）
                Button("在项目中查找…") { workbench.active?.showFindInPath() }
                    .keyboardShortcut("f", modifiers: [.control, .shift])
                    .disabled(workbench.active == nil)
            }
        }
    }

    /// 显示（系统的 View 菜单，中文系统里叫「显示」）：工具窗口 ▸、外观 ▸、缩放、diff / Markdown 视图。
    /// 放进系统的 View 菜单而不是另开一个叫「视图」的 CommandMenu：SwiftUI 总会建出系统那个（里面有「进入全屏幕」），
    /// 另开一个就是菜单栏上两个视图菜单（1.7.0 验收时用户报的）。
    @CommandsBuilder private var viewCommands: some Commands {
        CommandGroup(before: .toolbar) {
            // IDEA 的 View → Tool Windows
            Menu("工具窗口") {
                Button("项目") { workbench.toggleToolWindow(.project) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("提交") { workbench.toggleToolWindow(.commit) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("提交历史") { workbench.toggleToolWindow(.history) }
                    .keyboardShortcut("9", modifiers: .command)
                Button("查找") { workbench.toggleToolWindow(.find) }
                    .keyboardShortcut("3", modifiers: .command)
                Button(workbench.isRunWindowShown ? "收起运行窗口" : "运行窗口") { workbench.isRunWindowShown.toggle() }
                    .keyboardShortcut("4", modifiers: .command)
                    .disabled(workbench.active == nil)
                Divider()
                // IDEA 的 Hide Active Tool Window。Esc 本身不能挂成菜单键（查找框、对话框要用它关），⇧Esc 不冲突：
                // 编辑器里 CodeMirror 没绑 Shift-Esc，不 preventDefault，WebKit 照样交给菜单
                Button("隐藏工具窗口") { workbench.hideToolWindow() }
                    .keyboardShortcut(.escape, modifiers: .shift)
                    .disabled(!workbench.canHideToolWindow)
            }
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
            Button(workbench.preferences.diffMode == .sideBySide ? "diff：切到单列视图" : "diff：切到并排视图") {
                workbench.preferences.diffMode = workbench.preferences.diffMode == .sideBySide ? .unified : .sideBySide
            }
            Button("Markdown：预览 / 源码 / 分栏") { workbench.active?.cycleMarkdownView() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
        }
    }

    /// 导航（IDEA 的 Navigate）：找文件、跳到行、定位、后退前进、变更之间、标签与项目之间。
    @CommandsBuilder private var navigateCommands: some Commands {
        CommandMenu("导航") {
            Button("查找文件…") {
                workbench.toolWindow = .project
                workbench.active?.search.activate()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(workbench.active == nil)
            // IDEA 的 Recent Files：打开过的文件（关掉的也在），第一项是上一个文件，回车就切回去
            Button("最近的文件…") { workbench.active?.showRecentFiles() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(workbench.active == nil)
            // IDEA 的 Go to Line（⌘L）
            Button("跳到行…") { workbench.active?.showGoToLine() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!(workbench.active?.canGoToLine ?? false))
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
                .disabled(!(workbench.active?.canNavigateChange(.next) ?? false))
            Button("上一处变更") { workbench.active?.navigateChange(.previous) }
                .keyboardShortcut(.f7, modifiers: .shift)
                .disabled(!(workbench.active?.canNavigateChange(.previous) ?? false))
            Divider()
            Button("下一个标签") { workbench.active?.selectNextTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("上一个标签") { workbench.active?.selectNextTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("下一个项目") { workbench.selectNextProject(offset: 1) }
                .keyboardShortcut("`", modifiers: .command)
                .disabled(workbench.sessions.count < 2)
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
    /// `@NSApplicationDelegateAdaptor` 要等应用启动完（`isRunning` 已经是 true、窗口已经建好）才建出这个对象，
    /// 回调一个都不转给它（willFinish / didFinish / shouldTerminate / open 实测全都不来）。1.2.3 之前日志因此一行不写、登录 shell 的环境没载入——
    /// 运行窗口里拿不到 `.zshrc` 里的环境变量，git 也找不到 ssh-agent。
    /// SwiftUI 不承诺 Scene 值只构造一次，所以副作用不放 Scene 的 init，这里再用 `didPrepare` 兜一层。
    override init() {
        super.init()
        MainActor.assumeIsolated { Self.prepareOnce() }
        // 自动保存的时机（切到别的应用、退出）改听通知：通知系统总会发，不靠 delegate 转发
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(saveAllDrafts), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(saveAllDrafts), name: NSApplication.willTerminateNotification, object: nil)
        center.addObserver(self, selector: #selector(refreshOnActivation), name: NSApplication.didBecomeActiveNotification, object: nil)
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

    @objc private func refreshOnActivation() {
        // 切回应用只核对磁盘变化；强制重读会重置没变化的 HTML 页面及编辑器撤销历史。
        MainActor.assumeIsolated { workbench?.active?.refreshGit() }
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
