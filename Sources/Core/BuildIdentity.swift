import Foundation

/// 当前跑的是**哪一次构建**。
///
/// 只有版本号不够用：本地边改边构建的包和发出去的正式包可能都叫 `0.1.0`。
/// 所以再带上构建时刻与渠道，显示成 `0.1.0(202609012310-debug)`。
/// 事实来源是 bundle 的 Info.plist，由 `scripts/build_app.sh` 在组装时写入。
public struct BuildIdentity: Equatable, Sendable {
    /// 区分的不是 `swift build -c debug/release`（那是优化级别），
    /// 而是「本地迭代中的构建」和「走了发布流程的那一份」。
    public enum Channel: String, Sendable {
        case debug
        case release
    }

    public let version: String
    /// `yyyyMMddHHmm`。`swift run` 直接跑时没有 bundle，为 nil。
    public let timestamp: String?
    public let channel: Channel

    public init(version: String, timestamp: String? = nil, channel: Channel = .debug) {
        self.version = version
        self.timestamp = timestamp
        self.channel = channel
    }

    /// Info.plist 里的键名。build_app.sh 里写的是同样这两个，改名要同步。
    public enum InfoKey {
        public static let version = "CFBundleShortVersionString"
        public static let timestamp = "AIBuildTimestamp"
        public static let channel = "AIBuildChannel"
    }

    public static let current = BuildIdentity(info: Bundle.main.infoDictionary)

    public init(info: [String: Any]?) {
        let version = info?[InfoKey.version] as? String ?? "0.0.0"
        let timestamp = (info?[InfoKey.timestamp] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // 认不出的渠道一律当本地构建：宁可把正式包说成本地的，也不能把来路不明的包说成「已发布」。
        let channel = Channel(rawValue: info?[InfoKey.channel] as? String ?? "") ?? .debug
        self.init(version: version, timestamp: timestamp, channel: channel)
    }

    /// 给人看的完整标识，如 `0.1.0(202609012310-debug)`。
    public var display: String {
        "\(version)(\(timestamp ?? "未知构建")-\(channel.rawValue))"
    }
}
