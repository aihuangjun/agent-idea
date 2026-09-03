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

# 编辑器：CodeMirror 5（单文件、不用打包）。mode 列表与 index.html 里的 <script> 一一对应。
CM="https://cdn.jsdelivr.net/npm/codemirror@5.65.18"
mkdir -p "$VENDOR/codemirror/addon" "$VENDOR/codemirror/mode"
fetch "$CM/lib/codemirror.js" "codemirror/codemirror.js"
fetch "$CM/lib/codemirror.css" "codemirror/codemirror.css"
for addon in edit/matchbrackets edit/closebrackets selection/active-line merge/merge; do
  fetch "$CM/addon/$addon.js" "codemirror/addon/$(basename "$addon").js"
done
fetch "$CM/addon/merge/merge.css" "codemirror/merge.css"
# merge 插件依赖的 diff 库（要挂成全局 diff_match_patch）
fetch "https://cdnjs.cloudflare.com/ajax/libs/diff_match_patch/20121119/diff_match_patch.js" "diff_match_patch.js"
for mode in xml javascript css htmlmixed jsx vue python shell swift markdown yaml go rust clike sql toml dockerfile properties diff ruby php lua perl r powershell cmake nginx protobuf groovy dart; do
  fetch "$CM/mode/$mode/$mode.js" "codemirror/mode/$mode.js"
done

echo; ls -lh "$VENDOR" | tail -n +2
