// swift-tools-version:6.0
import PackageDescription

// 分层靠 target 边界强制，而不是靠目录约定——目录约定挡不住 internal 互相可见。
//
//   Core          —— 纯逻辑：版本、日志、git 命令与解析、diff 解析与排版、目录扫描。零 UI。
//   DesignSystem  —— 外观词汇：深色主题、WebView 渲染宿主、通用控件、随包分发的前端资源。
//   Workbench     —— 工作台：模型（打开项目、目录树、标签页、变更）与全部视图、窗口、菜单。
//   AgentIDEAApp  —— 只剩一个 @main。SwiftPM 测不了 executable target，所以这里什么都不放。
//
// 测试框架用 swift-testing：本机只有 Command Line Tools，XCTest.framework 不在 SDK 里。
let package = Package(
    name: "AgentIDEA",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DesignSystem",
            dependencies: ["Core"],
            path: "Sources/DesignSystem",
            resources: [.copy("Resources/web")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "Workbench",
            dependencies: ["Core", "DesignSystem"],
            path: "Sources/Workbench",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgentIDEAApp",
            dependencies: ["Workbench"],
            path: "Sources/AgentIDEAApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // 普通 target 而不是 testTarget：test target 之间不能互相 import。
        .target(
            name: "TestSupport",
            dependencies: ["Core"],
            path: "Tests/TestSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core", "TestSupport"],
            path: "Tests/CoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem", "TestSupport"],
            path: "Tests/DesignSystemTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WorkbenchTests",
            dependencies: ["Workbench", "TestSupport"],
            path: "Tests/WorkbenchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 架构不变量的守卫：读源文件本身断言「哪些 import 不许出现」，刻意不依赖任何产品 target。
        .testTarget(
            name: "ArchitectureTests",
            path: "Tests/ArchitectureTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
