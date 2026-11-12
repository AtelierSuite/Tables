// The sheet on screen: a canvas drawn from engine-rendered tiles, over a native
// scrolling layer, with headers, frozen panes, selection, the cell editor,
// resizing, the fill handle and the clipboard.
//
// A sheet laid out with others on a canvas, as a Numbers sheet holds its
// tables, is shown on that canvas's page instead, as the Mac's CanvasView
// shows it: the active table is the grid, carried to its place with its
// headers round it, and the others are drawn about it until one is clicked.
// A table is moved by the corner where its headers meet, or by the edge just
// outside its cells, and snaps into line with the tables around it.
//
// Events: "edit" (editing started or text changed), "editend", "message".

import { SheetMetrics, columnName } from "./metrics.js";
import { paint, readPalette, fontFor, familyFor, cssColor } from "./paint.js";
import { attachContextMenu } from "../design/menus.js";

const TILE = 256;
const HEADER_HEIGHT = 24;
const RESIZE_SLOP = 4;
const EXTRA_ROOM = 64;
const TILE_LIMIT = 240;
const MIN_ZOOM = 0.5;
const MAX_ZOOM = 3;
/** How long zooming must pause before tiles are drawn again at the new scale. */
const ZOOM_SETTLE = 160;
/** The room Tables leaves round what it places on a canvas, and a table name's height, in points at 100% (SheetCanvas). */
const CANVAS_MARGIN = 40;
const NAME_HEIGHT = 26;
/**
 * How far in from the page's left edge its tables start: room for the widest
 * row numbers a sheet can have (1,048,576 rows), so the page never shifts as
 * tables are picked, as the Mac's CanvasSnapping.pageInset keeps it.
 */
const PAGE_INSET_X = rowHeaderWidthFor(1048576) + 4;
/** How far outside its cells a table can be picked up, and how close it comes before it snaps into line. */
const GRAB_SLOP = 5;
/** How far a press on the bare page may move and still count as a tap on it. */
const PAGE_TAP_SLOP = 8;
const SNAP_THRESHOLD = 6;
/** How opaque the headers are while their table is dragged, so what it passes over shows through. */
const DRAGGING_HEADER_OPACITY = 0.4;

