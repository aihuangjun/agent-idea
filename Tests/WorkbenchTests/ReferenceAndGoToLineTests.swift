import AppKit
import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@testable import Workbench

@MainActor private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor private func cursor(_ renderer: ContentRenderer) async -> String {
    let value = try? await renderer.webView.evaluateJavaScript("(() => { const c = window.ide && window.ide.getState().cursor; return c ? c.line + ':' + c.ch : '' })()")
    return value as? String ?? ""
}

@MainActor private func reference(_ session: ProjectSession, _ tabID: String) async -> String? {
    let result = Locked<String?>(nil)
    session.reference(of: tabID) { result.value = $0 }
    await waitUntil { result.value != nil }
    return result.value
}

@Test @MainActor func definitionNavigationUsesF3AndTheWebContextMenu() async throws {
    try await withTemporaryDirectory { directory in
        let java = directory.appendingPathComponent("Use.java")
        try """
        package client;
        import api.Box;
        class Use {
            int value = 1;
            int read(Box box) {
                int value = 2;
                return box.get(value) + this.value;
            }
        }
        """.write(to: java, atomically: true, encoding: .utf8)
        let target = directory.appendingPathComponent("Box.java")
        try """
        package api;
        class Box {
            int get() { return 0; }
            int get(int number) { return number; }
        }
        """.write(to: target, atomically: true, encoding: .utf8)
        try "package wrong; class Box { int get(int n) { return n; } }"
            .write(to: directory.appendingPathComponent("Other.java"), atomically: true, encoding: .utf8)
        let suite = "agentidea-definitions-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let renderer = ContentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        let session = ProjectSession(root: directory, git: nil, renderer: renderer, preferences: ReadingPreferences(defaults: defaults))
        renderer.onGoToDefinition = { [weak session] path, point in session?.goToDefinition(path: path, point: point) }
        session.setActive(true)
        defer { session.tearDown() }
        session.openFile(java, pinned: true)
        await waitUntil { await cursor(renderer) == "0:0" }

        let web = renderer.webView
        func select(_ name: String, last: Bool = false) async throws -> String {
            try #require((try await web.evaluateJavaScript("""
            (() => {
              const cm = document.querySelector('.CodeMirror').CodeMirror;
              const line = 6, ch = cm.getLine(line).\(last ? "lastIndexOf" : "indexOf")('\(name)');
              cm.setSelection({line, ch}, {line, ch: ch + \(name.count)});
              return ch.toString();
            })()
            """)) as? String)
        }
        func pressF3() async throws {
            _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'F3', bubbles: true, cancelable: true })); true")
        }

        _ = try await select("value")
        try await pressF3()
        await waitUntil { await cursor(renderer) == "5:17" }
        #expect(await cursor(renderer) == "5:17", "局部变量优先于同名字段")

        let field = try await select("value", last: true)
        _ = try await select("get")
        let coords = try await web.evaluateJavaScript("""
        (() => {
          const rect = document.querySelector('.CodeMirror').CodeMirror.charCoords({line: 6, ch: \(field)}, 'window');
          return { x: (rect.left + rect.right) / 2, y: (rect.top + rect.bottom) / 2 };
        })()
        """)
        let point = try #require(coords as? [String: Double])
        let local = CGPoint(x: try #require(point["x"]), y: web.isFlipped ? try #require(point["y"]) : web.bounds.height - (try #require(point["y"])))
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: web.convert(local, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = NSMenu()
        web.willOpenMenu(menu, with: event)
        let item = try #require(menu.items.first(where: { $0.title == "跳转到定义（F3）" }))
        #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
        await waitUntil { await cursor(renderer) == "3:13" }
        #expect(await cursor(renderer) == "3:13", "右键使用点击位置，this.value 跳到字段")

        _ = try await select("get")
        try await pressF3()
        await waitUntil {
            guard session.activeTab?.fileURL?.path == target.path else { return false }
            return await cursor(renderer) == "3:11"
        }
        #expect(session.activeTab?.fileURL?.path == target.path)
        #expect(await cursor(renderer) == "3:11", "跳到显式导入类型的单参数重载，选中函数名")
        #expect(session.canGoBack)

        let swiftFile = directory.appendingPathComponent("Crate.swift")
        try """
        struct Crate {
            func measure() -> Int {
                let icon = "🙂"; return amount
            }
        }
        """.write(to: swiftFile, atomically: true, encoding: .utf8)
        session.openFile(swiftFile, pinned: true)
        await waitUntil { await cursor(renderer) == "0:0" }
        _ = try await web.evaluateJavaScript("""
        (() => {
          const cm = document.querySelector('.CodeMirror').CodeMirror;
          cm.replaceRange('        let amount = 42\\n', {line: 2, ch: 0});
          cm.setCursor({line: 3, ch: cm.getLine(3).indexOf('amount') + 2});
          return true;
        })()
        """)
        try await pressF3()
        await waitUntil { await cursor(renderer) == "2:18" }
        #expect(await cursor(renderer) == "2:18", "使用当前草稿与 UTF-16 光标位置")

        let ts = directory.appendingPathComponent("main.ts")
        try "import { load as refresh } from './network';\nrefresh();".write(to: ts, atomically: true, encoding: .utf8)
        let module = directory.appendingPathComponent("network.ts")
        try "export function load() {}".write(to: module, atomically: true, encoding: .utf8)
        let otherModule = directory.appendingPathComponent("other.ts")
        try "export function load() {}".write(to: otherModule, atomically: true, encoding: .utf8)
        session.openFile(ts, pinned: true, at: SourceLocation(line: 2, column: 2))
        await waitUntil { await cursor(renderer) == "1:1" }
        try await pressF3()
        await waitUntil {
            guard session.activeTab?.fileURL?.path == module.path else { return false }
            return await cursor(renderer) == "0:20"
        }
        #expect(session.activeTab?.fileURL?.path == module.path)
        #expect(await cursor(renderer) == "0:20", "别名跳到实际导入的函数")
    }
}

@Test @MainActor func globalSearchAndJavaImplementationMenuShareLiveSourceIndex() async throws {
    try await withTemporaryDirectory { directory in
        func write(_ name: String, _ text: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let use = try write("client/Client.java", """
        package client;
        import api.Service;
        class Client { Service<String> service; }
        """)
        _ = try write("api/Service.java", "package api;\npublic interface Service<T> {}")
        _ = try write("spi/Extended.java", "package spi;\npublic interface Extended extends api.Service<String> {}")
        _ = try write("impl/Base.java", "package impl;\nimport spi.Extended;\nabstract class Base implements Extended {}")
        let implementation = try write("impl/Worker.java", """
        package impl;
        class Worker extends Base {
            void publishEvent() {}
        }
        """)
        _ = try write("legacy/Service.java", "package legacy;\ninterface Service {}\nclass Other implements Service {}")
        _ = try write("README.md", "# Project")
        _ = try write("impl/Worker.java.bak", "旧备份")

        let suite = "agentidea-project-search-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let renderer = ContentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        let session = ProjectSession(root: directory, git: nil, renderer: renderer, preferences: ReadingPreferences(defaults: defaults), defaults: defaults)
        renderer.onJavaImplementations = { [weak session] path, point in session?.showJavaImplementations(path: path, point: point) }
        session.setActive(true)
        defer { session.tearDown() }
        session.openFile(use, pinned: true)
        await waitUntil { await cursor(renderer) == "0:0" }

        let web = renderer.webView
        let coords = try await web.evaluateJavaScript("""
        (() => {
          const cm = document.querySelector('.CodeMirror').CodeMirror;
          const line = 2, ch = cm.getLine(line).indexOf('Service');
          cm.setSelection({line, ch}, {line, ch: ch + 'Service'.length});
          const rect = cm.charCoords({line, ch}, 'window');
          return { x: (rect.left + rect.right) / 2, y: (rect.top + rect.bottom) / 2 };
        })()
        """)
        let point = try #require(coords as? [String: Double])
        let x = try #require(point["x"]), y = try #require(point["y"])
        let local = CGPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: web.convert(local, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = NSMenu()
        web.willOpenMenu(menu, with: event)
        let item = try #require(menu.items.first { $0.title == "查看实现类" })
        #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
        await waitUntil { session.definitionChoices != nil }
        let choices = try #require(session.definitionChoices)
        #expect(choices.targets.compactMap { $0.symbol?.qualifiedName } == ["impl.Base", "impl.Worker"])
        session.openDefinition(try #require(choices.targets.last), name: choices.name)
        await waitUntil { session.activeTab?.fileURL?.path == implementation.path }
        #expect(session.activeTab?.fileURL?.path == implementation.path)

        session.showProjectSearch()
        let search = session.projectSearch
        #expect(search.isShown)
        search.query = "Worker"
        await waitUntil { search.results.first?.symbol?.qualifiedName == "impl.Worker" }
        #expect(search.results.first?.symbol?.qualifiedName == "impl.Worker")
        search.cycleScope(backwards: false)
        #expect(search.scope == .types)
        await waitUntil { !search.results.isEmpty }
        #expect(search.results.allSatisfy { $0.symbol?.kind.isType == true })
        search.scope = .files
        search.query = "README.md"
        await waitUntil { search.results.first?.path == "README.md" }
        #expect(search.results.first?.symbol == nil)
        search.scope = .symbols
        search.query = "publishEvent"
        await waitUntil { search.results.first?.symbol?.name == "publishEvent" }
        let method = try #require(search.selected)
        session.openProjectSearchResult(method)
        await waitUntil { await cursor(renderer) == "2:21" }
        #expect(!search.isShown)
        #expect(await cursor(renderer) == "2:21", "打开已存在的标签时仍定位并选中函数名")

        _ = try await web.evaluateJavaScript("""
        (() => {
          const cm = document.querySelector('.CodeMirror').CodeMirror;
          cm.replaceRange('updateQueue', {line: 2, ch: 9}, {line: 2, ch: 21});
          return true;
        })()
        """)
        session.showProjectSearch()
        search.scope = .symbols
        search.query = "updateQueue"
        await waitUntil { search.results.first?.symbol?.name == "updateQueue" }
        #expect(search.results.first?.symbol?.name == "updateQueue", "草稿变更应使已缓存的符号更新")

        session.showSidebarSearch()
        #expect(search.presentation == .sidebar && search.scope == .all)
        search.query = "Worker"
        await waitUntil { search.results.first?.symbol?.qualifiedName == "impl.Worker" }
        #expect(search.results.first?.symbol?.qualifiedName == "impl.Worker")
        search.query = "updateQueue"
        await waitUntil { search.results.first?.symbol?.name == "updateQueue" }
        let sidebarMethod = try #require(search.selected)
        #expect(sidebarMethod.symbol?.name == "updateQueue")
        session.openProjectSearchResult(sidebarMethod)
        await waitUntil { await cursor(renderer) == "2:20" }
        #expect(await cursor(renderer) == "2:20")
        #expect(session.selectedPath == implementation.path)

        session.showSidebarSearch()
        search.query = "Worker.java"
        await waitUntil { search.results.first?.path == "impl/Worker.java" }
        #expect(search.results.map(\.path) == ["impl/Worker.java"])
        #expect(search.selected?.symbol == nil)
    }
}

/// 查找文件里粘 `路径:行号`：行号拆出来、路径照常搜，打开后跳到那一行（新开的、已经开着的、大文件后台读的都要跳到）；
/// ⌘L 的输入条跳到行；Markdown 预览没有行，跳之前切到分栏；复制引用拼出相对项目根的 `路径:行号`。
@Test @MainActor func pastedReferencesOpenAtTheLineAndGoToLineJumpsWithinTheFile() async throws {
    try await withTemporaryDirectory { directory in
        let sources = directory.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("Foo.swift")
        try (1...300).map { "let value\($0) = \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let readme = directory.appendingPathComponent("README.md")
        try (1...80).map { "paragraph \($0)\n" }.joined(separator: "\n").write(to: readme, atomically: true, encoding: .utf8)
        // 超过同步读的上限：后台读完才画，跳到行要等到那一次渲染
        let big = directory.appendingPathComponent("big.txt")
        try (1...40_000).map { "row \($0) of the big file" }.joined(separator: "\n").write(to: big, atomically: true, encoding: .utf8)

        let suite = "agentidea-reference-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let renderer = ContentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        let session = ProjectSession(root: directory, git: nil, renderer: renderer, preferences: ReadingPreferences(defaults: defaults))
        session.setActive(true)
        defer { session.tearDown() }

        session.showSidebarSearch()
        session.projectSearch.query = "./Sources/Foo.swift:150:3"
        await waitUntil { session.projectSearch.results.first?.path == "Sources/Foo.swift" }
        #expect(session.projectSearch.location == SourceLocation(line: 150, column: 3))
        let match = try #require(session.projectSearch.selected)
        session.openProjectSearchResult(match)
        await waitUntil { await cursor(renderer) == "149:2" }
        #expect(await cursor(renderer) == "149:2", "新打开的文件跳到粘进来的行列")

        // 已经是当前标签：不重画，直接跳
        session.openFile(file, pinned: true, at: SourceLocation(line: 10))
        await waitUntil { await cursor(renderer) == "9:0" }
        #expect(await cursor(renderer) == "9:0")

        // ⌘L：格式不对留着输入条提示，对了跳过去并关掉
        session.showGoToLine()
        #expect(session.isGoToLineShown)
        session.setGoToLineText("abc")
        session.submitGoToLine()
        #expect(session.isGoToLineShown && session.goToLineInvalid)
        session.setGoToLineText(" 30:2 ")
        #expect(!session.goToLineInvalid, "改了输入就不再提示错误")
        session.submitGoToLine()
        #expect(!session.isGoToLineShown)
        await waitUntil { await cursor(renderer) == "29:1" }
        #expect(await cursor(renderer) == "29:1")
        let fileTabID = try #require(session.activeTabID)
        #expect(await reference(session, fileTabID) == "Sources/Foo.swift:30")
        #expect(session.referencePath(of: file) == "Sources/Foo.swift", "临时目录的 /var 与 /private/var 也要对上")

        // Markdown 预览没有行：切到分栏再跳
        session.openFile(readme, pinned: true, at: SourceLocation(line: 40))
        await waitUntil { await cursor(renderer) == "39:0" }
        #expect(session.activeTab?.markdownView == .split)
        #expect(await cursor(renderer) == "39:0")
        // 不是当前的标签：用切走时记下的光标
        #expect(await reference(session, fileTabID) == "Sources/Foo.swift:30")

        // 大文件后台读：挂起来，读完画出来的那一次带着跳
        session.openFile(big, pinned: true, at: SourceLocation(line: 30_000))
        #expect(session.activeContent == .loading)
        await waitUntil(20) { await cursor(renderer) == "29999:0" }
        #expect(await cursor(renderer) == "29999:0")
        #expect(session.canGoToLine)
    }
}

/// 对已经是当前标签的文件 `openFile(at:)`：页面直接跳，挂着的行要清掉——否则之后任意一次重画（切主题、换行、切回来）
/// 会再跳一次，还会压掉 diff 的 revealChange 与阅读现场恢复。
@Test @MainActor func directJumpOnTheActiveTabDoesNotLeaveAPendingReveal() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("a.txt")
        try (1...200).map { "line \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let suite = "agentidea-reference-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let renderer = ContentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        let session = ProjectSession(root: directory, git: nil, renderer: renderer, preferences: ReadingPreferences(defaults: defaults))
        session.setActive(true)
        defer { session.tearDown() }

        session.openFile(file, pinned: true)
        await waitUntil { await cursor(renderer) == "0:0" }
        session.openFile(file, pinned: true, at: SourceLocation(line: 120))
        await waitUntil { await cursor(renderer) == "119:0" }
        #expect(await cursor(renderer) == "119:0")
        #expect(renderer.lastPayload?.revealLine == nil, "直接跳不经过 payload")

        // 用户挪了光标再重画：不该被拉回第 120 行
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.setCursor({line: 4, ch: 1}); true")
        session.rerenderActiveTab()
        await waitUntil { renderer.lastPayload?.content.kindName == "code" && renderer.lastPayload?.scrollTop != nil && session.activeTab?.cursor == EditorCursor(line: 4, ch: 1) }
        await waitUntil { await cursor(renderer) == "4:1" }
        #expect(renderer.lastPayload?.revealLine == nil, "重画的 payload 不再带 revealLine")
        #expect(await cursor(renderer) == "4:1")
    }
}

/// 折叠现场随标签走：切到别的文件再切回来（编辑器重建）折叠还在；重画当前标签也在。
@Test @MainActor func foldsFollowTheTabAcrossSwitches() async throws {
    try await withTemporaryDirectory { directory in
        let swift = directory.appendingPathComponent("a.swift")
        try "struct A {\n    func run() {\n        print(1)\n    }\n}\n".write(to: swift, atomically: true, encoding: .utf8)
        let other = directory.appendingPathComponent("b.txt")
        try "other\n".write(to: other, atomically: true, encoding: .utf8)
        let suite = "agentidea-folds-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let renderer = ContentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        let session = ProjectSession(root: directory, git: nil, renderer: renderer, preferences: ReadingPreferences(defaults: defaults))
        session.setActive(true)
        defer { session.tearDown() }
        let folds = "(() => { const node = document.querySelector('.CodeMirror'); return node ? node.CodeMirror.getAllMarks().filter(m => m.__isFold && m.find()).map(m => m.find().from.line).join(',') : 'no editor' })()"
        func current() async -> String { (try? await renderer.webView.evaluateJavaScript(folds)) as? String ?? "" }

        session.openFile(swift, pinned: true)
        await waitUntil { await cursor(renderer) == "0:0" }
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.foldCode({line: 1, ch: 0}, null, 'fold'); true")
        #expect(await current() == "1")

        session.openFile(other, pinned: true)
        await waitUntil { renderer.lastPayload.map { if case .code(let path, _, _, _, _, _, _) = $0.content { return path == other.path } else { return false } } ?? false }
        let swiftTab = EditorTab.id(forFile: swift)
        // 切走时向页面要状态是异步的：等它回来
        await waitUntil { session.tabs.first { $0.id == swiftTab }?.foldState != nil }
        #expect(session.tabs.first { $0.id == swiftTab }?.foldState != nil)
        session.activate(swiftTab)
        await waitUntil { await current() == "1" }
        #expect(await current() == "1", "切回来折叠还在")

        session.rerenderActiveTab()
        await waitUntil { renderer.lastPayload?.foldState != nil }
        await waitUntil { await current() == "1" }
        #expect(await current() == "1")
    }
}
