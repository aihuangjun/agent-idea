import Foundation

extension GitClient {
    /// 全项目文本搜索的 `git grep`，在 `directory`（项目根）里跑：结果只落在项目里，路径直接是相对项目根的。
    ///
    /// - 退出码 1 是「一处都没找到」，不是错误。
    /// - 正则先用 `-P`；git 没编进 PCRE（报 `USE_LIBPCRE` / Perl-compatible）就换 `-E` 再跑一次。
    /// - 正则写错 git 报 128 + `-e option`，转成 `TextSearchError.invalidRegex`；目录不在仓库里转成 `.notARepository`。
    /// - 环境里的 `LC_ALL` 换成 UTF-8：`LC_ALL=C` 下 `-i` 只折叠 ASCII（`Ä` 找不到 `ä`），`-P` 也按字节处理。错误信息仍是英文。
    public func grep(_ query: TextSearchQuery, matcher: TextSearchMatcher, in directory: URL, limit: Int) async throws -> TextSearchResult {
        var environment = Self.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        var perl = true
        while true {
            let output = try await runner.run(
                executable: executable, arguments: query.gitGrepArguments(perl: perl),
                currentDirectory: directory, environment: environment
            )
            switch output.status {
            case 0, 1:
                return GitGrepParser.parse(output.standardOutput, matcher: matcher, limit: limit)
            default:
                let message = output.standardError
                if query.isRegex, perl, message.contains("USE_LIBPCRE") || message.contains("Perl-compatible") {
                    perl = false
                    continue
                }
                if message.contains("not a git repository") { throw TextSearchError.notARepository }
                if message.contains("-e option") {
                    throw TextSearchError.invalidRegex("正则表达式有误：\(Self.grepErrorDetail(message))。要按普通文字查找，关掉「.*」（正则）。")
                }
                throw TextSearchError.failed("git grep 出错了：\(message.isEmpty ? "退出码 \(output.status)" : message)")
            }
        }
    }

    /// `fatal: -e option, '(': missing closing parenthesis` → `missing closing parenthesis`。
    static func grepErrorDetail(_ message: String) -> String {
        let line = message.split(separator: "\n").first.map(String.init) ?? message
        guard let colon = line.range(of: "': ", options: .backwards) else { return line }
        return String(line[colon.upperBound...])
    }
}
