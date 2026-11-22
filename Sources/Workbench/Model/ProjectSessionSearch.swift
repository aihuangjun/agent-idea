import Core
import Foundation

extension ProjectSession {
    /// 搜索使用项目根的相对路径，Git 状态的忽略项使用仓库根的相对路径。
    var sourceSearchExclusion: @Sendable (String, Bool) -> Bool {
        guard let prefix = project.repositoryRelativePath(of: project.root) else {
            return { path, isDirectory in isDirectory && TextSearchScanner.skipsDirectory(path) }
        }
        let index = gitIndex
        return { path, isDirectory in
            index.isIgnored(prefix.isEmpty ? path : prefix + "/" + path, isDirectory: isDirectory)
        }
    }

    var draftsByPath: [String: String] {
        Dictionary(uniqueKeysWithValues: drafts.compactMap { id, text in
            EditorTab.fileURL(fromID: id).map { ($0.path, text) }
        })
    }

    /// 索引要看得到尚未经过 edited 去抖的最后几笔。
    func collectDraftForProjectSearch() async {
        guard isActive, let tab = activeTab, isEditable(tab), let url = documentURL(for: tab) else { return }
        await withCheckedContinuation { continuation in
            renderer.currentState { [weak self] state in
                if let self, self.isActive, self.activeTabID == tab.id, let text = state.text {
                    self.applyEdit(path: url.path, text: text)
                }
                continuation.resume()
            }
        }
    }

    func showProjectSearch() {
        recentFiles.close()
        let recent = recentFiles.store.candidates(excluding: nil).map(\.path)
            .filter { fileManager.fileExists(atPath: project.root.appendingPathComponent($0).path) }
        projectSearch.show(.popup, recent: recent)
        Task { [weak self] in await self?.collectDraftForProjectSearch() }
    }

    func showSidebarSearch() {
        recentFiles.close()
        projectSearch.show(.sidebar)
        Task { [weak self] in await self?.collectDraftForProjectSearch() }
    }

    func closeProjectSearch() {
        projectSearch.close()
        renderer.focusContent()
    }

    func openProjectSearchResult(_ result: ProjectSearch.Result) {
        let fromSidebar = projectSearch.presentation == .sidebar
        projectSearch.close()
        let url = project.root.appendingPathComponent(result.path)
        guard fileManager.fileExists(atPath: url.path) else {
            projectSearch.invalidate()
            notify("文件已移除")
            renderer.focusContent()
            return
        }
        openFile(url, pinned: true, at: result.location, selecting: result.symbol?.name.utf16.count ?? 0)
        if fromSidebar { reveal(url) }
        renderer.focusContent()
    }
}
