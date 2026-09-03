/* Agent IDEA 正文渲染。
 *
 * Swift 侧主要做一件事：window.ide.render(payload)。Swift 那边的事实源是 DesignSystem/RenderPayload.swift，
 * 改一边必须改另一边。每个 payload 都带 scrollTop（渲染完滚到哪）和 wrap（代码是否自动换行），kind 决定画什么：
 *   code     { path, text, language, editable, cursor?: {line, ch}, base?: HEAD 里的内容 }
 *   markdown { path, markdown, docDir, view: "preview" | "source" | "split", editable, cursor?, base? }
 *   image    { path, url, sizeText }
 *   diff     { path, language, mode: "side" | "unified", rows, binary, empty, added, removed, emptyReason }
 *            或可编辑的 { path, language, mode, edit: { oldText, newText, filePath, cursor? } }：左/上是基线只读，右/下是工作区可改
 *   message  { title, detail }
 * editable 为真的 code / markdown 源码用 CodeMirror 编辑器画，否则是只读的静态视图。
 * 宿主还会问 window.ide.getState() → { scrollTop, text: 编辑器里的全文或 null, cursor }，切标签前拿走最新文字；
 * 基线是异步取的，到了就 window.ide.setBase({ path, base })，编辑器在行号右侧画「改过（蓝）/ 新增（绿）」的标记（IDEA 的 gutter）。
 * path：diff 用来显示（summary 那一行）；编辑器发 edited 消息时带上它，宿主据此找到是哪个文件。
 * 往 Swift 发消息一律 post({type, ...})：ready / rendered / openExternal / openPath / edited { path, text } /
 * navigate { direction: "back" | "forward" }（编辑器里按 ⌥← / ⌥→：这两个键在应用里是后退/前进，不给 CodeMirror 按词移动）。
 * 自有代码不写内联事件处理器（CSP 不给 unsafe-inline）。
 */
