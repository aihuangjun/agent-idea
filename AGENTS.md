# AGENTS.md — Agent IDEA 交接约定

## 快速上手

```bash
swift build && swift test
scripts/build_app.sh            # 组装 .build/AgentIDEA.app，签名，冒烟启动，装到 /Applications
scripts/release.sh 0.2.0        # 发布：测试 → 构建 → dmg → releases/ → git commit + push
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
| `DesignSystem` | 深色主题常量、`RenderPayload`（渲染契约的 Swift 事实源）、`ContentRenderer`（WKWebView + render.js 的桥）、通用控件、文件图标、随包分发的 `Resources/web` | Core |
| `Workbench` | `WorkbenchModel`（多个项目、`ReadingPreferences`、共用的 WebView）→ `ProjectSession`（单个项目：树、git 状态、标签）→ `CommitController`（勾选、提交、推送、回滚）/ `ChangeWatcher`（监听 + 去抖）/ `FileContentLoader`（文件与 diff → `TabContent` → `RenderPayload`），加全部视图、窗口、菜单、更新器。除 `AgentIDEARootScene` 外全部 internal | Core, DesignSystem |
| `AgentIDEAApp` | 只有 `@main` | Workbench |

**规矩：**

- **有分支、能出 bug 的逻辑进 `Core` 并配单测**（`GitStatusParser`、`UnifiedDiffParser`、`DiffLayout`、`FlattenedTree`、`GitStatusIndex` 都是这么来的）。UI 层只做状态编排与视图。`ArchitectureTests` 守着 Core 不许 import UI 框架。
- **executable target 里一行逻辑都不放**——SwiftPM 测不了它。
- **`runModal()` 只允许出现在 `WorkbenchView` 选目录那一处**，别处会让测试整体挂住（有架构测试守着）。
- **模型测试用假的 `CommandRunning`**，不真起 git；只有 `realGitEndToEnd` 一条真跑系统 git，找不到 git 时跳过。
- **正文渲染都在 WebView 里**（代码、Markdown、diff、图片）。契约的 Swift 事实源是 `DesignSystem/RenderPayload`（键名只在它的 `encode` 里出现一次），render.js 顶部注释是另一份，改一边必须改另一边；`DesignSystemTests` 会真起 WKWebView 渲染一遍核对。

## 几个容易踩的点

- **`Bundle.module` 不能用**：library target 的资源在打包后找不到。走 `WebResources.bundle`，名字 `AgentIDEA_DesignSystem.bundle` 在 build_app.sh、WebResources.swift 两处硬编码，架构测试核对它们一致。
- **git 命令带 `GIT_OPTIONAL_LOCKS=0`**：否则 `git status` 会写 `.git/index`，被 FSEvents 监听到，再触发一次 status，循环不止。`DirectoryWatcher.isRelevant` 另外把 `.git/` 里除 index/HEAD/refs 之外的噪音都滤掉。
- **`git diff --no-index` 有差异时退出码是 1**，`GitClient.diff` 接受 0 和 1。
- **`--ignored=matching` 而不是默认的 `traditional`**：配合 `--untracked-files=all` 时后者会把 `node_modules` 里几万个文件逐个列出来。
- **目录树照 IDEA 习惯**：单击只选中，双击文件打开（固定标签）、双击目录展开/折叠。预览标签（斜体、复用同一个）只给变更列表单击和 Markdown 链接用。`ProjectSession.show` 是标签的唯一入口。
- **多项目共用一个 WebView**：`ProjectSession` 不认识父对象，依赖全部注入；是否当前由 `WorkbenchModel.activate` 调 `setActive` 写入，只有当前会话才往 WebView 里画。要壳做事（切工具窗口）走 `onRequestToolWindow` 回调。
- **取消不是失败**：`ShellCommand.run` 被取消时抛 `CancellationError`（不是退出码 15）。`refreshGit` 每次会取消上一次，靠这一点区分「被顶掉」和「git 出错」；转圈只由最新那次刷新关掉。
- **双击判定**在 Core 的 `DoubleClickDetector`（纯逻辑，可测），视图持有；模型不 import AppKit，`NSWorkspace` 调用在视图层的 `Desktop`。
- **提交只动勾选的路径**：`git add -A -- <paths>` 再 `git commit --only -- <paths>`，用户在终端里 add 过的别的东西不会被带进去。git 的环境底子是 `LoginShellEnvironment`（登录 shell 抓的），否则 GUI 里 push 找不到 ssh-agent 和凭据助手；同时 `GIT_TERMINAL_PROMPT=0`，绝不让 git 停下来等输入。
- **切标签前要先问 WebView 当前滚动位置**（`rememberScrollOfActiveTab`），否则切回来在顶部。
- **签名**：`build_app.sh` 优先用钥匙串里的「AgentIDEA Local」证书，没有就 adhoc。`release.sh` 会核对产物的指定要求里确实是那张证书（钥匙串锁着时 find-identity 找得到、codesign 却签不成，会静默退回 adhoc）。
- **发布落点两份事实**：`scripts/release.sh` 的 `RELEASES` / `latest.json` 与 `Core/AppDistribution.swift` 的常量必须一致（bash 引不到 Swift）；架构测试核对。
- **更新器访问私有仓库**：token 依次取 `~/.agentidea/github_token`、`GITHUB_TOKEN`/`GH_TOKEN`、`gh auth token`。GUI 应用不继承 shell 的 PATH，所以 gh / git 都按固定路径找（`ExecutableLocator`）。
- **主题色两份**：`Theme.swift` 与 `web/style.css` 顶部变量，架构测试核对几个关键色。

## 本地状态

全部在 `~/.agentidea/`：`recent.json`（最近项目）、`logs/agentidea.log`（滚动日志，菜单「显示日志…」）、`github_token`（可选）。
UserDefaults 里放：工具窗口（显示哪个、宽度）、diff 模式、缩放、自动换行、上次开着的项目列表与当前项目、上次检查更新的时间。
