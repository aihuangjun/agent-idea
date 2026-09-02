import Foundation

/// 把一阵密集的调用合并成最后一次。主线程用。
@MainActor
public final class Debouncer {
    private let delay: TimeInterval
    private var pending: Task<Void, Never>?

    public init(delay: TimeInterval) {
        self.delay = delay
    }

    public func call(_ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { @MainActor [delay] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }
}
