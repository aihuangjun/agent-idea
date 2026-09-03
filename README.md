# Agent IDEA

Agent 开发配套的 IDEA：一个很轻的 macOS 工作台，用来看 Agent 的工作区（workspace）、看 Agent 改了什么，顺手改几笔、提交。

- **打开项目**：选一个目录（或把目录拖进窗口、`open -a AgentIDEA <目录>`），可同时开多个项目，顶栏切换；重启后自动恢复上次开着的项目。
- **目录树**：IDEA 习惯（单击选中、双击打开 / 展开），按 git 状态着色（修改蓝、新增绿、删除灰、忽略灰）；右键「删除…」或选中后按 ⌫ 删文件 / 目录（进废纸篓，删前确认）；「定位当前文件」（⌥⌘L）；右键 `.sh` / `.zsh` / `.fish` 脚本「在终端中运行」。
- **编辑**：代码与 Markdown 源码在 CodeMirror 编辑器里改，按语言高亮、括号匹配、自动缩进；行号右侧有相对 HEAD 的变更标记（改过的行蓝条、新增的行绿条，边敲边更新）。⌘S 保存；照 IDEA 的做法自动保存：关标签、切到别的应用、退出时都会写回磁盘，改过没保存的标签有个蓝点。保存保留原文件的编码与行尾。超过 2MB 的文件只读。别人在磁盘上改了你正在改的文件会在标题条提示。
- **阅读**：Markdown 预览 / 源码 / 分栏（左编辑右预览）三种看法，支持 mermaid、任务列表、相对图片；压成一行的 JSON 自动格式化显示；图片预览；自动换行、缩放。
- **后退 / 前进**（⌥← / ⌥→，标题条左侧也有按钮）：按打开顺序在标签间来回。
- **Git**：显示当前分支；变更列表像 IDEA 提交窗口那样列出所有改动，点一条看 diff。**工作区变更的 diff 可以直接编辑**：并排视图左边是 HEAD 只读、右边是工作区文件（chunk 之间有连接带和「撤回这一块」按钮），单列视图就是文件本身的编辑器（新增行带底色、被删的行以只读小块嵌在原位）。勾选要提交的文件，填信息，「提交」或「提交并推送」；右键可回滚、删除。
- **提交历史**（⌘9）：当前分支的提交列表（可翻页），选中看它改了哪些文件、每个文件的 diff（只读）；右键某个文件「回滚这个变更…」，把那次提交对它的改动反向打回工作区，不产生提交。
- **查找文件**（⌘F）：按文件名 / 路径模糊搜索（支持子序列，`amdl` 能找到 `AppModel.swift`），回车打开并在树上定位。
- **自动刷新**：项目目录一有变化（Agent 在改），树、git 状态、正在看的文件自动更新；改过没保存的文件不会被覆盖。

界面照 IntelliJ 新版深色 UI。

### 快捷键

| 操作 | 快捷键 |
|---|---|
| 打开项目 | ⌘O |
| 项目 / 提交 / 提交历史 工具窗口 | ⌘1 / ⌘0 / ⌘9 |
| 查找文件 | ⌘F |
| 在项目视图中定位当前文件 | ⌥⌘L |
| 后退 / 前进 | ⌥← / ⌥→ |
| 保存 / 全部保存 | ⌘S / ⌥⌘S |
| 关闭标签 / 关闭全部标签 / 关闭项目 | ⌘W / ⇧⌘W / ⌥⌘W |
| 上一个 / 下一个标签 | ⇧⌘[ / ⇧⌘] |
| 下一个项目 | ⌘` |
| Markdown 预览 / 源码 / 分栏 | ⇧⌘M |
| 提交 / 推送 | ⌘K / ⇧⌘K |
| 刷新 | ⌘R |
| 放大 / 缩小 / 实际大小 | ⌘= / ⌘- / ⌥⌘0 |
| 删除选中的文件（目录树） | ⌫ |

### 本地状态

全部在 `~/.agentidea/`：`recent.json`（最近项目）、`logs/agentidea.log`（滚动日志，菜单「显示日志…」）、`run/`（「在终端中运行」生成的包装脚本）、`github_token`（可选）。删掉整个目录就回到首次运行的样子。

## 构建与运行

本机只需 Command Line Tools（没有 Xcode 也行）。

```bash
swift build                 # 编译
swift test                  # 单测（swift-testing）
scripts/build_app.sh        # 产出 .build/AgentIDEA.app 并装到 /Applications
scripts/build_app.sh --no-install
```

首次构建前建议跑一次 `scripts/make_signing_identity.sh`，造一张本机自签证书让应用有稳定身份。

正文渲染与编辑都在一个 WKWebView 里，前端依赖（markdown-it、highlight.js、mermaid、CodeMirror 5 及其 merge 插件、diff_match_patch）已下载进仓库的 `Sources/DesignSystem/Resources/web/vendor/`，构建与运行都不联网；只有升级它们时才跑 `scripts/fetch_vendor.sh`。

## 发布

```bash
scripts/release.sh 0.3.0            # 跑测试 → 构建 → 打 dmg → 提交推送 → 打 tag → 建 GitHub Release
scripts/release.sh 0.3.0 --local    # 只打到 dist/，不动仓库
```

历史版本都在仓库的 [Releases](https://github.com/aihuangjun/agent-idea/releases)（tag `vX.Y.Z`，dmg 作附件）。
应用里「Agent IDEA → 检查更新…」读的就是最新那个 Release。仓库是私有的，
更新器需要 GitHub 凭据：本机装好 `gh` 并登录，或把 token 写进 `~/.agentidea/github_token`。

## 结构

见 [`AGENTS.md`](AGENTS.md)。
