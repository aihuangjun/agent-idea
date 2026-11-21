import Core
import Foundation

extension ProjectSession {
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
        projectSearch.show(recent: recent)
        Task { [weak self] in await self?.collectDraftForProjectSearch() }
    }

    func closeProjectSearch() {
        projectSearch.close()
        renderer.focusContent()
    }

    func openProjectSearchResult(_ result: ProjectSearch.Result) {
        closeProjectSearch()
        let url = project.root.appendingPathComponent(result.path)
        guard fileManager.fileExists(atPath: url.path) else {
            projectSearch.invalidate()
            notify("文件已移除")
            return
        }
        openFile(url, pinned: true, at: result.location, selecting: result.symbol?.name.utf16.count ?? 0)
        renderer.focusContent()
    }
}
