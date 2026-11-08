// The sheet on screen: a canvas drawn from engine-rendered tiles, over a native
// scrolling layer, with headers, frozen panes, selection, the cell editor,
// resizing, the fill handle and the clipboard.
//
// Events: "edit" (editing started or text changed), "editend", "message".

import { SheetMetrics, columnName } from "./metrics.js";
import { paint, readPalette, fontFor } from "./paint.js";
import { attachContextMenu } from "../design/menus.js";

const TILE = 256;
const HEADER_HEIGHT = 24;
const RESIZE_SLOP = 4;
const EXTRA_ROOM = 64;
const TILE_LIMIT = 240;

export class GridView extends EventTarget {
  /**
   * @param {HTMLElement} root
   * @param {import("./engine-client.js").EngineClient} engine
   * @param {{ t: (key: string) => string, contextMenu: (kind: string, event: MouseEvent, info: object) => object[] | null }} options
   */
  constructor(root, engine, options) {
    super();
    this.root = root;
    this.engine = engine;
    this.options = options;
    this.zoom = 1;
    this.metrics = null;
    this.tiles = new Map();
    this.pendingTiles = new Set();
    this.editing = null;
    this.drag = null;
    this.drawQueued = false;
    this.dark = false;
    this.palette = readPalette();

    root.classList.add("grid");
    root.innerHTML = `
      <div class="grid__scroller" tabindex="-1"><div class="grid__spacer"></div></div>
      <canvas class="grid__canvas" aria-hidden="true"></canvas>
      <textarea class="grid__editor" spellcheck="false" autocomplete="off" autocapitalize="off" aria-label="Cell"></textarea>
      <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs grid__add grid__add--row" aria-label="Add Row" title="Add Row" tabindex="-1">
        <svg class="ds-icon" viewBox="0 0 16 16"><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.5"/></svg>
      </button>
      <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs grid__add grid__add--column" aria-label="Add Column" title="Add Column" tabindex="-1">
        <svg class="ds-icon" viewBox="0 0 16 16"><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.5"/></svg>
      </button>`;
    this.scroller = root.querySelector(".grid__scroller");
    this.spacer = root.querySelector(".grid__spacer");
    this.canvas = root.querySelector(".grid__canvas");
    this.editor = root.querySelector(".grid__editor");
    this.addRowButton = root.querySelector(".grid__add--row");
    this.addColumnButton = root.querySelector(".grid__add--column");
    this.ctx = this.canvas.getContext("2d");

    this.addRowButton.addEventListener("click", () => this.engine.call("addRows", { count: 1 }));
    this.addColumnButton.addEventListener("click", () => this.engine.call("addColumns", { count: 1 }));
    this.editor.ariaLabel = options.t("Mac.Inspector.Cell");
    this.addRowButton.title = this.addRowButton.ariaLabel = options.t("HeaderMenu.Row.AddAtEnd");
    this.addColumnButton.title = this.addColumnButton.ariaLabel = options.t("HeaderMenu.Column.AddAtEnd");

    this.scroller.addEventListener("scroll", () => this.requestDraw());
    new ResizeObserver(() => this.resize()).observe(root);
    engine.addEventListener("layout", (event) => this.setLayout(event.detail));
    engine.addEventListener("content", () => this.requestDraw());
    engine.addEventListener("state", () => {
      this.syncEditor();
      this.requestDraw();
    });

    this.bindPointer();
    this.bindKeyboard();
    this.bindClipboard();
    attachContextMenu(this.scroller, (event) => this.contextMenu(event));

    const scheme = matchMedia("(prefers-color-scheme: dark)");
    scheme.addEventListener("change", () => this.themeChanged());
    new MutationObserver(() => this.themeChanged()).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    this.themeChanged();
  }

  // MARK: - Geometry

  get rowHeaderWidth() {
    const digits = String(this.metrics ? this.metrics.layout.rows : 1).length;
    return Math.max(40, 8 * digits + 18);
  }

  get viewport() {
    return { width: this.scroller.clientWidth, height: this.scroller.clientHeight };
  }

  setLayout(layout) {
    const sheetChanged = this.metrics?.layout.sheet !== layout.sheet;
    this.metrics = new SheetMetrics(layout);
    if (sheetChanged) {
      this.scroller.scrollTo(0, 0);
      this.cancelEdit();
    }
    this.tiles.clear();
    this.updateSpacer();
    this.requestDraw();
  }

  updateSpacer() {
    if (!this.metrics) return;
    const z = this.zoom;
    this.spacer.style.width = `${this.rowHeaderWidth + this.metrics.totalWidth * z + EXTRA_ROOM}px`;
    this.spacer.style.height = `${HEADER_HEIGHT + this.metrics.totalHeight * z + EXTRA_ROOM}px`;
  }

  setZoom(zoom) {
    const clamped = Math.min(3, Math.max(0.5, Math.round(zoom * 100) / 100));
    if (clamped === this.zoom) return;
    const { width, height } = this.viewport;
    const centre = this.toSheet(width / 2, height / 2);
    this.zoom = clamped;
    this.updateSpacer();
    if (centre) {
      this.scroller.scrollLeft = Math.max(0, (centre.x - this.metrics.frozenWidth) * clamped - (width - this.rowHeaderWidth) / 2);
      this.scroller.scrollTop = Math.max(0, (centre.y - this.metrics.frozenHeight) * clamped - (height - HEADER_HEIGHT) / 2);
    }
    this.requestDraw();
    this.dispatchEvent(new CustomEvent("zoom", { detail: clamped }));
  }

  /** Sheet x for a screen x inside the grid, or null over the row header. */
  sheetX(screenX) {
    const z = this.zoom, header = this.rowHeaderWidth, frozen = this.metrics.frozenWidth;
    if (screenX < header) return null;
    if (screenX < header + frozen * z) return (screenX - header) / z;
    return frozen + (screenX - header - frozen * z + this.scroller.scrollLeft) / z;
  }

