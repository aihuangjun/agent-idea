import SwiftUI
import Workbench

/// 可执行入口，只有这一层壳。窗口、菜单、模型全在 Workbench（library target）里，那边才测得到。
@main
struct AgentIDEAApp: App {
    var body: some Scene {
        AgentIDEARootScene()
    }
}
