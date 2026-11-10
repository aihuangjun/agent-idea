import Core
import DesignSystem

extension ProjectSession {
    /// diff 正文与标签的右键菜单：多选包含当前文件时对整组选中执行，未跟踪文件跳过。
    func rollbackMenuAction(for change: GitChange) -> ContentRenderer.ContextAction? {
        let targets = changesForAction(on: change).filter { $0.kind != .untracked }
        guard !targets.isEmpty else { return nil }
        return ContentRenderer.ContextAction(
            title: targets.count == 1 ? "回滚" : "回滚 \(targets.count) 个文件"
        ) { [weak self] in self?.rollback(targets) }
    }
}
