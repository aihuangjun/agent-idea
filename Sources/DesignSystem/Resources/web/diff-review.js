/* Full-text diff presentation. Core/DiffReviewAnalysis owns comparison; this module only
 * folds, aligns and decorates the original CodeMirror documents. It never normalizes text. */
(function () {
  "use strict";

  // Decorations change document height, not the user's reading position. Keep a logical
  // line and its screen offset across those mutations; each pane keeps its own horizontal scroll.
  class DiffViewport {
    constructor(editors, primary) {
      this.editors = editors;
      this.primary = primary;
      this.depth = 0;
      this.listeners = [];
      for (const cm of editors) {
        const use = () => { this.primary = cm; };
        const scroll = () => {
          // Only the pane the user is operating drives scrolling. Layout changes in the
          // other pane must never pull the active editor back toward its cursor or the top.
          if (this.depth || this.primary !== cm) return;
          this.depth++;
          try { for (const other of editors) if (other !== cm) other.scrollTo(null, cm.getScrollInfo().top); }
          finally { this.depth--; }
        };
        const wrapper = cm.getWrapperElement();
        for (const event of ["wheel", "mousedown", "keydown"]) wrapper.addEventListener(event, use, {capture: true, passive: true});
        cm.on("scroll", scroll);
        this.listeners.push({cm, wrapper, use, scroll});
      }
      this.updateTailSpace();
      this.didResize = () => {};
      this.resizeObserver = new ResizeObserver(() => this.preserve(() => {
        for (const cm of this.editors) { cm.setSize(null, null); cm.refresh(); }
        this.didResize();
      }));
      for (const cm of editors) this.resizeObserver.observe(cm.getWrapperElement());
    }
    use(cm) { if (this.editors.includes(cm)) this.primary = cm; }
    snapshot(cm) {
      const info = cm.getScrollInfo(), line = cm.lineAtHeight(info.top, "local");
      return {line, offset: cm.heightAtLine(line, "local") - info.top, left: info.left};
    }
    restore(cm, state) {
      this.use(cm);
      const top = cm.heightAtLine(Math.min(state.line, cm.lastLine()), "local") - state.offset;
      this.depth++;
      try { for (const pane of this.editors) pane.scrollTo(state.left, Math.max(0, top)); }
      finally { this.depth--; }
    }
    updateTailSpace() {
      // A collapsed suffix can leave too little content below the anchor. Reserve one
      // viewport at EOF so expansion can retain its position without scroll clamping.
      for (const cm of this.editors) {
        const wrapper = cm.getWrapperElement(), lines = wrapper.querySelector(".CodeMirror-lines");
        const top = parseFloat(getComputedStyle(lines).paddingTop) || 0;
        const padding = Math.max(0, Math.floor(cm.getScrollInfo().clientHeight - cm.defaultTextHeight() - top)) + "px";
        if (wrapper.style.getPropertyValue("--diff-tail-space") === padding) continue;
        wrapper.style.setProperty("--diff-tail-space", padding);
        cm.refresh();
      }
    }
    editingAnchor(cm) {
      const position = cm.getCursor(), info = cm.getScrollInfo();
      const y = cm.charCoords(position, "local").top - info.top;
      // Native analysis may finish after focus moves to a toolbar or another window.
      // The last operated pane remains the scroll owner until the user operates another.
      return this.primary === cm && y >= 0 && y < info.clientHeight ? {cm, position} : {};
    }
    preserve(change, options = {}) {
      if (this.depth) return change();
      const cm = options.cm || this.primary;
      const info = cm.getScrollInfo();
      const line = options.position ? options.position.line : (options.line == null ? cm.lineAtHeight(info.top, "local") : Math.min(options.line, cm.lastLine()));
      const handle = cm.getLineHandle(line);
      const offset = (options.position ? cm.charCoords(options.position, "local").top : cm.heightAtLine(line, "local")) - info.top;
      const horizontal = this.editors.map(editor => editor.getScrollInfo().left);
      this.primary = cm;
      this.depth++;
      try { this.updateTailSpace(); return change(); }
      finally {
        try {
          const number = cm.getLineNumber(handle);
          const restoredLine = number == null ? Math.min(line, cm.lastLine()) : number;
          const target = (options.position ? cm.charCoords({line: restoredLine, ch: options.position.ch}, "local").top : cm.heightAtLine(restoredLine, "local")) - offset;
          this.editors.forEach((editor, index) => editor.scrollTo(horizontal[index], Math.max(0, target)));
        } finally { this.depth--; }
      }
    }
    destroy() {
      this.resizeObserver.disconnect();
      for (const {cm, wrapper, use, scroll} of this.listeners) {
        cm.off("scroll", scroll);
        for (const event of ["wheel", "mousedown", "keydown"]) wrapper.removeEventListener(event, use, true);
      }
      this.listeners = [];
    }
  }

  class DiffContextFolds {
    constructor(panes, regions, viewport, changed) {
      this.panes = panes;
      this.viewport = viewport;
      this.changed = changed || (() => {});
      this.expanded = [];
      this.marks = [];
      this.generation = 0;
      this.update(regions);
    }
    update(regions, reset = false) {
      if (reset) this.expanded = [];
      this.regions = regions.filter(region => !this.expanded.some(open =>
        region.oldStart < open.end && region.oldStart + region.count > open.start))
        .map(region => Object.assign({}, region));
      this.draw();
    }
    restore(regions, expanded) {
      this.expanded = Array.isArray(expanded) ? expanded.filter(region => region && Number.isInteger(region.start) && Number.isInteger(region.end) && region.start >= 0 && region.end > region.start) : [];
      this.update(regions);
    }
    clear() {
      this.generation++;
      for (const mark of this.marks) mark.clear();
      this.marks = [];
    }
    draw() {
      this.clear();
      const generation = this.generation;
      this.regions.forEach(region => {
        if (region.count < 2) return;
        for (const pane of this.panes) {
          const start = region[pane.original ? "oldStart" : "newStart"];
          if (start >= pane.cm.lineCount()) continue;
          const end = Math.min(start + region.count - 1, pane.cm.lastLine());
          const node = document.createElement("span");
          node.className = "diff-context-fold";
          node.setAttribute("contenteditable", "false");
          const button = document.createElement("button");
          button.type = "button";
          button.textContent = `展开 ${region.count} 行未修改内容`;
          button.title = "全部展开，保持阅读位置";
          button.addEventListener("keydown", event => {
            if (event.key === "Enter" || event.key === " ") event.stopPropagation();
          });
          button.addEventListener("mousedown", event => { event.preventDefault(); event.stopPropagation(); });
          button.addEventListener("click", event => {
            event.preventDefault(); event.stopPropagation();
            const after = start + region.count;
            const info = pane.cm.getScrollInfo();
            const y = pane.cm.heightAtLine(after, "local") - info.top;
            // Preserve visible code above a middle/suffix fold. If the viewport starts
            // inside the fold, retain the existing context immediately below it instead.
            const hasContext = after < pane.cm.lastLine() || (after === pane.cm.lastLine() && pane.cm.getLine(after) !== "");
            const firstVisible = pane.cm.lineAtHeight(info.top, "local");
            const startsInFold = firstVisible >= start && firstVisible < after;
            this.expand(region, {cm: pane.cm, line: startsInFold && hasContext && y >= 0 && y < info.clientHeight ? after : null});
          });
          node.appendChild(button);
          const mark = pane.cm.markText({line: start, ch: 0}, {line: end, ch: pane.cm.getLine(end).length},
            {collapsed: true, replacedWith: node, clearOnEnter: true, inclusiveLeft: false, inclusiveRight: false});
          // CodeMirror dispatches clear after its operation. A boolean around clear() is
          // insufficient: delayed callbacks from a previous draw must never expand new folds.
          mark.on("clear", () => { if (this.generation === generation) this.expand(region); });
          this.marks.push(mark);
        }
      });
    }
    expand(region, anchor) {
      if (!region.count) return;
      this.viewport.preserve(() => {
        this.expanded.push({start: region.oldStart, end: region.oldStart + region.count});
        region.count = 0;
        this.draw();
        this.changed();
      }, anchor);
    }
    reveal(cm, line) {
      const pane = this.panes.find(item => item.cm === cm);
      if (!pane) return;
      for (const region of [...this.regions]) {
        const start = region[pane.original ? "oldStart" : "newStart"];
        if (line >= start && line < start + region.count) this.expand(region);
      }
    }
  }

  class DiffReviewView {
    constructor(host, options, analysis, reading) {
      host.innerHTML = '<div class="review-columns CodeMirror-merge"><div class="CodeMirror-merge-pane CodeMirror-merge-left"></div><div class="CodeMirror-merge-pane CodeMirror-merge-editor"></div></div>';
      this.left = window.CodeMirror(host.querySelector(".CodeMirror-merge-left"), Object.assign({}, options,
        {value: options.origLeft, readOnly: true, gutters: ["CodeMirror-linenumbers", "diff-revert"]}));
      this.right = window.CodeMirror(host.querySelector(".CodeMirror-merge-editor"), options);
      this.viewport = new DiffViewport([this.left, this.right], this.right);
      this.analysis = analysis;
      this.reading = reading;
      this.widgets = new Map();
      this.backgrounds = [];
      this.timer = null;
      this.destroyed = false;
      for (const source of [this.left, this.right]) {
        source.on("refresh", () => this.scheduleLayout());
        source.on("update", () => this.scheduleLayout());
      }
      const invalidate = () => {
        this.dirty = this.right.getValue() !== this.analyzedText || this.left.getValue() !== this.analyzedOriginal;
        // Chunk coordinates belong to the last completed analysis. Never apply a stale revert.
        if (this.dirty) this.left.clearGutter("diff-revert");
        else {
          // Undo can return exactly to the analyzed text, so no native recomparison is needed.
          this.update(this.analysis);
        }
      };
      this.right.on("change", invalidate);
      this.left.on("change", invalidate);
      this.update(analysis);
      this.viewport.didResize = () => this.align();
    }
    editor() { return this.right; }
    leftOriginal() { return this.left; }
    scheduleLayout() {
      if (this.destroyed || this.timer !== null) return;
      this.timer = setTimeout(() => { this.timer = null; this.align(); }, 0);
    }
    update(analysis) {
      this.viewport.preserve(() => this.applyAnalysis(analysis), this.dirty ? this.viewport.editingAnchor(this.right) : {});
    }
    applyAnalysis(analysis) {
      const hadFolds = !!this.folds;
      const baseChanged = this.analyzedOriginal !== this.left.getValue();
      this.analysis = analysis;
      this.analyzedText = this.right.getValue();
      this.analyzedOriginal = this.left.getValue();
      this.dirty = false;
      this.resetAlignment();
      for (const mark of this.backgrounds) mark.cm.removeLineClass(mark.line, "background", "CodeMirror-merge-l-chunk");
      this.backgrounds = [];
      this.left.clearGutter("diff-revert");
      for (const change of analysis.changes) {
        for (const [cm, start, count] of [[this.left, change.oldStart, change.oldCount], [this.right, change.newStart, change.newCount]]) {
          for (let i = 0; i < count; i++) this.backgrounds.push({cm, line: cm.addLineClass(start + i, "background", "CodeMirror-merge-l-chunk")});
        }
        if (!this.right.getOption("readOnly")) {
          const button = document.createElement("button");
          button.className = "diff-revert-button CodeMirror-merge-copy";
          button.type = "button"; button.textContent = "→"; button.title = "回退此处变更";
          button.addEventListener("click", () => this.revert(change));
          this.left.setGutterMarker(Math.min(change.oldStart, this.left.lastLine()), "diff-revert", button);
        }
      }
      const regions = this.reading.collapseUnchanged ? analysis.folds : [];
      if (this.folds) this.folds.update(regions, baseChanged);
      else this.folds = new DiffContextFolds([{cm: this.left, original: true}, {cm: this.right, original: false}],
        regions, this.viewport, () => { this.resetAlignment(); this.align(); });
      if (hadFolds) this.folds.reveal(this.right, this.right.getCursor().line);
      this.scheduleLayout();
    }
    resetAlignment() {
      for (const item of this.widgets.values()) item.widget.clear();
      this.widgets.clear();
      this.scheduleLayout();
    }
    revert(change) {
      const offset = (cm, line) => line > cm.lastLine() ? cm.getValue().length : cm.indexFromPos({line, ch: 0});
      const oldStart = offset(this.left, change.oldStart), newStart = offset(this.right, change.newStart);
      const oldEnd = change.oldStart + change.oldCount >= this.analysis.oldLineCount ? this.left.getValue().length : offset(this.left, change.oldStart + change.oldCount);
      const newEnd = change.newStart + change.newCount >= this.analysis.newLineCount ? this.right.getValue().length : offset(this.right, change.newStart + change.newCount);
      this.right.replaceRange(this.left.getValue().slice(oldStart, oldEnd), this.right.posFromIndex(newStart), this.right.posFromIndex(newEnd), "+revert");
    }
    align() {
      // During edit debounce, old coordinates can refer to lines that no longer exist.
      if (this.destroyed || this.dirty) return;
      this.viewport.preserve(() => this.alignPanes());
    }
    alignPanes() {
      // Every common line is an anchor: ignored indentation and wrapping can give equal lines
      // different visual heights. Collapsed interiors have no independent visual anchor.
      const anchors = [{oldStart: 0, newStart: 0}, {oldStart: this.left.lineCount(), newStart: this.right.lineCount()}];
      const hidden = (region, i) => this.folds.regions.some(fold => fold.count > 1 && region.oldStart + i > fold.oldStart && region.oldStart + i < fold.oldStart + fold.count);
      for (const region of this.analysis.unchanged) {
        for (let i = 0; i < region.count; i++) if (!hidden(region, i)) anchors.push({oldStart: region.oldStart + i, newStart: region.newStart + i});
      }
      for (const change of this.analysis.changes) {
        // A pure insertion/deletion has no line on one side. Its start and end
        // cannot both anchor that same line: align the following common line instead.
        if (change.oldCount && change.newCount) anchors.push(change);
      }
      anchors.sort((a, b) => a.oldStart - b.oldStart || a.newStart - b.newStart);
      const height = (cm, line) => cm.heightAtLine(line, "local");
      const visited = new Set();
      this.left.operation(() => this.right.operation(() => {
        for (const anchor of anchors) {
          const key = anchor.oldStart + ":" + anchor.newStart;
          if (visited.has(key)) continue;
          visited.add(key);
          const delta = height(this.left, anchor.oldStart) - height(this.right, anchor.newStart);
          if (Math.abs(delta) < 1) continue;
          const previous = this.widgets.get(key);
          const padding = delta + (previous ? previous.padding : 0);
          if (previous) { previous.widget.clear(); this.widgets.delete(key); }
          if (Math.abs(padding) < 1) continue;
          const cm = padding > 0 ? this.right : this.left, line = padding > 0 ? anchor.newStart : anchor.oldStart;
          const node = document.createElement("div"); node.className = "diff-align-space"; node.style.height = Math.abs(padding) + "px";
          const widget = cm.addLineWidget(Math.min(line, cm.lastLine()), node, {above: line <= cm.lastLine(), height: Math.abs(padding), noHScroll: true});
          this.widgets.set(key, {widget, padding});
        }
      }));
    }
    destroy() {
      this.destroyed = true;
      if (this.timer !== null) clearTimeout(this.timer);
      if (this.folds) this.folds.clear();
      for (const item of this.widgets.values()) item.widget.clear();
      this.viewport.destroy();
    }
  }
  window.DiffContextFolds = DiffContextFolds;
  window.DiffViewport = DiffViewport;
  window.DiffReviewView = DiffReviewView;
})();
