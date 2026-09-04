# AGENTS.md — Agent IDEA 交接约定

## 快速上手

```bash
swift build && swift test
scripts/build_app.sh            # 组装 .build/AgentIDEA.app，签名，冒烟启动，装到 /Applications
scripts/release.sh 0.2.0        # 发布：测试 → 构建 → dmg → git commit + push + tag → gh release create
swift scripts/make_icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns \
  && rm -rf Resources/AppIcon.iconset     # 仅改图标时
scripts/fetch_vendor.sh         # 仅升级前端离线依赖时（需联网）
```

构建环境：本机只有 Command Line Tools，没有 Xcode。不要引入 `.xcodeproj`。
测试框架必须用 swift-testing（`import Testing`），XCTest 不在本机 SDK 里。
所有 target 都用 `.swiftLanguageMode(.v5)`：Swift 6 严格并发下 WebKit/AppKit 的回调会满屏报错。

## 分层（由 Package.swift 的 target 边界强制）

| target | 职责 | 依赖 |
|---|---|---|
| `Core` | 纯逻辑：版本/构建标识、日志、命令执行、git status/diff 解析、diff 排版、目录树扁平化、语言映射、文本解码、FSEvents 监听、GitHub 分发地址 | 无 |
| `DesignSystem` | 深色主题常量、`RenderPayload`（渲染契约的 Swift 事实源）、`ContentRenderer`（WKWebView + render.js 的桥，含编辑器状态往返）、通用控件（`PlainTextEditor` 等）、文件图标、随包分发的 `Resources/web`（render.js + vendor：markdown-it、highlight.js、mermaid、CodeMirror 5） | Core |
| `Workbench` | `WorkbenchModel`（多个项目、`ReadingPreferences`、共用的 WebView）→ `ProjectSession`（单个项目：树、git 状态、标签）→ `CommitController`（勾选、提交、推送、回滚）/ `HistoryController`（`git log` 分页、选中提交的文件列表）/ `FileSearchController`（文件搜索索引与查询）/ `ChangeWatcher`（监听 + 去抖）/ `FileContentLoader`（文件与 diff → `TabContent` → `RenderPayload`），加全部视图、窗口、菜单、更新器。除 `AgentIDEARootScene` 外全部 internal | Core, DesignSystem |
| `AgentIDEAApp` | 只有 `@main` | Workbench |

**规矩：**

- **有分支、能出 bug 的逻辑进 `Core` 并配单测**（`GitStatusParser`、`UnifiedDiffParser`、`DiffLayout`、`FlattenedTree`、`GitStatusIndex` 都是这么来的）。UI 层只做状态编排与视图。`ArchitectureTests` 守着 Core 不许 import UI 框架。
- **executable target 里一行逻辑都不放**——SwiftPM 测不了它。
- **`runModal()` 只允许出现在 `WorkbenchView` 选目录那一处**，别处会让测试整体挂住（有架构测试守着）。
- **模型测试用假的 `CommandRunning`**，不真起 git；只有 `realGitEndToEnd` 一条真跑系统 git，找不到 git 时跳过。
- **正文渲染与编辑都在 WebView 里**（代码、Markdown、diff、图片；可编辑的代码 / Markdown 源码用 CodeMirror 5，只读的走静态视图）。契约的 Swift 事实源是 `DesignSystem/RenderPayload`（键名只在它的 `encode` 里出现一次），render.js 顶部注释是另一份，改一边必须改另一边；`DesignSystemTests` 会真起 WKWebView 渲染一遍核对。

## 几个容易踩的点

