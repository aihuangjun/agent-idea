import Core
import Foundation

extension ProjectSession {
    var selectedComparisonFiles: [URL] {
        let nodes = selectedNodes
        guard nodes.count == 2, nodes.allSatisfy({ !$0.isDirectory }) else { return [] }
        return nodes.map(\.url)
    }

    func compareFiles(_ first: URL, _ second: URL) {
        let first = first.resolvingSymlinksInPath().standardizedFileURL
        let second = second.resolvingSymlinksInPath().standardizedFileURL
        guard first != second else { notify("请选择两个不同的文件"); return }
        compare(first, against: second, clipboard: nil)
    }

    func compareWithClipboard(_ file: URL, text: String) {
        compare(file.resolvingSymlinksInPath().standardizedFileURL, against: nil, clipboard: text)
    }

    private func compare(_ first: URL, against second: URL?, clipboard: String?) {
        let rightName = second?.lastPathComponent ?? "剪贴板"
        let leftName = first.lastPathComponent
        let comparison = ComparisonTab(left: referencePath(of: first), right: second.map(referencePath(of:)) ?? "剪贴板",
            title: "\(leftName) ↔ \(rightName)", languageFilename: second?.lastPathComponent ?? leftName)
        Task { [weak self] in
            guard let self else { return }
            await collectDraftForProjectSearch()
            let drafts = draftsByPath
            let left: FileComparison.Source = .file(first, draft: drafts[first.path])
            guard let right = second.map({ FileComparison.Source.file($0, draft: drafts[$0.path]) })
                ?? clipboard.map(FileComparison.Source.clipboard) else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FileComparison.read(left, right) }
            }.value
            guard isActive else { return }
            let content: TabContent
            switch result {
            case .success(.text(let old, let new)):
                content = .textDiff(oldText: old, newText: new, language: Language.forFile(named: comparison.languageFilename))
            case .success(.binary(let identical)):
                content = .message(title: identical ? "二进制文件内容相同" : "二进制文件内容不同", detail: "\(comparison.left)\n\(comparison.right)")
            case .failure(let error):
                showError(error.localizedDescription)
                return
            }
            openComparison(comparison, content: content)
            renderer.focusContent()
        }
    }
}
