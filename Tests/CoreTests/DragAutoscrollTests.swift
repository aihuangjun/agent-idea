import Core
import Testing

@Test func dragAutoscrollDirectionFollowsTheEdgeTheCursorTouches() {
    func direction(_ y: Double) -> Double? { DragAutoscroll.direction(pointY: y, visibleMinY: 100, visibleMaxY: 400, margin: 28, slack: 28) }
    #expect(direction(250) == nil, "中间不滚")
    #expect(direction(110) == -1, "贴着 y 小的那条边")
    #expect(direction(127.9) == -1)
    #expect(direction(128) == nil)
    #expect(direction(390) == 1, "贴着 y 大的那条边")
    #expect(direction(372) == nil)
    #expect(direction(372.1) == 1)
    #expect(direction(80) == -1, "跑到列表外一点还算贴边")
    #expect(direction(420) == 1)
    #expect(direction(71) == nil, "跑远了就不滚")
    #expect(direction(429) == nil)
}
