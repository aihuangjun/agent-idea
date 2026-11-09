#!/bin/bash
# 下载渲染层依赖到 DesignSystem 的 web 资源目录。产物提交进仓库：运行与构建都不联网。
# 只在升级依赖版本时执行（需联网）。highlight.js 的配色是自己写的（hljs-idea.css，深浅两套走 CSS 变量），不在这里。
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
# addon 列表与 index.html 里的 <script>、vendor/codemirror/addon 目录一一对应（ArchitectureTests 核对）；
# merge 例外：全文 diff 改用自写的 diff-review.js，页面不再加载它，留着只为升级时对照。
# 代码折叠：foldcode 是核心，foldgutter 画箭头，*-fold 是各类区块的查找器（mode 的 fold 属性挑用哪个）。
for addon in edit/matchbrackets edit/closebrackets selection/active-line merge/merge fold/foldcode fold/foldgutter fold/brace-fold fold/indent-fold fold/comment-fold fold/markdown-fold fold/xml-fold; do
  fetch "$CM/addon/$addon.js" "codemirror/addon/$(basename "$addon").js"
done
fetch "$CM/addon/merge/merge.css" "codemirror/merge.css"
# merge 插件依赖的 diff 库（要挂成全局 diff_match_patch）
fetch "https://cdnjs.cloudflare.com/ajax/libs/diff_match_patch/20121119/diff_match_patch.js" "diff_match_patch.js"
for mode in xml javascript css htmlmixed jsx vue python shell swift markdown yaml go rust clike sql toml dockerfile properties diff ruby php lua perl r powershell cmake nginx protobuf groovy dart; do
  fetch "$CM/mode/$mode/$mode.js" "codemirror/mode/$mode.js"
done

# 语法着色：web-tree-sitter（WASM 运行时）+ 各语言的语法包（.wasm）与官方高亮查询（.scm）。
# 语言表在 web/syntax.js 的 LANGUAGES，语法包与查询的文件名和这里一一对应（ArchitectureTests 核对三份一致）。
# 自写的查询（IDEA 式的声明 / 调用 / 参数 / 字段 / 全局区分）在 web/syntax/，不是 vendor，升级不要覆盖。
TS_RUNTIME="0.27.1"
TS="vendor/tree-sitter"
mkdir -p "$WEB/$TS/queries"
fetch "https://cdn.jsdelivr.net/npm/web-tree-sitter@$TS_RUNTIME/web-tree-sitter.wasm" "tree-sitter/web-tree-sitter.wasm"
# 只有 ES module 与 CommonJS 两种构建，WebKit 不从 file:// 加载 module 脚本：取 CommonJS 版包一层，挂成 window.TreeSitter
fetch "https://cdn.jsdelivr.net/npm/web-tree-sitter@$TS_RUNTIME/web-tree-sitter.cjs" "tree-sitter/web-tree-sitter.cjs"
{
  printf '/* web-tree-sitter %s 的 CommonJS 构建，由 scripts/fetch_vendor.sh 包一层挂到 window.TreeSitter（生成文件，别手改）。 */\n' "$TS_RUNTIME"
  printf '(function () {\nvar module = { exports: {} }, exports = module.exports;\n'
  cat "$WEB/$TS/web-tree-sitter.cjs"
  printf '\nwindow.TreeSitter = module.exports;\n})();\n'
} > "$WEB/$TS/web-tree-sitter.js"
rm "$WEB/$TS/web-tree-sitter.cjs"
# 「npm 包@版本:wasm 名」。TypeScript 一个包出两个语法（.ts 与 .tsx）。
for grammar in java@0.23.5:java cpp@0.23.4:cpp python@0.25.0:python go@0.25.0:go javascript@0.23.1:javascript typescript@0.23.2:typescript typescript@0.23.2:tsx json@0.24.8:json; do
  package="${grammar%%:*}"
  fetch "https://cdn.jsdelivr.net/npm/tree-sitter-$package/tree-sitter-${grammar##*:}.wasm" "tree-sitter/tree-sitter-${grammar##*:}.wasm"
done
# 「npm 包@版本:查询文件」。C++ 的查询要叠在 C 上、TypeScript 叠在 JavaScript 上，版本取各自语法包依赖的那一版。
for query in java@0.23.5:highlights c@0.23.6:highlights cpp@0.23.4:highlights python@0.25.0:highlights go@0.25.0:highlights javascript@0.23.1:highlights javascript@0.23.1:highlights-jsx javascript@0.23.1:highlights-params typescript@0.23.2:highlights json@0.24.8:highlights; do
  package="${query%%:*}"
  name="${package%@*}"
  mkdir -p "$WEB/$TS/queries/$name"
  fetch "https://cdn.jsdelivr.net/npm/tree-sitter-$package/queries/${query##*:}.scm" "tree-sitter/queries/$name/${query##*:}.scm"
done

echo; ls -lh "$VENDOR" | tail -n +2
