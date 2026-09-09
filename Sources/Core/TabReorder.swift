import Foundation

/// 横向标签栏拖动排序的纯逻辑：标签宽窄不一，「拖到哪一格」得按各自的宽度算，不能按格数除。
///
/// 坐标一律用**标签栏内容的左边缘**为原点（不含滚动偏移，滚动是视图层的事），
/// 下标 `destination` 按「先把拖着的那个拿掉」之后的插入位算——所以 `destination == 原下标` 就是不动。
public enum TabReorder {
    /// 第 `index` 个标签静止时的左边缘。
    public static func origin(of index: Int, widths: [Double]) -> Double {
        widths[..<min(max(index, 0), widths.count)].reduce(0, +)
    }

    /// 拖着的那个标签的左边缘落在 `left` 时，它该插到哪一格：
    /// 拿掉它之后各个插入位的左边缘里，离 `left` 最近的那个。
    ///
    /// 按左边缘而不是中心比：两者只差一个固定的半宽，但左边缘不用知道自己多宽，
    /// 而且「往右挪过邻居一半宽度就换位」这条手感是一样的。
    public static func destination(of index: Int, movedTo left: Double, widths: [Double]) -> Int {
        guard widths.indices.contains(index) else { return index }
        var remaining = widths
        remaining.remove(at: index)
        var best = 0
        var bestDistance = abs(left)        // 插到最前面：左边缘是 0
        var edge = 0.0
        for (offset, width) in remaining.enumerated() {
            edge += width
            let distance = abs(left - edge)
            if distance < bestDistance {
                bestDistance = distance
                best = offset + 1
            }
        }
        return best
    }

    /// 把 `from` 挪到 `to`（`to` 是拿掉它之后的插入位）。越界或原地不动时原样返回。
    public static func reordered<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), to >= 0, to < items.count, to != from else { return items }
        var result = items
        let item = result.remove(at: from)
        result.insert(item, at: to)
        return result
    }
}
