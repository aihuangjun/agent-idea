/* Agent IDEA 正文渲染。
 *
 * Swift 侧主要做一件事：window.ide.render(payload)。Swift 那边的事实源是 DesignSystem/RenderPayload.swift，
 * 改一边必须改另一边。每个 payload 都带 scrollTop（渲染完滚到哪）和 wrap（代码是否自动换行），kind 决定画什么：
 * revealChange 为 "first" / "last" 时定位 diff 的第一处 / 最后一处差异；恢复标签位置时省略。
 * revealLine?: {line, ch, length?}（从 0 数）渲染完跳到那一行，与 window.ide.revealLine 同一套做法；用过即清，主题 / 换行重画不再跳。
 *   length（UTF-16 单元）> 0 时从 ch 起选中这么多（全项目搜索打开结果后把命中选上），省略或 0 只放光标。
 *   code     { path, text, language, editable, cursor?: {line, ch}, base?: HEAD 里的内容, history?: 编辑器撤销历史的 JSON 文本 }
 *   markdown { path, markdown, docDir, view: "preview" | "source" | "split", editable, cursor?, base?, history? }
 *   image    { path, url, sizeText }
 *   html     { path, text, docDir }（宿主用独立 WebView 预览，HTML 脚本没有编辑桥）
 *   diff     { path, language, mode: "side" | "unified", rows, binary, empty, added, removed, emptyReason }
 *            或全文的 { path, language, mode, edit: { oldText, newText, baseIdentity, filePath, cursor?, history?, readOnly },
 *              diffViewState?: 阅读现场的 JSON（逻辑行、偏移、展开区间、基线标识），
 *              diffReading: {collapseUnchanged, contextLines, whitespace: "none" | "trailing" | "all"},
 *              analysis: Core/DiffReviewAnalysis（changes、unchanged、folds、行数统计） }。
 *            updateDiffReview({path,newText,analysis,baseIdentity}) 接收编辑后的分析，原文不匹配时丢弃。
 *   message  { title, detail }
 * editable 为真的 code / markdown 源码用 CodeMirror 编辑器画，否则是只读的静态视图。
 * 宿主还会问 window.ide.getState() → { kind, scrollTop, text: 编辑器里的全文或 null, cursor, history, diffViewState }，切标签前拿走最新文字和阅读现场；
 * history 是 CodeMirror getHistory() 的 JSON 文本，下次渲染同一份内容时随 payload 送回来（setHistory），切走再切回 ⌘Z 照样能撤。
 * window.ide.undo() / redo() 是编辑器里的撤销 / 重做，回有没有编辑器接下这一步（只读视图回 false，宿主去撤文件操作）；
 * 焦点在编辑器里时 ⌘Z / ⇧⌘Z 由 CodeMirror 自己处理，不会传到应用菜单。
 * 基线是异步取的，到了就 window.ide.setBase({ path, base })，编辑器在行号右侧画「改过（蓝）/ 新增（绿）」的标记（IDEA 的 gutter）。
 * window.ide.setTheme("light" | "dark") 切浅色 / 深色：只换根元素的 class，颜色都在 style.css 的变量里。
 * window.ide.revealLine({line, ch}) 跳到行（从 0 数，夹到首尾）：编辑器放光标、只读代码视图与只读 diff 表格选中那一行，都滚到正中；
 *   diff 一律按新版本那一侧（并排的右边）。回 true / false（这种视图没有行）。参数同 payload 的 revealLine，可带 length 选中命中。
 * window.ide.selectedText() → 编辑器的选区或只读视图的 DOM 选区文字，没有选区回 ""（在项目中查找拿它预填）。
 * window.ide.reference() → { from: {line, ch}, to: {line, ch} } 或 null：选区 / 光标在新版本里的位置（从 0 数，复制引用用），
 *   并排 diff 里选的是左边（旧版本）就按差异换算到右边；Markdown 预览、图片这些没有行号的视图回 null。
 * window.ide.navigateChange("next" | "previous") 跳到下一处 / 上一处变更（IDEA 的 F7 / ⇧F7）：编辑器里按光标找、把那一行滚到正中；
 * 只读 diff 表格按连续的变更行段落跳。回 { index, total }，没有可跳的回 null；页面里按 F7 / ⇧F7 也走它。
 * 渲染完、跳转后、光标移动、改动、滚动时都会 post changes { hasPrevious, hasNext }，宿主据此把到头的箭头灰掉。
 * path：diff 用来显示（summary 那一行）；编辑器发 edited 消息时带上它，宿主据此找到是哪个文件。
 * edited 的 history 是同一时刻的 getHistory() JSON（超过 HISTORY_POST_LIMIT 不带）：宿主落盘撤销历史时要与刚保存的文字对得上，退出时来不及再问 getState。
 * 往 Swift 发消息一律 post({type, ...})：ready / rendered / openExternal / openPath / edited { path, text, history? } /
 * navigate { direction: "back" | "forward" }（编辑器里按 ⌥← / ⌥→：这两个键在应用里是后退/前进，不给 CodeMirror 按词移动）/
 * changes { hasPrevious, hasNext }。
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
  let changeIndex = -1;                 // 只读 diff 表格里当前停在第几处变更（navigateChange 用），换内容时归零

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
  let sideDiff = null;    // DiffReviewView，管理两侧原文、对齐、上下文与逐块回退
  let diffViewport = null; // diff 装饰重算时保留逻辑行及屏幕位置
  const diffGutterMarks = new Map();
  let diffWordMarks = [];
  let editTimer = null;    // 停手之后再发 edited，别每敲一个键就把整份文本送过去
  let referencePane = "new"; // 并排 diff 里最后点的是哪一边（复制引用用）
  let editorLayoutTimer = null;
  const EDIT_DEBOUNCE = 300;
  const HISTORY_POST_LIMIT = 2 * 1024 * 1024; // 与 EditorHistoryStore 的单份上限一致：再大宿主也不存，不必送

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
    if (current.edit && current.edit.readOnly) return;
    const message = { type: "edited", path: editedPath(), text: editor.getValue() };
    try {
      const history = JSON.stringify(editor.getHistory());
      if (history.length <= HISTORY_POST_LIMIT) message.history = history;
    } catch (e) { /* 历史拿不到就只送文字 */ }
    post(message);
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
      theme: "idea",
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
      changeLinesCache = null;
      if (editTimer) clearTimeout(editTimer);
      editTimer = setTimeout(() => { editTimer = null; postEdited(); updateChangeMarkers(); reportChangePosition(); }, EDIT_DEBOUNCE);
      if (onChange) onChange();
    });
    // 纯光标移动才即时上报；刚敲过字的那 300ms 交给上面的定时器——避免每敲一个键就同步重算全文差异
    editor.on("cursorActivity", () => { if (!editTimer) reportChangePosition(); });
  }

  /* 把编辑器装进 host。 */
  function mountEditor(host, payload, text, language, onChange) {
    editor = window.CodeMirror(host, editorOptions(editorMode(language, payload.path), {
      value: text,
      gutters: ["CodeMirror-linenumbers", CHANGE_GUTTER],
    }));
    attachEditorEvents(onChange);
    attachSyntax(editor, language, payload.path);
    if (payload.cursor) editor.setCursor(payload.cursor);
    restoreHistory(payload.history);
    updateChangeMarkers();
    return editor;
  }

  /* tree-sitter 着色（syntax.js）：语法包已就绪就同步装上，没就绪先用 CodeMirror 的 mode，加载完再换上。 */
  function attachSyntax(cm, language, path) {
    if (!window.Syntax) return;
    try { window.Syntax.attach(cm, language, path); } catch (_) { /* 着色出错不能影响编辑 */ }
  }

  /* 切回来的标签把撤销历史带回来了：装回编辑器。坏掉的 JSON 就当没有，别让正文画不出来。 */
  function restoreHistory(history) {
    if (!editor || !history) return;
    try { editor.setHistory(JSON.parse(history)); } catch (e) { /* 历史对不上就从头记 */ }
  }

  function renderEditor(payload, text, language) {
    root.innerHTML = `<div class="editor-host"></div>`;
    mountEditor(root.firstChild, payload, text, language, null);
    editor.scrollTo(null, payload.scrollTop || 0);
  }

  /* 换内容前把还没发出去的最后几笔发掉，别丢。 */
  function flushEditor() {
    if (editTimer) { clearTimeout(editTimer); editTimer = null; postEdited(); }
    // 编辑器随 DOM 丢掉：语法树收进 syntax.js 的缓存（WASM 内存要手动释放），切回来 / 切主题不用重新解析
    if (window.Syntax) window.Syntax.releaseAll();
    if (editorLayoutTimer !== null) { clearTimeout(editorLayoutTimer); editorLayoutTimer = null; }
    if (sideDiff) sideDiff.destroy();
    else if (diffViewport) diffViewport.destroy();
    if (contextFolds) { contextFolds.clear(); contextFolds = null; }
    editor = null;
    sideDiff = null;
    diffViewport = null;
    referencePane = "new";
    unifiedBase = null;
    diffGutterMarks.clear();
    diffWordMarks = [];
    unifiedWidgets = [];
    changeLinesCache = null;
  }

  /* 窗口 / 字号变化要同时重量两栏与单列删除块。setSize 会更新 noHScroll 行组件的实际宽度，
   * 只 refresh 会留下旧的组件宽度；合并到下一轮处理，后台窗口也需要更新尺寸。 */
  function refreshEditorLayout() {
    if (!editor) return;
    const refresh = () => {
      for (const cm of sideDiff ? [sideDiff.leftOriginal(), editor] : [editor]) {
        cm.operation(() => { cm.setSize(null, null); cm.refresh(); });
      }
      for (const widget of unifiedWidgets) widget.changed();
    };
    if (diffViewport) diffViewport.preserve(refresh); else refresh();
  }

  function scheduleEditorLayout() {
    if (!editor || editorLayoutTimer !== null) return;
    editorLayoutTimer = setTimeout(() => { editorLayoutTimer = null; refreshEditorLayout(); }, 0);
  }

  window.addEventListener("resize", scheduleEditorLayout);

  /* ---------- 可编辑的 diff（工作区变更） ---------- */

  let unifiedWidgets = [];   // 单列模式里表示「被删的行」的小块
  let contextFolds = null;
  let unifiedBase = null;

  function diffSummaryHTML(payload, added, removed) {
    const hint = payload.edit.readOnly ? "版本对比 · 只读" : "基线是 HEAD，右边 / 下边可以直接改";
    return `<div class="diff-summary"><span class="path">${escapeHTML(payload.path || "")}</span><span class="add">+${added}</span><span class="del">−${removed}</span><span class="hint">${hint}</span></div>`;
  }

  function updateDiffSummary() {
    if (!current || !current.edit || !editor) return;
    const analysis = current.analysis;
    const groups = analysis.changes.map(region => ({oldStart: region.oldStart, newStart: region.newStart,
      dels: region.oldCount, adds: Array.from({length: region.newCount}, (_, i) => region.newStart + i)}));
    const counts = analysis;
    const add = root.querySelector(".diff-summary .add"), del = root.querySelector(".diff-summary .del");
    if (add) add.textContent = `+${counts.added}`;
    if (del) del.textContent = `−${counts.removed}`;
    const hint = root.querySelector(".diff-summary .hint");
    if (hint) hint.textContent = analysis.simplified ? "大范围改写：以整块显示，原文完整保留" :
      (!analysis.changes.length ? "当前比较规则下没有差异" : (current.edit.readOnly ? "版本对比 · 只读" : "基线是 HEAD，右边 / 下边可以直接改"));
    post({type: "diffStatistics", path: current.edit.filePath, added: counts.added, removed: counts.removed});
    return groups;
  }

  /* 与摘要、导航共用 Core 的行级差异。
   * 整行 gutter 背景跟着折行高度和固定行号栏走；文末虚拟空行不算一条增删。 */
  function decorateSideBySideGutters(groups) {
    if (!sideDiff) return;
    const left = sideDiff.leftOriginal();
    for (const mark of diffWordMarks) mark.clear();
    diffWordMarks = [];
    const contentLines = cm => cm.lineCount() - (cm.getLine(cm.lastLine()) === "" ? 1 : 0);
    const oldCount = contentLines(left), newCount = contentLines(editor);
    const panes = [
      { cm: left, original: true, kind: "removed" },
      { cm: editor, original: false, kind: "added" },
    ];
    for (const pane of panes) pane.cm.operation(() => {
      for (const mark of diffGutterMarks.get(pane.cm) || []) pane.cm.removeLineClass(mark.line, "gutter", mark.className);
      const marks = [];
      for (const group of groups || []) {
        const removed = Math.max(0, Math.min(group.dels, oldCount - group.oldStart));
        const added = Math.max(0, Math.min(group.adds.length, newCount - group.newStart));
        const paired = Math.min(removed, added);
        const start = pane.original ? group.oldStart : group.newStart;
        const count = pane.original ? removed : added;
        for (let index = 0; index < count; index++) {
          const className = "diff-gutter-" + (index < paired ? "modified" : pane.kind);
          marks.push({ line: pane.cm.addLineClass(start + index, "gutter", className), className });
        }
      }
      diffGutterMarks.set(pane.cm, marks);
    });
    for (const group of groups || []) {
      for (let i = 0; i < Math.min(group.dels, group.adds.length); i++) {
        const oldText = left.getLine(group.oldStart + i), newText = editor.getLine(group.newStart + i);
        if (oldText.length > WORD_DIFF_LIMIT || newText.length > WORD_DIFF_LIMIT) continue;
        const ranges = changedRanges(oldText, newText);
        if (!ranges) continue;
        for (const [cm, line, spans, className] of [[left, group.oldStart + i, ranges.left, "CodeMirror-merge-l-deleted"],
          [editor, group.newStart + i, ranges.right, "CodeMirror-merge-l-inserted"]]) {
          for (const span of spans) diffWordMarks.push(cm.markText({line, ch: span[0]}, {line, ch: span[1]}, {className}));
        }
      }
    }
  }

  /* 并排：完整原文的两个 CodeMirror，比较与折叠由 DiffReviewView 编排。 */
  function renderSideBySideEditable(payload) {
    const edit = payload.edit;
    root.innerHTML = diffSummaryHTML(payload, 0, 0) + `<div class="editor-host merge-host"></div>`;
    sideDiff = new window.DiffReviewView(root.querySelector(".merge-host"), editorOptions(editorMode(payload.language, edit.filePath), {
      value: edit.newText,
      origLeft: edit.oldText,
      readOnly: !!edit.readOnly,
    }), payload.analysis, payload.diffReading);
    editor = sideDiff.editor();
    diffViewport = sideDiff.viewport;
    // 复制引用要知道选区在哪一边：左边是旧版本，行号得换算到右边
    sideDiff.leftOriginal().on("focus", () => { referencePane = "old"; });
    editor.on("focus", () => { referencePane = "new"; });
    attachEditorEvents();
    attachSyntax(sideDiff.leftOriginal(), payload.language, edit.filePath);
    attachSyntax(editor, payload.language, edit.filePath);
    if (edit.cursor) editor.setCursor(edit.cursor);
    restoreHistory(edit.history);
    decorateSideBySideGutters(updateDiffSummary());
    editor.scrollTo(null, payload.scrollTop || 0);
  }

  /* 单列：就是工作区文件的编辑器，新增的行带底色，被删的行以只读小块嵌在原位（改不了，它们已经不在文件里）。 */
  function renderUnifiedEditable(payload) {
    const edit = payload.edit;
    root.innerHTML = diffSummaryHTML(payload, 0, 0) + `<div class="editor-host diff-host"></div>`;
    editor = window.CodeMirror(root.querySelector(".diff-host"), editorOptions(editorMode(payload.language, edit.filePath), {
      value: edit.newText,
      readOnly: !!edit.readOnly,
      gutters: ["CodeMirror-linenumbers", CHANGE_GUTTER],
    }));
    diffViewport = new window.DiffViewport([editor], editor);
    diffViewport.didResize = () => { for (const widget of unifiedWidgets) widget.changed(); };
    attachEditorEvents();
    attachSyntax(editor, payload.language, edit.filePath);
    if (edit.cursor) editor.setCursor(edit.cursor);
    restoreHistory(edit.history);
    decorateUnified();
    editor.scrollTo(null, payload.scrollTop || 0);
  }

  function decorateUnified() {
    if (!editor || !current || !current.edit) return;
    diffViewport.preserve(() => editor.operation(() => {
      const hadFolds = !!contextFolds;
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
        node.dataset.changeLine = String(group.newStart);
        for (const text of oldLines.slice(group.oldStart, group.oldStart + group.dels)) {
          const row = document.createElement("div");
          row.textContent = text || " ";
          node.appendChild(row);
        }
        // 删除发生在 newStart 那一行之前；删在文件末尾就挂在最后一行下面
        const at = Math.min(group.newStart, lastLine);
        unifiedWidgets.push(editor.addLineWidget(at, node, { above: group.newStart <= lastLine, coverGutter: false, noHScroll: !!current.wrap }));
      }
      const regions = current.diffReading.collapseUnchanged ? current.analysis.folds : [];
      if (contextFolds) contextFolds.update(regions, unifiedBase !== current.edit.oldText);
      else contextFolds = new window.DiffContextFolds([{cm: editor, original: false}], regions, diffViewport, scheduleEditorLayout);
      unifiedBase = current.edit.oldText;
      if (hadFolds) contextFolds.reveal(editor, editor.getCursor().line);
    }), diffViewport.editingAnchor(editor));
  }

  function renderEditableDiff(payload) {
    if (payload.mode === "side") renderSideBySideEditable(payload); else renderUnifiedEditable(payload);
  }

  function restoreDiffViewState(payload) {
    if (!diffViewport || !payload.diffViewState || payload.revealChange || payload.revealLine) return;
    let state;
    try { state = JSON.parse(payload.diffViewState); } catch (_) { return; }
    if (!state || !Number.isInteger(state.line) || state.line < 0 || !Number.isFinite(state.offset) || !Number.isFinite(state.left)) return;
    const folds = sideDiff ? sideDiff.folds : contextFolds;
    const regions = payload.diffReading.collapseUnchanged ? payload.analysis.folds : [];
    folds.restore(regions, state.baseIdentity === payload.edit.baseIdentity ? state.expanded : []);
    if (!state.folded) folds.reveal(editor, Math.min(state.line, editor.lastLine()));
    if (sideDiff) { sideDiff.resetAlignment(); sideDiff.align(); }
    else refreshEditorLayout();
    diffViewport.restore(editor, state);
  }

  function diffViewSnapshot() {
    if (!diffViewport) return null;
    const state = diffViewport.snapshot(editor);
    state.baseIdentity = current.edit.baseIdentity;
    state.expanded = (sideDiff ? sideDiff.folds : contextFolds).expanded;
    state.folded = editor.getAllMarks().some(mark => {
      const range = mark.collapsed && mark.find();
      return range && state.line >= range.from.line && state.line <= range.to.line;
    });
    return JSON.stringify(state);
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
        payload.reformatted = true;   // 显示的行号与原文对不上：不能跳到行、不报行号
      } catch (_) { /* 不是合法 JSON 就算了 */ }
    }
    if (text.length > HIGHLIGHT_LIMIT) notices.push("文件较大，已关闭语法高亮");

    // tree-sitter 着色（syntax.js）已就绪就用它，否则先用 highlight.js 画出来，语法包加载完再重画一遍
    const treeLines = window.Syntax ? window.Syntax.highlightLines(payload.language, payload.path, text) : null;
    const lines = treeLines || highlightLines(text, language);
    const parts = [];
    if (notices.length) parts.push(`<div class="notice">${notices.map(escapeHTML).join(" · ")}</div>`);
    parts.push(codeView(lines, !!(current && current.wrap)));
    root.innerHTML = parts.join("");
    const view = root.querySelector(".code-view");
    if (treeLines && view) view.dataset.syntax = "tree-sitter";
    else upgradeStaticCode(payload, text);
  }

  /* 只读代码视图：语法包加载完、还停在这份内容上就用 tree-sitter 重画一遍。整块重建 DOM 会抹掉刚做的定位，
   * 所以重画前记下滚动位置、跳到行标出的那一行（.current-line）和选区（跳到行 / 全项目搜索打开结果时选中的命中、
   * 用户自己的选区），重画后原样放回。WebKit 查找的高亮放不回去（下一次 ⌘G 照常从选区接着找）。 */
  function upgradeStaticCode(payload, text) {
    const ready = window.Syntax ? window.Syntax.whenReady(payload.language, payload.path, text) : null;
    if (!ready) return;
    ready.then((ok) => {
      if (!ok || current !== payload || editor) return;
      const top = window.scrollY || document.documentElement.scrollTop || 0;
      const before = staticCodeLines();
      const marked = before ? Array.prototype.indexOf.call(before, root.querySelector(".code-view .line.current-line")) : -1;
      const selection = window.getSelection();
      const range = selection && selection.rangeCount ? selection.getRangeAt(0) : null;
      const inView = range && root.querySelector(".code-view") && root.querySelector(".code-view").contains(range.startContainer);
      const from = inView ? staticPosition(range.startContainer, range.startOffset) : null;
      const to = inView ? staticPosition(range.endContainer, range.endOffset) : null;
      renderCode(payload);
      const lines = staticCodeLines();
      if (lines && marked >= 0 && marked < lines.length) lines[marked].classList.add("current-line");
      if (lines && from && to && from.line < lines.length && to.line < lines.length) {
        const start = textPoint(lines[from.line].querySelector(".src") || lines[from.line], from.ch);
        const end = textPoint(lines[to.line].querySelector(".src") || lines[to.line], to.ch);
        if (start && end) window.getSelection().setBaseAndExtent(start.node, start.offset, end.node, end.offset);
      }
      window.scrollTo(0, top);
    });
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

  /* mermaid 的配色是初始化时定的，跟着当前主题走。 */
  function mermaidOptions() {
    const light = document.documentElement.classList.contains("light");
    return { startOnLoad: false, theme: light ? "default" : "dark", securityLevel: "strict" };
  }

  let mermaidReady = false;
  function ensureMermaid() {
    if (mermaidReady || !window.mermaid) return;
    window.mermaid.initialize(mermaidOptions());
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
      renderCode({ path: payload.path, text: payload.markdown, language: "markdown", editable: payload.editable, cursor: payload.cursor, base: payload.base, history: payload.history });
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
        parts.push(`<tr${k === "add" || k === "del" ? ' class="changed"' : ""}${row.n == null ? "" : ` data-line="${row.n}"`}><td class="ln ${k}">${row.o == null ? "" : row.o}</td><td class="ln ${k}">${row.n == null ? "" : row.n}</td>` +
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
        const changed = l.k === "del" || l.k === "add" || r.k === "del" || r.k === "add";
        const modified = l.k === "del" && r.k === "add";
        const leftMark = l.k === "del" ? "diff-gutter-" + (modified ? "modified" : "removed") : "";
        const rightMark = r.k === "add" ? "diff-gutter-" + (modified ? "modified" : "added") : "";
        parts.push(`<tr${changed ? ' class="changed"' : ""}${r.n == null ? "" : ` data-line="${r.n}"`}><td class="ln ${l.k} ${leftMark}">${l.n == null ? "" : l.n}</td>${cell(l, language, ranges && ranges.left)}` +
          `<td class="ln right-ln ${r.k} ${rightMark}">${r.n == null ? "" : r.n}</td>${cell(r, language, ranges && ranges.right)}</tr>`);
      }
      parts.push(`</tbody></table>`);
    }
    root.innerHTML = parts.join("");
  }

  /* ---------- 上一个 / 下一个变更（IDEA 的 F7 / ⇧F7） ---------- */

  function lastIndex(array, test) {
    for (let i = array.length - 1; i >= 0; i--) if (test(array[i])) return i;
    return -1;
  }

  let changeLinesCache = null;   // editorChangeLines 的结果；光标每动一下都要问，文本一变就作废

  /* 全文 diff 的起始行来自 Core 比较结果；普通编辑器沿用相对 HEAD 的行级分组。 */
  function editorChangeLines() {
    if (!editor || !current) return [];
    // 纯删除的 EOF chunk 指向 lastLine + 1；光标只能停在最后一行，导航也必须用同一个可达位置。
    const reachable = lines => [...new Set(lines.map(line => Math.min(line, editor.lastLine())))];
    if (current.edit) return reachable(current.analysis.changes.map(change => change.newStart));
    if (changeLinesCache) return changeLinesCache;
    const base = current.edit ? current.edit.oldText : current.base;
    if (typeof base !== "string") return [];
    const groups = lineChanges(base.split("\n"), editor.getValue().split("\n"));
    changeLinesCache = reachable((groups || []).map((group) => group.newStart));
    return changeLinesCache;
  }

  /* 编辑器：以光标所在行为准找下一处 / 上一处，光标放到那一行行首、把它滚到视口正中（IDEA 就是这么放的）。 */
  function navigateEditor(direction) {
    const lines = editorChangeLines();
    if (!lines.length) return null;
    const cursor = editor.getCursor().line;
    const index = direction === "next" ? lines.findIndex((line) => line > cursor) : lastIndex(lines, (line) => line < cursor);
    if (index < 0) return { index: lines.indexOf(cursor), total: lines.length, moved: false };
    revealEditorLine(lines[index]);
    return { index, total: lines.length, moved: true };
  }

  function revealEditorLine(target) {
    const line = Math.min(target, editor.lastLine());
    if (diffViewport) diffViewport.use(editor);
    if (sideDiff) sideDiff.folds.reveal(editor, line);
    if (contextFolds) contextFolds.reveal(editor, line);
    editor.setCursor({ line, ch: 0 });   // cursorActivity 会把新位置报给宿主
    const info = editor.getScrollInfo();
    let top = editor.heightAtLine(line, "local");
    if (sideDiff) {
      const deleted = current.analysis.changes.find(change => !change.newCount && Math.min(change.newStart, editor.lastLine()) === line);
      if (deleted) top = sideDiff.leftOriginal().heightAtLine(deleted.oldStart, "local");
    }
    editor.scrollTo(null, Math.max(0, top - info.clientHeight / 2 + editor.defaultTextHeight() / 2));
  }

  /* 只读 diff 表格：一段连续的变更行算一处。上次跳到的那处还在视口里就从它往下 / 往上数一处，
   * 否则（用户自己滚过了）从视口顶部往下找第一处 / 往上找最后一处。 */
  function staticChangeRuns() {
    const runs = [];
    for (const row of root.querySelectorAll("table.diff tr.changed")) {
      const previous = row.previousElementSibling;
      if (previous && previous.classList.contains("changed")) runs[runs.length - 1].push(row); else runs.push([row]);
    }
    return runs;
  }

  function staticTopOf(run) { return run[0].getBoundingClientRect().top + (window.scrollY || document.documentElement.scrollTop || 0); }

  /* 往 direction 方向该跳到第几处；到头了回 -1。 */
  function staticTarget(runs, direction) {
    const top = window.scrollY || document.documentElement.scrollTop || 0, height = window.innerHeight;
    const selected = runs[changeIndex];
    // 长行折成的变更块可以高于整个窗口；块顶滚出去了，仍可能正在阅读块的中间。
    const selectedVisible = selected && selected[0].getBoundingClientRect().top < height
      && selected[selected.length - 1].getBoundingClientRect().bottom > 0;
    let index;
    if (selectedVisible) {
      index = changeIndex + (direction === "next" ? 1 : -1);
    } else if (direction === "next") {
      index = runs.findIndex((run) => staticTopOf(run) > top + 1);
    } else {
      index = lastIndex(runs, (run) => staticTopOf(run) < top - 1);
    }
    return index >= 0 && index < runs.length ? index : -1;
  }

  function navigateStatic(direction) {
    const runs = staticChangeRuns();
    if (!runs.length) return null;
    const index = staticTarget(runs, direction);
    if (index < 0) return { index: changeIndex, total: runs.length, moved: false };
    revealStaticRun(runs, index);
    reportChangePosition();
    return { index, total: runs.length, moved: true };
  }

  function revealStaticRun(runs, index) {
    const run = runs[index];
    for (const row of root.querySelectorAll("tr.current-change")) row.classList.remove("current-change");
    for (const row of run) row.classList.add("current-change");
    window.scrollTo(0, Math.max(0, staticTopOf(run) - window.innerHeight / 2 + run[0].getBoundingClientRect().height / 2));
    changeIndex = index;
  }

  function revealDiffChange(edge) {
    if (!current || current.kind !== "diff") return;
    if (editor) {
      const lines = editorChangeLines();
      if (lines.length) {
        const target = edge === "last" ? lines[lines.length - 1] : lines[0];
        revealEditorLine(target);
        // 单列中的删除块在目标行上方；整块很高时仍应让删除内容进入视口。
        const widget = unifiedWidgets.find(item => Math.min(Number(item.node.dataset.changeLine), editor.lastLine()) === target);
        if (widget) widget.node.scrollIntoView({block: "center"});
      }
    } else {
      const runs = staticChangeRuns();
      if (runs.length) revealStaticRun(runs, edge === "last" ? runs.length - 1 : 0);
    }
  }

  /* 告诉宿主前面 / 后面还有没有变更可跳（到头的箭头灰掉）。编辑器以光标行为准，只读 diff 按 staticTarget 的答案。 */
  function reportChangePosition() {
    let hasPrevious = false, hasNext = false;
    let index = 0, total = 0;
    if (editor) {
      const lines = editorChangeLines();
      const cursor = editor.getCursor().line;
      hasPrevious = lines.some((line) => line < cursor);
      hasNext = lines.some((line) => line > cursor);
      total = lines.length;
      const previous = lastIndex(lines, line => line <= cursor);
      index = total ? Math.max(0, previous) + 1 : 0;
    } else if (current && current.kind === "diff") {
      const runs = staticChangeRuns();
      total = runs.length;
      index = total ? Math.max(0, changeIndex) + 1 : 0;
      if (runs.length) {
        hasPrevious = staticTarget(runs, "previous") >= 0;
        hasNext = staticTarget(runs, "next") >= 0;
      }
    }
    post({ type: "changes", hasPrevious, hasNext, index, total });
  }

  // 只读 diff 里用户自己滚动之后，「前面 / 后面」的答案会变
  let scrollReportTimer = null;
  window.addEventListener("scroll", () => {
    if (editor || !current || current.kind !== "diff") return;
    if (scrollReportTimer) clearTimeout(scrollReportTimer);
    scrollReportTimer = setTimeout(() => { scrollReportTimer = null; reportChangePosition(); }, 100);
  }, { passive: true });

  function navigateChange(direction) {
    if (editor) return navigateEditor(direction);
    if (current && current.kind === "diff") return navigateStatic(direction);
    return null;
  }

  // 普通上下键在 diff 中按变更导航；捕获阶段先于 CodeMirror，组合键仍用于文本选择 / 光标移动。
  document.addEventListener("keydown", event => {
    if (!current || current.kind !== "diff" || event.defaultPrevented || event.isComposing || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.preventDefault();
    event.stopPropagation();
    post({type: "diffNavigate", direction: event.key === "ArrowDown" ? "next" : "previous", path: current.path});
  }, true);

  // F7 / ⇧F7 在 diff 里同样交给宿主，才能在文件边界继续跳；普通编辑器仍在页内跳。
  document.addEventListener("keydown", (event) => {
    if (event.key !== "F7" || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
    event.preventDefault();
    const direction = event.shiftKey ? "previous" : "next";
    if (current && current.kind === "diff") post({type: "diffNavigate", direction, path: current.path});
    else navigateChange(direction);
  });

  document.addEventListener("keydown", (event) => {
    if (event.key.toLowerCase() !== "f" || !(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return;
    event.preventDefault();
    event.stopPropagation();
    post({ type: "find" });
  }, true);

  let findState = null;
  function clearFind() {
    findState = null;
    for (const widget of unifiedWidgets) widget.node.classList.remove("cm-find-removed");
  }

  function findInEditors(options) {
    if (!editor) return null;
    for (const widget of unifiedWidgets) widget.node.classList.remove("cm-find-removed");
    if (!options.query) { clearFind(); return false; }
    const editors = sideDiff ? [sideDiff.leftOriginal(), editor] : [editor];
    const texts = editors.map(cm => cm.getValue());
    const removed = [];
    if (current && current.edit && current.mode === "unified") {
      const oldLines = current.edit.oldText.split("\n");
      for (const group of lineChanges(oldLines, editor.getValue().split("\n")) || []) {
        if (group.dels) removed.push({ line: group.newStart, text: oldLines.slice(group.oldStart, group.oldStart + group.dels).join("\n") });
      }
      texts.push(...removed.map(group => group.text));
    }
    const key = JSON.stringify([options.query, options.caseSensitive, texts]);
    const matches = [];
    texts.forEach((text, pane) => {
      // 正则 i 保持 UTF-16 位置不变，大小写转换会改变某些 Unicode 字符的长度。
      const escaped = options.query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const pattern = new RegExp(escaped, options.caseSensitive ? "g" : "gi");
      let match;
      while ((match = pattern.exec(text))) matches.push({ pane, from: match.index, to: match.index + match[0].length });
    });
    if (!matches.length) { findState = null; return false; }
    let index;
    if (findState && findState.key === key) index = (findState.index + (options.backwards ? -1 : 1) + matches.length) % matches.length;
    else {
      const position = editor.indexFromPos(editor.getCursor());
      index = options.backwards
        ? lastIndex(matches, m => m.pane === editors.length - 1 && m.from < position)
        : matches.findIndex(m => m.pane === editors.length - 1 && m.from >= position);
      if (index < 0) index = options.backwards ? matches.length - 1 : 0;
    }
    const match = matches[index], cm = editors[match.pane];
    if (cm) {
      const from = cm.posFromIndex(match.from), to = cm.posFromIndex(match.to);
      if (diffViewport) diffViewport.use(cm);
      if (sideDiff) sideDiff.folds.reveal(cm, from.line);
      if (contextFolds) contextFolds.reveal(cm, from.line);
      cm.setSelection(from, to);
      cm.scrollIntoView({ from, to }, 60);
    } else {
      // 单列 diff 中删除的文字不在 CodeMirror 文档里，要查旧文本并滚到对应的删除块。
      const groupIndex = match.pane - editors.length;
      const group = removed[groupIndex];
      editor.scrollIntoView({line: Math.min(group.line, editor.lastLine()), ch: 0}, 60);
      const widget = unifiedWidgets[groupIndex];
      if (widget) {
        widget.node.classList.add("cm-find-removed");
        widget.node.scrollIntoView({block: "center"});
      }
    }
    findState = { key, index, pane: match.pane };
    return true;
  }

  /* ---------- 跳到行 / 复制引用 ---------- */

  /* 只读代码视图的行（换行与不换行两种 DOM 都是 .line）；格式化显示过的 JSON 行号与原文对不上，不算。 */
  function staticCodeLines() {
    if (!current || current.reformatted) return null;
    const view = root.querySelector(".code-view");
    return view ? view.querySelectorAll(".line") : null;
  }

  /* 只读 diff 表格里带新版本行号的行（data-line 从 1 数）。 */
  function staticDiffRows() {
    return Array.from(root.querySelectorAll("table.diff tr[data-line]"));
  }

  function markStaticLine(element) {
    for (const old of root.querySelectorAll(".current-line")) old.classList.remove("current-line");
    element.classList.add("current-line");
    const rect = element.getBoundingClientRect();
    window.scrollTo(window.scrollX, Math.max(0, rect.top + window.scrollY - window.innerHeight / 2 + rect.height / 2));
  }

  /* 宿主给的行列（从 0 数）→ 非负整数。不用 `| 0`：大到超过 32 位的数会被它折成别的值。 */
  function toIndex(value) {
    const number = Math.floor(Number(value));
    return Number.isFinite(number) && number > 0 ? number : 0;
  }

  /* 只读视图里把选区收成一个插入点放在那一行：之后复制引用拿到的就是这一行。length > 0 时从那里起选中这么多个字符（夹到行尾）。 */
  function placeCaret(element, ch, length) {
    const source = element.querySelector(".src") || element;
    const start = textPoint(source, ch);
    const selection = window.getSelection();
    if (!selection) return;
    if (!start) { selection.collapse(source, 0); return; }
    if (length > 0) {
      const end = textPoint(source, ch + length);
      selection.setBaseAndExtent(start.node, start.offset, end.node, end.offset);
    } else {
      selection.collapse(start.node, start.offset);
    }
  }

  /* 元素里第 ch 个字符（UTF-16）落在哪个文本节点的哪个位置；超出夹到最后。没有文本节点回 null。 */
  function textPoint(source, ch) {
    const walker = document.createTreeWalker(source, NodeFilter.SHOW_TEXT);
    let remaining = ch, node, target = null, offset = 0;
    while ((node = walker.nextNode())) {
      target = node;
      if (remaining <= node.length) { offset = remaining; break; }
      remaining -= node.length;
      offset = node.length;
    }
    return target ? { node: target, offset } : null;
  }

  /* 编辑器：光标放到那一行那一列，把它滚到视口正中；折叠着的上下文先展开。并排 diff 只跳右边（新版本）。 */
  function revealEditorPosition(target) {
    const line = Math.min(toIndex(target.line), editor.lastLine());
    const lineLength = editor.getLine(line).length;
    const ch = Math.min(toIndex(target.ch), lineLength);
    const end = Math.min(ch + toIndex(target.length), lineLength);
    if (diffViewport) diffViewport.use(editor);
    if (sideDiff && sideDiff.folds) sideDiff.folds.reveal(editor, line);
    if (contextFolds) contextFolds.reveal(editor, line);
    // 带长度的（全项目搜索的命中）选上那一段，锚点在前、光标在后：一眼看得见，复制引用也落在这一行
    if (end > ch) editor.setSelection({ line, ch }, { line, ch: end }); else editor.setCursor({ line, ch });
    const info = editor.getScrollInfo();
    const top = editor.heightAtLine(line, "local");
    editor.scrollTo(null, Math.max(0, top - info.clientHeight / 2 + editor.defaultTextHeight() / 2));
  }

  function revealLine(target) {
    if (!current || !target) return false;
    if (editor) { revealEditorPosition(target); return true; }
    const line = toIndex(target.line);
    const lines = staticCodeLines();
    if (lines && lines.length) {
      const element = lines[Math.min(line, lines.length - 1)];
      markStaticLine(element);
      placeCaret(element, toIndex(target.ch), toIndex(target.length));
      return true;
    }
    // 只读 diff 表格只有补丁里那几段：取新版本里不早于目标的第一行，都早于它就取最后一行
    const rows = current.kind === "diff" ? staticDiffRows() : [];
    if (rows.length) {
      const row = rows.find((candidate) => Number(candidate.dataset.line) >= line + 1) || rows[rows.length - 1];
      markStaticLine(row);
      placeCaret(row.querySelector("td.src:last-child") || row, 0);
      return true;
    }
    return false;
  }

  /* 并排 diff 左边（旧版本）的行 → 右边（新版本）的行：改动段之外按前面累积的行数差平移，段内按位置配对。 */
  function newLineForOld(line) {
    let delta = 0;
    // 分析结果缺席时（还没算完 / 超限整块显示前）按行号原样对应
    const changes = (current.analysis && current.analysis.changes) || [];
    for (const change of changes) {
      if (line < change.oldStart) break;
      if (line < change.oldStart + change.oldCount) {
        return Math.min(change.newStart + Math.min(line - change.oldStart, Math.max(0, change.newCount - 1)), editor.lastLine());
      }
      delta = change.newStart + change.newCount - (change.oldStart + change.oldCount);
    }
    return Math.max(0, Math.min(line + delta, editor.lastLine()));
  }

  /* 只读视图里 DOM 选区的一端 → {line, ch}；不在有行号的地方回 null。 */
  function staticPosition(node, offset) {
    const element = node && (node.nodeType === 1 ? node : node.parentElement);
    if (!element) return null;
    const lines = staticCodeLines();
    const lineElement = lines && element.closest(".code-view .line");
    if (lineElement) {
      const index = Array.prototype.indexOf.call(lines, lineElement);
      if (index < 0) return null;
      let ch = 0;
      try {
        const range = document.createRange();
        range.setStart(lineElement.querySelector(".src") || lineElement, 0);
        range.setEnd(node, offset);
        ch = range.toString().length;
      } catch (_) { /* 落在行号上：算行首 */ }
      return { line: index, ch };
    }
    const row = current && current.kind === "diff" && element.closest("table.diff tr");
    if (!row) return null;
    // 删除的行没有新版本行号：删除发生在下一个有行号的行之前，取它；后面没有就取前一个
    for (let probe = row; probe; probe = probe.nextElementSibling) if (probe.dataset.line) return { line: Number(probe.dataset.line) - 1, ch: 0 };
    for (let probe = row.previousElementSibling; probe; probe = probe.previousElementSibling) if (probe.dataset.line) return { line: Number(probe.dataset.line) - 1, ch: 0 };
    return null;
  }

  function selectionReference() {
    if (!current) return null;
    if (editor) {
      const pane = sideDiff && referencePane === "old" ? sideDiff.leftOriginal() : editor;
      const from = pane.getCursor("from"), to = pane.getCursor("to");
      if (pane === editor) return { from: { line: from.line, ch: from.ch }, to: { line: to.line, ch: to.ch } };
      return { from: { line: newLineForOld(from.line), ch: from.ch }, to: { line: newLineForOld(to.line), ch: to.ch } };
    }
    const selection = window.getSelection();
    if (!selection || !selection.rangeCount) return null;
    const range = selection.getRangeAt(0);
    const from = staticPosition(range.startContainer, range.startOffset), to = staticPosition(range.endContainer, range.endOffset);
    if (!from && !to) return null;
    return { from: from || to, to: to || from };
  }

  /* ---------- 入口 ---------- */

  window.ide = {
    find(options) { return findInEditors(options); },
    clearFind,
    focusEditor() {
      if (!editor) return false;
      const target = sideDiff && findState && findState.pane === 0 ? sideDiff.leftOriginal() : editor;
      target.focus();
      return true;
    },
    render(payload) {
      const started = performance.now();
      flushEditor();
      findState = null;
      current = payload;
      root.classList.toggle("editable-diff", payload.kind === "diff" && !!payload.edit);
      changeIndex = -1;
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
      // 建立两栏后再量一次 gutter，初始定位必须使用两栏建立后的尺寸。
      if (sideDiff) refreshEditorLayout();
      restoreDiffViewState(payload);
      // 渲染是同步的，但图片与 mermaid 会撑高页面；先按给的位置滚一次，图出来后位置大体也还对
      window.scrollTo(0, payload.scrollTop || 0);
      if (payload.revealChange) {
        revealDiffChange(payload.revealChange);
        // 页面内部切主题 / 换行重画时，也保留已经定位后的状态。
        payload.revealChange = null;
      }
      if (payload.revealLine) {
        revealLine(payload.revealLine);
        payload.revealLine = null;
      }
      // 告诉宿主画完了、花了多久（宿主据此记日志、探针据此计时）
      post({ type: "rendered", kind: payload.kind, ms: Math.round(performance.now() - started) });
      reportChangePosition();
    },
    getScrollTop() {
      if (editor) return editor.getScrollInfo().top;
      return window.scrollY || document.documentElement.scrollTop || 0;
    },
    /* 宿主切标签前问一次：滚到哪、编辑器里现在是什么、光标在哪。 */
    getState() {
      const cursor = editor ? editor.getCursor() : null;
      return {
        kind: current ? current.kind : null,
        scrollTop: window.ide.getScrollTop(),
        text: editor && !(current.edit && current.edit.readOnly) ? editor.getValue() : null,
        cursor: cursor ? { line: cursor.line, ch: cursor.ch } : null,
        history: editor ? JSON.stringify(editor.getHistory()) : null,
        diffViewState: diffViewSnapshot(),
      };
    },
    /* 编辑器里的撤销 / 重做；没有编辑器（只读视图）回 false，宿主去撤文件操作。 */
    undo() {
      if (!editor || editor.getOption("readOnly")) return false;
      editor.undo();
      return true;
    },
    redo() {
      if (!editor || editor.getOption("readOnly")) return false;
      editor.redo();
      return true;
    },
    /* 基线（HEAD 里的内容）异步到了：是当前文件就重画标记 / 重算 diff。 */
    setBase(message) {
      if (!current) return;
      if (current.edit) {
        if (current.edit.filePath !== message.path) return;
        current.edit.oldText = typeof message.base === "string" ? message.base : "";
        changeLinesCache = null;
        if (sideDiff) diffViewport.preserve(() => sideDiff.leftOriginal().setValue(current.edit.oldText));
        post({type: "diffReview", path: current.edit.filePath, text: editor.getValue(), base: current.edit.oldText});
        return;
      }
      if (current.path !== message.path) return;
      current.base = typeof message.base === "string" ? message.base : null;
      changeLinesCache = null;
      updateChangeMarkers();
      reportChangePosition();
    },
    updateDiffReview(message) {
      if (!current || !current.edit || !editor || current.edit.filePath !== message.path || editor.getValue() !== message.newText) return false;
      current.edit.newText = message.newText;
      current.edit.baseIdentity = message.baseIdentity;
      current.analysis = message.analysis;
      changeLinesCache = null;
      if (sideDiff) { sideDiff.update(message.analysis); decorateSideBySideGutters(updateDiffSummary()); }
      else decorateUnified();
      reportChangePosition();
      return true;
    },
    /* 跳到行（从 0 数）；回 false 表示这种视图没有行。 */
    revealLine(target) {
      return revealLine(target);
    },
    /* 选中的文字（在项目中查找预填）；没有选区回 ""。 */
    selectedText() {
      if (editor) return editor.getSelection();
      const selection = window.getSelection();
      return selection ? selection.toString() : "";
    },
    /* 选区 / 光标在新版本里的位置（复制引用）；拿不到回 null。 */
    reference() {
      return selectionReference();
    },
    /* 上一处 / 下一处变更；回 { index, total }，没有可跳的回 null。 */
    navigateChange(direction) {
      return navigateChange(direction);
    },
    /* 浅色 / 深色：外壳跟着 NSApp.appearance 走，这里只切根元素的 class，颜色全在 CSS 变量里。
       mermaid 的图是渲染时定色的，切完要把当前 payload 重画一遍。 */
    setTheme(theme) {
      const light = theme === "light";
      if (light === document.documentElement.classList.contains("light")) return;
      document.documentElement.classList.toggle("light", light);
      if (window.mermaid) {
        try { window.mermaid.initialize(mermaidOptions()); } catch (e) { /* 主题切换不该把正文弄没 */ }
      }
      if (current) {
        // 主题切换会重建编辑器：先收取页面里的最新草稿、光标和历史，不能重画旧 payload。
        if (editor) {
          const state = window.ide.getState();
          const target = current.edit || current;
          if (current.edit) target.newText = editor.getValue();
          else if (current.kind === "markdown") target.markdown = state.text;
          else target.text = state.text;
          target.cursor = state.cursor;
          target.history = state.history;
          current.diffViewState = state.diffViewState;
        }
        current.scrollTop = window.ide.getScrollTop();
        window.ide.render(current);
      }
    },
    setZoom(zoom) {
      document.documentElement.style.setProperty("--zoom", String(zoom));
      // 字号变了编辑器要重新量行高
      scheduleEditorLayout();
    },
    setWrap(wrap) {
      if (!current) return;
      current.wrap = !!wrap;
      if (editor) {
        const update = () => {
          editor.setOption("lineWrapping", current.wrap);
          if (sideDiff) sideDiff.leftOriginal().setOption("lineWrapping", current.wrap);
          if (current.kind === "diff" && current.mode === "unified") decorateUnified();
          refreshEditorLayout();
        };
        if (diffViewport) diffViewport.preserve(update); else update();
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
