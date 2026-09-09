# SETUP.md — 换一台新 Mac，怎么把这个仓库跑起来

只讲**机器上要装什么**。软件怎么用看 [`README.md`](README.md)，仓库的规矩看 [`AGENTS.md`](AGENTS.md)。

这个仓库**没有任何第三方代码依赖，也不需要任何密钥或配置文件**：`Package.swift` 里一个 `.package(` 都没有，
前端那几个库（markdown-it、highlight.js、mermaid、CodeMirror 5）已经下载进仓库，构建与运行都不联网。
`git clone` 之后要装的只有下面几样——其中三样缺了都**不会给出指向真实原因的报错**：

| 症状 | 真实原因 | 看哪一节 |
|---|---|---|
| `swift test` 报 `no such module 'Testing'`，但 `swift build` 好好的 | 只装了 Command Line Tools | [2](#2-swift-官方-toolchain必装) |
| `build_app.sh` 打印「adhoc 签名」；重新构建后系统授权莫名失效 | 没有本机签名证书 | [3](#3-本机签名证书打包必装) |
| `release.sh` 跑完测试、打完 dmg，最后报 `Author identity unknown` | 仓库没配 git 身份 | [4](#4-git-身份发布必装) |

## 0. 一次性清单

```bash
xcode-select --install                    # 1. Command Line Tools
# 2. Swift 官方 toolchain（见下，装到用户目录，不需要 sudo）
scripts/make_signing_identity.sh          # 3. 本机签名证书（会弹密码框，得自己跑）
git config user.name "…" && git config user.email "…"    # 4. git 身份（发布才用到）
swift build && swift test                 # 5. 自检
```

发布还要一个 `gh`，见[第 6.1 节](#61-发布gh)。

## 1. Command Line Tools（必装）

```bash
xcode-select --install
xcode-select -p          # 应当是 /Library/Developer/CommandLineTools
```

**不要装完整 Xcode**：这个仓库刻意不依赖它（不引入 `.xcodeproj`），而这条约束是靠「机器上根本没有」守住的。
系统要求 macOS 14+。

## 2. Swift 官方 toolchain（必装）

CLT 里其实带着 swift-testing，但 SwiftPM 不去那个位置找它，于是 `swift build` 正常、`swift test` 报
`no such module 'Testing'`。而本仓库的测试全部用 swift-testing（XCTest 的 framework 不在 CLT 的 SDK 里，没有退路）。

```bash
V=6.3.3   # ← 换成 swift --version 看到的版本号，与 CLT 对齐
curl -L -o /tmp/swift-$V.pkg \
  https://download.swift.org/swift-$V-release/xcode/swift-$V-RELEASE/swift-$V-RELEASE-osx.pkg
pkgutil --check-signature /tmp/swift-$V.pkg      # 应当是 Swift Open Source 的 Developer ID，且已公证
installer -pkg /tmp/swift-$V.pkg -target CurrentUserHomeDirectory   # 装到用户目录，不用 sudo
```

再把它放进 PATH **最前面**，这一段加到 `~/.zprofile`：

```sh
# Swift 官方 toolchain（Agent IDEA 需要），详见 <仓库>/SETUP.md
__ai_swift_tc="$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin"
if [ -x "$__ai_swift_tc/swift" ]; then
  path=("$__ai_swift_tc" ${path:#$__ai_swift_tc})
fi
unset __ai_swift_tc
```

三个坑，都踩过：

- **只能换 PATH**，`xcrun --toolchain` / `TOOLCHAINS=` 只换编译器，换不掉 SwiftPM 自己——找不到 Testing 的正是它。
- **写 `.zprofile`，不写 `.zshrc`**（只对交互式 shell 生效，脚本里一律漏掉）**也不写 `.zshenv`**
  （比 `/etc/zprofile` 早，会被 `path_helper` 盖掉）。
- **判据是「排在最前面」，不是「在不在 PATH 里」**：`path_helper` 会把继承来的 PATH 接在系统路径**后面**，
  于是第二层 shell 里它明明在、却排在 `/usr/bin` 之后。上面那句是先摘掉已有的再置顶，摘的动作不能省。

验（**新开终端**）：`which swift` 指向 toolchain；`zsh -lc 'zsh -lc "which swift"'` 套两层也指向它；`swift test` 裸跑。

> **应急**：不想装 toolchain 时可以手工指路，但 `release.sh` 里的 `swift test` 是裸跑的，加不进这些 flag。
> ```bash
> CLT=/Library/Developer/CommandLineTools
> swift test -Xswiftc -F -Xswiftc $CLT/Library/Developer/Frameworks \
>   -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks \
>   -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib
> ```
> 两条 `-rpath` 缺一不可：少第一条链接得上但跑不起来，少第二条卡在 `lib_TestingInterop.dylib`。

## 3. 本机签名证书（打包必装）

```bash
scripts/make_signing_identity.sh                                  # 会弹框要登录密码，得自己跑
security find-identity -v -p codesigning | grep "AgentIDEA Local"
```

`swift build` / `swift test` 不需要它，打包才需要。不装的话 `build_app.sh` **静默**退回 adhoc 签名
（只打印一行提示，退出码仍是 0）：adhoc 的包没有稳定身份，系统只能拿每次构建都变的 cdhash 认它，
给过的授权下次构建后就失效，界面上还看不出来。`release.sh` 因此硬性要求它，且核对的是**产物**的
certificate leaf 而不是「钥匙串里有没有」——钥匙串锁着时 `find-identity` 列得出、`codesign` 却会退回 adhoc。

证书只在本机有效（不是 Apple 签发的，不能对外分发）。换机器时重新生成一张最省事，代价是签名身份变了，
已装旧版的机器升级后系统授权要重给一次；想保持一致就从老机器用「钥匙串访问」导出 `.p12` 再导入。
**除了这张证书，换机器没有别的东西要带。**

## 4. git 身份（发布必装）

```bash
git config user.name "…" && git config user.email "…"    # 不加 --global，只作用于本仓库
```

`release.sh` 里那句 `git commit` 用默认配置，没配的话它会在**跑完测试、打完 dmg 之后**才失败。

## 5. 自检

```bash
swift build
swift test
grep -rhoE '^[[:space:]]*@Test' Tests | wc -l    # 要和 "Test run with N tests" 对上
scripts/build_app.sh                              # 出 .build/AgentIDEA.app 并装到 /Applications
```

**「全绿」要连着声明数一起看**：test target 编译失败时 `swift test` 照样可能打印通过（`release.sh` 有同样的核对）。
`build_app.sh` 末尾那行 `Terminated: 15` 是正常的：启动应用、等 3 秒、再杀掉，确认包没有一起来就崩。
只出包不安装加 `--no-install`。

## 6. 只有某些功能才需要的

### 6.1 发布：`gh`

```bash
brew install gh
gh auth login       # GitHub.com → HTTPS → 浏览器登录；问「用 gh 作为 git 凭据助手」选 Yes
gh auth status      # token scopes 里要有 repo
```

`release.sh` 用它建 Release、传 dmg、校验附件 sha256，第一道门就是 `gh auth status`。
还有三道软性门槛：`CHANGELOG.md` 必须有 `## <版本>` 那一节；工作区除 `VERSION` / `CHANGELOG.md` 外必须干净；
`vX.Y.Z` 这个 tag 与 Release 不能已存在。

### 6.2 其它

| 什么时候 | 要什么 |
|---|---|
| 升级前端依赖 | `scripts/fetch_vendor.sh`，**唯一需要联网的脚本**（curl 拉 jsdelivr），产物提交进仓库 |
| 改图标 | `swift scripts/make_icon.swift` + `iconutil`（系统自带）；`AppIcon.icns` 已入库 |
| 跑性能探针 / 导界面截图 | 环境变量 `AGENTIDEA_PERF=1`、`AGENTIDEA_PERF_ROOT`、`AGENTIDEA_PERF_FILES`、`AGENTIDEA_SNAPSHOT_DIR` |

系统自带的够用，确认一下就行：`for c in git hdiutil codesign security openssl shasum xattr iconutil; do printf "%-10s %s\n" "$c" "$(command -v $c || echo 缺失)"; done`。
`openssl` 用系统的 LibreSSL 即可，`make_signing_identity.sh` 那两条命令实测跑得通，不用 `brew install openssl`。

### 6.3 明确**不需要**装的

Xcode（见第 1 节）、Node / npm（前端库是静态文件，没有 `package.json`）、任何 SwiftPM 第三方依赖、
CocoaPods / Carthage、**任何 API key 或 `.env`**（应用不调用第三方服务）。`gh` 是唯一从 brew 装的，且只发布用。

## 7. 应用运行期要什么（与构建无关）

- **git**：GUI 不继承 shell 的 PATH，按 `/usr/local/bin` → `/opt/homebrew/bin` → `/usr/bin` 找；没有也能开，只是没有 git 功能。
- **登录 shell 的环境**：`Core/LoginShellEnvironment` 抓一次，否则界面里 push 找不到 ssh-agent 和凭据助手。
- **检查更新的凭据**：仓库公开时不需要；私有时按 `~/.agentidea/github_token` → `GITHUB_TOKEN` / `GH_TOKEN` → `gh auth token` 取。
- **本地状态全在 `~/.agentidea/`**（最近项目、日志、包装脚本），删掉就回到首次运行的样子；其余偏好在 UserDefaults。

## 附：故障速查

| 报错 / 现象 | 怎么办 |
|---|---|
| `no such module 'Testing'` | toolchain 没装或没排在 PATH 最前，见[第 2 节](#2-swift-官方-toolchain必装) |
| `Library not loaded: @rpath/Testing.framework/…` | 同上；应急 flag 只加了 `-F`，没加两条 `-rpath` |
| `build_app.sh` 说「adhoc 签名」 | 证书没建，或登录钥匙串锁着，见[第 3 节](#3-本机签名证书打包必装) |
| `release.sh`：`Author identity unknown` | 没配 git 身份，见[第 4 节](#4-git-身份发布必装) |
| `release.sh`：源码里有 N 个 @Test，实际只跑了 M 个 | `rm -rf .build` 再来 |
| 包根冒出 `.o` / `.d` / `.swiftdeps` | 编辑器的 `sourcekit-lsp` 干的，`scripts/clean_strays.sh` 清（两个构建脚本开头会自己调） |
| 使用者说「已损坏，无法打开」 | 首次打开要右键 →「打开」；或 `xattr -cr /Applications/AgentIDEA.app` |
