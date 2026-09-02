# Agent IDEA

Agent 开发配套的 IDEA：一个很轻的 macOS 阅读器，用来看 Agent 的工作区（workspace）和 Agent 改了什么。

- **打开项目**：选一个目录（或把目录拖进窗口、`open -a AgentIDEA <目录>`），可同时开多个项目，顶栏切换；重启后自动恢复。
- **目录树 + 阅读**：代码按语言高亮、Markdown 渲染（含 mermaid）、压成一行的 JSON 自动格式化、图片预览。只读，不编辑。
- **Git**：显示当前分支，目录树按 IDEA 的配色标注修改 / 新增 / 删除 / 未跟踪 / 忽略。
- **变更、diff 与提交**：像 IDEA 提交窗口那样列出所有变更，点一条看 diff（并排 / 单列、词级高亮）；勾选要提交的文件，填信息，「提交」或「提交并推送」；右键可回滚或删除。
- **提交历史**（⌘9）：当前分支的提交列表，选中看它改了哪些文件、每个文件的 diff。
- **查找文件**（⇧⌘O）：按文件名 / 路径模糊搜索，回车打开并在树上定位。
- **自动刷新**：项目目录一有变化（Agent 在改），树、git 状态、正在看的文件自动更新。

界面照 IntelliJ 新版深色 UI。

## 构建与运行

本机只需 Command Line Tools（没有 Xcode 也行）。

```bash
swift build                 # 编译
swift test                  # 单测（swift-testing）
scripts/build_app.sh        # 产出 .build/AgentIDEA.app 并装到 /Applications
scripts/build_app.sh --no-install
```

首次构建前建议跑一次 `scripts/make_signing_identity.sh`，造一张本机自签证书让应用有稳定身份。

## 发布

```bash
scripts/release.sh 0.2.0            # 跑测试 → 构建 → 打 dmg → 放进 releases/ → 提交并推送
scripts/release.sh 0.2.0 --local    # 只打到 dist/，不动仓库
```

历史版本都在 [`releases/`](releases/) 目录（每版一个 dmg，`latest.json` 指向最新）。
应用里「Agent IDEA → 检查更新…」读的就是 GitHub 上这份 `latest.json`。仓库是私有的，
更新器需要 GitHub 凭据：本机装好 `gh` 并登录，或把 token 写进 `~/.agentidea/github_token`。

## 结构

见 [`AGENTS.md`](AGENTS.md)。