(function () {
  "use strict";

  const root = document.getElementById("root");
  const HIGHLIGHT_LIMIT = 600 * 1024;   // 超过这个体积不做语法高亮，纯文本也照样能看
  const AUTO_DETECT_LIMIT = 64 * 1024;  // 语言未知时只对小文件做自动识别，大文件太慢
  const WORD_DIFF_LIMIT = 2000;         // 单行超过这个长度不做词级对比
  const LINE_HIGHLIGHT_LIMIT = 2000;    // diff 里单行超过这个长度不做语法高亮
  let current = null;                   // 最近一次 payload：Markdown 相对链接要用它的 docDir，setWrap 要改它的 wrap

  function post(message) {
    try { window.webkit.messageHandlers.ide.postMessage(message); } catch (_) { /* 测试页里没有宿主 */ }
  }

  // 页面里没抓住的异常告诉宿主记日志，不然一片空白谁也不知道为什么
  window.addEventListener("error", (event) => {
    post({ type: "error", message: String(event.message || event.error || "unknown"), where: `${event.filename || ""}:${event.lineno || 0}` });
  });

  function escapeHTML(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function resolveLanguage(language, text) {
    if (language && hljs.getLanguage(language)) return language;
    if (!language && text && text.length <= AUTO_DETECT_LIMIT) {
      const guess = hljs.highlightAuto(text, ["javascript", "typescript", "python", "json", "xml", "yaml", "bash", "swift", "java", "go", "rust", "ini", "markdown"]);
      if (guess.relevance >= 8 && guess.language) return guess.language;
    }
    return null;
  }

  /* hljs 的 span 可以跨行（多行注释、多行字符串）。按行切开时要把打开着的 span 在行尾关掉、行首重开。 */
  function splitHighlighted(html) {
    const lines = [];
    let open = [];
    let buffer = "";
    const tokenizer = /<span class="([^"]*)">|<\/span>|\n|[^<\n]+|</g;
    let match;
    while ((match = tokenizer.exec(html)) !== null) {
      const token = match[0];
      if (token === "\n") {
        buffer += "</span>".repeat(open.length);
        lines.push(buffer);
        buffer = open.map((cls) => `<span class="${cls}">`).join("");
      } else if (token === "</span>") {
        if (open.length) { open.pop(); buffer += token; }
      } else if (token.startsWith("<span")) {
        open.push(match[1]);
        buffer += token;
      } else {
        buffer += token;
      }
    }
    buffer += "</span>".repeat(open.length);
    lines.push(buffer);
    return lines;
  }

  function highlightLines(text, language) {
    const raw = text.split("\n");
    if (raw.length && raw[raw.length - 1] === "") raw.pop();
    if (!language || text.length > HIGHLIGHT_LIMIT) return raw.map(escapeHTML);
    try {
      const html = hljs.highlight(text, { language, ignoreIllegals: true }).value;
      const lines = splitHighlighted(html);
      if (lines.length && lines[lines.length - 1] === "" && lines.length === raw.length + 1) lines.pop();
      return lines.length === raw.length ? lines : raw.map(escapeHTML);
    } catch (_) {
      return raw.map(escapeHTML);
    }
  }

  function highlightOne(text, language) {
    if (!language || text.length > LINE_HIGHLIGHT_LIMIT) return escapeHTML(text);
    try { return hljs.highlight(text, { language, ignoreIllegals: true }).value; } catch (_) { return escapeHTML(text); }
  }

  /* ---------- 代码 ---------- */

  /* ---------- 编辑器（CodeMirror 5） ---------- */

  let editor = null;       // 当前的 CodeMirror 实例（可编辑那一侧）；换别的内容时随 DOM 一起丢掉
  let mergeView = null;    // 并排可编辑 diff 时的 MergeView（editor 是它右边那个）
  let editTimer = null;    // 停手之后再发 edited，别每敲一个键就把整份文本送过去
  const EDIT_DEBOUNCE = 300;

  /* 正在编辑的是哪个文件：普通编辑器是 payload.path，可编辑 diff 是 edit.filePath。 */
  function editedPath() {
    if (!current) return "";
    return current.edit ? current.edit.filePath : (current.path || "");
  }

  // highlight.js 的语言名（Core/Language.swift 给的）→ CodeMirror 的 mode。表里没有的按纯文本编辑，照样能改。
  const CM_MODES = {
    javascript: "javascript", typescript: "text/typescript", json: { name: "javascript", json: true },
    python: "python", bash: "shell", swift: "swift", markdown: { name: "markdown", highlightFormatting: true },
    yaml: "yaml", xml: "xml", css: "css", scss: "text/x-scss", less: "text/x-less", go: "go", rust: "rust",
    java: "text/x-java", kotlin: "text/x-kotlin", c: "text/x-csrc", cpp: "text/x-c++src", objectivec: "text/x-objectivec",
    csharp: "text/x-csharp", scala: "text/x-scala", sql: "sql", ini: "properties", dockerfile: "dockerfile", diff: "diff",
    ruby: "ruby", php: "php", lua: "lua", perl: "perl", r: "r", powershell: "powershell", cmake: "cmake",
    protobuf: "protobuf", groovy: "groovy", dart: "dart", nginx: "nginx",
  };

  function editorMode(language, path) {
    // 几个 hljs 只有一个名字、CodeMirror 却分得更细的，按扩展名再挑一次
    const ext = (path || "").toLowerCase().split(".").pop();
    if (ext === "html" || ext === "htm") return "htmlmixed";
    if (ext === "vue") return "vue";
    if (ext === "jsx") return "jsx";
    if (ext === "tsx") return "text/typescript-jsx";
    if (ext === "toml") return "toml";
    return CM_MODES[language] || null;
  }

  function postEdited() {
    if (!editor || !current) return;
    post({ type: "edited", path: editedPath(), text: editor.getValue() });
  }

  /* ---------- 相对 HEAD 的行变更标记 ---------- */

  const CHANGE_GUTTER = "cm-changes";
  const DIFF_LINE_LIMIT = 20000;   // 掐掉头尾相同的部分之后还剩这么多行就不算了
  const DIFF_EDIT_LIMIT = 3000;    // Myers 的 D 超过这个数（改动太大）也不算了

  /* 行级 Myers diff。返回 [{ dels, adds: [新文本里的行号…] }]，一个元素是一段连续的改动；
   * 掐头去尾之后剩下的部分超出上限返回 null（太大就不画标记）。 */
  function lineChanges(oldLines, newLines) {
    let start = 0;
    const maxStart = Math.min(oldLines.length, newLines.length);
    while (start < maxStart && oldLines[start] === newLines[start]) start++;
    let endA = oldLines.length, endB = newLines.length;
    while (endA > start && endB > start && oldLines[endA - 1] === newLines[endB - 1]) { endA--; endB--; }
    const a = oldLines.slice(start, endA), b = newLines.slice(start, endB);
    const n = a.length, m = b.length;
    if (n > DIFF_LINE_LIMIT || m > DIFF_LINE_LIMIT) return null;
    if (!n && !m) return [];
    if (!n) return [{ dels: 0, adds: b.map((_, i) => start + i), oldStart: start, newStart: start }];
    if (!m) return [{ dels: n, adds: [], oldStart: start, newStart: start }];

    const max = Math.min(n + m, DIFF_EDIT_LIMIT);
    const offset = max + 1;
    const v = new Int32Array(2 * offset + 1);
    const trace = [];
    let found = false;
    for (let d = 0; d <= max && !found; d++) {
      trace.push(v.slice());
      for (let k = -d; k <= d; k += 2) {
        let x = (k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1;
        let y = x - k;
        while (x < n && y < m && a[x] === b[y]) { x++; y++; }
        v[offset + k] = x;
        if (x >= n && y >= m) { found = true; break; }
      }
    }
    if (!found) return null;

    // 回溯出编辑步骤（倒序），"eq" 是一段相同的行，用来切分改动段
    const steps = [];
    let x = n, y = m;
    for (let d = trace.length - 1; d >= 0; d--) {
      const vd = trace[d];
      const k = x - y;
      const prevK = (k === -d || (k !== d && vd[offset + k - 1] < vd[offset + k + 1])) ? k + 1 : k - 1;
      const prevX = vd[offset + prevK], prevY = prevX - prevK;
      if (x > prevX && y > prevY) steps.push(["eq", Math.min(x - prevX, y - prevY)]);
      while (x > prevX && y > prevY) { x--; y--; }
      if (d > 0) {
        if (x === prevX) { steps.push(["add", y - 1]); y = prevY; } else { steps.push(["del"]); x = prevX; }
      }
    }
    steps.reverse();
    // 顺着走一遍，记下每段改动在旧文本 / 新文本里从哪一行开始（单列 diff 要拿旧文本里被删的行来显示）
    const groups = [];
    let group = null;
    let ox = 0, ny = 0;
    for (const step of steps) {
      if (step[0] === "eq") { group = null; ox += step[1]; ny += step[1]; continue; }
      if (!group) { group = { dels: 0, adds: [], oldStart: start + ox, newStart: start + ny }; groups.push(group); }
      if (step[0] === "del") { group.dels++; ox++; } else { group.adds.push(start + step[1]); ny++; }
    }
    return groups;
  }

  /* 把一段改动分成「改过」与「新增」：删了 d 行、加了 a 行 → 前 min(d, a) 行是改过的，多出来的是新增。 */
  function classifyChanges(groups) {
    const marks = new Map();
    for (const group of groups) {
      group.adds.forEach((line, index) => marks.set(line, index < group.dels ? "modified" : "added"));
    }
    return marks;
  }

  function changeMarker(kind) {
    const node = document.createElement("div");
    node.className = "cm-change-mark " + kind;
    return node;
  }

  function updateChangeMarkers() {
    if (!editor || !current) return;
    editor.operation(() => {
      editor.clearGutter(CHANGE_GUTTER);
      if (typeof current.base !== "string") return;
      const groups = lineChanges(current.base.split("\n"), editor.getValue().split("\n"));
      if (!groups) return;
      for (const [line, kind] of classifyChanges(groups)) editor.setGutterMarker(line, CHANGE_GUTTER, changeMarker(kind));
    });
  }

  /* 所有可编辑视图共用的编辑器选项。 */
  function editorOptions(mode, extra) {
    return Object.assign({
      mode,
      theme: "idea-dark",
      lineNumbers: true,
      lineWrapping: !!(current && current.wrap),
      indentUnit: 4,
      tabSize: 4,
      indentWithTabs: false,
      matchBrackets: true,
      autoCloseBrackets: true,
      styleActiveLine: true,
      viewportMargin: 20,
      extraKeys: {
        Tab: (cm) => (cm.somethingSelected() ? cm.indentSelection("add") : cm.execCommand("insertSoftTab")),
        "Shift-Tab": "indentLess",
        // 应用级的后退 / 前进；焦点在编辑器里时由这里转发，别让 CodeMirror 当成按词移动
        "Alt-Left": () => post({ type: "navigate", direction: "back" }),
        "Alt-Right": () => post({ type: "navigate", direction: "forward" }),
      },
    }, extra || {});
  }

  /* 改动停手 300ms 后：把全文发给宿主、重算标记；onChange 给分栏预览 / diff 装饰用（它们自己再去抖）。 */
  function attachEditorEvents(onChange) {
    editor.on("change", () => {
      if (editTimer) clearTimeout(editTimer);
      editTimer = setTimeout(() => { editTimer = null; postEdited(); updateChangeMarkers(); }, EDIT_DEBOUNCE);
      if (onChange) onChange();
    });
  }

  /* 把编辑器装进 host。 */
  function mountEditor(host, payload, text, language, onChange) {
    editor = window.CodeMirror(host, editorOptions(editorMode(language, payload.path), {
      value: text,
      gutters: ["CodeMirror-linenumbers", CHANGE_GUTTER],
    }));
    attachEditorEvents(onChange);
    if (payload.cursor) editor.setCursor(payload.cursor);
    updateChangeMarkers();
    return editor;
  }

  function renderEditor(payload, text, language) {
    root.innerHTML = `<div class="editor-host"></div>`;
    mountEditor(root.firstChild, payload, text, language, null);
    editor.scrollTo(null, payload.scrollTop || 0);
  }

  /* 换内容前把还没发出去的最后几笔发掉，别丢。 */
  function flushEditor() {
    if (editTimer) { clearTimeout(editTimer); editTimer = null; postEdited(); }
    if (diffTimer) { clearTimeout(diffTimer); diffTimer = null; }
    editor = null;
    mergeView = null;
    unifiedWidgets = [];
  }

  /* ---------- 可编辑的 diff（工作区变更） ---------- */

  let diffTimer = null;
  let unifiedWidgets = [];   // 单列模式里表示「被删的行」的小块

  function diffSummaryHTML(payload, added, removed) {
    return `<div class="diff-summary"><span class="path">${escapeHTML(payload.path || "")}</span><span class="add">+${added}</span><span class="del">−${removed}</span><span class="hint">基线是 HEAD，右边 / 下边可以直接改</span></div>`;
  }

  function diffCounts(groups) {
    let added = 0, removed = 0;
    for (const group of groups || []) { added += group.adds.length; removed += group.dels; }
    return { added, removed };
  }

  function updateDiffSummary() {
    if (!current || !current.edit || !editor) return;
    const groups = lineChanges(current.edit.oldText.split("\n"), editor.getValue().split("\n"));
    const counts = diffCounts(groups);
    const add = root.querySelector(".diff-summary .add"), del = root.querySelector(".diff-summary .del");
    if (add) add.textContent = `+${counts.added}`;
    if (del) del.textContent = `−${counts.removed}`;
    return groups;
  }

  /* 并排：CodeMirror 的 MergeView，左边基线只读、右边是工作区文件。chunk 之间有连接带和「撤回这一块」按钮。 */
  function renderSideBySideEditable(payload) {
    const edit = payload.edit;
    root.innerHTML = diffSummaryHTML(payload, 0, 0) + `<div class="editor-host merge-host"></div>`;
    mergeView = window.CodeMirror.MergeView(root.querySelector(".merge-host"), editorOptions(editorMode(payload.language, edit.filePath), {
      value: edit.newText,
      origLeft: edit.oldText,
      connect: "align",
      revertButtons: true,
      collapseIdentical: false,
      allowEditingOriginals: false,
      showDifferences: true,
    }));
    editor = mergeView.editor();
    attachEditorEvents(() => {
      if (diffTimer) clearTimeout(diffTimer);
      diffTimer = setTimeout(() => { diffTimer = null; updateDiffSummary(); }, EDIT_DEBOUNCE);
    });
    if (edit.cursor) editor.setCursor(edit.cursor);
    updateDiffSummary();
    editor.scrollTo(null, payload.scrollTop || 0);
  }

  /* 单列：就是工作区文件的编辑器，新增的行带底色，被删的行以只读小块嵌在原位（改不了，它们已经不在文件里）。 */
  function renderUnifiedEditable(payload) {
    const edit = payload.edit;
    root.innerHTML = diffSummaryHTML(payload, 0, 0) + `<div class="editor-host diff-host"></div>`;
    editor = window.CodeMirror(root.querySelector(".diff-host"), editorOptions(editorMode(payload.language, edit.filePath), {
      value: edit.newText,
      gutters: ["CodeMirror-linenumbers", CHANGE_GUTTER],
    }));
    attachEditorEvents(() => {
      if (diffTimer) clearTimeout(diffTimer);
      diffTimer = setTimeout(() => { diffTimer = null; decorateUnified(); }, EDIT_DEBOUNCE);
    });
    if (edit.cursor) editor.setCursor(edit.cursor);
    decorateUnified();
    editor.scrollTo(null, payload.scrollTop || 0);
  }

  function decorateUnified() {
    if (!editor || !current || !current.edit) return;
    editor.operation(() => {
      for (const widget of unifiedWidgets) widget.clear();
      unifiedWidgets = [];
      editor.eachLine((line) => editor.removeLineClass(line, "background", "cm-diff-added"));
      const oldLines = current.edit.oldText.split("\n");
      const groups = updateDiffSummary();
      if (!groups) return;
      const lastLine = editor.lineCount() - 1;
      for (const group of groups) {
        for (const line of group.adds) editor.addLineClass(line, "background", "cm-diff-added");
        if (!group.dels) continue;
        const node = document.createElement("div");
        node.className = "cm-diff-removed";
        for (const text of oldLines.slice(group.oldStart, group.oldStart + group.dels)) {
          const row = document.createElement("div");
          row.textContent = text || " ";
          node.appendChild(row);
        }
        // 删除发生在 newStart 那一行之前；删在文件末尾就挂在最后一行下面
        const at = Math.min(group.newStart, lastLine);
        unifiedWidgets.push(editor.addLineWidget(at, node, { above: group.newStart <= lastLine, coverGutter: false }));
      }
    });
  }

  function renderEditableDiff(payload) {
    if (payload.mode === "side") renderSideBySideEditable(payload); else renderUnifiedEditable(payload);
  }

  /* ---------- 代码（只读视图） ---------- */

  function renderCode(payload) {
    if (payload.editable) {
      renderEditor(payload, payload.text || "", payload.language);
      return;
    }
    const notices = [];
    let text = payload.text || "";
    let language = resolveLanguage(payload.language, text);

    // 压成一行的 JSON 没法读，自动格式化显示；原文没有被改动，只是看的时候展开
    if (payload.language === "json" && text.length > 120 && text.split("\n").length <= 3) {
      try {
        text = JSON.stringify(JSON.parse(text), null, 2);
        notices.push("原文是单行 JSON，已格式化显示");
      } catch (_) { /* 不是合法 JSON 就算了 */ }
    }
    if (text.length > HIGHLIGHT_LIMIT) notices.push("文件较大，已关闭语法高亮");

    const lines = highlightLines(text, language);
    const parts = [];
    if (notices.length) parts.push(`<div class="notice">${notices.map(escapeHTML).join(" · ")}</div>`);
    parts.push(codeView(lines, !!(current && current.wrap)));
    root.innerHTML = parts.join("");
  }

  /* 代码视图的 DOM。
   * 不换行：左边一个整块的行号栏 + 右边一列行。行号栏只有**一个** position:sticky 元素——
   *   之前是每行一个 sticky 的 <td>，WebKit 给每个 sticky 元素单独建合成层，几千行的文件切进来要卡几百毫秒。
   * 自动换行：一行折成几行后行号栏对不齐，改成每行自带行号的 flex 行，此时没有横向滚动也就不需要 sticky。 */
  function codeView(lines, wrap) {
    const digits = String(Math.max(1, lines.length)).length;
    if (!lines.length) {
      return `<div class="code-view hljs" style="--digits:${digits}"><div class="gutter"><div>1</div></div><div class="lines"><div class="line"><span style="color:var(--text-3)">（空文件）</span></div></div></div>`;
    }
    if (wrap) {
      const rows = [];
      for (let i = 0; i < lines.length; i++) rows.push(`<div class="line"><span class="ln">${i + 1}</span><span class="src">${lines[i] || " "}</span></div>`);
      return `<div class="code-view wrap hljs" style="--digits:${digits}">${rows.join("")}</div>`;
    }
    const numbers = [];
    for (let i = 1; i <= lines.length; i++) numbers.push(i);
    const rows = [];
    for (let i = 0; i < lines.length; i++) rows.push(`<div class="line">${lines[i] || " "}</div>`);
    return `<div class="code-view hljs" style="--digits:${digits}"><div class="gutter">${numbers.join("\n")}</div><div class="lines">${rows.join("")}</div></div>`;
  }

  /* ---------- Markdown ---------- */

  let markdownEngine = null;
  function engine() {
    if (markdownEngine) return markdownEngine;
    markdownEngine = window.markdownit({
      html: true,
      linkify: true,
      typographer: false,
      highlight(code, lang) {
        if (lang === "mermaid") return `<pre class="mermaid">${escapeHTML(code)}</pre>`;
        const language = lang && hljs.getLanguage(lang) ? lang : null;
        const body = language ? hljs.highlight(code, { language, ignoreIllegals: true }).value : escapeHTML(code);
        return `<pre class="hljs"><code>${body}</code></pre>`;
      },
    });
    // 图片的相对路径按文档所在目录解析
    const defaultImage = markdownEngine.renderer.rules.image;
    markdownEngine.renderer.rules.image = function (tokens, idx, options, env, self) {
      const token = tokens[idx];
      const src = token.attrGet("src") || "";
      if (env.docDir && !/^[a-z][a-z0-9+.-]*:/i.test(src) && !src.startsWith("/")) {
        token.attrSet("src", env.docDir + src.split("/").map(encodeURIComponent).join("/"));
      } else if (src.startsWith("/")) {
        token.attrSet("src", "file://" + src.split("/").map(encodeURIComponent).join("/"));
      }
      return defaultImage(tokens, idx, options, env, self);
    };
    // 任务列表 [ ] / [x]
    markdownEngine.core.ruler.after("inline", "task_list", (state) => {
      for (const token of state.tokens) {
        if (token.type !== "inline" || !token.children || !token.children.length) continue;
        const first = token.children[0];
        if (first.type !== "text") continue;
        const match = /^\[( |x|X)\]\s+/.exec(first.content);
        if (!match) continue;
        first.content = first.content.slice(match[0].length);
        const box = new state.Token("html_inline", "", 0);
        box.content = `<input type="checkbox" disabled${match[1] === " " ? "" : " checked"}>`;
        token.children.unshift(box);
      }
    });
    return markdownEngine;
  }

  let mermaidReady = false;
  function ensureMermaid() {
    if (mermaidReady || !window.mermaid) return;
    window.mermaid.initialize({ startOnLoad: false, theme: "dark", securityLevel: "strict" });
    mermaidReady = true;
  }

  function markdownHTML(payload, text) {
    return `<article class="md">${engine().render(text || "", { docDir: payload.docDir || "" })}</article>`;
  }

  function runMermaid(container) {
    const diagrams = container.querySelectorAll("pre.mermaid");
    if (diagrams.length && window.mermaid) {
      ensureMermaid();
      window.mermaid.run({ nodes: diagrams }).catch(() => { /* 语法错的图原样留着 */ });
    }
  }

  function renderMarkdown(payload) {
    if (payload.view === "source") {
      renderCode({ path: payload.path, text: payload.markdown, language: "markdown", editable: payload.editable, cursor: payload.cursor, base: payload.base });
      return;
    }
    if (payload.view === "split" && payload.editable) {
      // 左边编辑、右边预览；预览在停手 300ms 后重画
      root.innerHTML = `<div class="md-split"><div class="editor-host"></div><div class="md-pane"></div></div>`;
      const pane = root.querySelector(".md-pane");
      let previewTimer = null;
      const refresh = () => { pane.innerHTML = markdownHTML(payload, editor.getValue()); runMermaid(pane); };
      mountEditor(root.querySelector(".editor-host"), payload, payload.markdown || "", "markdown", () => {
        if (previewTimer) clearTimeout(previewTimer);
        previewTimer = setTimeout(refresh, 300);
      });
      refresh();
      editor.scrollTo(null, payload.scrollTop || 0);
      return;
    }
    root.innerHTML = markdownHTML(payload, payload.markdown);
    runMermaid(root);
  }

  // 链接：站内锚点滚动；http(s) 交给系统浏览器；相对路径是项目里的文件，请宿主在标签里打开
  root.addEventListener("click", (event) => {
    const anchor = event.target.closest && event.target.closest("a[href]");
    if (!anchor) return;
    const href = anchor.getAttribute("href") || "";
    event.preventDefault();
    if (href.startsWith("#")) {
      const id = decodeURIComponent(href.slice(1));
      const target = document.getElementById(id) || Array.from(root.querySelectorAll("h1,h2,h3,h4,h5,h6")).find((h) => slug(h.textContent) === slug(id));
      if (target) target.scrollIntoView({ block: "start" });
      return;
    }
    // 带协议的（http、mailto……）都交给系统
    if (/^[a-z][a-z0-9+.-]*:/i.test(href)) { post({ type: "openExternal", href }); return; }
    if (current && current.kind === "markdown") {
      const base = current.docDir || "";
      const cleaned = href.split("#")[0];
      if (!cleaned) return;
      try {
        const url = new URL(cleaned, base);
        if (url.protocol === "file:") post({ type: "openPath", path: decodeURIComponent(url.pathname) });
      } catch (_) { /* 解析不出来就不管 */ }
    }
  });

  function slug(text) { return (text || "").trim().toLowerCase().replace(/[^\w一-龥]+/g, "-"); }

  /* ---------- 图片 ---------- */

  function renderImage(payload) {
    root.innerHTML = `<div class="image-stage"><img id="img" alt=""></div><div class="image-meta" id="img-meta">${escapeHTML(payload.sizeText || "")}</div>`;
    const img = document.getElementById("img");
    img.addEventListener("load", () => {
      const meta = document.getElementById("img-meta");
      if (meta) meta.textContent = `${img.naturalWidth} × ${img.naturalHeight}${payload.sizeText ? " · " + payload.sizeText : ""}`;
    });
    img.src = payload.url;
  }

  /* ---------- 提示 ---------- */

  function renderMessage(payload) {
    root.innerHTML = `<div class="message"><h2>${escapeHTML(payload.title || "")}</h2><p>${escapeHTML(payload.detail || "")}</p></div>`;
  }

  /* ---------- Diff ---------- */

  // 词级对比：把两行按「单词 / 空白 / 单个符号」切成 token，做 LCS，标出不在公共子序列里的 token。
  function tokenize(text) { return text.match(/[\p{L}\p{N}_]+|\s+|[^\s\p{L}\p{N}_]/gu) || []; }

  function changedRanges(a, b) {
    const ta = tokenize(a), tb = tokenize(b);
    if (ta.length * tb.length > 250000) return null;
    const n = ta.length, m = tb.length;
    const dp = new Array(n + 1);
    for (let i = 0; i <= n; i++) dp[i] = new Uint16Array(m + 1);
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = ta[i] === tb[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
    const left = [], right = [];
    let i = 0, j = 0, oa = 0, ob = 0;
    while (i < n && j < m) {
      if (ta[i] === tb[j]) { oa += ta[i].length; ob += tb[j].length; i++; j++; }
      else if (dp[i + 1][j] >= dp[i][j + 1]) { left.push([oa, oa + ta[i].length]); oa += ta[i].length; i++; }
      else { right.push([ob, ob + tb[j].length]); ob += tb[j].length; j++; }
    }
    while (i < n) { left.push([oa, oa + ta[i].length]); oa += ta[i].length; i++; }
    while (j < m) { right.push([ob, ob + tb[j].length]); ob += tb[j].length; j++; }
    // 只有整行都变了的情况就不标了，满屏高亮等于没高亮
    const total = (ranges, text) => ranges.reduce((s, r) => s + (r[1] - r[0]), 0) / Math.max(1, text.replace(/\s/g, "").length);
    if (total(left, a) > 0.85 && total(right, b) > 0.85) return null;
    return { left: merge(left), right: merge(right) };
  }

  function merge(ranges) {
    const out = [];
    for (const r of ranges) {
      if (out.length && out[out.length - 1][1] >= r[0]) out[out.length - 1][1] = Math.max(out[out.length - 1][1], r[1]);
      else out.push([r[0], r[1]]);
    }
    return out;
  }

  /* 在已经带语法 span 的 HTML 上按纯文本偏移插 <span class="wd">。遇到标签时先闭合再重开，保证嵌套合法。 */
  function wrapRanges(html, ranges) {
    if (!ranges || !ranges.length) return html;
    let out = "", offset = 0, ri = 0, open = false;
    const tokenizer = /<[^>]+>|&[a-zA-Z#0-9]+;|[\s\S]/g;
    let match;
    const inRange = (pos) => {
      while (ri < ranges.length && pos >= ranges[ri][1]) ri++;
      return ri < ranges.length && pos >= ranges[ri][0] && pos < ranges[ri][1];
    };
    while ((match = tokenizer.exec(html)) !== null) {
      const token = match[0];
      if (token[0] === "<") {
        if (open) { out += "</span>"; open = false; }
        out += token;
        continue;
      }
      const marked = inRange(offset);
      if (marked && !open) { out += '<span class="wd">'; open = true; }
      if (!marked && open) { out += "</span>"; open = false; }
      out += token;
      offset += 1;
    }
    if (open) out += "</span>";
    return out;
  }

  function cell(c, language, ranges, extraClass) {
    const cls = ["src", c.k, extraClass || ""].join(" ").trim();
    if (c.k === "empty") return `<td class="${cls}"></td>`;
    const html = wrapRanges(highlightOne(c.t, language), ranges);
    return `<td class="${cls}">${html || " "}</td>`;
  }

  function hunkRow(text, span) {
    const match = /^(@@[^@]*@@)\s?(.*)$/.exec(text);
    const range = match ? match[1] : text, heading = match ? match[2] : "";
    return `<tr class="hunk"><td colspan="${span}"><span class="hunk-range">${escapeHTML(range)}</span>${escapeHTML(heading)}</td></tr>`;
  }

  function renderDiff(payload) {
    if (payload.edit) { renderEditableDiff(payload); return; }
    const language = payload.language && hljs.getLanguage(payload.language) ? payload.language : null;
    const parts = [];
    const summary = [];
    summary.push(`<span class="path">${escapeHTML(payload.path || "")}</span>`);
    if (payload.binary) {
      summary.push(`<span>二进制文件</span>`);
    } else {
      summary.push(`<span class="add">+${payload.added || 0}</span><span class="del">−${payload.removed || 0}</span>`);
    }
    parts.push(`<div class="diff-summary">${summary.join("")}</div>`);

    if (payload.binary) {
      parts.push(`<div class="message" style="min-height:40vh"><h2>二进制文件有改动</h2><p>没有可以按行对比的内容。</p></div>`);
      root.innerHTML = parts.join("");
      return;
    }
    if (payload.empty || !payload.rows || !payload.rows.length) {
      parts.push(`<div class="message" style="min-height:40vh"><h2>没有差异</h2><p>${escapeHTML(payload.emptyReason || "内容与 HEAD 一致（可能只是文件模式或空白变化）。")}</p></div>`);
      root.innerHTML = parts.join("");
      return;
    }

    if (payload.mode === "unified") {
      parts.push(`<table class="diff unified hljs"><colgroup><col style="width:3.6em"><col style="width:3.6em"><col></colgroup><tbody>`);
      for (const row of payload.rows) {
        if (row.type === "hunk") { parts.push(hunkRow(row.text, 3)); continue; }
        const k = row.k;
        const marker = k === "add" ? "+" : k === "del" ? "−" : " ";
        parts.push(`<tr><td class="ln ${k}">${row.o == null ? "" : row.o}</td><td class="ln ${k}">${row.n == null ? "" : row.n}</td>` +
          `<td class="src ${k}"><span class="marker">${marker}</span>${highlightOne(row.t, language) || " "}</td></tr>`);
      }
      parts.push(`</tbody></table>`);
    } else {
      parts.push(`<table class="diff side hljs"><colgroup><col style="width:3.6em"><col><col style="width:3.6em"><col></colgroup><tbody>`);
      for (const row of payload.rows) {
        if (row.type === "hunk") { parts.push(hunkRow(row.text, 4)); continue; }
        const l = row.l, r = row.r;
        let ranges = null;
        if (l.k === "del" && r.k === "add" && l.t.length <= WORD_DIFF_LIMIT && r.t.length <= WORD_DIFF_LIMIT) {
          ranges = changedRanges(l.t, r.t);
        }
        parts.push(`<tr><td class="ln ${l.k}">${l.n == null ? "" : l.n}</td>${cell(l, language, ranges && ranges.left)}` +
          `<td class="ln right-ln ${r.k}">${r.n == null ? "" : r.n}</td>${cell(r, language, ranges && ranges.right)}</tr>`);
      }
      parts.push(`</tbody></table>`);
    }
    root.innerHTML = parts.join("");
  }

  /* ---------- 入口 ---------- */

  window.ide = {
    render(payload) {
      const started = performance.now();
      flushEditor();
      current = payload;
      try {
        switch (payload.kind) {
          case "code": renderCode(payload); break;
          case "markdown": renderMarkdown(payload); break;
          case "image": renderImage(payload); break;
          case "diff": renderDiff(payload); break;
          default: renderMessage(payload);
        }
      } catch (error) {
        // 渲染出错宁可把错误摆出来，也不能留一页空白让人以为文件是空的
        renderMessage({ title: "渲染失败", detail: String(error && error.stack || error) });
      }
      // 渲染是同步的，但图片与 mermaid 会撑高页面；先按给的位置滚一次，图出来后位置大体也还对
      window.scrollTo(0, payload.scrollTop || 0);
      // 告诉宿主画完了、花了多久（宿主据此记日志、探针据此计时）
      post({ type: "rendered", kind: payload.kind, ms: Math.round(performance.now() - started) });
    },
    getScrollTop() {
      if (editor) return editor.getScrollInfo().top;
      return window.scrollY || document.documentElement.scrollTop || 0;
    },
    /* 宿主切标签前问一次：滚到哪、编辑器里现在是什么、光标在哪。 */
    getState() {
      const cursor = editor ? editor.getCursor() : null;
      return {
        scrollTop: window.ide.getScrollTop(),
        text: editor ? editor.getValue() : null,
        cursor: cursor ? { line: cursor.line, ch: cursor.ch } : null,
      };
    },
    /* 基线（HEAD 里的内容）异步到了：是当前文件就重画标记 / 重算 diff。 */
    setBase(message) {
      if (!current) return;
      if (current.edit) {
        if (current.edit.filePath !== message.path) return;
        current.edit.oldText = typeof message.base === "string" ? message.base : "";
        if (mergeView) mergeView.leftOriginal().setValue(current.edit.oldText);
        if (current.mode === "unified") decorateUnified(); else updateDiffSummary();
        return;
      }
      if (current.path !== message.path) return;
      current.base = typeof message.base === "string" ? message.base : null;
      updateChangeMarkers();
    },
    setZoom(zoom) {
      document.documentElement.style.setProperty("--zoom", String(zoom));
      // 字号变了编辑器要重新量行高
      if (editor) setTimeout(() => { if (editor) editor.refresh(); if (mergeView) mergeView.leftOriginal().refresh(); }, 0);
    },
    setWrap(wrap) {
      if (!current) return;
      current.wrap = !!wrap;
      if (editor) {
        editor.setOption("lineWrapping", current.wrap);
        if (mergeView) mergeView.leftOriginal().setOption("lineWrapping", current.wrap);
        return;
      }
      // 只读代码视图换行与否是两种 DOM 结构，切换要重画；保持滚动位置
      if (current.kind === "code" || (current.kind === "markdown" && current.view === "source")) {
        current.scrollTop = window.ide.getScrollTop();
        window.ide.render(current);
      }
    },
  };

  post({ type: "ready" });
})();
