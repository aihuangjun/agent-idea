# 选一个本机编译得了 SwiftUI 的 SDK，写进 SDKROOT。由 build_app.sh / release.sh source，
# ~/.zprofile 里也 source 它（见 SETUP.md 第 2 节），裸跑 swift build / swift test 才能过。bash 与 zsh 都能 source。
#
# macOS 27 SDK 起，SwiftUI 的 @State 等不再是属性包装器而是宏，实现在 SwiftUIMacros 插件里——
# 这个插件只随 Xcode 发，CLT 和 swift.org 的官方 toolchain 都没有，于是报
# 「external macro implementation type 'SwiftUIMacros.StateMacro' could not be found」。
# 本仓库刻意不装 Xcode，所以默认 SDK 需要这个插件时，换成 CLT 里还不需要它的最新一版 SDK（CLT 会留着上一版）。
# 已经设了 SDKROOT 的不动。

__agentidea_needs_swiftui_macros() {
  grep -q 'module: "SwiftUIMacros", type: "StateMacro"' \
    "$1/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface" 2>/dev/null
}

__agentidea_has_swiftui_macros() {
  __swift_bin="$(command -v swift 2>/dev/null)"
  for __plugins in "${__swift_bin%/*}/../lib/swift/host/plugins" /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins; do
    [ -e "$__plugins/libSwiftUIMacros.dylib" ] && return 0
  done
  return 1
}

if [ -z "${SDKROOT:-}" ] && command -v xcrun >/dev/null 2>&1; then
  __default_sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [ -n "$__default_sdk" ] && __agentidea_needs_swiftui_macros "$__default_sdk" && ! __agentidea_has_swiftui_macros; then
    # 带小版本号的才是真目录（MacOSX.sdk、MacOSX26.sdk 是指过去的链接），按版本号从新到旧挑
    for __sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.[0-9]*.sdk 2>/dev/null | sort -t X -k 3 -V -r); do
      if ! __agentidea_needs_swiftui_macros "$__sdk"; then
        export SDKROOT="$__sdk"
        break
      fi
    done
    if [ -z "${SDKROOT:-}" ]; then
      echo "sdk_env.sh：默认 SDK（$__default_sdk）的 SwiftUI 要用 Xcode 才有的宏插件，CLT 里也没有更早的 SDK 可换，SwiftUI 代码编不过。" >&2
    fi
  fi
  unset __default_sdk __sdk
fi
unset __swift_bin __plugins
unset -f __agentidea_needs_swiftui_macros __agentidea_has_swiftui_macros
