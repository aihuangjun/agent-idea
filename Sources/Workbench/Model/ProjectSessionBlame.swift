import Core
import DesignSystem
import Foundation

struct FileBlame {
    let path: String
    let text: String
    let lines: [Int: GitBlameLine]
    let marks: [RenderPayload.BlameMark]

    init(path: String, text: String, lines: [GitBlameLine]) {
        self.path = path
        self.text = text
        self.lines = Dictionary(lines.map { ($0.line, $0) }, uniquingKeysWith: { first, _ in first })
        marks = lines.map { line in
            guard let hash = line.hash else {
                return .init(line: line.line, label: "未提交", detail: "这一行包含尚未提交的改动", committed: false)
            }
            let date = line.date?.formatted(date: .abbreviated, time: .omitted)
            let label = [line.author, date].compactMap { $0 }.joined(separator: " · ")
            return .init(line: line.line, label: label, detail: "\(label)\n\(hash.prefix(9)) · \(line.summary)", committed: true)
        }
    }
}

extension ProjectSession {
    private static var blameLoadingMessage: String { "正在读取 Git 行归属…" }

    var blameFile: URL? {
        guard hasGit, let tab = activeTab, let url = tab.fileURL, canReplaceInFile, change(for: url)?.kind != .untracked,
              project.repositoryRelativePath(of: url) != nil else { return nil }
        return url
    }

    var showsBlame: Bool { fileBlame != nil && fileBlame?.path == blameFile?.path }
    var blameActionTitle: String { showsBlame ? "隐藏 Git 行归属" : "显示 Git 行归属" }

    func toggleBlame() {
        guard let source = blameFile, let git, let root = project.repositoryRoot,
              let path = project.repositoryRelativePath(of: source), let tab = activeTab else { return }
        if showsBlame || blameTask != nil {
            clearBlame(path: source.path)
            return
        }
        let headPath = change(for: source)?.originalPath ?? path
        notify(Self.blameLoadingMessage)
        let request = UUID()
        blameRequest = request
        blameTask = Task { [weak self] in
            guard let self else { return }
            defer { if blameRequest == request { cancelBlameRequest() } }
            do {
                guard let snapshot = try await renderer.editableSnapshot(path: source.path),
                      !Task.isCancelled, activeTabID == tab.id else { return }
                guard !snapshot.text.isEmpty else { notify("空文件没有可显示的行归属"); return }
                guard snapshot.text.utf8.count <= 512 * 1024, TextFileLoader.lineCount(of: snapshot.text) <= 12_000 else {
                    notify("Git 行归属支持 512 KB、12,000 行以内的文本文件")
                    return
                }
                let document = contents[tab.id]
                let bytes = TextFileSaver.data(for: snapshot.text, encodingName: document?.encodingName ?? "UTF-8", original: document?.text ?? "")
                let lines = try await git.blame(path: headPath, contents: bytes, repositoryRoot: root)
                guard !Task.isCancelled, activeTabID == tab.id, blameRequest == request,
                      try await renderer.editableSnapshot(path: source.path)?.text == snapshot.text,
                      !Task.isCancelled, blameRequest == request, activeTabID == tab.id else { return }
                guard !lines.isEmpty else { notify("没有找到可显示的行归属"); return }
                let result = FileBlame(path: source.path, text: snapshot.text, lines: lines)
                fileBlame = result
                renderer.updateBlame(path: source.path, marks: result.marks)
            } catch {
                if !Task.isCancelled { showError("无法显示 Git 行归属：\(error.userFacingDescription)") }
            }
        }
    }

    func cancelBlameRequest() {
        blameTask?.cancel()
        blameTask = nil
        blameRequest = nil
        if banner == Self.blameLoadingMessage { dismissBanner() }
    }

    func clearBlame(path: String? = nil) {
        if path == nil || path == activeTab?.fileURL?.path { cancelBlameRequest() }
        guard let fileBlame, path == nil || path == fileBlame.path else { return }
        self.fileBlame = nil
        renderer.updateBlame(path: fileBlame.path, marks: nil)
    }

    func blameMarks(for tab: EditorTab, text: String?) -> [RenderPayload.BlameMark]? {
        guard let fileBlame, tab.fileURL?.path == fileBlame.path, let text,
              LineEnding.normalized(text) == fileBlame.text else { return nil }
        return fileBlame.marks
    }

    func openBlamedCommit(path: String, line: Int) {
        guard isActive, activeTab?.fileURL?.path == path, fileBlame?.path == path,
              let attribution = fileBlame?.lines[line], let hash = attribution.hash,
              let git, let root = project.repositoryRoot else { return }
        let tab = activeTabID
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let commit = try await git.commit(hash: hash, repositoryRoot: root) else { return }
                let changes = try await git.changedFiles(in: commit, repositoryRoot: root)
                guard isActive, activeTabID == tab, fileBlame?.lines[line] == attribution else { return }
                guard let change = changes.first(where: { $0.path == attribution.path }) else {
                    notify("提交 \(commit.shortHash) · \(commit.subject) 未找到对应文件的差异")
                    return
                }
                openCommitDiff(change, in: commit, pinned: true, at: SourceLocation(line: attribution.originalLine, column: 1))
                renderer.focusContent()
            } catch {
                if isActive, activeTabID == tab { showError("无法打开提交：\(error.userFacingDescription)") }
            }
        }
    }
}