  sheetY(screenY) {
    const z = this.zoom, frozen = this.metrics.frozenHeight;
    if (screenY < HEADER_HEIGHT) return null;
    if (screenY < HEADER_HEIGHT + frozen * z) return (screenY - HEADER_HEIGHT) / z;
    return frozen + (screenY - HEADER_HEIGHT - frozen * z + this.scroller.scrollTop) / z;
  }

  toSheet(screenX, screenY) {
    if (!this.metrics) return null;
    const x = this.sheetX(Math.max(screenX, this.rowHeaderWidth));
    const y = this.sheetY(Math.max(screenY, HEADER_HEIGHT));
    return { x, y };
  }

  screenX(sheetX) {
    const z = this.zoom, frozen = this.metrics.frozenWidth;
    return sheetX < frozen ? this.rowHeaderWidth + sheetX * z : this.rowHeaderWidth + sheetX * z - this.scroller.scrollLeft;
  }

  screenY(sheetY) {
    const z = this.zoom, frozen = this.metrics.frozenHeight;
    return sheetY < frozen ? HEADER_HEIGHT + sheetY * z : HEADER_HEIGHT + sheetY * z - this.scroller.scrollTop;
  }

  /** A sheet rectangle on screen, ignoring which pane it would be clipped to. */
  screenRect(frame) {
    return { x: this.screenX(frame.x), y: this.screenY(frame.y), width: frame.width * this.zoom, height: frame.height * this.zoom };
  }

  cellAt(screenX, screenY) {
    const point = this.toSheet(screenX, screenY);
    if (!point) return null;
    return { row: this.metrics.rowAt(point.y), column: this.metrics.columnAt(point.x) };
  }

  localPoint(event) {
    const box = this.scroller.getBoundingClientRect();
    return { x: event.clientX - box.left, y: event.clientY - box.top };
  }

  /** Scrolls a cell into view, leaving frozen panes alone. */
  reveal(row, column) {
    if (!this.metrics) return;
    const z = this.zoom;
    const frame = this.metrics.cellFrame(row, column);
    const { width, height } = this.viewport;
    if (column >= this.metrics.frozenColumns) {
      const left = (frame.x - this.metrics.frozenWidth) * z;
      const right = left + frame.width * z;
      const visible = width - this.rowHeaderWidth - this.metrics.frozenWidth * z;
      if (left < this.scroller.scrollLeft) this.scroller.scrollLeft = left;
      else if (right > this.scroller.scrollLeft + visible) this.scroller.scrollLeft = right - visible;
    }
    if (row >= this.metrics.frozenRows) {
      const top = (frame.y - this.metrics.frozenHeight) * z;
      const bottom = top + frame.height * z;
      const visible = height - HEADER_HEIGHT - this.metrics.frozenHeight * z;
      if (top < this.scroller.scrollTop) this.scroller.scrollTop = top;
      else if (bottom > this.scroller.scrollTop + visible) this.scroller.scrollTop = bottom - visible;
    }
  }

  // MARK: - Drawing

  themeChanged() {
    const theme = document.documentElement.dataset.theme;
    this.dark = theme ? theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
    this.palette = readPalette();
    this.tiles.clear();
    this.requestDraw();
  }

  resize() {
    const dpr = window.devicePixelRatio || 1;
    const { width, height } = this.viewport;
    this.canvas.width = Math.round(width * dpr);
    this.canvas.height = Math.round(height * dpr);
    this.canvas.style.width = `${width}px`;
    this.canvas.style.height = `${height}px`;
    this.requestDraw();
  }

  requestDraw() {
    if (this.drawQueued) return;
    this.drawQueued = true;
    requestAnimationFrame(() => {
      this.drawQueued = false;
      this.draw();
    });
  }

  tileKey(tx, ty) {
    return `${this.dark ? 1 : 0}|${this.zoom}|${tx}|${ty}`;
  }

  /** The newest bitmap for a tile, requesting a fresh one when it is out of date. */
  tile(tx, ty) {
    const key = this.tileKey(tx, ty);
    const version = this.engine.versions.content * 100000 + this.engine.versions.layout;
    const cached = this.tiles.get(key);
    if ((!cached || cached.version !== version) && !this.pendingTiles.has(key)) {
      this.pendingTiles.add(key);
      const dark = this.dark, zoom = this.zoom;
      this.engine.render({ x: tx * TILE, y: ty * TILE, w: TILE, h: TILE }, dark).then((list) => {
        this.pendingTiles.delete(key);
        if (dark !== this.dark || zoom !== this.zoom) return;
        this.tiles.set(key, { version, canvas: this.rasterize(list, tx, ty) });
        if (this.tiles.size > TILE_LIMIT) this.tiles.delete(this.tiles.keys().next().value);
        this.requestDraw();
      }, () => this.pendingTiles.delete(key));
    }
    return cached?.canvas ?? null;
  }

  rasterize(list, tx, ty) {
    const dpr = window.devicePixelRatio || 1;
    const scale = this.zoom * dpr;
    const size = Math.ceil(TILE * scale);
    const canvas = document.createElement("canvas");
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext("2d");
    ctx.setTransform(scale, 0, 0, scale, -tx * TILE * scale, -ty * TILE * scale);
    ctx.fillStyle = list.paper ? this.palette.paper : this.palette.paper;
    ctx.fillRect(tx * TILE, ty * TILE, TILE, TILE);
    ctx.beginPath();
    ctx.rect(tx * TILE, ty * TILE, TILE, TILE);
    ctx.clip();
    paint(ctx, list, this.palette);
    return canvas;
  }

