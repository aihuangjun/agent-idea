#!/bin/bash
# 下载渲染层依赖到 DesignSystem 的 web 资源目录。产物提交进仓库：运行与构建都不联网。
# 只在升级依赖版本时执行（需联网）。highlight.js 的深色主题是自己写的（hljs-idea-dark.css），不在这里。
set -euo pipefail
cd "$(dirname "$0")/.."
WEB="Sources/DesignSystem/Resources/web"
[[ -d "$WEB" ]] || { echo "✗ 找不到渲染层资源目录：$WEB" >&2; exit 1; }
VENDOR="$WEB/vendor"
mkdir -p "$VENDOR"

fetch() {
  local url="$1" out="$2"
  echo "→ $out"
  curl -fsSL --retry 3 "$url" -o "$VENDOR/$out"
}

fetch "https://cdn.jsdelivr.net/npm/markdown-it@14.1.0/dist/markdown-it.min.js" "markdown-it.min.js"
fetch "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.10.0/highlight.min.js" "highlight.min.js"
fetch "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js" "mermaid.min.js"

echo; ls -lh "$VENDOR" | tail -n +2
