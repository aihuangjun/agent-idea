#!/bin/bash
# 发布一个版本：更新版本号 → 跑测试 → 构建 → 打 dmg → 落到 releases/ → 提交并推送到 GitHub。
#
# 用法：scripts/release.sh 0.2.0 [--local]
#   --local  只打到 dist/，不动 releases/、不提交（本地验证用）
#
# 历史发布的 app 全部留在 releases/ 目录里（每个版本一个 dmg + 一份 latest.json 指向最新版），
# 应用内「检查更新…」读的就是 GitHub 上这份 latest.json。
# 版本号请先与用户确认——推出去的包收不回来。
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
UPLOAD=true
[ "${2:-}" = "--local" ] && UPLOAD=false

if [ -z "$VERSION" ]; then
  echo "用法: scripts/release.sh <版本号> [--local]    例如: scripts/release.sh 0.2.0"
  echo "当前版本: $(cat VERSION 2>/dev/null || echo '（未设置）')"
  exit 1
fi
if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "版本号要形如 1.2.0（主.次.修订）"
  exit 1
fi

scripts/clean_strays.sh

# 发布必须有变更记录，否则过几个版本就没人说得清每个包里到底有什么。
if ! grep -q "^## $VERSION " CHANGELOG.md 2>/dev/null; then
  echo "CHANGELOG.md 里没有 \"## $VERSION\" 这一节，先补上再发布。"
  exit 1
fi

# 要提交推送，工作区里除了 VERSION/CHANGELOG 之外不能有别的未提交改动，
# 否则「release X」这个提交会把无关改动一起卷进去。
if $UPLOAD && [ -n "$(git status --porcelain | grep -vE ' (VERSION|CHANGELOG.md)$')" ]; then
  echo "发布中止：工作区有未提交的改动，先提交或暂存掉再发布（--local 不受此限）。"
  git status --short
  exit 1
fi

echo "==> 版本 $VERSION"
echo "$VERSION" > VERSION

# 发布前必须全绿，且**核对用例总数**：test target 编译失败时 swift test 照样可能打印通过。
echo "==> swift test"
TEST_LOG="$(mktemp)"
STAGE=""
cleanup() {
  rm -f "$TEST_LOG"
  [ -n "$STAGE" ] && rm -rf "${STAGE:?}"
  return 0
}
trap cleanup EXIT
swift test 2>&1 | tee "$TEST_LOG"

DECLARED=$(grep -rhoE '^[[:space:]]*@Test' Tests | wc -l | tr -d ' ')
EXECUTED=$(grep -oE 'Test run with [0-9]+ test' "$TEST_LOG" | grep -oE '[0-9]+' | tail -1)
if [ -z "$EXECUTED" ]; then
  echo "发布中止：没能从测试输出里读到用例总数，八成是 test target 根本没跑起来。"
  exit 1
fi
if [ "$DECLARED" != "$EXECUTED" ]; then
  echo "发布中止：源码里有 $DECLARED 个 @Test，实际只跑了 $EXECUTED 个。先 rm -rf .build 再试。"
  exit 1
fi
echo "    用例总数核对通过：$EXECUTED"

# 签名身份必须在，缺了会退回 adhoc，已安装用户的系统授权会随之失效。
SIGN_ID="AgentIDEA Local"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "发布中止：这台机器上没有签名身份「${SIGN_ID}」，先跑 scripts/make_signing_identity.sh。"
  echo "    换了机器要导入原来那张证书，重新生成一张也算换身份。"
  exit 1
fi

# 不装到 /Applications：发布构建不该顺手替换掉本机正在用的那个。
AGENTIDEA_BUILD_CHANNEL=release scripts/build_app.sh release --no-install

# 验产物而不是验前置条件：钥匙串锁着时 find-identity 列得出身份、codesign 却签不成，
# build_app.sh 会静默退回 adhoc。这里直接问打出来的 app 的指定要求。
SIGN_HASH="$(security find-identity -v -p codesigning \
  | awk -v id="$SIGN_ID" '$0 ~ id {print $2; exit}' | tr 'A-Z' 'a-z')"
if [ -z "$SIGN_HASH" ] \
  || ! codesign -d -r- .build/AgentIDEA.app 2>&1 | grep -q "certificate leaf = H\"${SIGN_HASH}\""; then
  echo "发布中止：打出来的 app 不是用「${SIGN_ID}」签的。最常见的原因是登录钥匙串被锁上了。"
  codesign -d -r- .build/AgentIDEA.app 2>&1 | tail -1 | sed 's/^/        /'
  exit 1
fi
echo "    产物签名核对通过：certificate leaf = ${SIGN_HASH}"

echo "==> 打包 dmg"
mkdir -p dist
DMG="dist/AgentIDEA-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R .build/AgentIDEA.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<TXT
Agent IDEA $VERSION

安装
1. 把 AgentIDEA 拖到旁边的 Applications 文件夹。
2. 第一次打开：在「访达」的「应用程序」里找到 AgentIDEA，右键 → 打开，再点一次「打开」。
   这个应用没有购买苹果开发者证书，直接双击会被系统拦下来；右键打开只需做一次。

如果提示「已损坏，无法打开」，在「终端」里执行一次：
    xattr -cr /Applications/AgentIDEA.app

以后怎么升级
菜单栏「Agent IDEA → 检查更新…」会自己从 GitHub 取最新版本。
仓库是私有的，本机要先装好 gh 并登录（brew install gh && gh auth login），
或者把一个有 repo 读权限的 token 写进 ~/.agentidea/github_token。

用法
- 欢迎页「打开项目…」选一个工作区目录，或把目录拖进窗口。
- 左侧工具条：项目（⌘1）看目录树，提交（⌘0）看 Agent 改了什么，点一条看 diff。
TXT

hdiutil create -volname "Agent IDEA $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
SIZE=$(stat -f%z "$DMG")
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "    $DMG  ($(du -h "$DMG" | cut -f1))"

if ! $UPLOAD; then
  echo
  echo "==> 本地打包完成（--local，未上传）"
  exit 0
fi

NOTES=$(awk -v ver="## $VERSION " '
  index($0, ver) == 1 { collecting = 1; next }
  collecting && /^## / { exit }
  collecting { print }
' CHANGELOG.md | sed '/^$/d' | head -12)

# 与 Core/AppDistribution.swift 里的目录名、清单名必须一致（bash 引用不到 Swift 常量）。
RELEASES="releases"
mkdir -p "$RELEASES"
cp "$DMG" "$RELEASES/"
MANIFEST="$RELEASES/latest.json"
AI_NOTES="$NOTES" /usr/bin/python3 - "$VERSION" "$(basename "$DMG")" "$SIZE" "$SHA" "$MANIFEST" <<'PY'
import json, sys, datetime, os
version, file_name, size, sha, out = sys.argv[1:6]
json.dump({
    "version": version,
    "fileName": file_name,
    "sizeBytes": int(size),
    "sha256": sha,
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "notes": os.environ.get("AI_NOTES") or None,
}, open(out, "w"), ensure_ascii=False, indent=2)
print(open(out).read())
PY

echo "==> 提交并推送到 GitHub"
git add VERSION CHANGELOG.md "$RELEASES/$(basename "$DMG")" "$MANIFEST"
git commit -m "release $VERSION" -m "$NOTES" >/dev/null
git push

echo
echo "==> 发布完成：$VERSION"
echo "    dmg    $RELEASES/$(basename "$DMG")"
echo "    清单   $MANIFEST"
echo "    装着旧版本的机器在「Agent IDEA → 检查更新…」里就能拿到它；也可以直接把 dmg 发过去。"
