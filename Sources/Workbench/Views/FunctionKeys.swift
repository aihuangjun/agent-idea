import AppKit
import SwiftUI

/// 功能键当 SwiftUI 的按键用：SwiftUI 没有现成的常量，按 AppKit 的功能键字符构造
/// （NSMenuItem 的 keyEquivalent、KeyPress.key 用的都是这个字符）。
extension KeyEquivalent {
    static let f6 = KeyEquivalent(Character(Unicode.Scalar(UInt32(NSF6FunctionKey))!))
    static let f7 = KeyEquivalent(Character(Unicode.Scalar(UInt32(NSF7FunctionKey))!))
}
