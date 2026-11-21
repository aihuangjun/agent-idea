import Foundation

/// 双击 Shift 由两次短按组成。夹着输入、点击或其它修饰键的序列由调用方重置。
public struct DoubleShiftDetector {
    private var pressedAt: TimeInterval?
    private var releasedAt: TimeInterval?
    private let interval: TimeInterval

    public init(interval: TimeInterval = 0.4) { self.interval = interval }

    public mutating func reset() {
        pressedAt = nil
        releasedAt = nil
    }

    public mutating func shift(isDown: Bool, at time: TimeInterval) -> Bool {
        if isDown {
            if pressedAt != nil { reset(); return false }
            pressedAt = time
            return false
        }
        guard let pressedAt, time >= pressedAt, time - pressedAt <= interval else {
            reset()
            return false
        }
        self.pressedAt = nil
        if let releasedAt, pressedAt >= releasedAt, time - releasedAt <= interval {
            self.releasedAt = nil
            return true
        }
        releasedAt = time
        return false
    }
}