- **`Bundle.module` 不能用**：library target 的资源在打包后找不到。走 `WebResources.bundle`，名字 `AgentIDEA_DesignSystem.bundle` 在 build_app.sh、WebResources.swift 两处硬编码，架构测试核对它们一致。
- **git 命令带 `GIT_OPTIONAL_LOCKS=0`**：否则 `git status` 会写 `.git/index`，被 FSEvents 监听到，再触发一次 status，循环不止。`DirectoryWatcher.isRelevant` 另外把 `.git/` 里除 index/HEAD/refs 之外的噪音都滤掉。
- **`git diff --no-index` 有差异时退出码是 1**，`GitClient.diff` 接受 0 和 1。
- **`--ignored=matching` 而不是默认的 `traditional`**：配合 `--untracked-files=all` 时后者会把 `node_modules` 里几万个文件逐个列出来。
- **目录树照 IDEA 习惯**：单击只选中，双击文件打开（固定标签）、双击目录展开/折叠。预览标签（斜体、复用同一个）只给变更列表 / 历史文件列表单击和 Markdown 链接用。`ProjectSession.show` 是标签的唯一入口。
- **列表点击一律用 `PressGesture`（`.onPress`）而不是 `onTapGesture`**：按下就选中，松开才结算双击。`onTapGesture` 要等 mouseUp，用户感觉「点了要等一下」。目录树的箭头区域按横坐标判断，不给箭头单独套手势（嵌套手势会互相等待）。
- **性能探针**：`Tests/WorkbenchTests/PerformanceProbe.swift`、`Tests/DesignSystemTests/LayoutProbe.swift`，只在 `AGENTIDEA_PERF=1` 时跑，往屏幕外的窗口合成鼠标事件量点击→选中、打开→渲染的耗时（`AGENTIDEA_PERF_FILES` 指定文件）。离屏窗口不会合成/绘制，量不到画到屏幕那一段。往离屏窗口合成点击前要先 `FirstMouse.enableGlobally()`（非活动窗口的第一下点击默认只负责激活窗口，SwiftUI 的行不会响应）；要看画出来的样子用 `NSView.cacheDisplay(in:to:)` 采样位图（`ChangesViewSelectionTests` 这么核对行的高亮，位图色值经色彩空间转换会整体偏移，别按精确色比）。
- **代码视图的 DOM 有两种**（render.js `codeView()`）：不换行时是「一个 sticky 行号栏 + 行列表」——原先每行一个 sticky `<td>`，WebKit 给每个 sticky 元素单独建合成层，几千行的文件切进来卡几百毫秒；自动换行时每行自带行号（折行后才对得齐）。所以 `setWrap` 对代码要重画一次。render.js 每次画完 post `rendered`（含毫秒数），超过 300ms 记日志。
- **小文件同步读**（`ProjectSession.synchronousReadLimit`，512KB）：点击的同一回合里读完画出来，没有「加载中」那一帧；大文件才走后台 + 延迟 200ms 出现的转圈。git 刷新的转圈同样延迟 300ms（`refreshGit`），所以测试里别拿 `isRefreshingGit` 当「刷新结束」的信号。
- **提交历史**：`GitClient.log` 用 `-z` + `%x1f` 分隔字段（`GitLogParser.format`），文件列表用 `diff --name-status -z --find-renames <第一个父提交|空树> <hash>`。回滚历史里的一个变更是 `GitClient.revert`：`diff --binary base hash -- path` 写到临时文件再 `apply --reverse`（我们不开 stdin），只动工作区。`GitBranch.headOID` 变了才重拉（`apply(snapshot)`），工作区改动不触发。历史 diff 标签是 `EditorTab.Kind.commitDiff`，`tab.change` 只指工作区变更（git 刷新据此关标签），要两种都拿用 `tab.diffChange`。
- **文件搜索**：索引（`FileIndexer`）在第一次打开搜索时于后台建，`ChangeWatcher` 报的变化增量套用（`applyChanges`），忽略集变了才整个重建（`markStale`）；跳过 git 忽略的路径（闭包只捕获值类型的 `GitStatusIndex`，能进后台）。打分在 `FileSearch`，纯逻辑有单测。
- **多项目共用一个 WebView**：`ProjectSession` 不认识父对象，依赖全部注入；是否当前由 `WorkbenchModel.activate` 调 `setActive` 写入，只有当前会话才往 WebView 里画。要壳做事（切工具窗口）走 `onRequestToolWindow` 回调。`ContentWebView` 返回的是自己的容器、WebView 挂在容器里（切项目时新旧 representable 争同一个 NSView 会把它摘空），`WebViewHostingTests` 离屏挂整个 WorkbenchView 核对。
- **排查正文空白**：先看日志。`ContentRenderer.send` 每次 render 记一行（种类、字节数），页面里没抓住的 JS 异常经 `error` 消息记成 warn。后台启动（`open -g`）的实例窗口不可见或在别的 Space 时 WebKit 不绘制，窗口截图会是空的——那不是 bug，用 `Tests/DesignSystemTests` 的离屏渲染核对。
- **取消不是失败**：`ShellCommand.run` 被取消时抛 `CancellationError`（不是退出码 15）。`refreshGit` 每次会取消上一次，靠这一点区分「被顶掉」和「git 出错」；转圈只由最新那次刷新关掉。
- **双击判定**在 Core 的 `DoubleClickDetector`（纯逻辑，可测），视图持有；模型不 import AppKit，`NSWorkspace` 调用在视图层的 `Desktop`。
- **提交只动勾选的路径**：磁盘上有的 `git add -A -- <paths>`，磁盘上没有的（删除、重命名的原路径）`git rm --cached --ignore-unmatch -- <paths>`，再 `git commit --only -- <paths>`，用户在终端里 add 过的别的东西不会被带进去。不能全交给 `add`：Agent 已经 `git mv`/`git rm` 过的路径既不在磁盘也不在索引里，`add` 会报 pathspec did not match（0.3.0 修的）。git 的环境底子是 `LoginShellEnvironment`（登录 shell 抓的），否则 GUI 里 push 找不到 ssh-agent 和凭据助手；同时 `GIT_TERMINAL_PROMPT=0`，绝不让 git 停下来等输入。
- **删除一律进废纸篓**（`Core/Trash.move`），不 rm：目录树的「删除…」/⌫ 走 `ProjectSession.delete`（关标签并**丢弃草稿**、挪选中、刷新），变更列表的走 `CommitController.delete`（任何还在磁盘上的变更都能删，`.deleted` 的不行）。要确认的危险操作统一用 `DestructiveConfirmation` + `.destructiveConfirmation()`；变更行的文件名/目录/状态字是 `ChangeFileLabel`，变更列表与历史共用。
- **重命名**（⇧F6 / 右键）：纯逻辑在 `Core/FileRename`（名字校验、初始选中扩展名之前那一段、路径改写），流程在 `ProjectSession.rename`：先 `saveAll`（IDEA 重构前也先保存），在仓库里且不是未跟踪文件的先 `git mv`（status 才显示成一条重命名），git 拒绝（`GitClient.refusedBecauseUntracked`：未跟踪、目录里没有已跟踪文件、目录只改大小写时的 Invalid argument）才退回 `FileManager.moveItem`，index.lock 被占这类失败直接报 banner——退回的话文件搬了索引没动，status 会变成「删除 + 未跟踪」；然后 `didRename` 把文件标签换成新 id（内容重读、基线 / 草稿 / 光标带过去）、关掉旧路径的工作区 diff 标签、`NavigationHistory.replace`、`FlattenedTree.rename`（展开状态换路径、旧缓存作废）、`search.applyChanges`、刷 git。`loadFile` 已有基线时不再取（否则重命名后 `git show HEAD:新路径` 会把带过来的基线清掉）；`fetchBaseText` 对重命名过的变更取 `originalPath`。
- **要抢焦点的单行输入框用 `DesignSystem/FocusedTextField`**（NSTextField 直包）：SwiftUI `TextField` 的 `@FocusState` 在 WKWebView 是第一响应者时拿不到焦点（⌘F 之后光标还在编辑器里，0.5.0 修的）。它挂上窗口就 `makeFirstResponder`，`focusRequests` 变一次再抢一次，能指定初始选中范围；↑ ↓ 回车 Esc 经 `onKey` 回调。搜索框、重命名对话框都用它。功能键常量在 `Views/FunctionKeys.swift`（`KeyEquivalent.f6/.f7`）。
- **提交信息框是 `DesignSystem/PlainTextEditor`**（NSTextView 直包）：占位符由文本视图用同一套排版画在第一行文字的原点上，不是叠一个 `Text` 猜位置；`PlainTextEditorTests` 核对原点一致。
- **切标签、重画当前标签前要先问 WebView 的状态**（`rememberScroll(of:)` → `ContentRenderer.currentState`：滚动位置、编辑器里的全文、光标），否则切回来在顶部、编辑器里还没送过来的那几笔（`edited` 消息停手 300ms 才发）会丢。`renderActiveTab()` 本身不问，调用方负责。
- **文档与标签是两回事**：文件标签的 id（`file:<绝对路径>`）同时是**文档 id**，`contents[文档 id]` 是文件内容、`baseTexts[文档 id]` 是 HEAD 基线、草稿也按文档 id 存；工作区 diff 标签通过 `documentID(for:)` 指向同一个文档（已删除的变更没有）。文档只在最后一个用它的标签关掉时释放（`finishClosing`）。可编辑的 diff 是 `TabContent.editableDiff(documentID:)`，`renderActiveTab` 用 `FileContentLoader.editableDiff` 组 payload（`edit: DiffEdit`，不送 rows）；render.js 并排用 CodeMirror 的 merge 插件（vendor 里多了 `addon/merge.js`、`merge.css`、`diff_match_patch.js`），单列是编辑器 + 行底色 + `addLineWidget` 的被删行小块。git 刷新时变更种类没变的可编辑 diff 不重载（重载会重建编辑器）。
- **编辑与保存**：规则在 `DraftStore`（值类型：草稿字典、可编辑判定、行尾归一比较、按原编码/原行尾原子写盘），时机在 `ProjectSession`（什么时候向编辑器要文字、写完刷 git、删文件时丢弃草稿）。`applyEdit` 只认可编辑的标签，一改预览标签就固定。保存时机照 IDEA：⌘S、关标签、切到别的应用（`applicationDidResignActive`）、退出、关项目，不弹「要不要保存」；`saveAll` 先同步写已有草稿再向编辑器补要一次，退出时只有同步那一段来得及。改过的标签磁盘上再变不重读，标题条提示。超过 `DraftStore.editableLimit`（2MB）只读。菜单项的启用状态只观察 workbench，所以 `WorkbenchModel.activate` 把当前会话的 `objectWillChange` 转发出去。
- **编辑器的行变更标记**（行号右侧蓝/绿条）与 **HEAD** 比，不是与已保存文件比：`ProjectSession.fetchBaseText` 在打开文件、HEAD 变化时 `git show HEAD:path`，存进 `baseTexts`，随 payload 的 `base` 送进去；晚到的走 `ContentRenderer.setBase`（不重画编辑器）。行级 diff 在 render.js（Myers，掐头去尾后超过 20000 行或 D 超过 3000 就不画），一段改动里前 min(删, 增) 行算「改过」、其余算「新增」，删除不画。
- **后退 / 前进**是 `Core/NavigationHistory`（纯值类型，元素是标签 id），`show` / `activate` 记录，`closeTab` 抹掉，`goBack` / `goForward` 期间 `isNavigating` 挡住记录。快捷键 ⌥← / ⌥→ 是用户定的（与他的 IDEA 键位一致）：菜单项管焦点在别处的情况，焦点在编辑器里时 render.js 的 `extraKeys` 把 Alt-Left/Right 转成 `navigate` 消息（否则 CodeMirror 会当成按词移动），不要改回 ⌘⌥。
- **上一处 / 下一处变更**（⇧F7 / F7）全在 render.js 的 `navigateChange`：编辑器按光标行找（并排可编辑 diff 问 MergeView 的 `leftChunks()`，其余用同一份 `lineChanges` 分组），只读 diff 表格按 `tr.changed` 的连续段落跳。页面里的 F7 自己处理并 `preventDefault`，WebKit 只把页面没处理的键交给应用菜单，所以菜单项（`KeyEquivalent` 用 `NSF7FunctionKey` 字符构造）与页面不会各跳一次。`ProjectSession.canNavigateChanges` 决定标题条箭头与菜单项是否出现；页面在渲染完、跳转后、光标移动、改动、滚动时 post `changes { hasPrevious, hasNext }`，存到 `ProjectSession.changePosition`，到头的方向灰掉。
- **列表行的「当前 / 选中」要作为值从父视图传进去**（`ChangeRow.isActive`、`CommitFileRow.isActive`、树的 `isSelected`），别在行里读 `session.activeTab`：行视图的存储属性没变 SwiftUI 就不重画它，上一行的高亮会留着（0.3.0 的变更列表 bug）。
- **在终端中运行**：`Core/TerminalLauncher` 生成 `~/.agentidea/run/<名字>-<hash>.command`（进目录、跑脚本、打印退出码），视图层 `Desktop.runInTerminal` 用 `NSWorkspace.open` 交给终端。不走 AppleScript（要自动化权限）。
- **签名**：`build_app.sh` 优先用钥匙串里的「AgentIDEA Local」证书，没有就 adhoc。`release.sh` 会核对产物的指定要求里确实是那张证书（钥匙串锁着时 find-identity 找得到、codesign 却签不成，会静默退回 adhoc）。
- **发布走 GitHub Releases**：`scripts/release.sh` 打 tag `v$VERSION`、`gh release create` 上传 dmg；应用读 `releases/latest` 接口，用附件的 `digest`（sha256）校验下载。tag 前缀在脚本与 `Core/AppDistribution.swift` 各有一份（bash 引不到 Swift），架构测试核对。私有仓库下载附件要走附件的 API 地址 + `Accept: application/octet-stream`，302 到对象存储时必须摘掉 Authorization（`Updater.RedirectSanitizer`）。
- **更新器访问私有仓库**：token 依次取 `~/.agentidea/github_token`、`GITHUB_TOKEN`/`GH_TOKEN`、`gh auth token`。GUI 应用不继承 shell 的 PATH，所以 gh / git 都按固定路径找（`ExecutableLocator`）。
- **主题色两份**：`Theme.swift` 与 `web/style.css` 顶部变量，架构测试核对几个关键色。

## 本地状态

全部在 `~/.agentidea/`：`recent.json`（最近项目）、`logs/agentidea.log`（滚动日志，菜单「显示日志…」）、`run/`（在终端中运行的包装脚本）、`github_token`（可选）。
UserDefaults 里放：工具窗口（显示哪个、宽度）、diff 模式、缩放、自动换行、上次开着的项目列表与当前项目、上次检查更新的时间。
