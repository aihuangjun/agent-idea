/* 语法着色：tree-sitter（WASM）按 IDEA 的习惯给代码上色——函数声明 / 调用、参数、局部变量、字段、全局 / 静态、常量、类型、注解……
 *
 * 分三层：
 *   1. 语法树：web-tree-sitter 解析整份文本；编辑器里每次改动 tree.edit + 带旧树增量重解析（同步，几毫秒）。
 *   2. 着色查询：官方 highlights.scm（vendor）在前、自写的 syntax/<名>.scm 在后，同一个节点「后面的模式赢」——
 *      官方查询本来就是先写 (identifier) @variable 再写具体的，自写的放最后就能盖掉官方的粗分类（声明 vs 调用等）。
 *   3. 作用域：自写的 syntax/<名>-locals.scm 标出作用域与定义（参数 / 局部 / 字段 / 静态），整份文件解析一遍，
 *      把每个标识符引用解析到定义上；根作用域里的局部定义就是全局变量。只覆盖着色查询给了「普通变量」的标识符。
 * 着色只算视口附近：编辑器是 CodeMirror 的 overlay，CodeMirror 只对要画的行（视口 + 500 行）调 token()，
 * 这里按 CHUNK 行一段去跑着色查询并缓存；重解析后清缓存、换一次 overlay，CodeMirror 只重画视口。
 * 颜色全在 CSS：token 的 class 是 cm-ts-*（编辑器里 CodeMirror 自己加 cm- 前缀，只读视图照样输出 cm-ts-*），
 * 映射到 style.css 的 --syn-* 变量在 syntax-idea.css；切主题不用重新解析。
 *
 * 退路：WASM / 语法包 / 查询任何一步失败、文件超过 SIZE_LIMIT、解析超时，都退回原来的高亮
 * （编辑器保留 CodeMirror 的 mode，只读视图用 highlight.js）。初始化是异步的：先用旧高亮画出来，就绪后再换上。
 *
 * 加一种语言：fetch_vendor.sh 下载语法包与官方查询 → 下面 LANGUAGES 加一行 → syntax/ 里写 <名>.scm 与 <名>-locals.scm
 * （可以没有）→ ArchitectureTests 核对三处一致。资源走宿主的 agentidea-asset: 协议（file:// 页面里 fetch 不到本地文件）。
 */