function rowHeaderWidthFor(rows) {
  return Math.max(40, 8 * String(rows).length + 18);
}

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
    /** Each sheet's own background ("AARRGGBB", or null for the theme's paper), as its tiles last reported it. */
    this.papers = new Map();
    /** The canvas the active sheet is on, from the engine's document info, or null for a sheet of its own. */
    this.canvasInfo = null;
    /** The other tables' row and column geometry, by sheet id. */
    this.tableLayouts = new Map();
    this.tableLayoutGeneration = 0;
    /** How far the table being dragged has come, once snapped: { id, dx, dy } in screen pixels. */
    this.tableDrag = null;
    this.guides = [];
    /** The field a table's name is being typed in: { id, input, original }. */
    this.renaming = null;
    /**
     * Set when the bare page around a canvas's tables was clicked: no table is
     * worked on, so the active one shows no selection or headers. Holds the
     * selection it hid, so the next change to the selection brings it back.
     */
    this.unfocused = null;

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
    engine.addEventListener("document", () => {
      this.refreshCanvas();
      this.updateSpacer();
      this.requestDraw();
    });
    engine.addEventListener("content", () => this.requestDraw());
    engine.addEventListener("state", (event) => {
      if (this.unfocused && this.unfocused !== selectionKey(event.detail)) this.unfocused = null;
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
    if (this.hidesHeadings) return 0;
    return rowHeaderWidthFor(this.metrics ? this.metrics.layout.rows : 1);
  }

  /** How tall the column letters are: none on a sheet of its own with its headings turned off. */
  get headerHeight() {
    return this.hidesHeadings ? 0 : HEADER_HEIGHT;
  }

  /** Whether the sheet, shown as a grid of its own, has its headings turned off. */
  get hidesHeadings() {
    return !this.onCanvas && this.metrics?.layout.showsHeadings === false;
  }

  get viewport() {
    return { width: this.scroller.clientWidth, height: this.scroller.clientHeight };
  }

  setLayout(layout) {
    const sheetChanged = this.metrics?.layout.sheet !== layout.sheet;
    const wasOnCanvas = this.onCanvas;
    // A table on a canvas is shown whole, where it sits: nothing in it scrolls, so nothing freezes.
    const onCanvas = Boolean(this.canvasContaining(layout.sheet));
    this.metrics = new SheetMetrics(onCanvas ? { ...layout, frozenRows: 0, frozenColumns: 0 } : layout);
    this.refreshCanvas();
    this.tiles.clear();
    this.updateSpacer();
    if (sheetChanged) {
      this.unfocused = null;
      this.cancelEdit();
      this.endRenamingTable(false);
      if (this.onCanvas) this.revealTableHead(!wasOnCanvas);
      else this.scroller.scrollTo(0, 0);
    }
    this.requestDraw();
  }

  updateSpacer() {
    if (!this.metrics) return;
    const z = this.zoom;
    if (this.onCanvas) {
      // The page holds every table with room to spare; the scroller fills the window regardless.
      const frames = this.tableFrames();
      const margin = CANVAS_MARGIN * z;
      this.spacer.style.width = `${Math.max(0, ...frames.map((f) => f.x + f.width)) + margin}px`;
      this.spacer.style.height = `${Math.max(0, ...frames.map((f) => f.y + f.height)) + margin * 2}px`;
      return;
    }
    this.spacer.style.width = `${this.rowHeaderWidth + this.metrics.totalWidth * z + EXTRA_ROOM}px`;
    this.spacer.style.height = `${this.headerHeight + this.metrics.totalHeight * z + EXTRA_ROOM}px`;
  }

  /**
   * Zooms about a point on screen (the pointer or the fingers; the middle of
   * the grid by default), keeping the part of the sheet under it in place, as
   * the Apple apps' pinch does. A gesture passes the sheet point it started
   * over as `pinned`, so rounded scroll positions can't make it drift, and
   * moving fingers carry the sheet with them.
   */
  setZoom(zoom, anchor = null, pinned = null) {
    if (!this.metrics) return;
    const clamped = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom));
    if (Math.abs(clamped - this.zoom) < 0.0005 && !pinned) return;
    const { width, height } = this.viewport;
    if (this.onCanvas) {
      // The whole page scales about the anchor, the tables and the room between them alike.
      const point = anchor ?? { x: width / 2, y: height / 2 };
      const before = pinned?.page ?? this.pagePoint(point);
      this.zoom = clamped;
      this.updateSpacer();
      this.scroller.scrollLeft = Math.max(0, PAGE_INSET_X + before.x * clamped - point.x);
      this.scroller.scrollTop = Math.max(0, this.pageInsetY() + before.y * clamped - point.y);
      this.zoomSettling();
      this.requestDraw();
      this.dispatchEvent(new CustomEvent("zoom", { detail: clamped }));
      return;
    }
    const point = anchor ?? { x: (this.rowHeaderWidth + width) / 2, y: (this.headerHeight + height) / 2 };
    const header = this.rowHeaderWidth;
    const m = this.metrics;
    // The sheet point under the anchor, before zooming.
    const before = pinned ?? this.toSheet(Math.max(point.x, header), Math.max(point.y, this.headerHeight));
    const previous = this.zoom;
    this.zoom = clamped;
    this.updateSpacer();
    // Where that point must scroll to so it lands under the anchor again. In a
    // frozen pane nothing scrolls, so the rest keeps its proportion.
    const left = before.x >= m.frozenWidth
      ? (before.x - m.frozenWidth) * clamped - (point.x - header - m.frozenWidth * clamped)
      : this.scroller.scrollLeft * clamped / previous;
    const top = before.y >= m.frozenHeight
      ? (before.y - m.frozenHeight) * clamped - (point.y - this.headerHeight - m.frozenHeight * clamped)
      : this.scroller.scrollTop * clamped / previous;
    this.scroller.scrollLeft = Math.max(0, left);
    this.scroller.scrollTop = Math.max(0, top);
    this.zoomSettling();
    this.requestDraw();
    this.dispatchEvent(new CustomEvent("zoom", { detail: clamped }));
  }

  /** The sheet point under a screen point, for a gesture to hold under the fingers. */
  pinnedPoint(point) {
    if (this.onCanvas) return { page: this.pagePoint(point) };
    return this.toSheet(Math.max(point.x, this.rowHeaderWidth), Math.max(point.y, this.headerHeight));
  }

  /** While zooming, existing tiles are stretched; once it pauses they are drawn again sharp. */
  zoomSettling() {
    this.isZooming = true;
    clearTimeout(this.zoomTimer);
    this.zoomTimer = setTimeout(() => {
      this.isZooming = false;
      this.requestDraw();
    }, ZOOM_SETTLE);
  }

  /**
   * Where the active sheet's first cell would be on screen if it scrolled with
   * the rest: past the headers on a sheet of its own, and at its table's place
   * on a canvas's page.
   */
  get originX() {
    return (this.onCanvas ? this.activePage().x : this.rowHeaderWidth) - this.scroller.scrollLeft;
  }

  get originY() {
    return (this.onCanvas ? this.activePage().y : this.headerHeight) - this.scroller.scrollTop;
  }

  /** Sheet x for a screen x inside the grid, or null over the row header. */
  sheetX(screenX) {
    const z = this.zoom, header = this.rowHeaderWidth, frozen = this.metrics.frozenWidth;
    if (this.onCanvas) return (screenX - this.originX) / z;
    if (screenX < header) return null;
    if (screenX < header + frozen * z) return (screenX - header) / z;
    return (screenX - this.originX) / z;
  }

  sheetY(screenY) {
    const z = this.zoom, frozen = this.metrics.frozenHeight;
    if (this.onCanvas) return (screenY - this.originY) / z;
    if (screenY < this.headerHeight) return null;
    if (screenY < this.headerHeight + frozen * z) return (screenY - this.headerHeight) / z;
    return (screenY - this.originY) / z;
  }

  toSheet(screenX, screenY) {
    if (!this.metrics) return null;
    if (this.onCanvas) return { x: this.sheetX(screenX), y: this.sheetY(screenY) };
    const x = this.sheetX(Math.max(screenX, this.rowHeaderWidth));
    const y = this.sheetY(Math.max(screenY, this.headerHeight));
    return { x, y };
  }

  screenX(sheetX) {
    const z = this.zoom, frozen = this.metrics.frozenWidth;
    return sheetX < frozen ? this.rowHeaderWidth + sheetX * z : this.originX + sheetX * z;
  }

  screenY(sheetY) {
    const z = this.zoom, frozen = this.metrics.frozenHeight;
    return sheetY < frozen ? this.headerHeight + sheetY * z : this.originY + sheetY * z;
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
    if (this.onCanvas) {
      this.scrollIntoView(this.screenRect(frame));
      return;
    }
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
      const visible = height - this.headerHeight - this.metrics.frozenHeight * z;
      if (top < this.scroller.scrollTop) this.scroller.scrollTop = top;
      else if (bottom > this.scroller.scrollTop + visible) this.scroller.scrollTop = bottom - visible;
    }
  }

  // MARK: - Canvas

  /** The canvas a sheet shares with others, from the engine's document info. */
  canvasContaining(id) {
    if (!id) return null;
    return (this.engine.info?.canvases ?? []).find((canvas) => canvas.tables.some((table) => table.id === id)) ?? null;
  }

  /** Whether the active sheet is shown as one of several tables on a canvas's page. */
  get onCanvas() {
    return Boolean(this.metrics && this.canvasInfo);
  }

  /** The canvas's tables as the engine last reported them, the other tables' geometry fetched afresh. */
  refreshCanvas() {
    const id = this.metrics?.layout.sheet;
    this.canvasInfo = this.canvasContaining(id);
    const generation = ++this.tableLayoutGeneration;
    const kept = this.tableLayouts;
    this.tableLayouts = new Map();
    if (!this.canvasInfo) return;
    for (const table of this.canvasInfo.tables) {
      if (table.id === id) continue;
      // Drawn as they were until the fresh geometry comes, so nothing flickers.
      if (kept.has(table.id)) this.tableLayouts.set(table.id, kept.get(table.id));
      this.engine.layoutOf(table.id).then((layout) => {
        if (generation !== this.tableLayoutGeneration) return;
        this.tableLayouts.set(table.id, new SheetMetrics({ ...layout, frozenRows: 0, frozenColumns: 0 }));
        this.updateSpacer();
        this.requestDraw();
      }, () => {});
    }
  }

  /** How far down the page its tables start: room for a table's column letters and its name above them. */
  pageInsetY(zoom = this.zoom) {
    return this.headerHeight + NAME_HEIGHT * zoom + 4;
  }

  /** A point on screen as a place on the page, in points at 100%, as tables are placed. */
  pagePoint(point) {
    return {
      x: (point.x + this.scroller.scrollLeft - PAGE_INSET_X) / this.zoom,
      y: (point.y + this.scroller.scrollTop - this.pageInsetY()) / this.zoom,
    };
  }

  /** Where a table on the canvas sits on the page, in pixels at the current zoom, before scrolling. */
  tablePage(table) {
    const z = this.zoom;
    let x = PAGE_INSET_X + table.x * z, y = this.pageInsetY() + table.y * z;
    if (this.tableDrag?.id === table.id) {
      x += this.tableDrag.dx;
      y += this.tableDrag.dy;
    }
    return { x, y };
  }

  activePage() {
    const id = this.metrics.layout.sheet;
    const table = this.canvasInfo.tables.find((t) => t.id === id) ?? { id, x: 0, y: 0 };
    return this.tablePage(table);
  }

  /** Every table on the canvas whose geometry is known, placed on the page, in the canvas's order. */
  tableFrames() {
    if (!this.onCanvas) return [];
    const active = this.metrics.layout.sheet;
    const z = this.zoom;
    const frames = [];
    for (const table of this.canvasInfo.tables) {
      const metrics = table.id === active ? this.metrics : this.tableLayouts.get(table.id);
      if (!metrics) continue;
      const { x, y } = this.tablePage(table);
      frames.push({ table, metrics, active: table.id === active, x, y, width: metrics.totalWidth * z, height: metrics.totalHeight * z });
    }
    return frames;
  }

  /** The tables on screen, each with the rectangle its name is drawn in when it shows one. */
  screenFrames() {
    const z = this.zoom, left = this.scroller.scrollLeft, top = this.scroller.scrollTop;
    return this.tableFrames().map((frame) => {
      const x = frame.x - left, y = frame.y - top;
      // The table worked on shows its headers and selection; none does once the page is clicked.
      const focused = frame.active && !this.unfocused;
      // Above its column letters on the table worked on, and straight on top of any other.
      const reach = focused ? this.headerHeight + NAME_HEIGHT * z : NAME_HEIGHT * z;
      const name = frame.table.showsName
        ? { x, y: y - reach, width: Math.max(frame.width, 120), height: NAME_HEIGHT * z }
        : null;
      return { ...frame, x, y, name, focused };
    });
  }

  /** Scrolls the least it can to show a rectangle on screen. */
  scrollIntoView(rect, margin = 0) {
    const { width, height } = this.viewport;
    const left = rect.x - margin, right = rect.x + rect.width + margin;
    const top = rect.y - margin, bottom = rect.y + rect.height + margin;
    if (left < 0) this.scroller.scrollLeft += left;
    else if (right > width) this.scroller.scrollLeft += Math.min(left, right - width);
    if (top < 0) this.scroller.scrollTop += top;
    else if (bottom > height) this.scroller.scrollTop += Math.min(top, bottom - height);
  }

  /**
   * Brings the active table's top-left corner into view, its headers and name
   * with it: from the page's corner on coming to a canvas, and as little as
   * it takes on moving between its tables.
   */
  revealTableHead(entering) {
    const page = this.activePage();
    const reach = this.headerHeight + NAME_HEIGHT * this.zoom;
    const header = this.rowHeaderWidth;
    if (entering) {
      this.scroller.scrollTo(Math.max(0, page.x - header - 24), Math.max(0, page.y - reach - 20));
      return;
    }
    const head = {
      x: page.x - header - this.scroller.scrollLeft, y: page.y - reach - this.scroller.scrollTop,
      width: header + Math.min(this.metrics.totalWidth * this.zoom, 240), height: reach + Math.min(this.metrics.totalHeight * this.zoom, 120),
    };
    this.scrollIntoView(head, 12);
  }

  /** Puts a field over a table's name to type a new one in, as a sheet's tab is renamed. */
  beginRenamingTable(id) {
    const table = this.canvasInfo?.tables.find((t) => t.id === id);
    if (!table?.showsName) return;
    this.endRenamingTable(true);
    const input = document.createElement("input");
    input.className = "grid__table-name";
    input.spellcheck = false;
    input.autocomplete = "off";
    input.value = table.name;
    input.ariaLabel = this.options.t("Canvas.RenameTable.Title");
    this.root.append(input);
    this.renaming = { id, input, original: table.name };
    input.addEventListener("keydown", (event) => {
      if (event.isComposing) return;
      if (event.key === "Enter") {
        event.preventDefault();
        this.endRenamingTable(true, true);
      } else if (event.key === "Escape") {
        event.preventDefault();
        this.endRenamingTable(false, true);
      }
    });
    input.addEventListener("blur", () => this.endRenamingTable(true));
    this.placeNameEditor();
    this.requestDraw();
    input.focus();
    input.select();
  }

  /** Puts the name typed in place, or leaves the old one. */
  async endRenamingTable(commit, refocus = false) {
    const renaming = this.renaming;
    if (!renaming) return;
    this.renaming = null;
    const name = renaming.input.value.trim();
    renaming.input.remove();
    this.requestDraw();
    if (refocus) this.focus();
    if (!commit || !name || name === renaming.original) return;
    try {
      await this.engine.call("renameTable", { id: renaming.id, name });
    } catch (error) {
      this.dispatchEvent(new CustomEvent("message", { detail: error.message }));
    }
  }

  /** Keeps the name field over the name as the page scrolls, zooms and moves. */
  placeNameEditor() {
    if (!this.renaming) return;
    const frame = this.screenFrames().find((f) => f.table.id === this.renaming.id);
    if (!frame?.name) {
      this.endRenamingTable(false);
      return;
    }
    const style = this.renaming.input.style;
    const z = this.zoom;
    style.left = `${Math.round(frame.name.x - 2)}px`;
    style.top = `${Math.round(frame.name.y)}px`;
    style.width = `${Math.round(frame.name.width + 2)}px`;
    style.height = `${Math.round(frame.name.height)}px`;
    style.fontSize = `${Math.max(9, 14 * z)}px`;
  }

  // MARK: - Drawing

  themeChanged() {
    const theme = document.documentElement.dataset.theme;
    this.dark = theme ? theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
    this.palette = readPalette();
    this.tiles.clear();
    this.papers.clear();
    this.requestDraw();
  }

  /** What a sheet's cells show through to: its background colour, or the theme's paper. */
  paperFor(sheet = null) {
    const id = sheet ?? this.metrics?.layout.sheet;
    return cssColor(this.papers.get(id)) ?? this.palette.paper;
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

  tileKey(tx, ty, sheet) {
    return `${sheet}|${this.dark ? 1 : 0}|${tx}|${ty}`;
  }

  /**
   * The newest bitmap for a tile, requesting a fresh one when it is out of
   * date. A tile drawn at another zoom is still returned, and stretched, until
   * zooming settles: re-rendering every tile on every step of a pinch would
   * leave the sheet blank while the fingers move.
   */
  tile(tx, ty, sheet = null) {
    const key = this.tileKey(tx, ty, sheet ?? this.metrics.layout.sheet);
    const version = this.engine.versions.content * 100000 + this.engine.versions.layout;
    const cached = this.tiles.get(key);
    const dpr = window.devicePixelRatio || 1;
    const stale = !cached || cached.version !== version
      || ((cached.zoom !== this.zoom || cached.dpr !== dpr) && !this.isZooming);
    if (stale && !this.pendingTiles.has(key)) {
      this.pendingTiles.add(key);
      const dark = this.dark, zoom = this.zoom;
      const id = sheet ?? this.metrics.layout.sheet;
      // The engine snaps the tile's edges and lines to the pixels a sheet point comes to.
      this.engine.render({ x: tx * TILE, y: ty * TILE, w: TILE, h: TILE, scale: zoom * dpr }, dark, sheet).then((list) => {
        this.pendingTiles.delete(key);
        if (dark !== this.dark) return;
        this.papers.set(id, list.paper ?? null);
        this.tiles.delete(key);
        this.tiles.set(key, { version, zoom, dpr, ...this.rasterize(list, tx, ty, zoom, dpr) });
        if (this.tiles.size > TILE_LIMIT) this.tiles.delete(this.tiles.keys().next().value);
        this.requestDraw();
      }, () => this.pendingTiles.delete(key));
    }
    return cached ?? null;
  }

  /**
   * A tile's bitmap, pixel for pixel: it covers the device pixels from where
   * its first sheet point rounds to up to where the next tile's does, so
   * tiles side by side meet without a seam or an overlap, and the lines the
   * engine snapped land on whole pixels in it.
   */
  rasterize(list, tx, ty, zoom = this.zoom, dpr = window.devicePixelRatio || 1) {
    const scale = zoom * dpr;
    const left = Math.round(tx * TILE * scale), top = Math.round(ty * TILE * scale);
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round((tx + 1) * TILE * scale) - left);
    canvas.height = Math.max(1, Math.round((ty + 1) * TILE * scale) - top);
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = cssColor(list.paper) ?? this.palette.paper;
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.setTransform(scale, 0, 0, scale, -left, -top);
    paint(ctx, list, this.palette);
    return { canvas, left, top };
  }

  /** The four panes: frozen corner, frozen top, frozen left, and the scrolling rest. On a canvas, the one table. */
  panes() {
    const m = this.metrics, z = this.zoom, header = this.rowHeaderWidth;
    const { width, height } = this.viewport;
    if (this.onCanvas) {
      const ox = this.originX, oy = this.originY;
      const x0 = Math.max(0, ox), y0 = Math.max(0, oy);
      const x1 = Math.min(width, ox + m.totalWidth * z), y1 = Math.min(height, oy + m.totalHeight * z);
      if (x1 <= x0 || y1 <= y0) return [];
      return [{ screen: { x: x0, y: y0, width: x1 - x0, height: y1 - y0 }, sheetX: (x0 - ox) / z, sheetY: (y0 - oy) / z }];
    }
    const fw = m.frozenWidth * z, fh = m.frozenHeight * z;
    const sx = m.frozenWidth + this.scroller.scrollLeft / z;
    const sy = m.frozenHeight + this.scroller.scrollTop / z;
    const panes = [];
    const add = (screen, sheetX, sheetY) => {
      if (screen.width > 0 && screen.height > 0) panes.push({ screen, sheetX, sheetY });
    };
    add({ x: header + fw, y: this.headerHeight + fh, width: width - header - fw, height: height - this.headerHeight - fh }, sx, sy);
    add({ x: header, y: this.headerHeight + fh, width: fw, height: height - this.headerHeight - fh }, 0, sy);
    add({ x: header + fw, y: this.headerHeight, width: width - header - fw, height: fh }, sx, 0);
    add({ x: header, y: this.headerHeight, width: fw, height: fh }, 0, 0);
    return panes;
  }

  /**
   * Draws a sheet's tiles into a rectangle on screen, `screen` showing the
   * part of the sheet from (sheetX, sheetY); `sheet` is null for the active one.
   */
  drawTiles(ctx, screen, sheetX, sheetY, metrics, sheet = null) {
    const z = this.zoom;
    ctx.save();
    ctx.beginPath();
    ctx.rect(screen.x, screen.y, screen.width, screen.height);
    ctx.clip();
    // Only the sheet's own extent is paper; past it is the window's background.
    const sheetRight = screen.x + (metrics.totalWidth - sheetX) * z;
    const sheetBottom = screen.y + (metrics.totalHeight - sheetY) * z;
    ctx.beginPath();
    ctx.rect(screen.x, screen.y, Math.min(screen.width, sheetRight - screen.x), Math.min(screen.height, sheetBottom - screen.y));
    ctx.clip();
    const x1 = sheetX + screen.width / z, y1 = sheetY + screen.height / z;
    // Where the sheet's first point falls, on a whole device pixel, which
    // tiles drawn at this zoom are laid from without being resampled.
    const dpr = window.devicePixelRatio || 1;
    const originX = Math.round((screen.x - sheetX * z) * dpr), originY = Math.round((screen.y - sheetY * z) * dpr);
    for (let ty = Math.floor(sheetY / TILE); ty * TILE < Math.min(y1, metrics.totalHeight); ty++) {
      for (let tx = Math.floor(sheetX / TILE); tx * TILE < Math.min(x1, metrics.totalWidth); tx++) {
        const tile = this.tile(tx, ty, sheet);
        const dx = screen.x + (tx * TILE - sheetX) * z, dy = screen.y + (ty * TILE - sheetY) * z;
        if (tile && tile.zoom === z && tile.dpr === dpr) {
          const { canvas, left, top } = tile;
          ctx.drawImage(canvas, (originX + left) / dpr, (originY + top) / dpr, canvas.width / dpr, canvas.height / dpr);
        } else if (tile) {
          ctx.drawImage(tile.canvas, dx, dy, TILE * z, TILE * z);
        } else {
          ctx.fillStyle = this.paperFor(sheet);
          ctx.fillRect(dx, dy, TILE * z, TILE * z);
        }
      }
    }
    ctx.restore();
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
    const frames = this.onCanvas ? this.screenFrames() : [];

    if (this.onCanvas) {
      // The tables share their sheet's page, and its colour: the first table's, as the Mac takes it.
      ctx.fillStyle = this.paperFor(this.canvasInfo.tables[0]?.id);
      ctx.fillRect(0, 0, width, height);
      for (const frame of frames) {
        if (frame.active) continue;
        const x0 = Math.max(0, frame.x), y0 = Math.max(0, frame.y);
        const x1 = Math.min(width, frame.x + frame.width), y1 = Math.min(height, frame.y + frame.height);
        if (x1 <= x0 || y1 <= y0) continue;
        this.drawTiles(ctx, { x: x0, y: y0, width: x1 - x0, height: y1 - y0 }, (x0 - frame.x) / z, (y0 - frame.y) / z, frame.metrics, frame.table.id);
      }
    }

    for (const pane of this.panes()) {
      const { screen } = pane;
      this.drawTiles(ctx, screen, pane.sheetX, pane.sheetY, m);
      ctx.save();
      ctx.beginPath();
      // On a canvas the selection's outline and fill handle may stand just past the table's edge.
      if (this.onCanvas) ctx.rect(screen.x - 4, screen.y - 4, screen.width + 8, screen.height + 8);
      else ctx.rect(screen.x, screen.y, screen.width, screen.height);
      ctx.clip();
      if (!this.unfocused) this.drawSelection(ctx, pane);
      ctx.restore();
    }

    if (this.onCanvas) {
      for (const frame of frames) this.drawTableChrome(ctx, style, frame);
      if (!this.unfocused) this.drawHeaders(ctx, style);
      this.drawGuides(ctx, style);
      this.placeAddButtons();
      this.positionEditor();
      this.placeNameEditor();
      return;
    }

    // The lines where frozen panes meet the scrolling ones.
    ctx.fillStyle = style.getPropertyValue("--ds-border-strong-01");
    if (m.frozenColumns > 0) ctx.fillRect(this.rowHeaderWidth + m.frozenWidth * z - 1, this.headerHeight, 1, height);
    if (m.frozenRows > 0) ctx.fillRect(this.rowHeaderWidth, this.headerHeight + m.frozenHeight * z - 1, width, 1);

    if (!this.hidesHeadings) this.drawHeaders(ctx, style);
    this.placeAddButtons();
    this.positionEditor();
  }

  /** A table's edge, so one without gridlines still reads as one, and its name above it. */
  drawTableChrome(ctx, style, frame) {
    ctx.strokeStyle = style.getPropertyValue("--ds-border-subtle-01");
    ctx.lineWidth = 1;
    ctx.strokeRect(Math.round(frame.x) - 0.5, Math.round(frame.y) - 0.5, Math.round(frame.width) + 1, Math.round(frame.height) + 1);
    if (!frame.name || this.renaming?.id === frame.table.id) return;
    const z = this.zoom;
    ctx.save();
    ctx.beginPath();
    ctx.rect(frame.name.x, frame.name.y, frame.name.width, frame.name.height);
    ctx.clip();
    ctx.font = `600 ${Math.max(9, 14 * z)}px ${FONT}`;
    // Light on a dark page, whatever the appearance, as the Mac draws it.
    const onDark = isDark(this.papers.get(this.canvasInfo.tables[0]?.id));
    ctx.fillStyle = onDark
      ? (frame.focused ? "rgba(255, 255, 255, 0.92)" : "rgba(255, 255, 255, 0.6)")
      : style.getPropertyValue(frame.focused ? "--ds-text-primary" : "--ds-text-secondary");
    ctx.textAlign = "left";
    ctx.textBaseline = "bottom";
    ctx.fillText(fitText(ctx, frame.table.name, frame.name.width), frame.name.x, frame.name.y + frame.name.height - 4 * z);
    ctx.restore();
  }

  /** The lines showing what a dragged table has lined up with, over everything. */
  drawGuides(ctx, style) {
    if (!this.guides.length) return;
    const left = this.scroller.scrollLeft, top = this.scroller.scrollTop;
    ctx.fillStyle = style.getPropertyValue("--ds-support-warning");
    for (const guide of this.guides) {
      if (guide.vertical) ctx.fillRect(guide.at - left - 0.5, guide.start - top, 1, guide.end - guide.start);
      else ctx.fillRect(guide.start - left, guide.at - top - 0.5, guide.end - guide.start, 1);
    }
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
        ctx.strokeStyle = this.paperFor();
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
    // With no table worked on, as after a tap on the page, no line is picked out.
    if (state && !this.unfocused) {
      for (const range of state.ranges) {
        for (let c = range[1]; c <= range[3] && c - range[1] < 2000; c++) selectedColumns.add(c);
        for (let r = range[0]; r <= range[2] && r - range[0] < 5000; r++) selectedRows.add(r);
      }
    }
    ctx.font = `12px ${FONT}`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";

    // Where the bars go: along the window's top and left edges, or round the table on a canvas.
    const onCanvas = this.onCanvas;
    const ox = this.originX, oy = this.originY;
    const columnTop = onCanvas ? oy - this.headerHeight : 0;
    const rowLeft = onCanvas ? ox - header : 0;
    const columnsRight = onCanvas ? Math.min(width, ox + m.totalWidth * z) : width;
    const rowsBottom = onCanvas ? Math.min(height, oy + m.totalHeight * z) : height;
    ctx.save();
    if (onCanvas && this.tableDrag?.id === m.layout.sheet) ctx.globalAlpha = DRAGGING_HEADER_OPACITY;

    // Column headers.
    ctx.fillStyle = token("--ds-grid-header");
    if (onCanvas) ctx.fillRect(ox, columnTop, columnsRight - ox, this.headerHeight);
    else ctx.fillRect(0, 0, width, this.headerHeight);
    const drawColumns = (fromX, toX, sheetStart) => {
      ctx.save();
      ctx.beginPath();
      ctx.rect(fromX, columnTop, toX - fromX, this.headerHeight);
      ctx.clip();
      let column = m.columnAt(sheetStart);
      while (column < m.layout.columns) {
        const x = fromX + (m.x(column) - sheetStart) * z;
        if (x > toX) break;
        const w = m.width(column) * z;
        if (w > 0) {
          if (selectedColumns.has(column)) {
            ctx.fillStyle = token("--ds-grid-header-selected");
            ctx.fillRect(x, columnTop, w, this.headerHeight);
          }
          ctx.fillStyle = selectedColumns.has(column) ? token("--ds-text-primary") : token("--ds-text-secondary");
          ctx.fillText(columnName(column), x + w / 2, columnTop + this.headerHeight / 2);
          ctx.fillStyle = token("--ds-grid-line");
          ctx.fillRect(x + w - 1, columnTop, 1, this.headerHeight);
        }
        column++;
      }
      ctx.restore();
    };
    if (onCanvas) {
      const fromX = Math.max(0, ox);
      drawColumns(fromX, columnsRight, (fromX - ox) / z);
    } else {
      const frozenX = header + m.frozenWidth * z;
      if (m.frozenColumns > 0) drawColumns(header, frozenX, 0);
      drawColumns(frozenX, width, m.frozenWidth + this.scroller.scrollLeft / z);
    }

    // Row headers.
    ctx.fillStyle = token("--ds-grid-header");
    if (onCanvas) ctx.fillRect(rowLeft, oy, header, rowsBottom - oy);
    else ctx.fillRect(0, this.headerHeight, header, height - this.headerHeight);
    const drawRows = (fromY, toY, sheetStart) => {
      ctx.save();
      ctx.beginPath();
      ctx.rect(rowLeft, fromY, header, toY - fromY);
      ctx.clip();
      let row = m.rowAt(sheetStart);
      while (row < m.layout.rows) {
        const y = fromY + (m.y(row) - sheetStart) * z;
        if (y > toY) break;
        const h = m.height(row) * z;
        if (h > 0) {
          if (selectedRows.has(row)) {
            ctx.fillStyle = token("--ds-grid-header-selected");
            ctx.fillRect(rowLeft, y, header, h);
          }
          ctx.fillStyle = selectedRows.has(row) ? token("--ds-text-primary") : token("--ds-text-secondary");
          ctx.fillText(String(row + 1), rowLeft + header / 2, y + h / 2);
          ctx.fillStyle = token("--ds-grid-line");
          ctx.fillRect(rowLeft, y + h - 1, header, 1);
        }
        row++;
      }
      ctx.restore();
    };
    if (onCanvas) {
      const fromY = Math.max(0, oy);
      drawRows(fromY, rowsBottom, (fromY - oy) / z);
      // The corner where the bars meet: the table's handle.
      ctx.fillStyle = token("--ds-border-subtle-01");
      ctx.fillRect(rowLeft, columnTop + this.headerHeight - 1, columnsRight - rowLeft, 1);
      ctx.fillRect(rowLeft + header - 1, columnTop, 1, rowsBottom - columnTop);
      ctx.fillStyle = token("--ds-grid-header");
      ctx.fillRect(rowLeft, columnTop, header - 1, this.headerHeight - 1);
      ctx.restore();
    } else {
      const frozenY = this.headerHeight + m.frozenHeight * z;
      if (m.frozenRows > 0) drawRows(this.headerHeight, frozenY, 0);
      drawRows(frozenY, height, m.frozenHeight + this.scroller.scrollTop / z);

      ctx.fillStyle = token("--ds-border-subtle-01");
      ctx.fillRect(0, this.headerHeight - 1, width, 1);
      ctx.fillRect(header - 1, 0, 1, height);
      ctx.fillStyle = token("--ds-grid-header");
      ctx.fillRect(0, 0, header - 1, this.headerHeight - 1);
      ctx.restore();
    }

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
    const minX = this.onCanvas ? 0 : this.rowHeaderWidth, minY = this.onCanvas ? 0 : this.headerHeight;
    const show = (button, x, y) => {
      const visible = !this.tableDrag && !this.unfocused && x > minX && y > minY && x < width - 8 && y < height - 8;
      button.hidden = !visible;
      if (visible) button.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
    };
    if (this.onCanvas) {
      // Just past the table's right and bottom edges.
      show(this.addColumnButton, right + 4, this.originY + 2);
      show(this.addRowButton, this.originX + 2, bottom + 4);
      return;
    }
    show(this.addColumnButton, right + 4, Math.max(this.headerHeight + 4, Math.min(bottom - 28, this.headerHeight + 4)));
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
    this.unfocused = null;
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
    style.fontWeight = state.style.bold ? "bold" : "normal";
    style.fontFamily = state.style.fontName ? familyFor(state.style.fontName) : "";
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
    el.addEventListener("pointercancel", () => this.cancelDrag());
    el.addEventListener("dblclick", (event) => this.doubleClick(event));
    this.bindZoomGestures();
  }

  /**
   * Pinch and ctrl-scroll zoom the sheet, about the fingers or the pointer.
   *
   * - Chrome, Edge and Firefox report a trackpad pinch as wheel events with
   *   ctrlKey set and small deltas, and ctrl-scroll with a mouse the same way
   *   with large ones: both scale smoothly by the delta.
   * - Safari reports pinches (trackpad and touch) as its own gesture events,
   *   with the scale since the gesture began.
   * - Elsewhere, two touch pointers on the grid make a pinch.
   */
  bindZoomGestures() {
    const el = this.scroller;
    el.addEventListener("wheel", (event) => {
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      if (this.gesture) return;
      const pixels = event.deltaMode === 1 ? event.deltaY * 16 : event.deltaMode === 2 ? event.deltaY * 400 : event.deltaY;
      const factor = Math.min(1.25, Math.max(0.8, Math.exp(-pixels * 0.01)));
      // A burst of wheel events is one pinch: it holds the sheet point it began over.
      const point = this.localPoint(event);
      const now = performance.now();
      if (!this.wheelPinch || now - this.wheelPinch.time > 200) this.wheelPinch = { pinned: this.pinnedPoint(point) };
      this.wheelPinch.time = now;
      this.setZoom(this.zoom * factor, point, this.wheelPinch.pinned);
    }, { passive: false });

    // Test for the type itself: macOS WebKit has GestureEvent but no ongesturechange property.
    const hasGestureEvents = typeof window.GestureEvent === "function";
    if (hasGestureEvents) {
      el.addEventListener("gesturestart", (event) => {
        event.preventDefault();
        this.cancelDrag();
        this.gesture = { zoom: this.zoom, pinned: this.pinnedPoint(this.localPoint(event)) };
      });
      el.addEventListener("gesturechange", (event) => {
        event.preventDefault();
        if (!this.gesture) return;
        this.setZoom(this.gesture.zoom * event.scale, this.localPoint(event), this.gesture.pinned);
      });
      el.addEventListener("gestureend", (event) => {
        event.preventDefault();
        this.gesture = null;
      });
      return;
    }

    // Touch pinch from pointers, where the browser has no gesture events.
    const touches = new Map();
    const pinchState = () => {
      const [a, b] = [...touches.values()];
      return {
        distance: Math.hypot(a.x - b.x, a.y - b.y),
        centre: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 },
      };
    };
    el.addEventListener("pointerdown", (event) => {
      if (event.pointerType !== "touch") return;
      touches.set(event.pointerId, this.localPoint(event));
      if (touches.size === 2) {
        this.cancelDrag();
        const { distance, centre } = pinchState();
        this.gesture = { zoom: this.zoom, distance, pinned: this.pinnedPoint(centre) };
      }
    }, true);
    el.addEventListener("pointermove", (event) => {
      if (!touches.has(event.pointerId)) return;
      touches.set(event.pointerId, this.localPoint(event));
      if (!this.gesture || touches.size !== 2) return;
      event.preventDefault();
      const { distance, centre } = pinchState();
      if (this.gesture.distance > 0) {
        this.setZoom(this.gesture.zoom * distance / this.gesture.distance, centre, this.gesture.pinned);
      }
    }, true);
    const lift = (event) => {
      touches.delete(event.pointerId);
      if (touches.size < 2) this.gesture = null;
    };
    el.addEventListener("pointerup", lift, true);
    el.addEventListener("pointercancel", lift, true);
  }

  /** A point over the column letters: a column, or the edge between two to resize. */
  columnHit(point) {
    const z = this.zoom;
    const x = this.sheetX(point.x);
    if (x == null || x < 0 || x > this.metrics.totalWidth + RESIZE_SLOP / z) return { kind: "none" };
    const edge = this.metrics.columns.boundaryNear(x, RESIZE_SLOP / z);
    if (edge >= 0) return { kind: "columnEdge", index: edge };
    if (x > this.metrics.totalWidth) return { kind: "none" };
    return { kind: "columnHeader", index: this.metrics.columnAt(x) };
  }

  rowHit(point) {
    const z = this.zoom;
    const y = this.sheetY(point.y);
    if (y == null || y < 0 || y > this.metrics.totalHeight + RESIZE_SLOP / z) return { kind: "none" };
    const edge = this.metrics.rows.boundaryNear(y, RESIZE_SLOP / z);
    if (edge >= 0) return { kind: "rowEdge", index: edge };
    if (y > this.metrics.totalHeight) return { kind: "none" };
    return { kind: "rowHeader", index: this.metrics.rowAt(y) };
  }

  fillHandleHit(point) {
    const handle = this.fillHandleRect();
    return Boolean(handle && !this.editing && point.x >= handle.x - 3 && point.x <= handle.x + handle.width + 3
      && point.y >= handle.y - 3 && point.y <= handle.y + handle.height + 3);
  }

  /**
   * What is under a point on a canvas's page: a table's name, the corner
   * where the active table's headers meet, its headers, its cells, the edge
   * just outside any table's cells, another table's cells, or the bare page.
   */
  canvasHit(point) {
    const m = this.metrics, z = this.zoom, header = this.rowHeaderWidth;
    const ox = this.originX, oy = this.originY;
    const right = ox + m.totalWidth * z, bottom = oy + m.totalHeight * z;
    const inside = (r, p, slop = 0) => p.x >= r.x - slop && p.x < r.x + r.width + slop && p.y >= r.y - slop && p.y < r.y + r.height + slop;
    const frames = this.screenFrames().reverse();
    const active = m.layout.sheet;
    const named = frames.find((frame) => frame.name && inside(frame.name, point));
    if (named) return { kind: "tableName", id: named.table.id };
    // With no table worked on, the active one is hit as any other is, its headers put away.
    const focused = !this.unfocused;
    if (focused && point.x >= ox - header && point.x < ox && point.y >= oy - this.headerHeight && point.y < oy) return { kind: "tableCorner", id: active };
    if (focused && point.y >= oy - this.headerHeight && point.y < oy && point.x >= ox && point.x <= right + RESIZE_SLOP) return this.columnHit(point);
    if (focused && point.x >= ox - header && point.x < ox && point.y >= oy && point.y <= bottom + RESIZE_SLOP) return this.rowHit(point);
    if (focused && this.fillHandleHit(point)) return { kind: "fillHandle" };
    if (focused && point.x >= ox && point.x < right && point.y >= oy && point.y < bottom) {
      return { kind: "cell", row: m.rowAt(this.sheetY(point.y)), column: m.columnAt(this.sheetX(point.x)) };
    }
    const edge = frames.find((frame) => inside(frame, point, GRAB_SLOP) && !inside(frame, point));
    if (edge) return { kind: "tableEdge", id: edge.table.id };
    const other = frames.find((frame) => !frame.focused && inside(frame, point));
    if (other) {
      return {
        kind: "otherTable", id: other.table.id,
        row: other.metrics.rowAt((point.y - other.y) / z), column: other.metrics.columnAt((point.x - other.x) / z),
      };
    }
    return { kind: "page" };
  }

  hit(point) {
    if (!this.metrics) return { kind: "none" };
    if (this.onCanvas) return this.canvasHit(point);
    const header = this.rowHeaderWidth;
    if (point.x < header && point.y < this.headerHeight) return { kind: "corner" };
    if (point.y < this.headerHeight) return this.columnHit(point);
    if (point.x < header) return this.rowHit(point);
    if (!this.unfocused && this.fillHandleHit(point)) return { kind: "fillHandle" };
    const sheet = this.toSheet(point.x, point.y);
    if (sheet.x > this.metrics.totalWidth || sheet.y > this.metrics.totalHeight) {
      // Beside a Numbers sheet's one table is its page, as round a canvas's tables.
      return { kind: this.engine.info?.kind === "numbers" ? "page" : "outside" };
    }
    return { kind: "cell", row: this.metrics.rowAt(sheet.y), column: this.metrics.columnAt(sheet.x) };
  }

  /** Whether this document lets its tables be moved and renamed. */
  get canLayOutTables() {
    return Boolean(this.engine.info?.allowsLayingOutTables);
  }

  cursorFor(point) {
    const hit = this.hit(point);
    switch (hit.kind) {
      case "columnEdge": return "col-resize";
      case "rowEdge": return "row-resize";
      case "fillHandle": return "crosshair";
      case "cell": return "cell";
      case "otherTable": return "cell";
      case "tableName": return this.canLayOutTables ? "text" : "default";
      case "tableCorner":
      case "tableEdge": return this.canLayOutTables ? "grab" : "default";
      default: return "default";
    }
  }

  async pointerDown(event) {
    if (event.button !== 0 || this.gesture) return;
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
    if (hit.kind !== "page") this.unfocused = null;

    switch (hit.kind) {
      case "corner":
        event.preventDefault();
        await this.commitIfEditing();
        await this.engine.call("selectAll");
        break;
      case "tableName":
        event.preventDefault();
        await this.commitIfEditing();
        if (hit.id !== this.metrics.layout.sheet) await this.engine.call("selectSheet", { id: hit.id });
        if (this.canLayOutTables) {
          this.beginRenamingTable(hit.id);
          return;
        }
        break;
      case "tableCorner":
      case "tableEdge": {
        event.preventDefault();
        await this.commitIfEditing();
        if (hit.id !== this.metrics.layout.sheet) await this.engine.call("selectSheet", { id: hit.id });
        if (this.canLayOutTables) {
          // Measured on the page, so scrolling while dragging carries the table along.
          this.drag = { kind: "table", id: hit.id, corner: hit.kind === "tableCorner",
            origin: { x: point.x + this.scroller.scrollLeft, y: point.y + this.scroller.scrollTop } };
          this.scroller.style.cursor = "grabbing";
        } else if (hit.kind === "tableCorner") {
          await this.engine.call("selectAll");
        }
        break;
      }
      case "otherTable":
        // Another table: it becomes the one worked on, with the cell clicked selected.
        event.preventDefault();
        await this.commitIfEditing();
        if (hit.id !== this.metrics.layout.sheet) await this.engine.call("selectSheet", { id: hit.id });
        await this.engine.call("select", { row: hit.row, column: hit.column });
        this.drag = { kind: "cells", last: [hit.row, hit.column], toggles: false };
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
      case "page":
        // Put down where it was picked up, it leaves no table worked on; a finger scrolling the page does not.
        this.drag = { kind: "page", origin: point };
        return;
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
    if (!drag || this.gesture) return;
    const point = this.localPoint(event);
    if (drag.kind === "page") {
      if (Math.hypot(point.x - drag.origin.x, point.y - drag.origin.y) > PAGE_TAP_SLOP) this.endDrag();
      return;
    }
    this.autoScroll(point);
    switch (drag.kind) {
      case "table":
        this.dragTable(drag, point);
        break;
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

  /**
   * Carries a table across the page, measured from where it rests so the
   * page and the tables round it decide where it lands, however far the
   * pointer goes.
   */
  dragTable(drag, point) {
    const table = this.canvasInfo?.tables.find((t) => t.id === drag.id);
    const frames = this.tableFrames();
    const moving = frames.find((frame) => frame.table.id === drag.id);
    if (!table || !moving) return;
    const z = this.zoom;
    const rest = { x: PAGE_INSET_X + table.x * z, y: this.pageInsetY() + table.y * z };
    const proposed = {
      x: rest.x + point.x + this.scroller.scrollLeft - drag.origin.x,
      y: rest.y + point.y + this.scroller.scrollTop - drag.origin.y,
      width: moving.width, height: moving.height,
    };
    const others = frames.filter((frame) => frame.table.id !== drag.id);
    const snapped = snapFrame(proposed, others, { x: PAGE_INSET_X, y: this.pageInsetY() });
    this.tableDrag = { id: drag.id, dx: snapped.x - rest.x, dy: snapped.y - rest.y };
    this.guides = snapped.guides;
    this.updateSpacer();
    this.requestDraw();
  }

  /** Puts a dragged table where it was let go, or selects the whole table when its corner was only clicked. */
  async dropTable(drag) {
    const moved = this.tableDrag;
    const table = this.canvasInfo?.tables.find((t) => t.id === drag.id);
    this.guides = [];
    this.scroller.style.cursor = "";
    if (moved && table && (Math.abs(moved.dx) >= 0.5 || Math.abs(moved.dy) >= 0.5)) {
      const z = this.zoom;
      try {
        await this.engine.call("moveTable", { id: drag.id, x: Math.round(table.x + moved.dx / z), y: Math.round(table.y + moved.dy / z) });
      } catch (error) {
        this.dispatchEvent(new CustomEvent("message", { detail: error.message }));
      }
    } else if (drag.corner) {
      await this.engine.call("selectAll");
    }
    // Held until the engine reports where the table now is, so it doesn't jump back meanwhile.
    this.tableDrag = null;
    this.updateSpacer();
    this.requestDraw();
  }

  async pointerUp(event) {
    const drag = this.drag;
    this.endDrag();
    if (!drag) return;
    switch (drag.kind) {
      case "table":
        await this.dropTable(drag);
        break;
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
      case "page":
        await this.unfocusTables();
        break;
    }
  }

  /**
   * Leaves no table worked on, as clicking the bare page does in Numbers: the
   * edit is put away, the selection and headers hidden, and a phone's
   * keyboard dismissed. The selection itself stays, for the next click or key.
   */
  async unfocusTables() {
    await this.commitIfEditing();
    await this.endRenamingTable(true);
    this.unfocused = selectionKey(this.engine.state);
    this.editor.blur();
    this.requestDraw();
  }

  /** Lets go of a drag without finishing it: a table being carried goes back where it was. */
  cancelDrag() {
    if (this.drag?.kind === "table") {
      this.tableDrag = null;
      this.guides = [];
      this.scroller.style.cursor = "";
      this.updateSpacer();
      this.requestDraw();
    }
    this.endDrag();
  }

  endDrag() {
    this.drag = null;
    clearInterval(this.scrollTimer);
    this.scrollTimer = null;
  }

  /** Scrolls while a drag is held past the edge of the grid. */
  autoScroll(point) {
    const { width, height } = this.viewport;
    const left = this.onCanvas ? 16 : this.rowHeaderWidth, top = this.onCanvas ? 16 : this.headerHeight;
    const dx = point.x > width - 16 ? 16 : point.x < left ? -16 : 0;
    const dy = point.y > height - 16 ? 16 : point.y < top ? -16 : 0;
    clearInterval(this.scrollTimer);
    this.scrollTimer = null;
    if (!dx && !dy) return;
    this.scrollTimer = setInterval(() => {
      this.scroller.scrollBy(dx, dy);
      // A table held at the edge keeps coming along as the page scrolls under it.
      if (this.drag?.kind === "table") this.dragTable(this.drag, point);
    }, 30);
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
      ctx.font = fontFor({ fs: entry.fs, b: entry.b, i: entry.i, ff: entry.ff });
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

    // With no table worked on, a key that would act on the hidden selection shows it again instead.
    if (this.unfocused) {
      if (GRID_KEYS.has(event.key)) {
        event.preventDefault();
        this.unfocused = null;
        this.requestDraw();
      }
      return;
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
        const rows = Math.max(1, Math.floor((this.viewport.height - this.headerHeight) / ((this.metrics.layout.rowHeight || 20) * this.zoom)) - 1);
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
    if (["tableName", "tableCorner", "tableEdge", "otherTable"].includes(hit.kind)) {
      if (hit.id !== this.metrics.layout.sheet) this.engine.call("selectSheet", { id: hit.id });
      return this.options.contextMenu("table", event, hit);
    }
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

/** What is selected, as a string to tell when it changes: always truthy. */
function selectionKey(state) {
  return state ? JSON.stringify([state.sheet, state.active, state.ranges]) : "none";
}

/** Whether an "AARRGGBB" background is dark enough to want light text on it. */
function isDark(argb) {
  if (!argb || parseInt(argb.slice(0, 2), 16) < 128) return false;
  const [r, g, b] = [2, 4, 6].map((at) => parseInt(argb.slice(at, at + 2), 16) / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5;
}

/** Text cut short with an ellipsis to fit a width, as the Mac truncates a table's name. */
function fitText(ctx, text, width) {
  if (ctx.measureText(text).width <= width) return text;
  let low = 0, high = text.length;
  while (low < high) {
    const middle = (low + high + 1) >> 1;
    if (ctx.measureText(`${text.slice(0, middle)}…`).width <= width) low = middle;
    else high = middle - 1;
  }
  return `${text.slice(0, low)}…`;
}

/**
 * Where a frame being dragged on a canvas lands among the others, never
 * nearer the page's top-left than `minimum`, lined up with any edge or middle
 * that comes within the threshold, and the guides showing what it lined up
 * with: the Mac's CanvasSnapping, in page pixels.
 */
function snapFrame(frame, others, minimum, threshold = SNAP_THRESHOLD) {
  const f = { ...frame, x: Math.max(minimum.x, frame.x), y: Math.max(minimum.y, frame.y) };
  const lines = (r, vertical) => (vertical ? [r.x, r.x + r.width / 2, r.x + r.width] : [r.y, r.y + r.height / 2, r.y + r.height]);
  const shift = (vertical) => {
    let best = null;
    for (const other of others) {
      for (const line of lines(f, vertical)) {
        for (const target of lines(other, vertical)) {
          const delta = target - line;
          if (Math.abs(delta) <= threshold && (best === null || Math.abs(delta) < Math.abs(best))) best = delta;
        }
      }
    }
    return best;
  };
  const dx = shift(true), dy = shift(false);
  if (dx !== null && f.x + dx >= minimum.x) f.x += dx;
  if (dy !== null && f.y + dy >= minimum.y) f.y += dy;
  const guides = [];
  for (const vertical of [true, false]) {
    for (const line of lines(f, vertical)) {
      const matches = others.filter((other) => lines(other, vertical).some((value) => Math.abs(value - line) < 0.5));
      if (!matches.length) continue;
      const all = [f, ...matches];
      guides.push(vertical
        ? { vertical, at: line, start: Math.min(...all.map((r) => r.y)), end: Math.max(...all.map((r) => r.y + r.height)) }
        : { vertical, at: line, start: Math.min(...all.map((r) => r.x)), end: Math.max(...all.map((r) => r.x + r.width)) });
    }
  }
  return { x: f.x, y: f.y, guides };
}

/** The keys the grid acts on the selection with, outside an edit. */
const GRID_KEYS = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Tab", "Enter", "F2", "Backspace", "Delete", "PageDown", "PageUp", " "]);

const REFERENCE_COLOURS = ["#2EA666", "#0F62FE", "#DA1E28", "#8A3FFC", "#FF832B", "#009D9A"];
