#!/bin/bash
# 清掉包根目录里散落的编译中间产物（.o / .d / .swiftdeps / .swiftdeps~）。
#
# **它们不是 `swift build` / `swift test` 产生的**——实测：清零后依次跑
# `swift build`、`swift build --build-tests`、`swift test`，包根一个都不多。
# 真正的来源是**编辑器的后台索引服务 `sourcekit-lsp`**：它会用 swiftc 单独编译刚改过的文件，
# 而 `-incremental -c … -emit-dependencies` 正好把这四件套吐到当前目录。
# 所以产物名总是「刚编辑过的那几个文件」，而且删掉之后一编辑又会回来。
# （早先这里写的是「有人在包内手跑 swiftc」，那个判断是错的，照它治标治不好。）
#
# 既然来源不在本仓库控制范围内，就别再让人记着手动清：
# `build_app.sh` 和 `release.sh` 开头都会调它一次。
# `.gitignore` 已经挡住它们进 git，这里管的是「目录别没法看」。
set -euo pipefail
cd "$(dirname "$0")/.."

# 用 find 不用 `ls ./*.o …`：通配符没匹配上时 ls 返回非零，
# 叠上 `set -o pipefail` 和 `set -e`，脚本会在那一行**静默退出**（踩过一次）。
STRAYS=$(find . -maxdepth 1 \
  \( -name '*.o' -o -name '*.d' -o -name '*.swiftdeps' -o -name '*.swiftdeps~' \) \
  | wc -l | tr -d ' ')

if [ "$STRAYS" != "0" ]; then
  find . -maxdepth 1 \
    \( -name '*.o' -o -name '*.d' -o -name '*.swiftdeps' -o -name '*.swiftdeps~' \) \
    -delete
  echo "==> 已清掉包根散落的 $STRAYS 个编译中间产物（编辑器索引服务留下的）"
fi
