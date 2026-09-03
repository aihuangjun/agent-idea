import Foundation

/// 「后退 / 前进」的历史（IDEA 的 Back / Forward）。纯值类型，元素是什么由调用方定（会话里放的是标签 id）。
///
/// 规则与浏览器一样：到了一个新地方就记一笔并砍掉「前进」那一截；后退/前进只移动指针不记录；
/// 连续访问同一个地方只记一次；地方没了（标签关了）就从历史里抹掉，指针跟着修正。
public struct NavigationHistory<Element: Equatable>: Equatable {
    public private(set) var entries: [Element] = []
    /// 指向 `entries` 里当前所在的位置；空历史时为 -1。
    public private(set) var index = -1
    public let capacity: Int

    public init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    public var current: Element? { entries.indices.contains(index) ? entries[index] : nil }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// 到了一个新地方。
    public mutating func visit(_ element: Element) {
        if current == element { return }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        entries.append(element)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        index = entries.count - 1
    }

    public mutating func goBack() -> Element? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    public mutating func goForward() -> Element? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }

    /// 某个地方没了：抹掉它的每一条记录，相邻的重复项合并。
    public mutating func remove(_ element: Element) {
        var kept: [Element] = []
        var newIndex = -1
        for (position, entry) in entries.enumerated() {
            if entry == element { continue }
            if kept.last == entry {
                // 抹掉中间那个之后两边一样了，合并成一个
                if position <= index { newIndex = kept.count - 1 }
                continue
            }
            kept.append(entry)
            if position <= index { newIndex = kept.count - 1 }
        }
        entries = kept
        index = kept.isEmpty ? -1 : max(0, min(newIndex, kept.count - 1))
    }
}
