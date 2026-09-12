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

    // 状态栏那个按钮只有两档：图标说的是当前**实际**是深是浅，点一下切到另一边。
    // 跟随系统不再进这个循环——否则它和它落到的那一档主题相同、图标却不同，看着像三种状态。
    #expect(AppTheme.symbolName(isDark: true) == "moon")
    #expect(AppTheme.symbolName(isDark: false) == "sun.max")
    #expect(AppTheme.toggled(isDark: true) == .light)
    #expect(AppTheme.toggled(isDark: false) == .dark)
}
