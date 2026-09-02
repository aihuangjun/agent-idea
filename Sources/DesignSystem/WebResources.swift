import Foundation

/// 定位随包分发的前端资源（`Resources/web`）。
///
/// **刻意不用 SwiftPM 生成的 `Bundle.module`**：它对 library target 只认两个位置——可执行文件旁边，
/// 以及一个硬编码的绝对 `.build` 路径。打出来的 app 在开发机上靠 `.build` 那条路径侥幸能跑，
/// 发给同事就崩在 `Bundle.module` 内部的 `fatalError` 上。
public enum WebResources {
    /// 名字是 SwiftPM 定的：「包名_target名」。改 target 名要同步改这里和 build_app.sh 那两处。
    public static let bundleName = "AgentIDEA_DesignSystem.bundle"

    public static let bundle: Bundle = {
        let token = Bundle(for: BundleToken.self)
        var starts: [URL] = [Bundle.main.bundleURL, token.bundleURL]
        if let resources = Bundle.main.resourceURL { starts.append(resources) }
        if let resources = token.resourceURL { starts.append(resources) }
        if let executable = Bundle.main.executableURL { starts.append(executable.deletingLastPathComponent()) }

        // 每个起点往上逐级找，同时看目录本身和它的 Resources 子目录：
        //   .app 里    → 可执行文件在 Contents/MacOS，资源在上一级的 Resources 下；
        //   测试进程里 → 代码在 .build/<arch>/debug/XXX.xctest 里，资源 bundle 在 .build/<arch>/debug 下。
        for start in starts {
            var directory = start
            for _ in 0..<5 {
                if let found = Bundle(url: directory.appendingPathComponent(bundleName)) { return found }
                let inResources = directory.appendingPathComponent("Resources").appendingPathComponent(bundleName)
                if let found = Bundle(url: inResources) { return found }
                directory = directory.deletingLastPathComponent()
            }
        }
        return token
    }()

    /// 渲染页 index.html。找不到说明打包漏了资源。
    public static var shellURL: URL? {
        bundle.url(forResource: "web/index", withExtension: "html")
    }

    private final class BundleToken {}
}