(function (global) {
  "use strict";

  const ASSET_BASE = "agentidea-asset://web/";
  const SIZE_LIMIT = 600 * 1024;     // 与 render.js 的 HIGHLIGHT_LIMIT 一致：再大就退回旧高亮
  const LINE_LIMIT = 10000;          // 与 CodeMirror 的 maxHighlightLength 一致：超长的行不着色
  const PARSE_BUDGET_MS = 1500;      // 解析超过这么久就放弃（返回 null → 退回旧高亮）
  const CHUNK = 80;                  // 编辑器里一次算多少行的着色
  const CACHE_SIZE = 4;              // 最近解析过的文本留几份语法树（切主题 / 切回标签时不用重新解析）
  const SEMANTIC_SYNC_MS = 6;        // 作用域解析比这快就每次改动同步重算，否则停手 SEMANTIC_DELAY 之后再算
  const SEMANTIC_DELAY = 150;

  /* 语言表。languages：Core/Language.swift 给的 highlight.js 语言名；extensions 优先于 languages（.tsx、.h 这种）。
   * grammar → vendor/tree-sitter/tree-sitter-<grammar>.wasm；highlights → vendor/tree-sitter/queries/<x>.scm（按顺序叠）；
   * own → syntax/<x>.scm（自写，叠在官方后面）；locals → syntax/<x>-locals.scm（自写的作用域查询，按顺序拼起来）。 */
  const LANGUAGES = [
    { id: "java", languages: ["java"], extensions: [], grammar: "java", highlights: ["java/highlights"], own: ["java"], locals: ["java"] },
    { id: "cpp", languages: ["cpp", "c"], extensions: ["h", "hpp", "hh", "hxx", "c", "cc", "cpp", "cxx", "ino"], grammar: "cpp", highlights: ["c/highlights", "cpp/highlights"], own: ["cpp"], locals: ["cpp"] },
    { id: "python", languages: ["python"], extensions: [], grammar: "python", highlights: ["python/highlights"], own: ["python"], locals: ["python"] },
    { id: "go", languages: ["go"], extensions: [], grammar: "go", highlights: ["go/highlights"], own: ["go"], locals: ["go"] },
    { id: "javascript", languages: ["javascript"], extensions: ["js", "mjs", "cjs", "jsx"], grammar: "javascript", highlights: ["javascript/highlights", "javascript/highlights-jsx", "javascript/highlights-params"], own: ["ecmascript", "jsx"], locals: ["ecmascript", "javascript"] },
    { id: "typescript", languages: ["typescript"], extensions: ["ts", "mts", "cts"], grammar: "typescript", highlights: ["javascript/highlights", "typescript/highlights"], own: ["ecmascript", "typescript"], locals: ["ecmascript", "typescript"] },
    { id: "tsx", languages: [], extensions: ["tsx"], grammar: "tsx", highlights: ["javascript/highlights", "javascript/highlights-jsx", "typescript/highlights"], own: ["ecmascript", "typescript", "jsx"], locals: ["ecmascript", "typescript"] },
    { id: "json", languages: ["json"], extensions: [], grammar: "json", highlights: ["json/highlights"], own: ["json"], locals: [] },
  ];

  /* 捕获名 → token 类（cm-ts-<类>）。按最长前缀查：function.declaration 先于 function。 */
  const CAPTURE_CLASSES = [
    ["comment.doc", "doc"], ["comment", "comment"],
    ["string.escape", "escape"], ["escape", "escape"], ["string.special.key", "field"], ["string.special", "regexp"], ["string.regex", "regexp"],
    ["string", "string"], ["character", "string"],
    ["number", "number"], ["float", "number"],
    ["function.declaration", "decl"], ["function.builtin", "builtin"], ["builtin", "builtin"], ["function.macro", "macro"], ["function.special", "macro"],
    ["function", "call"], ["method", "call"], ["constructor", "type"],
    ["keyword", "keyword"], ["constant.builtin", "keyword"], ["constant.macro", "macro"], ["constant", "constant"], ["boolean", "keyword"],
    ["type.parameter", "type-param"], ["type.builtin", "keyword"], ["type", "type"],
    ["variable.builtin.self", "self"], ["variable.builtin", "builtin"], ["variable.parameter", "param"], ["variable", "variable"],
    ["property", "field"], ["attribute", "annotation"], ["tag.attribute", "plain"], ["tag", "tag"],
    ["label", "label"], ["operator", "operator"], ["punctuation", "plain"], ["embedded", "plain"], ["module", "plain"], ["namespace", "plain"],
  ];
  const classCache = new Map();
  function captureClass(name) {
    if (classCache.has(name)) return classCache.get(name);
    let found = null;
    for (const [prefix, cls] of CAPTURE_CLASSES) {
      if (name === prefix || name.startsWith(prefix + ".")) { found = cls; break; }
    }
    classCache.set(name, found);
    return found;
  }

  /* 作用域解析的结果 → token 类。根作用域里的局部定义是全局变量（IDEA 的 global variable：紫色斜体）。 */
  const KIND_CLASSES = { parameter: "param", local: "local", global: "global", field: "field", static: "static", typeparam: "type-param" };

  /* 着色查询给出的类能不能被作用域解析覆盖：普通变量都能；类型只能被「类型参数」覆盖，字段只能被「静态」覆盖。 */
  function semanticClass(base, kind) {
    if (!kind) return base;
    if (base === "variable") return KIND_CLASSES[kind] || base;
    if (base === "type" && kind === "typeparam") return "type-param";
    if (base === "field" && kind === "static") return "static";
    return base;
  }

  /* ---------- 加载 ---------- */

  let base = ASSET_BASE;
  let runtime = null;              // Promise<TreeSitter>
  const loaded = new Map();        // id → { promise, value: { language, highlights, locals } | null, failed }
  let simulateFailure = false;

  function fetchBytes(path) {
    if (simulateFailure) return Promise.reject(new Error("simulated failure"));
    return fetch(base + path).then((response) => {
      if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
      return response.arrayBuffer();
    }).then((buffer) => new Uint8Array(buffer));
  }

  function fetchText(path) {
    return fetchBytes(path).then((bytes) => new TextDecoder().decode(bytes));
  }

  function loadRuntime() {
    if (runtime) return runtime;
    const TreeSitter = global.TreeSitter;
    if (!TreeSitter) return Promise.reject(new Error("web-tree-sitter 没有加载"));
    runtime = fetchBytes("vendor/tree-sitter/web-tree-sitter.wasm")
      .then((wasmBinary) => TreeSitter.Parser.init({ wasmBinary, locateFile: (name) => base + "vendor/tree-sitter/" + name }))
      .then(() => TreeSitter);
    runtime.catch(() => { runtime = null; });
    return runtime;
  }

  function load(spec) {
    if (!spec) return Promise.resolve(null);
    let entry = loaded.get(spec.id);
    if (entry) return entry.promise;
    entry = { value: null, failed: false, promise: null };
    loaded.set(spec.id, entry);
    entry.promise = loadRuntime().then((TreeSitter) => Promise.all([
      fetchBytes(`vendor/tree-sitter/tree-sitter-${spec.grammar}.wasm`).then((bytes) => TreeSitter.Language.load(bytes)),
      Promise.all(spec.highlights.map((name) => fetchText(`vendor/tree-sitter/queries/${name}.scm`))),
      Promise.all(spec.own.map((name) => fetchText(`syntax/${name}.scm`))),
      Promise.all(spec.locals.map((name) => fetchText(`syntax/${name}-locals.scm`))),
    ]).then(([language, official, own, locals]) => {
      entry.value = {
        TreeSitter,
        language,
        // 官方在前、自写在后：同一个节点后面的模式赢
        highlights: new TreeSitter.Query(language, official.concat(own).join("\n")),
        locals: locals.length ? new TreeSitter.Query(language, locals.join("\n")) : null,
      };
      return entry.value;
    })).catch((error) => {
      entry.failed = true;
      try { global.webkit.messageHandlers.ide.postMessage({ type: "error", message: `语法着色加载失败（${spec.id}）：${error && error.message || error}`, where: "syntax.js" }); } catch (_) { /* 测试页 */ }
      return null;
    });
    return entry.promise;
  }

  function specFor(language, path) {
    const name = (path || "").toLowerCase().split("/").pop();
    const ext = name.includes(".") ? name.split(".").pop() : "";
    return LANGUAGES.find((spec) => spec.extensions.includes(ext))
      || (language ? LANGUAGES.find((spec) => spec.languages.includes(language)) : null)
      || null;
  }

  /* ---------- 解析 ---------- */

  function parse(rt, text, oldTree) {
    const parser = new rt.TreeSitter.Parser();
    try {
      parser.setLanguage(rt.language);
      const started = performance.now();
      return parser.parse(text, oldTree || null, { progressCallback: () => performance.now() - started > PARSE_BUDGET_MS }) || null;
    } catch (_) {
      return null;
    } finally {
      parser.delete();
    }
  }

  /* 最近解析过的文本：切主题 / 换行重画 / 切回标签时编辑器重建，同一份文本不再解析一遍。 */
  const treeCache = [];
  function cachedTree(spec, text) {
    const index = treeCache.findIndex((item) => item.spec === spec && item.text === text);
    if (index < 0) return null;
    const [item] = treeCache.splice(index, 1);
    return item;
  }
  function rememberTree(spec, text, tree, semantics) {
    treeCache.unshift({ spec, text, tree, semantics });
    while (treeCache.length > CACHE_SIZE) treeCache.pop().tree.delete();
  }

  /* ---------- 作用域解析 ---------- */

  const DEF_KINDS = { "def.parameter": "parameter", "def.local": "local", "def.field": "field", "def.static": "static", "def.global": "global", "def.typeparam": "typeparam" };

  /* 整份文件跑一遍 locals 查询：作用域按嵌套入栈，定义记在最内层作用域里，引用最后统一往外层找（不讲先后——
   * 字段、全局、JS 的提升都可能先用后定义）。返回 Map<标识符起点（UTF-16）, 种类>。 */
  function resolveSemantics(rt, tree) {
    const result = new Map();
    if (!rt.locals) return result;
    let captures;
    try { captures = rt.locals.captures(tree.rootNode); } catch (_) { return result; }
    const root = { start: 0, end: Infinity, parent: null, defs: new Map(), isolated: false, root: true };
    const scopes = [];
    const items = [];
    for (const capture of captures) {
      const node = capture.node;
      if (capture.name === "scope" || capture.name === "scope.isolated") {
        scopes.push({ start: node.startIndex, end: node.endIndex, parent: null, defs: new Map(), isolated: capture.name === "scope.isolated", root: false });
      } else if (capture.name === "ref" || DEF_KINDS[capture.name]) {
        items.push({ start: node.startIndex, name: node.text, kind: DEF_KINDS[capture.name] || null, pattern: capture.patternIndex });
      }
    }
    scopes.sort((a, b) => a.start - b.start || b.end - a.end);
    items.sort((a, b) => a.start - b.start || a.pattern - b.pattern);
    const stack = [root];
    let next = 0;
    const refs = [];
    for (const item of items) {
      while (stack.length > 1 && stack[stack.length - 1].end <= item.start) stack.pop();
      while (next < scopes.length && scopes[next].start <= item.start) {
        const scope = scopes[next++];
        while (stack.length > 1 && stack[stack.length - 1].end <= scope.start) stack.pop();
        scope.parent = stack[stack.length - 1];
        stack.push(scope);
      }
      while (stack.length > 1 && stack[stack.length - 1].end <= item.start) stack.pop();
      const scope = stack[stack.length - 1];
      if (item.kind) {
        // 同一个节点有多条定义模式时后面的赢（Java 的 static 字段先匹配「字段」再匹配「静态」）
        const kind = item.kind === "local" && scope.root ? "global" : item.kind;
        scope.defs.set(item.name, kind);
        result.set(item.start, kind);
      } else {
        refs.push({ item, scope });
      }
    }
    for (const { item, scope } of refs) {
      if (result.has(item.start)) continue;   // 定义自己也被 (identifier) @ref 捕获过
      let kind = null;
      for (let s = scope, first = true; s; s = s.parent) {
        // Python 的类体：方法里看不见类体里的名字（只有写在类体自己里的引用看得见）
        if (s.isolated && !first) continue;
        if (s.defs.has(item.name)) { kind = s.defs.get(item.name); break; }
        first = false;
      }
      if (kind) result.set(item.start, kind);
    }
    return result;
  }

  /* ---------- 着色 ---------- */

  /* rows 行（[from, to)）的着色：每行一个 [起, 止, 类] 的有序数组，不重叠。lineText(row) 给那一行的文字。 */
  function paintRows(rt, tree, semantics, from, to, lineText) {
    const out = new Map();
    let captures;
    try {
      captures = rt.highlights.captures(tree.rootNode, { startPosition: { row: from, column: 0 }, endPosition: { row: to, column: 0 } });
    } catch (_) { return out; }
    // 同一段范围只留一个捕获：模式序号大的赢（官方在前、自写在后）
    const best = new Map();
    for (const capture of captures) {
      const node = capture.node;
      const key = node.startIndex + ":" + node.endIndex;
      const previous = best.get(key);
      if (previous && previous.pattern > capture.patternIndex) continue;
      // 以 _ 开头的是只给谓词用的辅助捕获；不认识的捕获名也不参与
      let cls = capture.name[0] === "_" ? null : captureClass(capture.name);
      if (cls === null) continue;
      if (cls === "variable" || cls === "type" || cls === "field") cls = semanticClass(cls, semantics.get(node.startIndex));
      best.set(key, { start: node.startPosition, end: node.endPosition, startIndex: node.startIndex, endIndex: node.endIndex, cls, pattern: capture.patternIndex });
    }
    const spans = Array.from(best.values()).filter((span) => span.cls);
    // 外层先画、里层后画（字符串里的转义、模板字符串里的 ${} 盖在外层上面）
    spans.sort((a, b) => a.startIndex - b.startIndex || b.endIndex - a.endIndex);
    for (let row = from; row < to; row++) {
      const text = lineText(row);
      if (text === null) break;
      out.set(row, { length: text.length, cells: text.length > LINE_LIMIT ? null : new Array(text.length).fill(null) });
    }
    for (const span of spans) {
      const first = Math.max(span.start.row, from), last = Math.min(span.end.row, to - 1);
      for (let row = first; row <= last; row++) {
        const line = out.get(row);
        if (!line || !line.cells) continue;
        const start = row === span.start.row ? span.start.column : 0;
        const end = row === span.end.row ? Math.min(span.end.column, line.length) : line.length;
        const cls = span.cls === "variable" ? "plain" : span.cls;
        for (let i = start; i < end; i++) line.cells[i] = cls;
      }
    }
    const segments = new Map();
    for (const [row, line] of out) {
      if (!line.cells) { segments.set(row, null); continue; }
      const list = [];
      let i = 0;
      while (i < line.length) {
        const cls = line.cells[i] || "plain";
        let j = i + 1;
        while (j < line.length && (line.cells[j] || "plain") === cls) j++;
        list.push([i, j, "ts-" + cls]);
        i = j;
      }
      segments.set(row, list);
    }
    return segments;
  }

  function escapeHTML(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  /* 只读视图：整份文本着色成每行一段 HTML（行数与 text.split("\n") 去掉末尾空行后一致）。没就绪 / 超限回 null。 */
  function highlightLines(language, path, text) {
    const spec = specFor(language, path);
    if (!spec || text.length > SIZE_LIMIT) return null;
    const entry = loaded.get(spec.id);
    const rt = entry && entry.value;
    if (!rt) return null;
    const raw = text.split("\n");
    if (raw.length && raw[raw.length - 1] === "") raw.pop();
    const cached = cachedTree(spec, text);
    const tree = cached ? cached.tree : parse(rt, text, null);
    if (!tree) return null;
    const semantics = cached ? cached.semantics : resolveSemantics(rt, tree);
    try {
      const segments = paintRows(rt, tree, semantics, 0, raw.length, (row) => (row < raw.length ? raw[row] : null));
      return raw.map((line, row) => {
        const list = segments.get(row);
        if (!list) return escapeHTML(line);
        return list.map(([from, to, cls]) => (cls === "ts-plain" ? escapeHTML(line.slice(from, to)) : `<span class="cm-${cls}">${escapeHTML(line.slice(from, to))}</span>`)).join("");
      });
    } finally {
      rememberTree(spec, text, tree, semantics);
    }
  }

  /* ---------- 编辑器（CodeMirror 5 的 overlay） ---------- */

  const attached = new Set();

  /* 作用域解析的结果是按标识符起点（UTF-16）记的：改动之后，改动之后的位置整体平移，改动范围里的作废（等重新解析）。 */
  function shiftSemantics(semantics, start, oldEnd, newEnd) {
    const shifted = new Map();
    const delta = newEnd - oldEnd;
    for (const [index, kind] of semantics) {
      if (index < start) shifted.set(index, kind);
      else if (index >= oldEnd) shifted.set(index + delta, kind);
    }
    return shifted;
  }

  class EditorSyntax {
    constructor(cm, spec, rt) {
      this.cm = cm;
      this.spec = spec;
      this.rt = rt;
      const text = cm.getValue();
      const cached = cachedTree(spec, text);
      this.tree = cached ? cached.tree : parse(rt, text, null);
      this.semanticCost = 0;
      this.semanticTimer = null;
      this.semantics = cached ? cached.semantics : (this.tree ? this.measureSemantics() : new Map());
      this.rows = new Map();
      this.overlay = { token: (stream) => this.token(stream), name: "tree-sitter" };
      this.onChanges = (_, changes) => this.applyChanges(changes);
    }

    get ok() { return !!this.tree; }

    start() {
      this.cm.on("changes", this.onChanges);
      this.cm.addOverlay(this.overlay);
      this.cm.getWrapperElement().dataset.syntax = "tree-sitter";
    }

    measureSemantics() {
      const started = performance.now();
      const result = resolveSemantics(this.rt, this.tree);
      this.semanticCost = performance.now() - started;
      return result;
    }

    /* 换一次 overlay：CodeMirror 把视口里的行重新着色（改动可能影响别的行：敲出一个 /* 后面全成了注释）。 */
    refresh() {
      this.rows.clear();
      this.cm.operation(() => {
        this.cm.removeOverlay(this.overlay);
        this.cm.addOverlay(this.overlay);
      });
    }

    /* 听的是 changes（一个 operation 一次），不是 change：CodeMirror 的 change 也是 operation 结束后才逐个补发的，
     * 那时文档已经是全部改动之后的样子，第一次回调里拿最终文档的 indexFromPos / getValue 去套「第一处改动」的
     * tree.edit 会让旧子树被错误复用，后面全是增量解析，错位不会自愈（缩进多行、多光标输入、撤销多处改动都会这样）。
     * 只有一处改动：tree.edit + 带旧树增量解析；多处：扔掉旧树整份重新解析、重算作用域。
     * 作用域解析在大文件里要十几毫秒，上次超过 SEMANTIC_SYNC_MS 就挪到停手之后，期间沿用平移过的旧结果。 */
    applyChanges(changes) {
      if (!this.tree || !changes.length) return;
      if (changes.length > 1) { this.reparseAll(); return; }
      const change = changes[0];
      const cm = this.cm;
      const startIndex = cm.indexFromPos(change.from);
      const removed = change.removed.join("\n"), inserted = change.text.join("\n");
      const lastRemoved = change.removed[change.removed.length - 1], lastInserted = change.text[change.text.length - 1];
      const oldEndIndex = startIndex + removed.length, newEndIndex = startIndex + inserted.length;
      this.tree.edit({
        startIndex,
        oldEndIndex,
        newEndIndex,
        startPosition: { row: change.from.line, column: change.from.ch },
        oldEndPosition: { row: change.from.line + change.removed.length - 1, column: (change.removed.length === 1 ? change.from.ch : 0) + lastRemoved.length },
        newEndPosition: { row: change.from.line + change.text.length - 1, column: (change.text.length === 1 ? change.from.ch : 0) + lastInserted.length },
      });
      const text = cm.getValue();
      const old = this.tree;
      this.tree = text.length > SIZE_LIMIT ? null : parse(this.rt, text, old);
      old.delete();
      if (!this.tree) { this.stop(); return; }
      this.updateSemantics(startIndex, oldEndIndex, newEndIndex);
    }

    reparseAll() {
      const text = this.cm.getValue();
      this.tree.delete();
      this.tree = text.length > SIZE_LIMIT ? null : parse(this.rt, text, null);
      if (!this.tree) { this.stop(); return; }
      this.updateSemantics(null);
    }

    /* start === null：整份重算（多处改动之后没法平移）。 */
    updateSemantics(startIndex, oldEndIndex, newEndIndex) {
      if (startIndex === null || this.semanticCost <= SEMANTIC_SYNC_MS) {
        if (this.semanticTimer) { clearTimeout(this.semanticTimer); this.semanticTimer = null; }
        this.semantics = this.measureSemantics();
      } else {
        this.semantics = shiftSemantics(this.semantics, startIndex, oldEndIndex, newEndIndex);
        if (this.semanticTimer) clearTimeout(this.semanticTimer);
        this.semanticTimer = setTimeout(() => {
          this.semanticTimer = null;
          if (!this.tree) return;
          this.semantics = this.measureSemantics();
          this.refresh();
        }, SEMANTIC_DELAY);
      }
      this.refresh();
    }

    segments(row) {
      if (this.rows.has(row)) return this.rows.get(row);
      const from = Math.floor(row / CHUNK) * CHUNK, to = Math.min(from + CHUNK, this.cm.lineCount());
      const painted = paintRows(this.rt, this.tree, this.semantics, from, to, (r) => (r < this.cm.lineCount() ? this.cm.getLine(r) : null));
      for (let r = from; r < to; r++) this.rows.set(r, painted.has(r) ? painted.get(r) : null);
      return this.rows.get(row);
    }

    /* CodeMirror 的 overlay 接口：从 stream.pos 往后吐一个 token。行号取 stream.lineOracle.line（CodeMirror 5.65 的
     * Context，未公开但 vendor 版本钉死，RenderTests 守着）。没有着色的空隙也吐 ts-plain：overlay 不透明，
     * 底下 CodeMirror mode 的 cm-* 类还在（getTokenTypeAt、括号匹配要用），颜色靠 syntax-idea.css 的三级选择器（.cm-s-idea .cm-overlay.cm-ts-*）盖住。 */
    token(stream) {
      const oracle = stream.lineOracle;
      const list = this.tree && oracle ? this.segments(oracle.line) : null;
      if (!list || !list.length) { stream.skipToEnd(); return null; }
      const pos = stream.pos;
      let lo = 0, hi = list.length - 1;
      while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (list[mid][1] <= pos) lo = mid + 1; else hi = mid;
      }
      const segment = list[lo];
      if (!segment || segment[1] <= pos) { stream.skipToEnd(); return null; }
      stream.pos = Math.max(segment[1], pos + 1);
      return segment[2];
    }

    detach() {
      this.cm.off("changes", this.onChanges);
      if (this.semanticTimer) { clearTimeout(this.semanticTimer); this.semanticTimer = null; }
      if (this.cm.state.treeSitter === this) this.cm.state.treeSitter = null;
      attached.delete(this);
    }

    /* 退回 CodeMirror 自己的 mode（解析失败 / 改大了超限）。 */
    stop() {
      this.detach();
      this.cm.removeOverlay(this.overlay);
      delete this.cm.getWrapperElement().dataset.syntax;
      if (this.tree) { this.tree.delete(); this.tree = null; }
    }

    /* 编辑器随 DOM 丢掉时：语法树留进缓存（WASM 内存要手动释放，缓存满了才 delete）。 */
    release() {
      // 作用域解析还挂在定时器上（大文件）：手里的是平移过的半成品，算完整了再进缓存，否则切回来改动那段一直没有语义色
      const pending = !!this.semanticTimer;
      this.detach();
      if (this.tree) rememberTree(this.spec, this.cm.getValue(), this.tree, pending ? this.measureSemantics() : this.semantics);
      this.tree = null;
    }
  }

  /* 给编辑器装上 tree-sitter 着色。语法包已就绪就同步装（首屏就是新颜色），否则先用 CodeMirror 的 mode，加载完再换。 */
  function attach(cm, language, path) {
    const spec = specFor(language, path);
    if (!spec || !cm) return;
    const install = (rt) => {
      if (!rt || !cm.getWrapperElement().isConnected || cm.state.treeSitter) return;
      if (cm.getValue().length > SIZE_LIMIT) return;
      const syntax = new EditorSyntax(cm, spec, rt);
      if (!syntax.ok) return;
      cm.state.treeSitter = syntax;
      attached.add(syntax);
      syntax.start();
    };
    const entry = loaded.get(spec.id);
    if (entry && entry.value) { install(entry.value); return; }
    load(spec).then((rt) => cm.operation(() => install(rt)));
  }

  /* 换内容前：把所有编辑器的语法树收进缓存。 */
  function releaseAll() {
    for (const syntax of Array.from(attached)) syntax.release();
  }

  /* 只读视图要不要等着换上 tree-sitter：有对应的语法、没超限、还没加载完。回 Promise<是否就绪>。 */
  function whenReady(language, path, text) {
    const spec = specFor(language, path);
    if (!spec || text.length > SIZE_LIMIT) return null;
    const entry = loaded.get(spec.id);
    if (entry && (entry.value || entry.failed)) return null;
    return load(spec).then((rt) => !!rt);
  }

  global.Syntax = {
    languages: LANGUAGES,
    specFor,
    load(language, path) { return load(specFor(language, path)); },
    isReady(language, path) { const spec = specFor(language, path); const entry = spec && loaded.get(spec.id); return !!(entry && entry.value); },
    highlightLines,
    attach,
    releaseAll,
    whenReady,
    /* 测试用：让之后的加载全部失败（核对退路），或换资源地址。已加载的语言一并清掉。 */
    resetForTesting(options) {
      simulateFailure = !!(options && options.fail);
      base = (options && options.base) || ASSET_BASE;
      runtime = null;
      loaded.clear();
      while (treeCache.length) treeCache.pop().tree.delete();
    },
    _internals: { resolveSemantics, paintRows, parse, captureClass },
  };
})(typeof window !== "undefined" ? window : globalThis);
