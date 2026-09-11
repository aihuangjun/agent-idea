import AppKit
import SwiftUI

/// 按下即响应的点击。
///
/// `onTapGesture` 要到松开才触发，按下到松开本身就有几十毫秒；IDEA、Finder 的列表都是按下就选中。
/// 这里用 `DragGesture(minimumDistance: 0)` 拿到 mouseDown：`press` 在按下时调（位置是行内坐标，外加按着的修饰键），
/// `release` 在松开时调，参数是「没拖动、算一次点击」。双击的判定交给调用方的 `DoubleClickDetector`。
struct PressGesture: ViewModifier {
    let press: (CGPoint, NSEvent.ModifierFlags) -> Void
    let release: (_ isClick: Bool) -> Void
    @State private var isPressing = false

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard !isPressing else { return }
                    isPressing = true
                    press(value.startLocation, Self.currentModifiers)
                }
                .onEnded { value in
                    isPressing = false
                    release(abs(value.translation.width) < 4 && abs(value.translation.height) < 4)
                }
        )
    }

    /// 手势回调里拿不到事件本身：优先看正在派发的那个鼠标事件，没有的话看此刻键盘上按着什么（按下的那一刻修饰键还按着）。
    private static var currentModifiers: NSEvent.ModifierFlags {
        let flags: NSEvent.ModifierFlags
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseDragged {
            flags = event.modifierFlags
        } else {
            flags = NSEvent.modifierFlags
        }
        return flags.intersection([.command, .shift, .option, .control])
    }
}

extension View {
    func onPress(_ press: @escaping (CGPoint) -> Void, release: @escaping (_ isClick: Bool) -> Void = { _ in }) -> some View {
        modifier(PressGesture(press: { point, _ in press(point) }, release: release))
    }

    /// 同上，按下时还给出按着的修饰键（⌘点击加减多选、⇧点击连选）。
    func onPress(modifiers press: @escaping (CGPoint, NSEvent.ModifierFlags) -> Void, release: @escaping (_ isClick: Bool) -> Void = { _ in }) -> some View {
        modifier(PressGesture(press: press, release: release))
    }
}
