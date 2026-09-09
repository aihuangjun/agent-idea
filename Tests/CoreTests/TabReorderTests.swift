import Core
import Foundation
import Testing

/// 标签宽窄不一，拖动排序的落点得按宽度算。
@Test func tabReorderPicksTheNearestSlot() {
    let widths = [100.0, 60, 140]

    #expect(TabReorder.origin(of: 0, widths: widths) == 0)
    #expect(TabReorder.origin(of: 1, widths: widths) == 100)
    #expect(TabReorder.origin(of: 2, widths: widths) == 160)
    #expect(TabReorder.origin(of: 3, widths: widths) == 300, "末尾之后就是总宽")

    // 第一个往右拖：拿掉它之后的插入位在 0 / 60 / 200
    #expect(TabReorder.destination(of: 0, movedTo: 0, widths: widths) == 0)
    #expect(TabReorder.destination(of: 0, movedTo: 29, widths: widths) == 0, "还没挪过邻居一半宽")
    #expect(TabReorder.destination(of: 0, movedTo: 31, widths: widths) == 1)
    #expect(TabReorder.destination(of: 0, movedTo: 500, widths: widths) == 2, "拖过头就是最后一格")
    #expect(TabReorder.destination(of: 0, movedTo: -500, widths: widths) == 0, "往左拖过头还是第一格")

    // 最后一个往左拖：插入位在 0 / 100 / 160
    #expect(TabReorder.destination(of: 2, movedTo: 160, widths: widths) == 2)
    #expect(TabReorder.destination(of: 2, movedTo: 120, widths: widths) == 1)
    #expect(TabReorder.destination(of: 2, movedTo: 40, widths: widths) == 0)

    // 越界的问下标不动
    #expect(TabReorder.destination(of: 3, movedTo: 0, widths: widths) == 3)
}

@Test func tabReorderMovesTheItem() {
    let items = ["a", "b", "c", "d"]
    #expect(TabReorder.reordered(items, from: 0, to: 2) == ["b", "c", "a", "d"])
    #expect(TabReorder.reordered(items, from: 3, to: 0) == ["d", "a", "b", "c"])
    #expect(TabReorder.reordered(items, from: 1, to: 1) == items, "原地不动")
    #expect(TabReorder.reordered(items, from: 4, to: 0) == items)
    #expect(TabReorder.reordered(items, from: 0, to: 4) == items)
    #expect(TabReorder.reordered(items, from: 0, to: -1) == items)

    // 每一格都落得回原样：destination 与 reordered 用的是同一套下标
    for from in items.indices {
        let moved = TabReorder.reordered(items, from: from, to: items.count - 1)
        #expect(moved.count == items.count && Set(moved) == Set(items))
    }
}
