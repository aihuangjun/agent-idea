import SwiftUI

/// 按下即响应的点击。
///
/// `onTapGesture` 要到松开才触发，按下到松开本身就有几十毫秒；IDEA、Finder 的列表都是按下就选中。
/// 这里用 `DragGesture(minimumDistance: 0)` 拿到 mouseDown：`press` 在按下时调（位置是行内坐标），
/// `release` 在松开时调，参数是「没拖动、算一次点击」。双击的判定交给调用方的 `DoubleClickDetector`。
struct PressGesture: ViewModifier {
    let press: (CGPoint) -> Void
    let release: (_ isClick: Bool) -> Void
    @State private var isPressing = false

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard !isPressing else { return }
                    isPressing = true
                    press(value.startLocation)
                }
                .onEnded { value in
                    isPressing = false
                    release(abs(value.translation.width) < 4 && abs(value.translation.height) < 4)
                }
        )
    }
}

extension View {
    func onPress(_ press: @escaping (CGPoint) -> Void, release: @escaping (_ isClick: Bool) -> Void = { _ in }) -> some View {
        modifier(PressGesture(press: press, release: release))
    }
}