  /** The four panes: frozen corner, frozen top, frozen left, and the scrolling rest. */
  panes() {
    const m = this.metrics, z = this.zoom, header = this.rowHeaderWidth;
    const { width, height } = this.viewport;
    const fw = m.frozenWidth * z, fh = m.frozenHeight * z;
    const sx = m.frozenWidth + this.scroller.scrollLeft / z;
    const sy = m.frozenHeight + this.scroller.scrollTop / z;
    const panes = [];
    const add = (screen, sheetX, sheetY) => {
      if (screen.width > 0 && screen.height > 0) panes.push({ screen, sheetX, sheetY });
    };
    add({ x: header + fw, y: HEADER_HEIGHT + fh, width: width - header - fw, height: height - HEADER_HEIGHT - fh }, sx, sy);
    add({ x: header, y: HEADER_HEIGHT + fh, width: fw, height: height - HEADER_HEIGHT - fh }, 0, sy);
    add({ x: header + fw, y: HEADER_HEIGHT, width: width - header - fw, height: fh }, sx, 0);
    add({ x: header, y: HEADER_HEIGHT, width: fw, height: fh }, 0, 0);
    return panes;
  }

  draw() {
    const ctx = this.ctx;
    const dpr = window.devicePixelRatio || 1;
    const { width, height } = this.viewport;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const style = getComputedStyle(this.root);
    ctx.fillStyle = style.getPropertyValue("--ds-layer-01");
    ctx.fillRect(0, 0, width, height);
    if (!this.metrics) return;
    const m = this.metrics, z = this.zoom;

    for (const pane of this.panes()) {
      const { screen } = pane;
      ctx.save();
      ctx.beginPath();
      ctx.rect(screen.x, screen.y, screen.width, screen.height);
      ctx.clip();
      // Only the sheet's own extent is paper; past it is the window's background.
      const sheetRight = screen.x + (m.totalWidth - pane.sheetX) * z;
      const sheetBottom = screen.y + (m.totalHeight - pane.sheetY) * z;
      ctx.beginPath();
      ctx.rect(screen.x, screen.y, Math.min(screen.width, sheetRight - screen.x), Math.min(screen.height, sheetBottom - screen.y));
      ctx.clip();
      const x0 = pane.sheetX, y0 = pane.sheetY;
      const x1 = x0 + screen.width / z, y1 = y0 + screen.height / z;
      for (let ty = Math.floor(y0 / TILE); ty * TILE < Math.min(y1, m.totalHeight); ty++) {
        for (let tx = Math.floor(x0 / TILE); tx * TILE < Math.min(x1, m.totalWidth); tx++) {
          const bitmap = this.tile(tx, ty);
          const dx = screen.x + (tx * TILE - x0) * z, dy = screen.y + (ty * TILE - y0) * z;
          if (bitmap) {
            ctx.drawImage(bitmap, dx, dy, TILE * z, TILE * z);
          } else {
            ctx.fillStyle = this.palette.paper;
            ctx.fillRect(dx, dy, TILE * z, TILE * z);
          }
        }
      }
      ctx.restore();
      ctx.save();
      ctx.beginPath();
      ctx.rect(screen.x, screen.y, screen.width, screen.height);
      ctx.clip();
      this.drawSelection(ctx, pane);
      ctx.restore();
    }

    // The lines where frozen panes meet the scrolling ones.
    ctx.fillStyle = style.getPropertyValue("--ds-border-strong-01");
    if (m.frozenColumns > 0) ctx.fillRect(this.rowHeaderWidth + m.frozenWidth * z - 1, HEADER_HEIGHT, 1, height);
    if (m.frozenRows > 0) ctx.fillRect(this.rowHeaderWidth, HEADER_HEIGHT + m.frozenHeight * z - 1, width, 1);

    this.drawHeaders(ctx, style);
    this.placeAddButtons();
    this.positionEditor();
  }

  /** Selection fills and outlines for one pane, in that pane's coordinates. */
  drawSelection(ctx, pane) {
    const state = this.engine.state;
    if (!state || state.sheet !== this.metrics.layout.sheet) return;
    const m = this.metrics, z = this.zoom;
    const toScreen = (frame) => ({
      x: pane.screen.x + (frame.x - pane.sheetX) * z,
      y: pane.screen.y + (frame.y - pane.sheetY) * z,
      width: frame.width * z,
      height: frame.height * z,
    });
    const selectionFill = getComputedStyle(this.root).getPropertyValue("--ds-grid-selection-fill");
    const accent = this.palette.accent;
    const active = state.active;
    const activeFrame = toScreen(m.cellFrame(active[0], active[1]));

    ctx.fillStyle = selectionFill;
    for (const range of state.ranges) {
      if (range[0] === range[2] && range[1] === range[3]) continue;
      const box = toScreen(m.frame(...range));
      ctx.save();
      ctx.beginPath();
      ctx.rect(box.x, box.y, box.width, box.height);
      ctx.rect(activeFrame.x, activeFrame.y, activeFrame.width, activeFrame.height);
      ctx.clip("evenodd");
      ctx.fillRect(box.x, box.y, box.width, box.height);
      ctx.restore();
    }

    // References in a formula being typed, each in its own colour.
    if (this.editing) {
      this.referenceRanges().forEach((range, index) => {
        const box = toScreen(m.frame(...range));
        ctx.strokeStyle = REFERENCE_COLOURS[index % REFERENCE_COLOURS.length];
        ctx.lineWidth = 2;
        ctx.setLineDash([4, 3]);
        ctx.strokeRect(box.x + 1, box.y + 1, box.width - 2, box.height - 2);
        ctx.setLineDash([]);
      });
    }

    const current = state.ranges[state.ranges.length - 1];
    const box = toScreen(m.frame(...(this.fillPreview ?? current)));
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    if (this.fillPreview) ctx.setLineDash([4, 3]);
    ctx.strokeRect(box.x + 1, box.y + 1, box.width - 2, box.height - 2);
    ctx.setLineDash([]);
    if (!this.editing && state.ranges.length === 1) {
      const handle = this.fillHandleRect(pane);
      if (handle) {
        ctx.fillStyle = accent;
        ctx.fillRect(handle.x, handle.y, handle.width, handle.height);
        ctx.strokeStyle = this.palette.paper;
        ctx.lineWidth = 1;
        ctx.strokeRect(handle.x - 0.5, handle.y - 0.5, handle.width + 1, handle.height + 1);
      }
    }
  }

