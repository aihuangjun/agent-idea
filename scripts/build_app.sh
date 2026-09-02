#!/bin/bash
# 构建 AgentIDEA.app（本地自用）。
#
# 本机只有 Command Line Tools、没有完整 Xcode，bundle 由这里手工组装。
# 用法：scripts/build_app.sh [debug|release] [--no-install]
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/clean_strays.sh

CONFIG="release"
INSTALL=true
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --no-install) INSTALL=false ;;
    *) echo "未知参数：$arg"; exit 1 ;;
  esac
done

APP=".build/AgentIDEA.app"
BUILD_DIR=".build/$CONFIG"

# 版本号的唯一事实来源是 VERSION 文件，由 scripts/release.sh 维护。
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"

# 光有版本号分不出手上这份是哪来的：本地边改边构建的包和已发布的正式包可能都叫 0.1.0。
# 所以再刻上构建时刻和渠道，应用里显示成 0.1.0(202609012310-debug)。
# 渠道只有 scripts/release.sh 会置成 release。键名与 Core/BuildIdentity.swift 里的必须一致。
BUILD_TIMESTAMP="$(date +%Y%m%d%H%M)"
BUILD_CHANNEL="${AGENTIDEA_BUILD_CHANNEL:-debug}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/AgentIDEAApp" "$APP/Contents/MacOS/AgentIDEA"

# SwiftPM 把 Resources/web 打进这个 bundle。名字是「包名_target名」，改 target 名要同步改这里
# 和 DesignSystem/WebResources.swift。
cp -R "$BUILD_DIR/AgentIDEA_DesignSystem.bundle" "$APP/Contents/Resources/"

# 图标由 scripts/make_icon.swift 预先生成并入库，这里只拷贝。
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Agent IDEA</string>
    <key>CFBundleDisplayName</key><string>Agent IDEA</string>
    <key>CFBundleExecutable</key><string>AgentIDEA</string>
    <key>CFBundleIdentifier</key><string>local.agentidea</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>AIBuildTimestamp</key><string>$BUILD_TIMESTAMP</string>
    <key>AIBuildChannel</key><string>$BUILD_CHANNEL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSRequiresAquaSystemAppearance</key><false/>
    <!-- 声明能打开文件夹：访达「打开方式」、拖到 Dock 图标、open -a AgentIDEA <目录> 都走这里 -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# 签名。WKWebView 在完全未签名的 bundle 里可能拒绝启动，这一步不能省。
#
# 优先用本机自签证书「AgentIDEA Local」（scripts/make_signing_identity.sh 造的）：
# 证书签名让应用有稳定身份，系统记住的隐私授权、「允许打开」决定不会随每次构建失效。
# adhoc 签名只有 cdhash，每次构建都变。
# 签完名就别再改 bundle 里的任何文件，否则签名失效、应用被拒绝启动。
SIGN_ID="AgentIDEA Local"
SIGNED=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  if codesign --force --sign "$SIGN_ID" "$APP" >/dev/null 2>&1; then
    SIGNED="yes"
    echo "==> 已用「${SIGN_ID}」签名"
  else
    echo "（用「${SIGN_ID}」签名失败，退回 adhoc）"
  fi
fi
if [ -z "$SIGNED" ]; then
  codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "（ad-hoc 签名失败，通常仍可运行）"
  echo "==> adhoc 签名。想要稳定身份，先跑一次 scripts/make_signing_identity.sh"
fi

# 冒烟检查：前端资源必须在 bundle 里的规范位置（bundle 内部是扁平的，没有 Contents/Resources）。
WEB="$APP/Contents/Resources/AgentIDEA_DesignSystem.bundle/web/index.html"
if [ ! -f "$WEB" ]; then
  echo "构建失败：${APP} 里没有前端资源（缺 ${WEB}）"
  exit 1
fi

# 真的启动一次，确认它不是起来就崩
"$APP/Contents/MacOS/AgentIDEA" >/dev/null 2>&1 &
SMOKE_PID=$!
sleep 3
if kill -0 "$SMOKE_PID" 2>/dev/null; then
  kill "$SMOKE_PID" 2>/dev/null || true
else
  echo "构建失败：应用启动后立刻退出了。单独跑一次看报错："
  echo "    $APP/Contents/MacOS/AgentIDEA"
  exit 1
fi

echo "==> 完成：$(pwd)/${APP}（版本 ${VERSION}(${BUILD_TIMESTAMP}-${BUILD_CHANNEL})）"

$INSTALL || exit 0

# 安装到应用程序目录，否则启动台索引不到——它只看 /Applications 与 ~/Applications。
INSTALL_DIR="/Applications"
[ -w "$INSTALL_DIR" ] || INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR:?}/AgentIDEA.app"
cp -R "$APP" "$INSTALL_DIR/"
echo "==> 已安装到 $INSTALL_DIR/AgentIDEA.app（启动台可搜到 Agent IDEA）"
