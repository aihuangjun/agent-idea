import AppKit
import DesignSystem
import Foundation
import Testing
@testable import Workbench

/// 外观：默认深色（0.8.0 之前应用固定深色，升级上来的人不该突然变浅），选过的存 UserDefaults。
@Test @MainActor func appearancePreferenceRoundTrips() {
    let suite = "agentidea-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let preferences = ReadingPreferences(defaults: defaults)
    #expect(preferences.theme == .dark)
    preferences.theme = .light
    #expect(ReadingPreferences(defaults: defaults).theme == .light, "选过的外观下次启动还在")

    #expect(AppTheme.system.appearance == nil, "跟随系统就是不设 appearance")
    #expect(AppTheme.light.appearance?.isDark == false)
    #expect(AppTheme.dark.appearance?.isDark == true)
    #expect(AppTheme.allCases.map(\.title) == ["跟随系统", "浅色", "深色"])

    // 状态栏那个按钮：图标是当前这一档，点一下转到下一档，转三下回到原点
    #expect(AppTheme.allCases.map(\.symbolName) == ["circle.lefthalf.filled", "sun.max", "moon"])
    #expect(AppTheme.system.next == .light)
    #expect(AppTheme.light.next == .dark)
    #expect(AppTheme.dark.next == .system)
    #expect(AppTheme.allCases.allSatisfy { $0.next.next.next == $0 })
}
