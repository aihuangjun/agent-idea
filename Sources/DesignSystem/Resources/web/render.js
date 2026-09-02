/* Agent IDEA 正文渲染。
 *
 * Swift 侧只做一件事：window.ide.render(payload)。Swift 那边的事实源是 DesignSystem/RenderPayload.swift，
 * 改一边必须改另一边。每个 payload 都带 scrollTop（渲染完滚到哪）和 wrap（代码是否自动换行），kind 决定画什么：
 *   code     { path, text, language }
 *   markdown { path, markdown, docDir, view: "preview" | "source" }
 *   image    { path, url, sizeText }
 *   diff     { path, language, mode: "side" | "unified", rows, binary, empty, added, removed, emptyReason }
 *   message  { title, detail }
 * path 目前只有 diff 用来显示（summary 那一行），code/markdown 的带着是为了排查问题时能看出画的是谁。
 * 往 Swift 发消息一律 post({type, ...})。自有代码不写内联事件处理器（CSP 不给 unsafe-inline）。
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

  function renderCode(payload) {
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
    parts.push(`<table class="code hljs"><tbody>`);
    for (let i = 0; i < lines.length; i++) {
      parts.push(`<tr><td class="ln">${i + 1}</td><td class="src">${lines[i] || " "}</td></tr>`);
    }
    if (!lines.length) parts.push(`<tr><td class="ln">1</td><td class="src"><span style="color:var(--text-3)">（空文件）</span></td></tr>`);
    parts.push(`</tbody></table>`);
    root.innerHTML = parts.join("");
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

  function renderMarkdown(payload) {
    if (payload.view === "source") {
      renderCode({ text: payload.markdown, language: "markdown" });
      return;
    }
    const html = engine().render(payload.markdown || "", { docDir: payload.docDir || "" });
    root.innerHTML = `<article class="md">${html}</article>`;
    const diagrams = root.querySelectorAll("pre.mermaid");
    if (diagrams.length && window.mermaid) {
      ensureMermaid();
      window.mermaid.run({ nodes: diagrams }).catch(() => { /* 语法错的图原样留着 */ });
    }
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
      current = payload;
      document.body.classList.toggle("wrap", !!payload.wrap);
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
    },
    getScrollTop() { return window.scrollY || document.documentElement.scrollTop || 0; },
    setZoom(zoom) { document.documentElement.style.setProperty("--zoom", String(zoom)); },
    setWrap(wrap) { document.body.classList.toggle("wrap", !!wrap); if (current) current.wrap = !!wrap; },
  };

  post({ type: "ready" });
})();
