import Core
import Foundation

/// 在全局搜索里使用与菜单相同的会话操作，并在执行时重新检查当前上下文。
enum WorkbenchAction: String, CaseIterable {
    case history, blame, compareFiles, compareClipboard, copyRelative, copyReference, fileStructure, definition, quickDefinition
    case findProject, findFile, replaceFile, recentFiles, recentLocations, lastEdit, goToLine, refresh, save, branches, nextChange
    case newAIChat

    private var metadata: (title: String, location: String, shortcut: String?, aliases: String) {
        switch self {
        case .history: return ("显示历史", "Git · 文件或目录", nil, "history log 提交记录")
        case .blame: return ("显示 Git 行归属", "Git", nil, "git blame annotate 作者 隐藏")
        case .compareFiles: return ("比较文件…", "文件", nil, "compare diff 与其他文件比较")
        case .compareClipboard: return ("与剪贴板比较", "编辑器右键", nil, "clipboard diff compare")
        case .copyRelative: return ("复制相对路径", "项目文件", nil, "copy relative path")
        case .copyReference: return ("复制路径和行号", "编辑", "⌥⇧⌘C", "copy reference path")
        case .fileStructure: return ("文件结构…", "导航", "⌘F12", "structure outline 大纲")
        case .definition: return ("跳转到定义", "导航", "F3", "go to definition declaration 声明")
        case .quickDefinition: return ("快速查看定义…", "导航", "⌥F3", "quick definition 预览")
        case .findProject: return ("在项目中查找…", "编辑 → 查找", "⌃⇧F", "find in files 全文")
        case .findFile: return ("文件内查找…", "编辑 → 查找", "⌘F", "find in file")
        case .replaceFile: return ("在当前文件中替换…", "编辑 → 查找", "⌥⌘R", "replace")
        case .recentFiles: return ("最近的文件…", "导航", "⌘E", "recent files")
        case .recentLocations: return ("最近的位置…", "导航", "⇧⌘E", "recent locations")
        case .lastEdit: return ("上次编辑位置", "导航", nil, "last edit")
        case .goToLine: return ("跳到行…", "导航", "⌘L", "go to line 行号")
        case .refresh: return ("从磁盘重新加载", "文件", "⌘R", "reload refresh 刷新")
        case .save: return ("保存", "文件", "⌘S", "save")
        case .branches: return ("分支…", "Git", nil, "git branches 切换分支")
        case .nextChange: return ("下一处变更", "导航", "F7", "next change diff")
        case .newAIChat: return ("新建 AI 对话", "文件", "⌥⌘I", "chat gpt assistant 聊天 工作区")
        }
    }

    @MainActor func searchEntry(in workbench: WorkbenchModel) -> ActionSearch.Entry {
        let data = metadata
        let session = workbench.active
        return .init(id: rawValue, title: self == .blame ? session?.blameActionTitle ?? data.title : data.title,
                     location: data.location, shortcut: data.shortcut, keywords: data.aliases,
                     enabled: session.map { enabled(in: $0, toolWindow: workbench.toolWindow) } ?? false)
    }

    @MainActor private func pathTargets(in session: ProjectSession, toolWindow: ToolWindow?) -> [URL] {
        if toolWindow == .project, !session.selectedNodes.isEmpty { return session.selectedNodes.map(\.url) }
        return session.activeTab.flatMap { session.referenceURL(for: $0) }.map { [$0] } ?? []
    }

    @MainActor private func enabled(in session: ProjectSession, toolWindow: ToolWindow?) -> Bool {
        switch self {
        case .history: return pathTargets(in: session, toolWindow: toolWindow).first.map(session.canShowHistory(of:)) == true
        case .blame: return session.blameFile != nil
        case .compareFiles: return (toolWindow == .project && session.selectedComparisonFiles.count == 2) || session.activeTab?.fileURL != nil
        case .compareClipboard: return session.activeTab?.fileURL != nil && session.activeContent?.text != nil
        case .copyRelative: return !pathTargets(in: session, toolWindow: toolWindow).isEmpty
        case .copyReference: return session.activeTab.flatMap { session.referenceURL(for: $0) } != nil
        case .fileStructure, .definition, .quickDefinition: return session.definitionSource != nil
        case .findProject, .recentFiles, .recentLocations, .refresh, .newAIChat: return true
        case .findFile: return session.activeTab != nil
        case .replaceFile: return session.canReplaceInFile
        case .lastEdit: return session.lastEditLocation != nil
        case .goToLine: return session.canGoToLine
        case .save: return session.activeTab.map(session.isModified) == true
        case .branches: return session.hasGit
        case .nextChange: return session.canNavigateChange(.next)
        }
    }

    @MainActor func perform(in workbench: WorkbenchModel) {
        guard let session = workbench.active, enabled(in: session, toolWindow: workbench.toolWindow) else { return }
        switch self {
        case .history:
            if let url = pathTargets(in: session, toolWindow: workbench.toolWindow).first {
                let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                session.showHistory(of: url, isDirectory: directory)
            }
        case .blame: session.toggleBlame()
        case .compareFiles:
            let files = workbench.toolWindow == .project ? session.selectedComparisonFiles : []
            if files.count == 2 { session.compareFiles(files[0], files[1]) }
            else if let file = session.activeTab?.fileURL { Desktop.chooseFileToCompare(with: file, in: session) }
        case .compareClipboard:
            if let file = session.activeTab?.fileURL { Desktop.compareWithClipboard(file, in: session) }
        case .copyRelative:
            let paths = pathTargets(in: session, toolWindow: workbench.toolWindow).map(session.referencePath(of:))
            Desktop.copyToClipboard(paths.joined(separator: "\n"))
            session.notify(paths.count == 1 ? "已复制 \(paths[0])" : "已复制 \(paths.count) 个相对路径")
        case .copyReference:
            if let id = session.activeTabID {
                session.reference(of: id) { text in
                    Desktop.copyToClipboard(text)
                    session.notify("已复制 \(text)")
                }
            }
        case .fileStructure: session.showFileStructure()
        case .definition: session.goToDefinition()
        case .quickDefinition: session.goToDefinition(preview: true)
        case .findProject: session.showFindInPath()
        case .findFile: session.showFind()
        case .replaceFile: session.showFileReplace()
        case .recentFiles: session.showRecentFiles()
        case .recentLocations: session.showRecentLocations()
        case .lastEdit: session.goToLastEdit()
        case .goToLine: session.showGoToLine()
        case .refresh: session.refreshAll()
        case .save: session.saveActiveTab()
        case .branches: session.showBranches()
        case .nextChange: session.navigateChange(.next)
        case .newAIChat: workbench.newAIChat()
        }
    }
}