  fillHandleRect(pane) {
    const state = this.engine.state;
    if (!state) return null;
    const current = state.ranges[state.ranges.length - 1];
    const frame = this.metrics.frame(...current);
    const z = this.zoom;
    const x = (pane ? pane.screen.x + (frame.x + frame.width - pane.sheetX) * z : this.screenX(frame.x + frame.width)) - 4;
    const y = (pane ? pane.screen.y + (frame.y + frame.height - pane.sheetY) * z : this.screenY(frame.y + frame.height)) - 4;
    return { x, y, width: 7, height: 7 };
  }

  drawHeaders(ctx, style) {
    const m = this.metrics, z = this.zoom, header = this.rowHeaderWidth;
    const { width, height } = this.viewport;
    const state = this.engine.state;
    const token = (name) => style.getPropertyValue(name);
    const selectedColumns = new Set();
    const selectedRows = new Set();
    if (state) {
      for (const range of state.ranges) {
        for (let c = range[1]; c <= range[3] && c - range[1] < 2000; c++) selectedColumns.add(c);
        for (let r = range[0]; r <= range[2] && r - range[0] < 5000; r++) selectedRows.add(r);
      }
    }
    ctx.font = `12px ${FONT}`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";

    // Column headers.
    ctx.fillStyle = token("--ds-grid-header");
    ctx.fillRect(0, 0, width, HEADER_HEIGHT);
    const drawColumns = (fromX, toX, sheetStart) => {
      ctx.save();
      ctx.beginPath();
      ctx.rect(fromX, 0, toX - fromX, HEADER_HEIGHT);
      ctx.clip();
      let column = m.columnAt(sheetStart);
      while (column < m.layout.columns) {
        const x = fromX + (m.x(column) - sheetStart) * z;
        if (x > toX) break;
        const w = m.width(column) * z;
        if (w > 0) {
          if (selectedColumns.has(column)) {
            ctx.fillStyle = token("--ds-grid-header-selected");
            ctx.fillRect(x, 0, w, HEADER_HEIGHT);
          }
          ctx.fillStyle = selectedColumns.has(column) ? token("--ds-text-primary") : token("--ds-text-secondary");
          ctx.fillText(columnName(column), x + w / 2, HEADER_HEIGHT / 2);
          ctx.fillStyle = token("--ds-grid-line");
          ctx.fillRect(x + w - 1, 0, 1, HEADER_HEIGHT);
        }
        column++;
      }
      ctx.restore();
    };
    const frozenX = header + m.frozenWidth * z;
    if (m.frozenColumns > 0) drawColumns(header, frozenX, 0);
    drawColumns(frozenX, width, m.frozenWidth + this.scroller.scrollLeft / z);

    // Row headers.
    ctx.fillStyle = token("--ds-grid-header");
    ctx.fillRect(0, HEADER_HEIGHT, header, height - HEADER_HEIGHT);
    const drawRows = (fromY, toY, sheetStart) => {
      ctx.save();
      ctx.beginPath();
      ctx.rect(0, fromY, header, toY - fromY);
      ctx.clip();
      let row = m.rowAt(sheetStart);
      while (row < m.layout.rows) {
        const y = fromY + (m.y(row) - sheetStart) * z;
        if (y > toY) break;
        const h = m.height(row) * z;
        if (h > 0) {
          if (selectedRows.has(row)) {
            ctx.fillStyle = token("--ds-grid-header-selected");
            ctx.fillRect(0, y, header, h);
          }
          ctx.fillStyle = selectedRows.has(row) ? token("--ds-text-primary") : token("--ds-text-secondary");
          ctx.fillText(String(row + 1), header / 2, y + h / 2);
          ctx.fillStyle = token("--ds-grid-line");
          ctx.fillRect(0, y + h - 1, header, 1);
        }
        row++;
      }
      ctx.restore();
    };
    const frozenY = HEADER_HEIGHT + m.frozenHeight * z;
    if (m.frozenRows > 0) drawRows(HEADER_HEIGHT, frozenY, 0);
    drawRows(frozenY, height, m.frozenHeight + this.scroller.scrollTop / z);

    ctx.fillStyle = token("--ds-border-subtle-01");
    ctx.fillRect(0, HEADER_HEIGHT - 1, width, 1);
    ctx.fillRect(header - 1, 0, 1, height);
    ctx.fillStyle = token("--ds-grid-header");
    ctx.fillRect(0, 0, header - 1, HEADER_HEIGHT - 1);

    if (this.resizeGuide) {
      ctx.fillStyle = this.palette.accent;
      if (this.resizeGuide.axis === "column") ctx.fillRect(this.resizeGuide.at - 1, 0, 2, height);
      else ctx.fillRect(0, this.resizeGuide.at - 1, width, 2);
    }
  }

  placeAddButtons() {
    const m = this.metrics;
    const { width, height } = this.viewport;
    const right = this.screenX(m.totalWidth);
    const bottom = this.screenY(m.totalHeight);
    const show = (button, x, y) => {
      const visible = x > this.rowHeaderWidth && y > HEADER_HEIGHT && x < width - 8 && y < height - 8;
      button.hidden = !visible;
      if (visible) button.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
    };
    show(this.addColumnButton, right + 4, Math.max(HEADER_HEIGHT + 4, Math.min(bottom - 28, HEADER_HEIGHT + 4)));
    show(this.addRowButton, this.rowHeaderWidth + 4, bottom + 4);
  }

