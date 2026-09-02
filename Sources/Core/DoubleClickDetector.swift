import Foundation

/// 按时间间隔判定双击：同一个目标上、间隔内的第二下算双击。
///
/// 不用 SwiftUI 的 `TapGesture(count: 2)`：在 macOS 上它会让同一视图的单击等到双击超时之后才被判定，
/// 表现是「点了要过一会儿才选中」。这里单击立即生效，只额外记一下时间。
/// 纯逻辑，间隔与时钟都可注入，视图层传系统的双击间隔进来。
public final class DoubleClickDetector {
    private let interval: TimeInterval
    private let now: () -> TimeInterval
    private var last: (id: String, time: TimeInterval)?

    public init(interval: TimeInterval, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.interval = interval
        self.now = now
    }

    /// 记录一次单击，返回它是不是双击的第二下。双击之后重新开始计数。
    public func registerClick(on id: String) -> Bool {
        let time = now()
        if let last, last.id == id, time - last.time <= interval {
            self.last = nil
            return true
        }
        last = (id, time)
        return false
    }
}
