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
    let manifest = UpdateManifest(version: "0.2.0", fileName: "AgentIDEA-0.2.0.dmg", sizeBytes: 1_048_576, sha256: "x", downloadURL: URL(string: "https://api.github.com/x")!)
    #expect(UpdatePolicy.hasUpdate(manifest: manifest, current: BuildIdentity(version: "0.1.0", channel: .release)))
    #expect(!UpdatePolicy.hasUpdate(manifest: manifest, current: BuildIdentity(version: "0.2.0", channel: .release)))
    #expect(!UpdatePolicy.hasUpdate(manifest: manifest, current: BuildIdentity(version: "0.3.0", channel: .debug)))
    #expect(UpdatePolicy.hasUpdate(manifest: manifest, current: BuildIdentity(version: "0.2.0", channel: .debug)), "同版本号的本地构建要能升到正式包")
    #expect(!UpdatePolicy.hasUpdate(manifest: manifest, current: BuildIdentity(version: "garbage", channel: .debug)))
    #expect(manifest.displaySize == "1.0 MB")

    let now = Date()
    #expect(UpdatePolicy.shouldAutoCheck(lastCheck: nil, now: now))
    #expect(!UpdatePolicy.shouldAutoCheck(lastCheck: now.addingTimeInterval(-3600), now: now))
    #expect(UpdatePolicy.shouldAutoCheck(lastCheck: now.addingTimeInterval(-90000), now: now))
    // 时间被往回调过也放行
    #expect(UpdatePolicy.shouldAutoCheck(lastCheck: now.addingTimeInterval(3600), now: now))
}

@Test func distributionPointsAtGitHubReleases() {
    #expect(AppDistribution.latestReleaseURL.absoluteString == "https://api.github.com/repos/aihuangjun/agent-idea/releases/latest")
    let request = AppDistribution.latestReleaseRequest(token: "tok")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(AppDistribution.latestReleaseRequest(token: nil).value(forHTTPHeaderField: "Authorization") == nil)
    let asset = AppDistribution.assetRequest(url: URL(string: "https://api.github.com/repos/o/r/releases/assets/1")!, token: "tok")
    #expect(asset.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
    #expect(asset.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
}

@Test func manifestIsBuiltFromReleaseJSON() throws {
    let json = """
    {"tag_name": "v0.2.0", "body": "- 提交历史\\n- 查找文件\\n", "draft": false,
     "assets": [
       {"name": "notes.txt", "size": 10, "url": "https://api.github.com/repos/o/r/releases/assets/1", "digest": "sha256:aa"},
       {"name": "AgentIDEA-0.2.0.dmg", "size": 2717371, "url": "https://api.github.com/repos/o/r/releases/assets/2",
        "browser_download_url": "https://github.com/o/r/releases/download/v0.2.0/AgentIDEA-0.2.0.dmg",
        "digest": "sha256:6CD87900B78412E26015A2D9C59C7A737AE422869325B5C6301A21348A8965E7"}
     ]}
    """
    let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    let manifest = try UpdateManifest(release: release)
    #expect(manifest.version == "0.2.0")
    #expect(manifest.fileName == "AgentIDEA-0.2.0.dmg" && manifest.sizeBytes == 2_717_371)
    #expect(manifest.sha256 == "6cd87900b78412e26015a2d9c59c7a737ae422869325b5c6301a21348a8965e7")
    #expect(manifest.downloadURL.absoluteString == "https://api.github.com/repos/o/r/releases/assets/2")
    #expect(manifest.notes == "- 提交历史\n- 查找文件")
    #expect(UpdatePolicy.hasUpdate(manifest: manifest, current: BuildIdentity(version: "0.1.0")))

    // 没有 dmg 附件、附件没有摘要：都不能当成可更新
    let noDmg = GitHubRelease(tagName: "v9.0.0", body: nil, assets: [release.assets[0]])
    #expect(throws: UpdateManifest.ReleaseError.noDiskImage) { try UpdateManifest(release: noDmg) }
    let noDigest = GitHubRelease(tagName: "v9.0.0", body: "", assets: [.init(name: "a.dmg", size: 1, url: release.assets[1].url, digest: nil)])
    #expect(throws: UpdateManifest.ReleaseError.noDigest("a.dmg")) { try UpdateManifest(release: noDigest) }
    // tag 没有 v 前缀也认
    #expect(try UpdateManifest(release: GitHubRelease(tagName: "1.0.0", body: nil, assets: [release.assets[1]])).version == "1.0.0")
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

@Test func relativeDateText() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 15, minute: 0))!
    #expect(DateText.relative(now.addingTimeInterval(-30), now: now, calendar: calendar) == "刚刚")
    #expect(DateText.relative(now.addingTimeInterval(-5 * 60), now: now, calendar: calendar) == "5 分钟前")
    #expect(DateText.relative(now.addingTimeInterval(-3 * 3600), now: now, calendar: calendar) == "3 小时前")
    #expect(DateText.relative(now.addingTimeInterval(-20 * 3600), now: now, calendar: calendar) == "昨天")
    #expect(DateText.relative(now.addingTimeInterval(-3 * 86400), now: now, calendar: calendar) == "3 天前")
    #expect(DateText.relative(now.addingTimeInterval(-30 * 86400), now: now, calendar: calendar) == "8月3日")
    #expect(DateText.relative(now.addingTimeInterval(-400 * 86400), now: now, calendar: calendar) == "2025年7月29日")
}