  // MARK: - Editing

  get isEditing() {
    return Boolean(this.editing);
  }

  /** Ranges named in the formula being typed, for highlighting. */
  referenceRanges() {
    const text = this.editor.value;
    if (!text.startsWith("=")) return [];
    const ranges = [];
    const pattern = /(?:'[^']*'|[A-Za-z0-9_.]+)?!?\$?([A-Za-z]{1,3})\$?(\d+)(?::\$?([A-Za-z]{1,3})\$?(\d+))?/g;
    for (const match of text.matchAll(pattern)) {
      if (match[0].includes("!")) continue;
      const before = text[match.index - 1];
      if (before && /[A-Za-z0-9_"]/.test(before)) continue;
      const column = (letters) => [...letters.toUpperCase()].reduce((n, c) => n * 26 + c.charCodeAt(0) - 64, 0) - 1;
      const r1 = Number(match[2]) - 1, c1 = column(match[1]);
      const r2 = match[4] ? Number(match[4]) - 1 : r1, c2 = match[3] ? column(match[3]) : c1;
      if (r1 < 0 || c1 < 0 || r2 < 0 || c2 < 0) continue;
      ranges.push([Math.min(r1, r2), Math.min(c1, c2), Math.max(r1, r2), Math.max(c1, c2)]);
    }
    return ranges;
  }

  /**
   * Opens the editor on the active cell. `seed` replaces the contents (typing
   * over a cell); otherwise the cell's own text is edited.
   */
  beginEdit({ seed = null, mode = "edit", focusEditor = true } = {}) {
    const state = this.engine.state;
    if (!state || this.metrics?.layout.chart) return;
    const [row, column] = state.active;
    this.editing = { row, column, mode, original: state.editText, references: null };
    this.editor.value = seed ?? state.editText;
    this.editor.classList.add("is-editing");
    this.positionEditor();
    if (focusEditor) {
      this.editor.focus({ preventScroll: true });
      const end = this.editor.value.length;
      this.editor.setSelectionRange(end, end);
    }
    this.dispatchEvent(new CustomEvent("edit", { detail: this.editor.value }));
    this.requestDraw();
  }

  /** Sets the text being edited from elsewhere, such as the formula bar. */
  setEditText(text) {
    if (!this.editing) this.beginEdit({ mode: "edit", focusEditor: false });
    this.editor.value = text;
    this.editor.setSelectionRange(text.length, text.length);
    this.positionEditor();
    this.requestDraw();
  }

  async commitEdit(advance = "down") {
    if (!this.editing) return;
    const { row, column } = this.editing;
    const text = this.editor.value;
    this.endEdit();
    try {
      await this.engine.call("commit", { row, column, text, advance: advance ?? undefined });
    } catch (error) {
      this.dispatchEvent(new CustomEvent("message", { detail: error.message }));
    }
    const state = this.engine.state;
    if (state) this.reveal(state.active[0], state.active[1]);
  }

  cancelEdit() {
    if (!this.editing) return;
    this.endEdit();
  }

  endEdit() {
    this.editing = null;
    this.pointing = null;
    this.editor.classList.remove("is-editing");
    this.editor.value = "";
    this.dispatchEvent(new CustomEvent("editend"));
    this.focus();
    this.requestDraw();
  }

  focus() {
    this.editor.focus({ preventScroll: true });
  }

  syncEditor() {
    if (!this.editing) this.positionEditor();
  }

  /** Keeps the editor over the active cell; hidden, but focused, while not editing, so typing and IME input start an edit. */
  positionEditor() {
    const state = this.engine.state;
    if (!state || !this.metrics) return;
    const [row, column] = this.editing ? [this.editing.row, this.editing.column] : state.active;
    const frame = this.screenRect(this.metrics.cellFrame(row, column));
    const z = this.zoom;
    const style = this.editor.style;
    style.left = `${Math.round(frame.x)}px`;
    style.top = `${Math.round(frame.y)}px`;
    style.minWidth = `${Math.round(frame.width)}px`;
    style.minHeight = `${Math.round(frame.height)}px`;
    style.fontSize = `${(state.style.fontSize ?? 12) * z}px`;
    style.fontWeight = state.style.bold ? "600" : "400";
    style.fontStyle = state.style.italic ? "italic" : "normal";
    if (this.editing) {
      // Grow with the text, as far as the window allows.
      style.width = "0px";
      style.height = "0px";
      const maxWidth = this.viewport.width - frame.x - 8;
      style.width = `${Math.max(frame.width, Math.min(this.editor.scrollWidth + 4, maxWidth))}px`;
      style.height = `${Math.max(frame.height, this.editor.scrollHeight)}px`;
    } else {
      style.width = `${Math.round(frame.width)}px`;
      style.height = `${Math.round(frame.height)}px`;
    }
  }

  /** While a formula is being typed, clicking a cell writes its reference in. */
  get isPointing() {
    if (!this.editing) return false;
    const text = this.editor.value;
    const caret = this.editor.selectionStart;
    if (!text.startsWith("=")) return false;
    if (this.pointing) return true;
    const before = text.slice(0, caret).trimEnd();
    return /[=(,+\-*/^&<>:;]$/.test(before);
  }

  insertReference(range) {
    const text = this.editor.value;
    const box = [Math.min(range[0], range[2]), Math.min(range[1], range[3]), Math.max(range[0], range[2]), Math.max(range[1], range[3])];
    const reference = box[0] === box[2] && box[1] === box[3]
      ? `${columnName(box[1])}${box[0] + 1}`
      : `${columnName(box[1])}${box[0] + 1}:${columnName(box[3])}${box[2] + 1}`;
    let start = this.editor.selectionStart;
    if (this.pointing) {
      start = this.pointing.start;
    }
    const after = text.slice(this.pointing ? this.pointing.end : this.editor.selectionEnd);
    this.editor.value = text.slice(0, start) + reference + after;
    this.pointing = { start, end: start + reference.length };
    this.editor.setSelectionRange(start + reference.length, start + reference.length);
    this.dispatchEvent(new CustomEvent("edit", { detail: this.editor.value }));
    this.positionEditor();
    this.requestDraw();
  }

  // MARK: - Pointer

  bindPointer() {
    const el = this.scroller;
    el.addEventListener("pointermove", (event) => {
      if (this.drag) return;
      el.style.cursor = this.cursorFor(this.localPoint(event));
    });
    el.addEventListener("pointerdown", (event) => this.pointerDown(event));
    el.addEventListener("pointermove", (event) => this.pointerMove(event));
    el.addEventListener("pointerup", (event) => this.pointerUp(event));
    el.addEventListener("pointercancel", () => this.endDrag());
    el.addEventListener("dblclick", (event) => this.doubleClick(event));
    el.addEventListener("wheel", (event) => {
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      this.setZoom(this.zoom * (event.deltaY < 0 ? 1.1 : 1 / 1.1));
    }, { passive: false });
  }

  hit(point) {
    if (!this.metrics) return { kind: "none" };
    const header = this.rowHeaderWidth;
    const z = this.zoom;
    if (point.x < header && point.y < HEADER_HEIGHT) return { kind: "corner" };
    if (point.y < HEADER_HEIGHT) {
      const x = this.sheetX(point.x);
      if (x == null || x > this.metrics.totalWidth + RESIZE_SLOP / z) return { kind: "none" };
      const edge = this.metrics.columns.boundaryNear(x, RESIZE_SLOP / z);
      if (edge >= 0) return { kind: "columnEdge", index: edge };
      if (x > this.metrics.totalWidth) return { kind: "none" };
      return { kind: "columnHeader", index: this.metrics.columnAt(x) };
    }
    if (point.x < header) {
      const y = this.sheetY(point.y);
      if (y == null || y > this.metrics.totalHeight + RESIZE_SLOP / z) return { kind: "none" };
      const edge = this.metrics.rows.boundaryNear(y, RESIZE_SLOP / z);
      if (edge >= 0) return { kind: "rowEdge", index: edge };
      if (y > this.metrics.totalHeight) return { kind: "none" };
      return { kind: "rowHeader", index: this.metrics.rowAt(y) };
    }
    const handle = this.fillHandleRect();
    if (handle && !this.editing && point.x >= handle.x - 3 && point.x <= handle.x + handle.width + 3
        && point.y >= handle.y - 3 && point.y <= handle.y + handle.height + 3) {
      return { kind: "fillHandle" };
    }
    const sheet = this.toSheet(point.x, point.y);
    if (sheet.x > this.metrics.totalWidth || sheet.y > this.metrics.totalHeight) return { kind: "outside" };
    return { kind: "cell", row: this.metrics.rowAt(sheet.y), column: this.metrics.columnAt(sheet.x) };
  }

  cursorFor(point) {
    const hit = this.hit(point);
    switch (hit.kind) {
      case "columnEdge": return "col-resize";
      case "rowEdge": return "row-resize";
      case "fillHandle": return "crosshair";
      case "cell": return "cell";
      default: return "default";
    }
  }

  async pointerDown(event) {
    if (event.button !== 0) return;
    const point = this.localPoint(event);
    const hit = this.hit(point);
    const state = this.engine.state;
    try {
      this.scroller.setPointerCapture(event.pointerId);
    } catch {
      // A pointer the browser no longer tracks; the drag still works without capture.
    }
    const extend = event.shiftKey;
    const add = event.metaKey || event.ctrlKey;

    switch (hit.kind) {
      case "corner":
        event.preventDefault();
        await this.commitIfEditing();
        await this.engine.call("selectAll");
        break;
      case "columnEdge":
      case "rowEdge": {
        event.preventDefault();
        const isColumn = hit.kind === "columnEdge";
        const start = isColumn ? this.metrics.x(hit.index) : this.metrics.y(hit.index);
        this.drag = { kind: "resize", isColumn, index: hit.index, start, origin: isColumn ? point.x : point.y,
          size: isColumn ? this.metrics.width(hit.index) : this.metrics.height(hit.index) };
        break;
      }
      case "columnHeader":
      case "rowHeader": {
        event.preventDefault();
        await this.commitIfEditing();
        const isColumn = hit.kind === "columnHeader";
        const anchor = extend && state ? (isColumn ? state.anchor[1] : state.anchor[0]) : hit.index;
        this.drag = { kind: isColumn ? "columns" : "rows", anchor, last: hit.index };
        await this.engine.call(isColumn ? "selectColumns" : "selectRows", { from: anchor, to: hit.index });
        break;
      }
      case "fillHandle":
        event.preventDefault();
        this.drag = { kind: "fill", target: null };
        break;
      case "cell": {
        event.preventDefault();
        if (this.editing && this.isPointing && !(hit.row === this.editing.row && hit.column === this.editing.column)) {
          this.drag = { kind: "point", anchor: [hit.row, hit.column] };
          this.insertReference([hit.row, hit.column, hit.row, hit.column]);
          return;
        }
        if (this.editing && hit.row === this.editing.row && hit.column === this.editing.column) return;
        await this.commitIfEditing();
        const wasActive = state && state.active[0] === hit.row && state.active[1] === hit.column && state.ranges.length === 1
          && state.selection[0] === state.selection[2] && state.selection[1] === state.selection[3];
        this.drag = { kind: "cells", last: [hit.row, hit.column], toggles: wasActive && state.style.checkbox && !extend && !add };
        await this.engine.call("select", { row: hit.row, column: hit.column, extend, add });
        break;
      }
      default:
        await this.commitIfEditing();
    }
    this.focus();
  }

  async commitIfEditing() {
    if (this.editing) await this.commitEdit(null);
  }

  async pointerMove(event) {
    const drag = this.drag;
    if (!drag) return;
    const point = this.localPoint(event);
    this.autoScroll(point);
    switch (drag.kind) {
      case "resize": {
        const delta = ((drag.isColumn ? point.x : point.y) - drag.origin) / this.zoom;
        drag.newSize = Math.max(drag.isColumn ? 24 : 12, drag.size + delta);
        const edge = drag.start + drag.newSize;
        this.resizeGuide = { axis: drag.isColumn ? "column" : "row", at: drag.isColumn ? this.screenX(edge) : this.screenY(edge) };
        this.requestDraw();
        break;
      }
      case "columns":
      case "rows": {
        const isColumn = drag.kind === "columns";
        const sheet = this.toSheet(point.x, point.y);
        const index = isColumn ? this.metrics.columnAt(sheet.x) : this.metrics.rowAt(sheet.y);
        if (index === drag.last) return;
        drag.last = index;
        await this.engine.call(isColumn ? "selectColumns" : "selectRows", { from: drag.anchor, to: index });
        break;
      }
      case "cells": {
        const cell = this.cellAt(point.x, point.y);
        if (!cell || (cell.row === drag.last[0] && cell.column === drag.last[1])) return;
        drag.last = [cell.row, cell.column];
        drag.toggles = false;
        await this.engine.call("select", { row: cell.row, column: cell.column, extend: true });
        break;
      }
      case "point": {
        const cell = this.cellAt(point.x, point.y);
        if (!cell) return;
        this.insertReference([drag.anchor[0], drag.anchor[1], cell.row, cell.column]);
        break;
      }
      case "fill": {
        const cell = this.cellAt(point.x, point.y);
        if (!cell) return;
        const key = `${cell.row},${cell.column}`;
        if (key === drag.key) return;
        drag.key = key;
        const target = await this.engine.call("fillTarget", { row: cell.row, column: cell.column });
        drag.target = target;
        this.fillPreview = target;
        this.requestDraw();
        break;
      }
    }
  }

  async pointerUp(event) {
    const drag = this.drag;
    this.endDrag();
    if (!drag) return;
    switch (drag.kind) {
      case "resize":
        this.resizeGuide = null;
        this.requestDraw();
        if (drag.newSize != null && Math.abs(drag.newSize - drag.size) > 0.5) {
          await this.engine.call(drag.isColumn ? "resizeColumn" : "resizeRow",
            drag.isColumn ? { column: drag.index, width: drag.newSize } : { row: drag.index, height: drag.newSize });
        }
        break;
      case "fill":
        this.fillPreview = null;
        if (drag.target) {
          const [row, column, endRow, endColumn] = drag.target;
          await this.engine.call("fill", { row, column, endRow, endColumn });
        }
        this.requestDraw();
        break;
      case "cells":
        if (drag.toggles) {
          const [row, column] = drag.last;
          await this.engine.call("toggleCheckbox", { row, column });
        }
        break;
      case "point":
        this.pointing = null;
        this.editor.focus({ preventScroll: true });
        break;
    }
  }

  endDrag() {
    this.drag = null;
    clearInterval(this.scrollTimer);
    this.scrollTimer = null;
  }

  /** Scrolls while a drag is held past the edge of the grid. */
  autoScroll(point) {
    const { width, height } = this.viewport;
    const dx = point.x > width - 16 ? 16 : point.x < this.rowHeaderWidth ? -16 : 0;
    const dy = point.y > height - 16 ? 16 : point.y < HEADER_HEIGHT ? -16 : 0;
    clearInterval(this.scrollTimer);
    this.scrollTimer = null;
    if (!dx && !dy) return;
    this.scrollTimer = setInterval(() => this.scroller.scrollBy(dx, dy), 30);
  }

  async doubleClick(event) {
    const hit = this.hit(this.localPoint(event));
    if (hit.kind === "columnEdge") {
      await this.fitColumn(hit.index);
    } else if (hit.kind === "cell") {
      if (this.editing) return;
      this.beginEdit({ mode: "edit" });
    }
  }

  /** Sizes a column to its widest entry, measured with the browser's fonts. */
  async fitColumn(column) {
    const texts = await this.engine.call("columnTexts", { column });
    const ctx = this.ctx;
    let widest = 0;
    for (const entry of texts ?? []) {
      ctx.font = fontFor({ fs: entry.fs, b: entry.b, i: entry.i });
      for (const line of entry.t.split("\n")) widest = Math.max(widest, ctx.measureText(line).width);
    }
    await this.engine.call("fitColumn", { column, width: widest });
  }

  // MARK: - Keyboard

  bindKeyboard() {
    const editor = this.editor;
    editor.addEventListener("keydown", (event) => this.keyDown(event));
    editor.addEventListener("compositionstart", () => {
      if (!this.editing) this.beginEdit({ seed: "", mode: "enter" });
    });
    editor.addEventListener("input", () => {
      if (!this.editing) {
        // Typed while the grid was focused: this starts an edit replacing the cell.
        const typed = editor.value;
        this.beginEdit({ seed: typed, mode: "enter" });
        return;
      }
      this.pointing = null;
      this.positionEditor();
      this.dispatchEvent(new CustomEvent("edit", { detail: editor.value }));
      this.requestDraw();
    });
    editor.addEventListener("blur", () => {
      // Leaving for another control keeps the edit open; the formula bar continues it.
    });
  }

  async keyDown(event) {
    if (event.isComposing || event.keyCode === 229) return;
    const command = event.metaKey || event.ctrlKey;
    if (this.editing) {
      switch (event.key) {
        case "Enter":
          if (event.altKey || (event.ctrlKey && !event.metaKey && navigator.platform.startsWith("Mac"))) {
            // A line break within the cell.
            event.preventDefault();
            const { selectionStart: s, selectionEnd: e, value } = this.editor;
            this.editor.value = value.slice(0, s) + "\n" + value.slice(e);
            this.editor.setSelectionRange(s + 1, s + 1);
            this.editor.dispatchEvent(new Event("input"));
            return;
          }
          event.preventDefault();
          await this.commitEdit(event.shiftKey ? "up" : "down");
          return;
        case "Tab":
          event.preventDefault();
          await this.commitEdit(event.shiftKey ? "left" : "right");
          return;
        case "Escape":
          event.preventDefault();
          this.cancelEdit();
          return;
        case "ArrowUp": case "ArrowDown": case "ArrowLeft": case "ArrowRight":
          // Typed straight into a cell, arrows move on as Excel's Enter mode does.
          if (this.editing.mode === "enter" && !this.isPointing && !event.shiftKey && !command) {
            event.preventDefault();
            await this.commitEdit({ ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" }[event.key]);
          }
          return;
        default:
          return;
      }
    }

    const directions = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" };
    if (directions[event.key] && !event.altKey) {
      event.preventDefault();
      await this.engine.call("move", { dir: directions[event.key], extend: event.shiftKey, edge: command });
      this.revealSelectionEnd();
      return;
    }
    if (command || event.altKey) return;
    switch (event.key) {
      case "Tab":
        event.preventDefault();
        await this.engine.call("move", { dir: event.shiftKey ? "left" : "right" });
        this.revealSelectionEnd();
        return;
      case "Enter":
        event.preventDefault();
        await this.engine.call("move", { dir: event.shiftKey ? "up" : "down" });
        this.revealSelectionEnd();
        return;
      case "F2":
        event.preventDefault();
        this.beginEdit({ mode: "edit" });
        return;
      case "Backspace":
      case "Delete":
        event.preventDefault();
        await this.engine.call("clear");
        return;
      case "PageDown":
      case "PageUp": {
        event.preventDefault();
        const rows = Math.max(1, Math.floor((this.viewport.height - HEADER_HEIGHT) / ((this.metrics.layout.rowHeight || 20) * this.zoom)) - 1);
        for (let i = 0; i < rows; i++) await this.engine.call("move", { dir: event.key === "PageDown" ? "down" : "up", extend: event.shiftKey });
        this.revealSelectionEnd();
        return;
      }
      case " ":
        if (this.engine.state?.style.checkbox) {
          event.preventDefault();
          const [row, column] = this.engine.state.active;
          await this.engine.call("toggleCheckbox", { row, column });
        }
        return;
    }
  }

  revealSelectionEnd() {
    const state = this.engine.state;
    if (!state) return;
    this.reveal(state.selection[2], state.selection[3]);
  }

  // MARK: - Clipboard

  bindClipboard() {
    const handles = () => !this.editing && document.activeElement === this.editor;
    document.addEventListener("copy", (event) => {
      if (!handles()) return;
      event.preventDefault();
      this.copy(false);
    });
    document.addEventListener("cut", (event) => {
      if (!handles()) return;
      event.preventDefault();
      this.copy(true);
    });
    document.addEventListener("paste", (event) => {
      if (!handles()) return;
      event.preventDefault();
      const text = event.clipboardData?.getData("text/plain") ?? "";
      this.engine.call("paste", { text });
    });
  }

  /** Copies (or cuts) the selection to the system clipboard as tab-separated text. */
  copy(cut) {
    const result = this.engine.call(cut ? "cut" : "copy");
    const text = result.then((r) => r.text);
    // ClipboardItem with a promise keeps the user's gesture in Safari while the worker answers.
    if (typeof ClipboardItem !== "undefined" && navigator.clipboard?.write) {
      const item = new ClipboardItem({ "text/plain": text.then((t) => new Blob([t], { type: "text/plain" })) });
      navigator.clipboard.write([item]).catch(() => text.then((t) => navigator.clipboard.writeText?.(t)).catch(() => {}));
    } else {
      text.then((t) => navigator.clipboard?.writeText?.(t)).catch(() => {});
    }
    return result;
  }

  /** Pastes from the system clipboard, for the menu command (keyboard paste uses the paste event). */
  async pasteFromClipboard() {
    let text = null;
    try {
      text = await navigator.clipboard.readText();
    } catch {
      // Without permission, paste what this window last copied.
    }
    await this.engine.call("paste", text == null ? {} : { text });
  }

  // MARK: - Context menus

  contextMenu(event) {
    const hit = this.hit(this.localPoint(event));
    const state = this.engine.state;
    if (hit.kind === "cell") {
      const inSelection = state?.ranges.some((r) => hit.row >= r[0] && hit.row <= r[2] && hit.column >= r[1] && hit.column <= r[3]);
      if (!inSelection) this.engine.call("select", { row: hit.row, column: hit.column });
      return this.options.contextMenu("cell", event, hit);
    }
    if (hit.kind === "columnHeader" || hit.kind === "rowHeader") {
      const isColumn = hit.kind === "columnHeader";
      const selected = state?.ranges.some((r) => (isColumn ? hit.index >= r[1] && hit.index <= r[3] : hit.index >= r[0] && hit.index <= r[2]));
      if (!selected) this.engine.call(isColumn ? "selectColumns" : "selectRows", { from: hit.index, to: hit.index });
      return this.options.contextMenu(isColumn ? "column" : "row", event, hit);
    }
    return null;
  }
}

const FONT = "system-ui, -apple-system, BlinkMacSystemFont, sans-serif";
const REFERENCE_COLOURS = ["#2EA666", "#0F62FE", "#DA1E28", "#8A3FFC", "#FF832B", "#009D9A"];
