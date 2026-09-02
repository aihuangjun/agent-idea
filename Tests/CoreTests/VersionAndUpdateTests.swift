import Core
import Foundation
import Testing

@Test func versionParsesAndCompares() {
    #expect(AppVersion("1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
    #expect(AppVersion("1.2") == AppVersion(major: 1, minor: 2, patch: 0))
    #expect(AppVersion("1.0.10")! > AppVersion("1.0.9")!)
    #expect(AppVersion("") == nil)
    #expect(AppVersion("1.2.3.4") == nil)
    #expect(AppVersion("a.b") == nil)
    #expect(AppVersion(" 2.0.0 ")?.description == "2.0.0")
}

@Test func buildIdentityReadsInfoPlistKeys() {
    let identity = BuildIdentity(info: [
        "CFBundleShortVersionString": "0.1.0",
        "AIBuildTimestamp": "202609012310",
        "AIBuildChannel": "release",
    ])
    #expect(identity.display == "0.1.0(202609012310-release)")
    // 认不出的渠道当本地构建
    #expect(BuildIdentity(info: ["AIBuildChannel": "nightly"]).channel == .debug)
    #expect(BuildIdentity(info: nil).display == "0.0.0(未知构建-debug)")
}

@Test func updatePolicy() {
    let manifest = UpdateManifest(version: "0.2.0", fileName: "AgentIDEA-0.2.0.dmg", sizeBytes: 1_048_576, sha256: "x", publishedAt: "")
    #expect(UpdatePolicy.hasUpdate(manifest: manifest, currentVersion: "0.1.0"))
    #expect(!UpdatePolicy.hasUpdate(manifest: manifest, currentVersion: "0.2.0"))
    #expect(!UpdatePolicy.hasUpdate(manifest: manifest, currentVersion: "garbage"))
    #expect(manifest.displaySize == "1.0 MB")

    let now = Date()
    #expect(UpdatePolicy.shouldAutoCheck(lastCheck: nil, now: now))
    #expect(!UpdatePolicy.shouldAutoCheck(lastCheck: now.addingTimeInterval(-3600), now: now))
    #expect(UpdatePolicy.shouldAutoCheck(lastCheck: now.addingTimeInterval(-90000), now: now))
    // 时间被往回调过也放行
    #expect(UpdatePolicy.shouldAutoCheck(lastCheck: now.addingTimeInterval(3600), now: now))
}

@Test func distributionPointsAtReleasesDirectoryOnGitHub() {
    let url = AppDistribution.contentsURL(fileName: "latest.json")
    #expect(url.absoluteString == "https://api.github.com/repos/aihuangjun/agent-idea/contents/releases/latest.json?ref=main")
    let request = AppDistribution.request(fileName: "a.dmg", token: "tok")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
    #expect(AppDistribution.request(fileName: "a.dmg", token: nil).value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func sha256OfFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentidea-sha-\(UUID().uuidString)")
    try "hello".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try AppDistribution.sha256(ofFileAt: url) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}

@Test func recentProjectsListRules() {
    let base = Date(timeIntervalSince1970: 0)
    var list: [RecentProject] = []
    list = RecentProjects.adding(URL(fileURLWithPath: "/tmp/a"), to: list, now: base)
    list = RecentProjects.adding(URL(fileURLWithPath: "/tmp/b"), to: list, now: base.addingTimeInterval(1))
    list = RecentProjects.adding(URL(fileURLWithPath: "/tmp/a/"), to: list, now: base.addingTimeInterval(2))
    #expect(list.map(\.path) == ["/tmp/a", "/tmp/b"])
    #expect(RecentProjects.removing("/tmp/a", from: list).map(\.path) == ["/tmp/b"])

    var many: [RecentProject] = []
    for index in 0..<30 {
        many = RecentProjects.adding(URL(fileURLWithPath: "/tmp/p\(index)"), to: many, now: base.addingTimeInterval(Double(index)))
    }
    #expect(many.count == RecentProjects.limit)
    #expect(many.first?.path == "/tmp/p29")
}
