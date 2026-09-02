import Core
import Foundation

/// 盯着项目目录：FSEvents 报上来的路径先过滤、再去抖，攒成一批交给回调。
///
/// 从 `ProjectSession` 里拆出来，让它只管「什么时候该刷新」，不管刷新做什么。
@MainActor
final class ChangeWatcher {
    private let watcher: DirectoryWatcher
    private let debouncer = Debouncer(delay: 0.35)
    private var pending: Set<String> = []
    private var isStopped = false
    private let onChanges: @MainActor (Set<String>) -> Void

    /// - Parameter onChanges: 一批变了的路径（绝对路径，已去掉 `.git/` 内部噪音）。
    init(root: URL, onChanges: @escaping @MainActor (Set<String>) -> Void) {
        self.onChanges = onChanges
        // FSEvents 回调在后台队列上，经一个弱引用中继跳回主线程；中继让 watcher 不必强持有 self
        let relay = Relay()
        watcher = DirectoryWatcher(url: root) { paths in relay.forward(paths) }
        relay.owner = self
        if !watcher.start() {
            Log.warn("watch", "FSEvents 启动失败，改动需要手动刷新（⌘R）")
        }
    }

    private final class Relay: @unchecked Sendable {
        @MainActor weak var owner: ChangeWatcher?

        func forward(_ paths: [String]) {
            let relevant = paths.filter(DirectoryWatcher.isRelevant)
            guard !relevant.isEmpty else { return }
            Task { @MainActor [self] in self.owner?.note(relevant) }
        }
    }

    fileprivate func note(_ paths: [String]) {
        guard !isStopped else { return }
        pending.formUnion(paths)
        debouncer.call { [weak self] in
            guard let self, !self.isStopped else { return }
            let changed = self.pending
            self.pending = []
            self.onChanges(changed)
        }
    }

    /// 项目关掉时调。已经排队的那一批也作废，不再对一个关掉的项目跑 git。
    func stop() {
        isStopped = true
        debouncer.cancel()
        pending = []
        watcher.stop()
    }
}
