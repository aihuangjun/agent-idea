import Foundation

/// 拖着东西贴近列表上下边缘时往哪个方向滚（纯逻辑，视图层每一拍问一次）。
///
/// 只看纵坐标：光标贴着 y 小的那条边就让视野的 origin.y 减小，贴着 y 大的那条边就增大——与坐标系翻不翻转无关
/// （翻转时 y 小是视觉上的上边，origin.y 减小就是往上看；不翻转时 y 小是下边，origin.y 减小就是往下看），
/// 两种情况都是「往光标指的方向滚」。光标跑到列表外面一点（比如往上拖过了头、停在标题条上）也算贴边：
/// 拖拽时 AppKit 只把更新发给光标下面的视图，列表外没人管，所以这一拍是定时器自己来问的，得把它算进去。
public enum DragAutoscroll {
    /// 返回视野 origin.y 该往哪边走（-1 / +1），不用滚返回 nil。`slack` 是光标跑到列表外多远之内还算贴边。
    public static func direction(pointY: Double, visibleMinY: Double, visibleMaxY: Double, margin: Double, slack: Double) -> Double? {
        if pointY < visibleMinY - slack || pointY > visibleMaxY + slack { return nil }
        if pointY < visibleMinY + margin { return -1 }
        if pointY > visibleMaxY - margin { return 1 }
        return nil
    }
}
