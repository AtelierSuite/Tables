// The workbook window: menu bar, toolbar, formula bar, grid, sheet tabs, status
// bar and inspector, and the start screen shown when no document is open.
// Every change to a document goes through the engine; this keeps the window in
// step with what it reports.

import { GridView } from "./grid.js";
import { t, language } from "./i18n.js";
import * as files from "./files.js";
import * as storage from "./storage.js";
import { attachMenuBar, attachToolbarOverflow, openMenu } from "../design/menus.js";
import { dismissSheet } from "../design/sheets.js";
import * as fonts from "./fonts.js";

const isApple = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
const AUTOSAVE_DELAY = 1500;

const ICONS = {
  undo: '<path d="M5 4L2 7l3 3M2 7h7.5a3.5 3.5 0 010 7H7" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  redo: '<path d="M11 4l3 3-3 3M14 7H6.5a3.5 3.5 0 000 7H9" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  alignLeft: '<path d="M2 3.5h12M2 6.5h8M2 9.5h12M2 12.5h8" stroke="currentColor" stroke-width="1.5"/>',
  alignCenter: '<path d="M2 3.5h12M4 6.5h8M2 9.5h12M4 12.5h8" stroke="currentColor" stroke-width="1.5"/>',
  alignRight: '<path d="M2 3.5h12M6 6.5h8M2 9.5h12M6 12.5h8" stroke="currentColor" stroke-width="1.5"/>',
  alignAuto: '<path d="M2 3.5h12M2 6.5h12M2 9.5h12M2 12.5h12" stroke="currentColor" stroke-width="1.5"/>',
  top: '<path d="M2 2.75h12M8 13V5.5M5 8l3-3 3 3" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  middle: '<path d="M2 8h12M8 1.5v4M6 3.5l2 2 2-2M8 14.5v-4M6 12.5l2-2 2 2" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  bottom: '<path d="M2 13.25h12M8 3v7.5M5 8l3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  sum: '<path d="M12 3H4l4.5 5L4 13h8" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  inspector: '<rect x="1.75" y="2.75" width="12.5" height="10.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10 3v10" stroke="currentColor" stroke-width="1.5"/>',
  function: '<path d="M10.5 2.5c-2 0-2.5 1-2.8 3L6.3 13c-.3 1.2-1 1.5-2.3 1.5M5 6.5h5" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  chevronDown: '<path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  chevronUp: '<path d="M4 10l4-4 4 4" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  close: '<path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="1.5"/>',
  info: '<path d="M8 1a7 7 0 100 14A7 7 0 008 1zm.75 10.5h-1.5V7h1.5zM8 5.75a1 1 0 110-2 1 1 0 010 2z"/>',
  warning: '<path d="M8 1L.5 15h15zm.75 11.5h-1.5V11h1.5zm0-2.5h-1.5V6h1.5z"/>',
  error: '<path d="M8 1a7 7 0 100 14A7 7 0 008 1zm3 9.6L10.6 11 8 8.4 5.4 11 5 10.6 7.6 8 5 5.4 5.4 5 8 7.6 10.6 5l.4.4L8.4 8z"/>',
  table: '<rect x="1.75" y="2.75" width="12.5" height="10.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M2 6.5h12M2 10h12M6 3v10" stroke="currentColor" stroke-width="1.2"/>',
  add: '<path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.5"/>',
  list: '<path d="M5.5 4h8M5.5 8h8M5.5 12h8" stroke="currentColor" stroke-width="1.5"/><path d="M2.5 4h1M2.5 8h1M2.5 12h1" stroke="currentColor" stroke-width="1.5"/>',
  borderAll: '<rect x="2.5" y="2.5" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 2.5v11M2.5 8h11" stroke="currentColor" stroke-width="1.5"/>',
  borderOutside: '<rect x="2.5" y="2.5" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1" stroke-dasharray="1 2" opacity=".5"/>',
  borderTop: '<path d="M2.5 2.75h11" stroke="currentColor" stroke-width="1.5"/><path d="M2.5 3v10.5h11V3M8 3v10M3 8h10" fill="none" stroke="currentColor" stroke-width="1" stroke-dasharray="1 2" opacity=".5"/>',
  borderBottom: '<path d="M2.5 13.25h11" stroke="currentColor" stroke-width="1.5"/><path d="M2.5 13V2.5h11V13M8 3v10M3 8h10" fill="none" stroke="currentColor" stroke-width="1" stroke-dasharray="1 2" opacity=".5"/>',
  borderLeft: '<path d="M2.75 2.5v11" stroke="currentColor" stroke-width="1.5"/><path d="M3 2.5h10.5v11H3M8 3v10M3 8h10" fill="none" stroke="currentColor" stroke-width="1" stroke-dasharray="1 2" opacity=".5"/>',
  borderRight: '<path d="M13.25 2.5v11" stroke="currentColor" stroke-width="1.5"/><path d="M13 2.5H2.5v11H13M8 3v10M3 8h10" fill="none" stroke="currentColor" stroke-width="1" stroke-dasharray="1 2" opacity=".5"/>',
  borderNone: '<path d="M2.5 2.5h11v11h-11zM8 3v10M3 8h10" fill="none" stroke="currentColor" stroke-width="1" stroke-dasharray="1 2" opacity=".5"/>',
};

const icon = (name, extra = "") => `<svg class="ds-icon ${extra}" viewBox="0 0 16 16" aria-hidden="true">${ICONS[name]}</svg>`;

/** A shortcut as the platform writes it: ⇧⌘S on Apple devices, Ctrl+Shift+S elsewhere. */
function shortcut(key, { shift = false, alt = false } = {}) {
  if (isApple) return `${alt ? "⌥" : ""}${shift ? "⇧" : ""}⌘${key}`;
  return `Ctrl+${shift ? "Shift+" : ""}${alt ? "Alt+" : ""}${key}`;
}

function escapeHTML(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function readSetting(key, fallback) {
  try {
    return localStorage.getItem(`tables.${key}`) ?? fallback;
  } catch {
    return fallback;
  }
}

function writeSetting(key, value) {
  try {
    localStorage.setItem(`tables.${key}`, value);
  } catch {
    // Settings are a convenience.
  }
}

export class WorkbookWindow {
  /** @param {HTMLElement} root @param {import("./engine-client.js").EngineClient} engine */
  constructor(root, engine) {
    this.root = root;
    this.engine = engine;
    this.document = null; // { id, name, handle?, format }
    this.autosaveTimer = null;
    this.numberFormat = new Intl.NumberFormat(language, { maximumFractionDigits: 4 });

    this.build();
    this.grid = new GridView(this.root.querySelector(".app__grid"), engine, {
      t,
      contextMenu: (kind) => this.contextMenu(kind),
    });
    this.bindEngine();
    this.bindKeyboard();
    this.applyAppearance(readSetting("appearance", ""));
    this.setInspectorVisible(readSetting("inspector", "1") === "1");

    files.onLaunchFiles((file) => file && this.openFile(file));
    files.onDroppedFiles(document.body, (file) => file && this.openFile(file), (hovering) => {
      this.root.classList.toggle("is-dropping", hovering);
    });
    window.addEventListener("beforeunload", (event) => {
      if (this.hasUnkeptChanges) {
        event.preventDefault();
        event.returnValue = "";
      }
    });
  }

  // MARK: - Building

  build() {
    this.root.className = "app ds-window";
    this.root.innerHTML = `
      <div class="ds-menu-bar" id="menu-bar"></div>
      <div class="ds-toolbar" id="toolbar">
        <div class="ds-toolbar__title" data-overflow="never"><span class="app__title"></span><span class="ds-toolbar__subtitle app__subtitle"></span></div>
        <div class="ds-toolbar__separator"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="undo">${icon("undo")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="redo">${icon("redo")}</button>
        <div class="ds-toolbar__separator"></div>
        <div class="ds-segmented ds-segmented--xs ds-segmented--icons" role="group" data-overflow-label="${escapeHTML(t("Mac.Toolbar.Style"))}" aria-label="${escapeHTML(t("Mac.Toolbar.Style"))}">
          <button class="ds-segmented__segment" data-command="bold" aria-pressed="false"><strong>B</strong></button>
          <button class="ds-segmented__segment" data-command="italic" aria-pressed="false"><em>I</em></button>
          <button class="ds-segmented__segment" data-command="underline" aria-pressed="false"><u>U</u></button>
          <button class="ds-segmented__segment" data-command="strike" aria-pressed="false"><s>S</s></button>
        </div>
        <div class="ds-segmented ds-segmented--xs ds-segmented--icons" role="radiogroup" aria-label="${escapeHTML(t("Mac.Menu.Alignment"))}">
          <button class="ds-segmented__segment" role="radio" data-align="leading" aria-checked="false">${icon("alignLeft")}</button>
          <button class="ds-segmented__segment" role="radio" data-align="center" aria-checked="false">${icon("alignCenter")}</button>
          <button class="ds-segmented__segment" role="radio" data-align="trailing" aria-checked="false">${icon("alignRight")}</button>
        </div>
        <div class="ds-toolbar__separator"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="sumMenu" aria-haspopup="menu">${icon("sum")}</button>
        <div class="ds-toolbar__spacer"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="toggleInspector" data-overflow="never" id="inspector-toggle">${icon("inspector")}</button>
      </div>
      <div class="ds-window__accessory app__accessory">
        <div class="ds-formula-bar">
          <input class="ds-text-input ds-text-input--xs ds-formula-bar__name app__name-box" spellcheck="false" autocomplete="off">
          <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs app__function-button" aria-haspopup="menu">${icon("function")}</button>
          <input class="ds-text-input ds-text-input--xs ds-formula-bar__input app__formula" spellcheck="false" autocomplete="off">
        </div>
        <div class="app__banners" aria-live="polite"></div>
      </div>
      <div class="ds-window__content app__content">
        <div class="app__grid"></div>
        <div class="ds-sheet-tabs app__tabs"></div>
        <section class="app__start" hidden></section>
        <div class="app__drop" aria-hidden="true"><p class="ds-heading-03"></p></div>
      </div>
      <div class="ds-status-bar app__status">
        <span class="app__status-sum"></span><span class="app__status-average"></span><span class="app__status-count"></span>
        <span class="ds-status-bar__spacer"></span>
        <span class="ds-popup ds-popup--xs app__zoom"><select class="ds-popup__select" aria-label="${escapeHTML(t("Mac.Menu.Zoom"))}">
          ${[50, 75, 100, 125, 150, 200, 300].map((z) => `<option value="${z / 100}">${z}%</option>`).join("")}
        </select>${icon("chevronDown", "ds-popup__chevron")}</span>
      </div>
      <aside class="ds-inspector ds-on-layer app__inspector" aria-label="${escapeHTML(t("Mac.Inspector.Title"))}"></aside>`;

    this.titleElement = this.root.querySelector(".app__title");
    this.subtitleElement = this.root.querySelector(".app__subtitle");
    this.nameBox = this.root.querySelector(".app__name-box");
    this.formula = this.root.querySelector(".app__formula");
    this.tabs = this.root.querySelector(".app__tabs");
    this.start = this.root.querySelector(".app__start");
    this.banners = this.root.querySelector(".app__banners");
    this.inspector = this.root.querySelector(".app__inspector");
    this.zoomSelect = this.root.querySelector(".app__zoom select");
    this.root.querySelector(".app__drop p").textContent = t("Web.Drop");

    this.nameBox.ariaLabel = this.nameBox.title = t("Mac.FormulaBar.CellName");
    this.formula.placeholder = t("FormulaBar.Field.Placeholder");
    this.formula.ariaLabel = t("FormulaBar.Field.Placeholder");
    const functionButton = this.root.querySelector(".app__function-button");
    functionButton.ariaLabel = functionButton.title = t("Toolbar.InsertFunction");

    this.buildToolbar();
    this.buildMenus();
    this.buildFormulaBar();
    this.buildInspector();
    this.zoomSelect.value = "1";
    this.zoomSelect.addEventListener("change", () => {
      this.grid.setZoom(Number(this.zoomSelect.value));
      this.grid.focus();
    });
  }

  buildToolbar() {
    const toolbar = this.root.querySelector("#toolbar");
    const labels = {
      undo: t("Toolbar.Undo"), redo: t("Toolbar.Redo"), bold: t("Toolbar.Bold"), italic: t("Toolbar.Italic"),
      underline: t("Toolbar.Underline"), strike: t("Toolbar.Strikethrough"), sumMenu: t("Toolbar.Sum"),
      toggleInspector: t("Mac.Menu.ShowInspector"),
    };
    for (const button of toolbar.querySelectorAll("[data-command]")) {
      const label = labels[button.dataset.command];
      button.title = label;
      button.setAttribute("aria-label", label);
      button.addEventListener("click", (event) => {
        if (button.dataset.command === "sumMenu") {
          openMenu(this.aggregateItems(), button, { opener: button });
          return;
        }
        this.run(button.dataset.command);
        event.currentTarget.blur?.();
        this.grid.focus();
      });
    }
    const alignLabels = { leading: t("Alignment.Horizontal.Left"), center: t("Alignment.Horizontal.Center"), trailing: t("Alignment.Horizontal.Right") };
    for (const button of toolbar.querySelectorAll("[data-align]")) {
      button.title = alignLabels[button.dataset.align];
      button.setAttribute("aria-label", button.title);
      button.addEventListener("click", () => {
        const current = this.engine.state?.style.h;
        this.style({ h: current === button.dataset.align ? "automatic" : button.dataset.align });
        this.grid.focus();
      });
    }
    attachToolbarOverflow(toolbar, { label: t("Toolbar.More"), before: toolbar.querySelector("#inspector-toggle") });
  }

  buildFormulaBar() {
    const formula = this.formula;
    formula.addEventListener("focus", () => {
      if (!this.document) return;
      if (!this.grid.isEditing) this.grid.beginEdit({ mode: "edit", focusEditor: false });
    });
    formula.addEventListener("input", () => this.grid.setEditText(formula.value));
    formula.addEventListener("keydown", async (event) => {
      if (event.key === "Enter" && !event.altKey) {
        event.preventDefault();
        await this.grid.commitEdit(event.shiftKey ? "up" : "down");
      } else if (event.key === "Tab") {
        event.preventDefault();
        await this.grid.commitEdit(event.shiftKey ? "left" : "right");
      } else if (event.key === "Escape") {
        event.preventDefault();
        this.grid.cancelEdit();
      }
    });
    this.nameBox.addEventListener("focus", () => this.nameBox.select());
    this.nameBox.addEventListener("keydown", async (event) => {
      if (event.key === "Escape") {
        this.nameBox.value = this.engine.state?.name ?? "";
        this.grid.focus();
      }
      if (event.key !== "Enter") return;
      event.preventDefault();
      const range = parseReference(this.nameBox.value);
      if (!range) {
        this.nameBox.select();
        return;
      }
      await this.engine.call("selectRange", { row: range[0], column: range[1], endRow: range[2], endColumn: range[3] });
      this.grid.reveal(range[0], range[1]);
      this.grid.focus();
    });
    const functionButton = this.root.querySelector(".app__function-button");
    functionButton.addEventListener("click", () => openMenu(this.aggregateItems(), functionButton, { opener: functionButton }));
  }

  // MARK: - Commands

  get commands() {
    const state = this.engine.state;
    const info = this.engine.info;
    const hasDocument = Boolean(this.document);
    const formatting = info?.formatting ?? {};
    return {
      new: { label: t("Mac.Menu.New"), shortcut: shortcut("N"), run: () => this.newDocument() },
      open: { label: t("Mac.Menu.Open"), shortcut: shortcut("O"), run: () => this.openPicked() },
      close: { label: t("Mac.Menu.Close"), shortcut: shortcut("W"), enabled: hasDocument, run: () => this.closeDocument() },
      save: { label: t("Web.Menu.Save"), shortcut: shortcut("S"), enabled: hasDocument, run: () => this.save() },
      saveAs: { label: t("Web.Menu.SaveAs"), shortcut: shortcut("S", { shift: true }), enabled: hasDocument, run: () => this.saveAs() },
      rename: { label: t("Mac.Menu.Rename"), enabled: hasDocument, run: () => this.renameDocument() },
      undo: { label: t("Toolbar.Undo"), shortcut: shortcut("Z"), enabled: hasDocument && state?.canUndo, run: () => this.engine.call("undo") },
      redo: { label: t("Toolbar.Redo"), shortcut: shortcut("Z", { shift: true }), enabled: hasDocument && state?.canRedo, run: () => this.engine.call("redo") },
      cut: { label: t("CellMenu.Cut"), shortcut: shortcut("X"), enabled: hasDocument, run: () => this.grid.copy(true) },
      copy: { label: t("CellMenu.Copy"), shortcut: shortcut("C"), enabled: hasDocument, run: () => this.grid.copy(false) },
      paste: { label: t("CellMenu.Paste"), shortcut: shortcut("V"), enabled: hasDocument, run: () => this.grid.pasteFromClipboard() },
      clear: { label: t("Mac.Menu.ClearContents"), enabled: hasDocument, run: () => this.engine.call("clear") },
      selectAll: { label: t("Mac.Menu.SelectAll"), shortcut: shortcut("A"), enabled: hasDocument, run: () => this.engine.call("selectAll") },
      edit: { label: t("CellMenu.Edit"), enabled: hasDocument, run: () => this.grid.beginEdit() },
      bold: { label: t("Toolbar.Bold"), shortcut: shortcut("B"), enabled: formatting.styles, checked: state?.style.bold, run: () => this.style({ toggle: "bold" }) },
      italic: { label: t("Toolbar.Italic"), shortcut: shortcut("I"), enabled: formatting.styles, checked: state?.style.italic, run: () => this.style({ toggle: "italic" }) },
      underline: { label: t("Toolbar.Underline"), shortcut: shortcut("U"), enabled: formatting.styles, checked: state?.style.underline, run: () => this.style({ toggle: "underline" }) },
      strike: { label: t("Mac.Toolbar.Strikethrough"), enabled: formatting.styles, checked: state?.style.strike, run: () => this.style({ toggle: "strike" }) },
      showFonts: { label: t("Mac.Menu.ShowFonts"), shortcut: shortcut("T"), enabled: Boolean(formatting.fonts), run: () => this.showFonts() },
      bigger: { label: t("Mac.Menu.Bigger"), shortcut: shortcut("+"), enabled: formatting.styles, run: () => this.style({ fontSizeDelta: 1 }) },
      smaller: { label: t("Mac.Menu.Smaller"), shortcut: shortcut("-"), enabled: formatting.styles, run: () => this.style({ fontSizeDelta: -1 }) },
      wrap: { label: t("Format.Alignment.WrapText"), enabled: formatting.styles, checked: state?.style.wrap, run: () => this.style({ toggle: "wrap" }) },
      indent: { label: t("Mac.Menu.IncreaseIndent"), enabled: formatting.indents, run: () => this.style({ indentDelta: 1 }) },
      outdent: { label: t("Mac.Menu.DecreaseIndent"), enabled: formatting.indents, run: () => this.style({ indentDelta: -1 }) },
      merge: { label: t("Format.Merge.Merge"), enabled: state?.canMerge, run: () => this.engine.call("merge") },
      unmerge: { label: t("Format.Merge.Unmerge"), enabled: state?.canUnmerge, run: () => this.engine.call("unmerge") },
      resetFormatting: { label: t("CellMenu.ResetFormatting"), enabled: formatting.styles || formatting.numberFormats, run: () => this.engine.call("clearFormatting") },
      noFill: { label: t("Mac.Menu.NoFill"), enabled: formatting.styles, run: () => this.style({ fill: null }) },
      insertRowAbove: { label: t("HeaderMenu.Row.InsertAbove"), enabled: info?.allowsInsertDelete, run: () => this.engine.call("insertRows", { above: true }) },
      insertRowBelow: { label: t("HeaderMenu.Row.InsertBelow"), enabled: info?.allowsInsertDelete, run: () => this.engine.call("insertRows", { above: false }) },
      insertColumnBefore: { label: t("HeaderMenu.Column.InsertBefore"), enabled: info?.allowsInsertDelete, run: () => this.engine.call("insertColumns", { before: true }) },
      insertColumnAfter: { label: t("HeaderMenu.Column.InsertAfter"), enabled: info?.allowsInsertDelete, run: () => this.engine.call("insertColumns", { before: false }) },
      addRow: { label: t("HeaderMenu.Row.AddAtEnd"), enabled: hasDocument, run: () => this.engine.call("addRows", { count: 1 }) },
      addColumn: { label: t("HeaderMenu.Column.AddAtEnd"), enabled: hasDocument, run: () => this.engine.call("addColumns", { count: 1 }) },
      deleteRow: { label: t("HeaderMenu.Row.Delete"), enabled: info?.allowsInsertDelete, run: () => this.engine.call("deleteRows") },
      deleteColumn: { label: t("HeaderMenu.Column.Delete"), enabled: info?.allowsInsertDelete, run: () => this.engine.call("deleteColumns") },
      hideRow: { label: t("HeaderMenu.Row.Hide"), enabled: hasDocument, run: () => this.engine.call("hideRows", { hidden: true }) },
      hideColumn: { label: t("HeaderMenu.Column.Hide"), enabled: hasDocument, run: () => this.engine.call("hideColumns", { hidden: true }) },
      unhideAll: { label: t("Mac.Menu.UnhideAll"), enabled: hasDocument, run: () => this.engine.call("unhideAll") },
      fitColumn: {
        label: t("HeaderMenu.Column.FitToContents"), enabled: hasDocument,
        run: async () => {
          const s = this.engine.state;
          for (let c = s.selection[1]; c <= s.selection[3]; c++) await this.grid.fitColumn(c);
        },
      },
      newSheet: { label: t("Mac.Menu.NewSheet"), shortcut: shortcut("N", { shift: true }), enabled: hasDocument, run: () => this.engine.call("addSheet") },
      previousSheet: { label: t("Mac.Menu.PreviousSheet"), enabled: hasDocument, run: () => this.stepSheet(-1) },
      nextSheet: { label: t("Mac.Menu.NextSheet"), enabled: hasDocument, run: () => this.stepSheet(1) },
      freezeTopRow: { label: t("Mac.Menu.FreezeTopRow"), enabled: info?.allowsFreeze, run: () => this.engine.call("freeze", { rows: 1, columns: this.engine.layout?.frozenColumns ?? 0 }) },
      freezeFirstColumn: { label: t("Mac.Menu.FreezeFirstColumn"), enabled: info?.allowsFreeze, run: () => this.engine.call("freeze", { rows: this.engine.layout?.frozenRows ?? 0, columns: 1 }) },
      freezeSelection: { label: t("Mac.Menu.FreezeAtSelection"), enabled: info?.allowsFreeze, run: () => this.engine.call("freezeSelection") },
      unfreeze: { label: t("Mac.Menu.Unfreeze"), enabled: info?.allowsFreeze && (this.engine.layout?.frozenRows || this.engine.layout?.frozenColumns), run: () => this.engine.call("freeze", { rows: 0, columns: 0 }) },
      zoomIn: { label: t("Mac.Menu.ZoomIn"), shortcut: shortcut("="), enabled: hasDocument, run: () => this.stepZoom(1) },
      zoomOut: { label: t("Mac.Menu.ZoomOut"), shortcut: shortcut("-", { alt: true }), enabled: hasDocument, run: () => this.stepZoom(-1) },
      actualSize: { label: t("Mac.Menu.ActualSize"), shortcut: shortcut("0"), enabled: hasDocument, run: () => this.grid.setZoom(1) },
      toggleInspector: { label: t("Mac.Menu.ShowInspector"), checked: !this.inspector.hidden, run: () => this.setInspectorVisible(this.inspector.hidden) },
      about: { label: t("Mac.Menu.About", "Tables"), run: () => this.showAbout() },
    };
  }

  /** The next preset zoom in either direction, from wherever a pinch left it. */
  stepZoom(direction) {
    const presets = [0.5, 0.75, 1, 1.25, 1.5, 2, 3];
    const current = this.grid.zoom;
    const next = direction > 0 ? presets.find((z) => z > current + 0.001) : [...presets].reverse().find((z) => z < current - 0.001);
    if (next) this.grid.setZoom(next);
  }

  run(id) {
    const command = this.commands[id];
    if (!command || command.enabled === false) return;
    return Promise.resolve(command.run()).catch((error) => this.showMessage(error.message, "error"));
  }

  item(id) {
    const command = this.commands[id];
    return {
      label: command.label,
      shortcut: command.shortcut,
      checked: command.checked === undefined ? undefined : Boolean(command.checked),
      disabled: "enabled" in command && !command.enabled,
      action: () => this.run(id),
    };
  }

  items(...ids) {
    return ids.map((id) => (id === "-" ? { separator: true } : this.item(id)));
  }

  style(args) {
    return this.engine.call("style", args);
  }

  aggregateItems() {
    return ["SUM", "AVERAGE", "COUNT", "MIN", "MAX"].map((name) => ({
      label: name,
      disabled: !this.document,
      action: async () => {
        const result = await this.engine.call("aggregate", { function: name });
        if (result?.editText) this.grid.beginEdit({ seed: result.editText });
        else this.grid.focus();
      },
    }));
  }

  buildMenus() {
    const self = this;
    const appearance = readSetting("appearance", "");
    const menus = [
      { label: t("Mac.Menu.File"), get items() { return self.fileMenu(); } },
      { label: t("Mac.Menu.Edit"), get items() { return self.items("undo", "redo", "-", "cut", "copy", "paste", "clear", "selectAll"); } },
      { label: t("Mac.Menu.Insert"), get items() {
        return [
          ...self.items("insertRowAbove", "insertRowBelow", "insertColumnBefore", "insertColumnAfter", "-", "addRow", "addColumn", "-", "newSheet"),
          { separator: true },
          { label: t("Toolbar.InsertFunction"), submenu: self.aggregateItems() },
        ];
      } },
      { label: t("Mac.Menu.Format"), get items() { return self.formatMenu(); } },
      { label: t("Mac.Menu.Table"), get items() {
        return self.items("deleteRow", "deleteColumn", "-", "hideRow", "hideColumn", "unhideAll", "-", "fitColumn");
      } },
      { label: t("Mac.Menu.View"), get items() {
        const current = readSetting("appearance", "");
        return [
          ...self.items("zoomIn", "zoomOut", "actualSize", "-"),
          { label: t("Mac.Menu.FreezePanes"), submenu: self.items("freezeTopRow", "freezeFirstColumn", "freezeSelection", "-", "unfreeze") },
          { separator: true },
          self.item("toggleInspector"),
          { label: t("Web.Menu.Appearance"), submenu: [
            { label: t("Web.Appearance.System"), checked: current === "", action: () => self.applyAppearance("") },
            { label: t("Web.Appearance.Light"), checked: current === "light", action: () => self.applyAppearance("light") },
            { label: t("Web.Appearance.Dark"), checked: current === "dark", action: () => self.applyAppearance("dark") },
          ] },
        ];
      } },
      { label: t("Mac.Menu.Window"), get items() {
        return [...self.items("previousSheet", "nextSheet"), { separator: true },
          ...(self.engine.info?.sheets ?? []).filter((s) => !s.hidden).map((sheet) => ({
            label: sheet.name, checked: self.engine.state?.sheet === sheet.id, disabled: !self.document,
            action: () => self.engine.call("selectSheet", { id: sheet.id }),
          }))];
      } },
      { label: t("Mac.Menu.Help"), get items() { return self.items("about"); } },
    ];
    void appearance;
    attachMenuBar(this.root.querySelector("#menu-bar"), menus, { label: t("Web.Menu.Label"), overflowLabel: t("Toolbar.More") });
  }

  fileMenu() {
    const formats = this.engine.info?.saveFormats ?? ["xlsx", "csv", "tsv"];
    const exportLabels = {
      xlsx: t("Mac.Menu.Export.Workbook"), xlsm: t("Web.Menu.Export.MacroWorkbook"), numbers: t("Web.Menu.Export.Numbers"),
      csv: t("Mac.Menu.Export.CSV"), tsv: t("Mac.Menu.Export.TSV"),
    };
    return [
      ...this.items("new", "open"),
      { label: t("Mac.Menu.OpenRecent"), submenu: this.recentItems() },
      { separator: true },
      ...this.items("close", "save", "saveAs", "rename"),
      { separator: true },
      {
        label: t("Mac.Menu.ExportTo"),
        disabled: !this.document,
        submenu: formats.map((format) => ({ label: exportLabels[format], action: () => this.exportAs(format) })),
      },
    ];
  }

  recentItems() {
    const recents = this.recents ?? [];
    if (!recents.length) return [{ label: t("Web.Start.NoRecent"), disabled: true }];
    return [
      ...recents.slice(0, 10).map((record) => ({ label: record.name, action: () => this.openRecord(record) })),
      { separator: true },
      { label: t("Mac.Menu.ClearRecent"), action: async () => {
        await storage.clearRecents();
        await this.refreshRecents();
      } },
    ];
  }

  formatMenu() {
    const info = this.engine.info;
    const state = this.engine.state;
    const presets = info?.numberFormats ?? [];
    return [
      { label: t("Mac.Menu.Font"), submenu: this.items("showFonts", "-", "bold", "italic", "underline", "strike", "-", "bigger", "smaller") },
      { label: t("Mac.Menu.Alignment"), submenu: [
        ...["automatic", "leading", "center", "trailing"].map((h) => ({
          label: t(`Alignment.Horizontal.${{ automatic: "Automatic", leading: "Left", center: "Center", trailing: "Right" }[h]}`),
          checked: state?.style.h === h, disabled: !info?.formatting.styles, action: () => this.style({ h }),
        })),
        { separator: true },
        ...["top", "middle", "bottom"].map((v) => ({
          label: t(`Alignment.Vertical.${v[0].toUpperCase()}${v.slice(1)}`),
          checked: state?.style.v === v, disabled: !info?.formatting.styles, action: () => this.style({ v }),
        })),
        { separator: true },
        ...this.items("wrap", "indent", "outdent"),
      ] },
      { label: t("Toolbar.NumberFormat"), submenu: presets.map((preset) => ({
        label: preset.label, checked: state?.style.numberFormat === preset.code, disabled: !info?.formatting.numberFormats,
        action: () => this.style({ numberFormat: preset.code }),
      })) },
      { label: t("Mac.Menu.Borders"), submenu: this.borderItems() },
      { separator: true },
      ...this.items("noFill", "-", "merge", "unmerge", "-", "resetFormatting"),
    ];
  }

  borderItems() {
    const enabled = this.engine.info?.formatting.borders;
    return [
      ["all", "Mac.Border.All"], ["outside", "Mac.Border.Outline"], ["top", "Mac.Border.Top"], ["bottom", "Mac.Border.Bottom"],
      ["left", "Mac.Border.Left"], ["right", "Mac.Border.Right"], ["none", "Mac.Border.None"],
    ].map(([preset, key]) => ({ label: t(key), disabled: !enabled, action: () => this.applyBorder(preset) }));
  }

  applyBorder(preset) {
    const lineStyle = this.inspector.querySelector(".app__line-style")?.value ?? "thin";
    const colorWell = this.inspector.querySelector(".app__border-color");
    const color = colorWell?.dataset.set === "1" ? colorWell.value : null;
    return this.engine.call("border", { preset, style: lineStyle, color });
  }

  contextMenu(kind) {
    if (!this.document) return null;
    const clipboard = this.items("cut", "copy", "paste");
    if (kind === "cell") {
      return [
        ...clipboard,
        { separator: true },
        ...this.items("insertRowAbove", "insertRowBelow", "insertColumnBefore", "insertColumnAfter", "-", "deleteRow", "deleteColumn", "-", "clear", "resetFormatting"),
        ...(this.engine.state?.canMerge ? this.items("merge") : []),
        ...(this.engine.state?.canUnmerge ? this.items("unmerge") : []),
      ];
    }
    if (kind === "column") {
      return [...clipboard, { separator: true },
        ...this.items("insertColumnBefore", "insertColumnAfter", "deleteColumn", "-", "hideColumn", "unhideAll", "-", "fitColumn")];
    }
    return [...clipboard, { separator: true }, ...this.items("insertRowAbove", "insertRowBelow", "deleteRow", "-", "hideRow", "unhideAll")];
  }

  // MARK: - Inspector

  buildInspector() {
    const section = (titleKey, body) => `
      <details class="ds-disclosure" open>
        <summary>${icon("chevronDown", "ds-disclosure__triangle app__triangle")}${escapeHTML(t(titleKey))}</summary>
        <div class="ds-disclosure__body ds-form">${body}</div>
      </details>`;
    const row = (labelKey, control) => `<span class="ds-form__label">${labelKey ? escapeHTML(t(labelKey)) : ""}</span><span class="ds-form__control">${control}</span>`;
    const stepper = (cls, label) => `
      <span class="ds-stepper ds-stepper--xs ${cls}"><input class="ds-stepper__input" type="number" aria-label="${escapeHTML(label)}">
        <span class="ds-stepper__arrows">
          <button class="ds-stepper__arrow" data-step="1" aria-label="${escapeHTML(t("Format.Text.Size.Increase"))}">${icon("chevronUp")}</button>
          <button class="ds-stepper__arrow" data-step="-1" aria-label="${escapeHTML(t("Format.Text.Size.Decrease"))}">${icon("chevronDown")}</button>
        </span></span>`;
    const popup = (cls, label, options) => `<span class="ds-popup ds-popup--xs" style="flex: 1"><select class="ds-popup__select ${cls}" aria-label="${escapeHTML(label)}">${options}</select>${icon("chevronDown", "ds-popup__chevron")}</span>`;
    const borderButtons = [["all", "borderAll", "Mac.Border.All"], ["outside", "borderOutside", "Mac.Border.Outline"], ["top", "borderTop", "Mac.Border.Top"],
      ["bottom", "borderBottom", "Mac.Border.Bottom"], ["left", "borderLeft", "Mac.Border.Left"], ["right", "borderRight", "Mac.Border.Right"], ["none", "borderNone", "Mac.Border.None"]]
      .map(([preset, glyph, key]) => `<button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" data-border="${preset}" title="${escapeHTML(t(key))}" aria-label="${escapeHTML(t(key))}">${icon(glyph)}</button>`).join("");
    const lineStyles = ["thin", "medium", "thick", "double", "dotted", "dashed", "hair"]
      .map((style) => `<option value="${style}">${escapeHTML(t(`BorderLineStyle.${{ hair: "Hairline", thin: "Thin", medium: "Medium", thick: "Thick", double: "Double", dotted: "Dotted", dashed: "Dashed" }[style]}`))}</option>`).join("");

    this.inspector.innerHTML = `
      <div class="ds-inspector__switcher">
        <div class="ds-segmented ds-segmented--xs ds-segmented--fill" role="tablist">
          <button class="ds-segmented__segment" role="tab" data-pane="cell" aria-selected="true">${escapeHTML(t("Mac.Inspector.Cell"))}</button>
          <button class="ds-segmented__segment" role="tab" data-pane="text" aria-selected="false">${escapeHTML(t("Format.Section.Text"))}</button>
          <button class="ds-segmented__segment" role="tab" data-pane="sheet" aria-selected="false">${escapeHTML(t("Web.Inspector.Sheet"))}</button>
        </div>
      </div>
      <div class="ds-inspector__body">
        <div class="app__no-formatting ds-notification" hidden>${icon("info", "ds-icon--20")}<div><span class="ds-notification__title">${escapeHTML(t("Mac.Inspector.NoFormatting.Title"))}</span> ${escapeHTML(t("Mac.Inspector.NoFormatting.Message"))}</div><span></span></div>
        <div data-pane-body="cell">
          ${section("Toolbar.NumberFormat",
            row("Mac.Inspector.NumberFormat.Format", popup("app__number-format", t("Toolbar.NumberFormat"), ""))
            + row("", `<input class="ds-text-input ds-text-input--xs app__format-code" spellcheck="false" aria-label="${escapeHTML(t("Mac.Inspector.NumberFormat.Custom"))}" hidden>`))}
          ${section("Format.Section.Fill",
            row("Mac.Inspector.Color", `<input type="color" class="ds-color-well app__fill" aria-label="${escapeHTML(t("Mac.Menu.FillColor"))}">
              <button class="ds-button ds-button--bordered ds-button--xs" data-command="noFill">${escapeHTML(t("Mac.Menu.NoFill"))}</button>`))}
          ${section("Format.Section.Borders",
            `<span class="ds-form__label">${escapeHTML(t("Format.Border.ApplyTo"))}</span><span class="ds-form__control app__border-buttons">${borderButtons}</span>`
            + row("Mac.Inspector.LineStyle", popup("app__line-style", t("Mac.Inspector.LineStyle"), lineStyles))
            + row("Mac.Inspector.Color", `<input type="color" class="ds-color-well app__border-color" value="#000000" aria-label="${escapeHTML(t("Mac.Inspector.Color"))}">`))}
          ${section("Format.Section.Merge",
            row("", `<button class="ds-button ds-button--bordered ds-button--xs" data-command="merge">${escapeHTML(t("Format.Merge.Merge"))}</button>
              <button class="ds-button ds-button--bordered ds-button--xs" data-command="unmerge">${escapeHTML(t("Format.Merge.Unmerge"))}</button>`))}
        </div>
        <div data-pane-body="text" hidden>
          ${section("Format.Section.Text",
            row("Mac.Toolbar.Style", `<span class="ds-segmented ds-segmented--xs ds-segmented--icons" role="group">
              <button class="ds-segmented__segment" data-command="bold" aria-pressed="false" title="${escapeHTML(t("Toolbar.Bold"))}"><strong>B</strong></button>
              <button class="ds-segmented__segment" data-command="italic" aria-pressed="false" title="${escapeHTML(t("Toolbar.Italic"))}"><em>I</em></button>
              <button class="ds-segmented__segment" data-command="underline" aria-pressed="false" title="${escapeHTML(t("Toolbar.Underline"))}"><u>U</u></button>
              <button class="ds-segmented__segment" data-command="strike" aria-pressed="false" title="${escapeHTML(t("Toolbar.Strikethrough"))}"><s>S</s></button></span>`)
            + row("Format.Text.Font", popup("app__font", t("Format.Text.Font"), ""))
            + row("Format.Text.Size", `${stepper("app__font-size", t("Format.Text.Size"))}<span class="ds-caption">pt</span>`)
            + row("Mac.Inspector.Color", `<input type="color" class="ds-color-well app__text-color" aria-label="${escapeHTML(t("Mac.Menu.TextColor"))}">
              <button class="ds-button ds-button--bordered ds-button--xs app__text-color-none">${escapeHTML(t("Mac.Inspector.Color.None"))}</button>`))}
          ${section("Format.Section.Alignment",
            row("Format.Alignment.Horizontal", `<span class="ds-segmented ds-segmented--xs ds-segmented--icons" role="radiogroup">
              ${[["automatic", "alignAuto", "Automatic"], ["leading", "alignLeft", "Left"], ["center", "alignCenter", "Center"], ["trailing", "alignRight", "Right"]]
                .map(([value, glyph, key]) => `<button class="ds-segmented__segment" role="radio" data-h="${value}" aria-checked="false" title="${escapeHTML(t(`Alignment.Horizontal.${key}`))}" aria-label="${escapeHTML(t(`Alignment.Horizontal.${key}`))}">${icon(glyph)}</button>`).join("")}</span>`)
            + row("Format.Alignment.Vertical", `<span class="ds-segmented ds-segmented--xs ds-segmented--icons" role="radiogroup">
              ${[["top", "top", "Top"], ["middle", "middle", "Middle"], ["bottom", "bottom", "Bottom"]]
                .map(([value, glyph, key]) => `<button class="ds-segmented__segment" role="radio" data-v="${value}" aria-checked="false" title="${escapeHTML(t(`Alignment.Vertical.${key}`))}" aria-label="${escapeHTML(t(`Alignment.Vertical.${key}`))}">${icon(glyph)}</button>`).join("")}</span>`)
            + row("Format.Alignment.Indent", `<button class="ds-button ds-button--bordered ds-button--xs" data-command="outdent">${escapeHTML(t("Mac.Menu.DecreaseIndent"))}</button>
              <button class="ds-button ds-button--bordered ds-button--xs" data-command="indent">${escapeHTML(t("Mac.Menu.IncreaseIndent"))}</button>`)
            + row("", `<label class="ds-check"><input type="checkbox" class="app__wrap">${escapeHTML(t("Format.Alignment.WrapText"))}</label>`))}
        </div>
        <div data-pane-body="sheet" hidden>
          ${section("Web.Inspector.Sheet",
            row("SheetTabBar.RenameField.Placeholder", `<input class="ds-text-input ds-text-input--xs app__sheet-name" spellcheck="false" aria-label="${escapeHTML(t("SheetTabBar.RenameField.Placeholder"))}">`)
            + row("Web.Inspector.TabColour", `<input type="color" class="ds-color-well app__tab-color" aria-label="${escapeHTML(t("Web.Inspector.TabColour"))}">
              <button class="ds-button ds-button--bordered ds-button--xs app__tab-color-none">${escapeHTML(t("Mac.Inspector.Color.None"))}</button>`))}
          ${section("Panel.RowsAndColumns.Title",
            row("Web.Inspector.Rows", `<span class="ds-caption ds-numeric app__row-count"></span><button class="ds-button ds-button--bordered ds-button--xs" data-command="addRow">${escapeHTML(t("HeaderMenu.Row.AddAtEnd"))}</button>`)
            + row("Web.Inspector.Columns", `<span class="ds-caption ds-numeric app__column-count"></span><button class="ds-button ds-button--bordered ds-button--xs" data-command="addColumn">${escapeHTML(t("HeaderMenu.Column.AddAtEnd"))}</button>`)
            + row("Web.Inspector.FrozenRows", stepper("app__frozen-rows", t("Web.Inspector.FrozenRows")))
            + row("Web.Inspector.FrozenColumns", stepper("app__frozen-columns", t("Web.Inspector.FrozenColumns")))
            + row("", `<button class="ds-button ds-button--bordered ds-button--xs" data-command="unhideAll">${escapeHTML(t("Mac.Menu.UnhideAll"))}</button>`))}
        </div>
      </div>`;

    const inspector = this.inspector;
    inspector.querySelectorAll(".ds-inspector__switcher [data-pane]").forEach((tab) => tab.addEventListener("click", () => {
      for (const other of inspector.querySelectorAll(".ds-inspector__switcher [data-pane]")) other.setAttribute("aria-selected", String(other === tab));
      for (const body of inspector.querySelectorAll("[data-pane-body]")) body.hidden = body.dataset.paneBody !== tab.dataset.pane;
    }));
    inspector.querySelectorAll("[data-command]").forEach((button) => button.addEventListener("click", () => this.run(button.dataset.command)));

    const fontPopup = inspector.querySelector(".app__font");
    fontPopup.addEventListener("change", async () => {
      const value = fontPopup.value;
      if (value === "__all") {
        // Choosing it is the user action the browser asks for before listing fonts.
        await fonts.listAllFonts();
        await this.updateFontPopup();
        fontPopup.focus();
        return;
      }
      await this.style({ fontName: value || null });
      this.grid.focus();
    });
    inspector.querySelectorAll("[data-border]").forEach((button) => button.addEventListener("click", () => this.applyBorder(button.dataset.border)));
    inspector.querySelectorAll("[data-h]").forEach((button) => button.addEventListener("click", () => this.style({ h: button.dataset.h })));
    inspector.querySelectorAll("[data-v]").forEach((button) => button.addEventListener("click", () => this.style({ v: button.dataset.v })));

    const numberFormat = inspector.querySelector(".app__number-format");
    const formatCode = inspector.querySelector(".app__format-code");
    numberFormat.addEventListener("change", () => {
      if (numberFormat.value === "__custom") {
        formatCode.hidden = false;
        formatCode.focus();
        return;
      }
      this.style({ numberFormat: numberFormat.value });
    });
    formatCode.addEventListener("change", () => this.style({ numberFormat: formatCode.value }));

    inspector.querySelector(".app__fill").addEventListener("input", (event) => this.style({ fill: event.target.value }));
    inspector.querySelector(".app__text-color").addEventListener("input", (event) => this.style({ textColor: event.target.value }));
    inspector.querySelector(".app__text-color-none").addEventListener("click", () => this.style({ textColor: null }));
    const borderColor = inspector.querySelector(".app__border-color");
    borderColor.addEventListener("input", () => { borderColor.dataset.set = "1"; });
    inspector.querySelector(".app__wrap").addEventListener("change", (event) => this.style({ wrap: event.target.checked }));

    const bindStepper = (selector, apply) => {
      const root = inspector.querySelector(selector);
      const input = root.querySelector("input");
      input.addEventListener("change", () => apply(Number(input.value)));
      root.querySelectorAll("[data-step]").forEach((arrow) => arrow.addEventListener("click", () => apply(Number(input.value || 0) + Number(arrow.dataset.step))));
    };
    bindStepper(".app__font-size", (size) => size > 0 && this.style({ fontSize: size }));
    bindStepper(".app__frozen-rows", (rows) => this.engine.call("freeze", { rows: Math.max(0, rows), columns: this.engine.layout?.frozenColumns ?? 0 }));
    bindStepper(".app__frozen-columns", (columns) => this.engine.call("freeze", { rows: this.engine.layout?.frozenRows ?? 0, columns: Math.max(0, columns) }));

    const sheetName = inspector.querySelector(".app__sheet-name");
    sheetName.addEventListener("change", () => this.engine.call("renameSheet", { id: this.engine.state.sheet, name: sheetName.value })
      .catch((error) => this.showMessage(error.message, "error")));
    inspector.querySelector(".app__tab-color").addEventListener("input", (event) => this.engine.call("sheetColor", { id: this.engine.state.sheet, color: event.target.value }));
    inspector.querySelector(".app__tab-color-none").addEventListener("click", () => this.engine.call("sheetColor", { id: this.engine.state.sheet, color: null }));
  }

  updateInspector() {
    const state = this.engine.state;
    const info = this.engine.info;
    if (!state || !info) return;
    const inspector = this.inspector;
    const style = state.style;
    const formatting = info.formatting;
    inspector.querySelector(".app__no-formatting").hidden = Object.values(formatting).some(Boolean);

    const numberFormat = inspector.querySelector(".app__number-format");
    const known = info.numberFormats.some((preset) => preset.code === style.numberFormat);
    numberFormat.innerHTML = info.numberFormats.map((preset) => `<option value="${escapeHTML(preset.code)}">${escapeHTML(preset.label)}</option>`).join("")
      + `<option value="__custom">${escapeHTML(t("Mac.Inspector.NumberFormat.Custom"))}</option>`;
    numberFormat.value = known ? style.numberFormat : "__custom";
    numberFormat.disabled = !formatting.numberFormats;
    const formatCode = inspector.querySelector(".app__format-code");
    if (document.activeElement !== formatCode) formatCode.value = style.numberFormat;
    formatCode.hidden = known;

    const setColor = (selector, value) => {
      const well = inspector.querySelector(selector);
      if (document.activeElement !== well) well.value = value ?? "#ffffff";
      well.disabled = !formatting.styles;
    };
    setColor(".app__fill", style.fill);
    setColor(".app__text-color", style.textColor ?? "#000000");
    for (const button of inspector.querySelectorAll("[data-border]")) button.disabled = !formatting.borders;
    for (const [command, key] of [["bold", "bold"], ["italic", "italic"], ["underline", "underline"], ["strike", "strike"]]) {
      inspector.querySelector(`.ds-segmented__segment[data-command="${command}"]`).setAttribute("aria-pressed", String(Boolean(style[key])));
    }
    for (const button of inspector.querySelectorAll("[data-h]")) button.setAttribute("aria-checked", String(style.h === button.dataset.h));
    for (const button of inspector.querySelectorAll("[data-v]")) button.setAttribute("aria-checked", String(style.v === button.dataset.v));
    inspector.querySelector(".app__wrap").checked = style.wrap;
    const fontSize = inspector.querySelector(".app__font-size input");
    if (document.activeElement !== fontSize) fontSize.value = style.fontSize;
    this.updateFontPopup();
    inspector.querySelector('[data-command="merge"]').disabled = !state.canMerge;
    inspector.querySelector('[data-command="unmerge"]').disabled = !state.canUnmerge;

    const sheet = info.sheets.find((s) => s.id === state.sheet);
    const sheetName = inspector.querySelector(".app__sheet-name");
    if (sheet && document.activeElement !== sheetName) sheetName.value = sheet.name;
    inspector.querySelector(".app__tab-color").value = sheet?.color ?? "#ffffff";
    const layout = this.engine.layout;
    if (layout) {
      inspector.querySelector(".app__row-count").textContent = this.numberFormat.format(layout.rows);
      inspector.querySelector(".app__column-count").textContent = this.numberFormat.format(layout.columns);
      inspector.querySelector(".app__frozen-rows input").value = layout.frozenRows;
      inspector.querySelector(".app__frozen-columns input").value = layout.frozenColumns;
    }
    for (const selector of [".app__frozen-rows", ".app__frozen-columns"]) {
      for (const control of inspector.querySelectorAll(`${selector} input, ${selector} button`)) control.disabled = !info.allowsFreeze;
    }
  }

  /**
   * Fills the font pop-up: the system font, the families the document uses,
   * those installed here, and, where the browser can list every installed
   * font, a way to ask for that. Names are set in the system font, as all
   * interface text is.
   */
  async updateFontPopup() {
    const popup = this.inspector.querySelector(".app__font");
    const state = this.engine.state;
    const info = this.engine.info;
    if (!popup || !state || !info) return;
    const current = state.style.fontName ?? "";
    const version = this.engine.versions.content;
    if (this.documentFonts?.version !== version) {
      // A read-only query: send, not call, so it doesn't publish state and refresh this pop-up again.
      const previous = this.documentFonts?.families ?? [];
      this.documentFonts = { version, families: previous };
      const { response } = await this.engine.send({ cmd: "documentFonts" }).catch(() => ({ response: {} }));
      if (this.documentFonts.version === version) this.documentFonts.families = response.result ?? [];
    }
    const inDocument = this.documentFonts.families;
    const installed = fonts.installedFamilies().filter((family) => !inDocument.includes(family));
    const option = (value, label) => `<option value="${escapeHTML(value)}">${escapeHTML(label)}</option>`;
    const key = JSON.stringify([current, inDocument, installed.length, fonts.hasListedAllFonts()]);
    if (popup.dataset.key !== key) {
      popup.dataset.key = key;
      popup.innerHTML = option("", t("Format.Text.Font.System"))
        + (inDocument.length ? `<optgroup label="${escapeHTML(t("Web.Font.InDocument"))}">${inDocument.map((f) => option(f, f)).join("")}</optgroup>` : "")
        + (installed.length ? `<optgroup label="${escapeHTML(t("Web.Font.OnDevice"))}">${installed.map((f) => option(f, f)).join("")}</optgroup>` : "")
        + (fonts.canListAllFonts && !fonts.hasListedAllFonts() ? option("__all", t("Web.Font.ShowAll")) : "");
    }
    if (document.activeElement !== popup) popup.value = current;
    popup.disabled = !info.formatting.fonts;
  }

  /** The web's "Show Fonts": the inspector's font pop-up, opened. */
  showFonts() {
    this.setInspectorVisible(true);
    this.inspector.querySelector('.ds-inspector__switcher [data-pane="text"]').click();
    const popup = this.inspector.querySelector(".app__font");
    popup.focus();
    try {
      popup.showPicker();
    } catch {
      // Focused is as far as some browsers let a page open a pop-up.
    }
  }

  setInspectorVisible(visible) {
    this.inspector.hidden = !visible;
    this.root.querySelector("#inspector-toggle").setAttribute("aria-pressed", String(visible));
    writeSetting("inspector", visible ? "1" : "0");
  }

  // MARK: - Sheet tabs

  renderTabs() {
    const info = this.engine.info;
    const state = this.engine.state;
    if (!info) return;
    const sheets = info.sheets.filter((sheet) => !sheet.hidden);
    const previousScroll = this.tabs.querySelector(".ds-sheet-tabs__strip")?.scrollLeft ?? 0;
    this.tabs.innerHTML = `
      <div class="ds-sheet-tabs__strip" role="tablist" aria-label="${escapeHTML(t("Web.SheetTabs.AllSheets"))}">
        ${sheets.map((sheet) => `
          <button class="ds-sheet-tabs__tab" role="tab" data-id="${sheet.id}" aria-selected="${sheet.id === state?.sheet}" title="${escapeHTML(sheet.name)}"
            ${sheet.color ? `style="--ds-tab-tint: ${escapeHTML(sheet.color)}"` : ""}>${escapeHTML(sheet.name)}</button>`).join("")}
      </div>
      <div class="ds-sheet-tabs__actions">
        <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs ds-sheet-tabs__add" aria-label="${escapeHTML(t("SheetTabBar.AddSheet"))}" title="${escapeHTML(t("SheetTabBar.AddSheet"))}">${icon("add")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs app__all-sheets" aria-haspopup="menu" aria-label="${escapeHTML(t("Web.SheetTabs.AllSheets"))}" title="${escapeHTML(t("Web.SheetTabs.AllSheets"))}">${icon("list")}</button>
      </div>`;
    this.tabs.removeAttribute("role");

    const strip = this.tabs.querySelector(".ds-sheet-tabs__strip");
    strip.scrollLeft = previousScroll;
    for (const tab of strip.querySelectorAll(".ds-sheet-tabs__tab")) {
      tab.addEventListener("click", async () => {
        await this.grid.commitIfEditing();
        await this.engine.call("selectSheet", { id: tab.dataset.id });
        this.grid.focus();
      });
      tab.addEventListener("dblclick", () => this.renameSheetInline(tab));
      tab.addEventListener("contextmenu", (event) => {
        event.preventDefault();
        this.engine.call("selectSheet", { id: tab.dataset.id });
        openMenu(this.sheetMenu(tab), { x: event.clientX, y: event.clientY }, { placement: "point" });
      });
    }
    // A mouse wheel scrolls the tabs sideways; trackpads already scroll them.
    strip.addEventListener("wheel", (event) => {
      if (event.ctrlKey || Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
      event.preventDefault();
      strip.scrollLeft += event.deltaY;
    }, { passive: false });
    this.tabs.querySelector(".ds-sheet-tabs__add").addEventListener("click", () => this.run("newSheet"));
    const allSheets = this.tabs.querySelector(".app__all-sheets");
    allSheets.addEventListener("click", () => openMenu(this.allSheetsMenu(), allSheets, { opener: allSheets, placement: "below" }));
    this.revealActiveTab();
  }

  /** Every sheet, the hidden ones last: choosing a hidden one shows it again. */
  allSheetsMenu() {
    const info = this.engine.info;
    const active = this.engine.state?.sheet;
    const visible = info.sheets.filter((sheet) => !sheet.hidden);
    const hidden = info.sheets.filter((sheet) => sheet.hidden);
    return [
      ...visible.map((sheet) => ({
        label: sheet.name, checked: sheet.id === active,
        action: async () => {
          await this.grid.commitIfEditing();
          await this.engine.call("selectSheet", { id: sheet.id });
          this.grid.focus();
        },
      })),
      ...(hidden.length ? [{ separator: true }, { header: t("SheetTabBar.ShowHiddenSheet") }] : []),
      ...hidden.map((sheet) => ({ label: sheet.name, action: () => this.engine.call("hideSheet", { id: sheet.id, hidden: false }) })),
    ];
  }

  /** Scrolls the tab strip just enough to show the active sheet's tab. */
  revealActiveTab() {
    const strip = this.tabs.querySelector(".ds-sheet-tabs__strip");
    const tab = strip?.querySelector('[aria-selected="true"]');
    if (!tab) return;
    const left = tab.offsetLeft, right = left + tab.offsetWidth;
    if (left < strip.scrollLeft) strip.scrollLeft = left;
    else if (right > strip.scrollLeft + strip.clientWidth) strip.scrollLeft = right - strip.clientWidth;
  }

  sheetMenu(tab) {
    const id = tab.dataset.id;
    const colours = ["#da1e28", "#ff832b", "#f1c21b", "#24a148", "#1192e8", "#8a3ffc", "#ee5396"];
    return [
      { label: t("SheetTabBar.Menu.Rename"), action: () => this.renameSheetInline(tab) },
      { label: t("SheetTabBar.Menu.Duplicate"), action: () => this.engine.call("duplicateSheet") },
      { label: t("SheetTabBar.Menu.Hide"), action: () => this.engine.call("hideSheet", { id, hidden: true }).catch((e) => this.showMessage(e.message, "error")) },
      { label: t("Web.Inspector.TabColour"), submenu: [
        { label: t("Mac.Inspector.Color.None"), action: () => this.engine.call("sheetColor", { id, color: null }) },
        { separator: true },
        ...colours.map((colour, index) => ({
          label: t(["Color.Red", "Color.Orange", "Color.Yellow", "Color.Green", "Color.Blue", "Color.Purple", "Color.Pink"][index]),
          action: () => this.engine.call("sheetColor", { id, color: colour }),
        })),
      ] },
      { separator: true },
      { label: t("SheetTabBar.Menu.Delete"), action: () => this.engine.call("deleteSheet", { id }) },
    ];
  }

  renameSheetInline(tab) {
    const input = document.createElement("input");
    input.className = "ds-text-input ds-text-input--xs app__tab-rename";
    input.value = tab.textContent.trim();
    input.ariaLabel = t("SheetTabBar.RenameField.Placeholder");
    tab.replaceWith(input);
    input.focus();
    input.select();
    let done = false;
    const finish = async (commit) => {
      if (done) return;
      done = true;
      if (commit && input.value.trim() && input.value !== tab.textContent.trim()) {
        await this.engine.call("renameSheet", { id: tab.dataset.id, name: input.value.trim() }).catch((error) => this.showMessage(error.message, "error"));
      }
      this.renderTabs();
      this.grid.focus();
    };
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") finish(true);
      if (event.key === "Escape") finish(false);
    });
    input.addEventListener("blur", () => finish(true));
  }

  stepSheet(direction) {
    const sheets = (this.engine.info?.sheets ?? []).filter((sheet) => !sheet.hidden);
    const index = sheets.findIndex((sheet) => sheet.id === this.engine.state?.sheet);
    const next = sheets[(index + direction + sheets.length) % sheets.length];
    if (next) this.engine.call("selectSheet", { id: next.id });
  }

  // MARK: - Engine events

  bindEngine() {
    this.engine.addEventListener("state", () => this.update());
    this.engine.addEventListener("document", () => {
      this.renderTabs();
      this.updateTitle();
    });
    this.engine.addEventListener("fatal", () => this.showMessage(t("Web.Error.Engine"), "error", {
      action: { label: t("Web.Error.Reload"), run: () => location.reload() },
      sticky: true,
    }));
    this.grid.addEventListener("edit", (event) => {
      if (document.activeElement !== this.formula) this.formula.value = event.detail;
    });
    this.grid.addEventListener("editend", () => {
      this.formula.value = this.engine.state?.editText ?? "";
    });
    this.grid.addEventListener("message", (event) => this.showMessage(event.detail, "error"));
    this.grid.addEventListener("zoom", (event) => {
      const zoom = event.detail;
      const preset = [...this.zoomSelect.options].find((option) => !option.dataset.custom && Math.abs(Number(option.value) - zoom) < 0.005);
      let custom = this.zoomSelect.querySelector("[data-custom]");
      if (preset) {
        custom?.remove();
        this.zoomSelect.value = preset.value;
        return;
      }
      if (!custom) {
        custom = new Option("", "");
        custom.dataset.custom = "1";
        this.zoomSelect.add(custom);
      }
      custom.value = String(zoom);
      custom.textContent = new Intl.NumberFormat(language, { style: "percent" }).format(zoom);
      this.zoomSelect.value = custom.value;
    });
  }

  update() {
    const state = this.engine.state;
    if (!state) return;
    if (document.activeElement !== this.nameBox) this.nameBox.value = state.name;
    if (!this.grid.isEditing && document.activeElement !== this.formula) this.formula.value = state.editText;

    // Toolbar state.
    const toolbar = this.root.querySelector("#toolbar");
    for (const [command, key] of [["bold", "bold"], ["italic", "italic"], ["underline", "underline"], ["strike", "strike"]]) {
      toolbar.querySelector(`[data-command="${command}"]`).setAttribute("aria-pressed", String(Boolean(state.style[key])));
    }
    for (const button of toolbar.querySelectorAll("[data-align]")) button.setAttribute("aria-checked", String(state.style.h === button.dataset.align));
    toolbar.querySelector('[data-command="undo"]').disabled = !state.canUndo;
    toolbar.querySelector('[data-command="redo"]').disabled = !state.canRedo;

    // Status bar.
    const status = state.status;
    const format = (value) => this.numberFormat.format(value);
    this.root.querySelector(".app__status-sum").textContent = status.numbers > 0 ? t("Web.Status.Sum", format(status.sum)) : "";
    this.root.querySelector(".app__status-average").textContent = status.numbers > 1 ? t("Web.Status.Average", format(status.average)) : "";
    this.root.querySelector(".app__status-count").textContent = status.count > 1 ? t("Web.Status.Count", format(status.count)) : "";

    if (state.message) this.showMessage(state.message, "error");
    this.updateTitle();
    this.updateInspector();
    for (const tab of this.tabs.querySelectorAll(".ds-sheet-tabs__tab")) tab.setAttribute("aria-selected", String(tab.dataset.id === state.sheet));
    this.revealActiveTab();
    if (this.hasUnkeptChanges && !this.autosaveTimer) this.scheduleAutosave();
  }

  updateTitle() {
    const name = this.document?.name ?? "Tables";
    this.titleElement.textContent = name;
    const dirty = this.engine.state?.dirty;
    this.subtitleElement.textContent = this.document ? (dirty ? t("Web.Document.Edited") : this.document.handle ? t("Web.Document.Saved") : "") : "";
    document.title = this.document ? `${name}${dirty ? " — " + t("Web.Document.Edited") : ""}` : "Tables";
  }

  // MARK: - Messages

  showMessage(text, kind = "info", { action = null, sticky = false } = {}) {
    if (!text) return;
    const banner = document.createElement("div");
    banner.className = `ds-notification ds-notification--${kind === "info" ? "info" : kind} app__banner`;
    banner.setAttribute("role", kind === "error" ? "alert" : "status");
    banner.innerHTML = `${icon(kind === "error" ? "error" : kind === "warning" ? "warning" : "info", "ds-icon--20")}<div></div>
      <span class="app__banner-actions"></span>`;
    banner.querySelector("div").textContent = text;
    const actions = banner.querySelector(".app__banner-actions");
    if (action) {
      const button = document.createElement("button");
      button.className = "ds-button ds-button--bordered ds-button--xs";
      button.textContent = action.label;
      button.addEventListener("click", () => {
        banner.remove();
        action.run();
      });
      actions.append(button);
    }
    const close = document.createElement("button");
    close.className = "ds-button ds-button--ghost ds-button--icon ds-button--xs";
    close.innerHTML = icon("close");
    close.ariaLabel = close.title = t("Mac.Find.Done");
    close.addEventListener("click", () => banner.remove());
    actions.append(close);
    this.banners.append(banner);
    if (!sticky) setTimeout(() => banner.remove(), kind === "error" ? 8000 : 5000);
  }

  showUnsupported() {
    const report = this.engine.info?.unsupported;
    if (!report) return;
    const list = (labels) => new Intl.ListFormat(language, { type: "conjunction" }).format(labels);
    if (report.lost.length) this.showMessage(t("Web.Unsupported.Lost", list(report.lost)), "warning", { sticky: true });
    else if (report.preserved.length) this.showMessage(t("Web.Unsupported.Preserved", list(report.preserved)), "info");
  }

  showAbout() {
    const backdrop = document.createElement("div");
    backdrop.className = "ds-sheet-backdrop app__sheet-backdrop";
    backdrop.innerHTML = `
      <div class="ds-sheet ds-alert app__about" role="alertdialog" aria-labelledby="about-title" aria-describedby="about-message">
        <div class="ds-sheet__body">
          <img class="app__about-icon" src="app/icons/icon.svg" width="48" height="48" alt="" draggable="false">
          <div>
            <h2 class="ds-sheet__title" id="about-title">Tables</h2>
            <p class="ds-caption app__about-version"></p>
            <p class="ds-sheet__message" id="about-message"></p>
            <p class="ds-sheet__message app__about-suite"><a href="https://atelier.ktgk.app" target="_blank" rel="noopener"></a></p>
          </div>
        </div>
        <div class="ds-sheet__buttons"><button class="ds-button ds-button--primary">${escapeHTML(t("Common.OK"))}</button></div>
      </div>`;
    backdrop.querySelector("#about-message").textContent = t("Web.About.Message");
    backdrop.querySelector(".app__about-version").textContent = t("Web.About.Version", self.TABLES_APP_VERSION ?? "");
    backdrop.querySelector(".app__about-suite a").textContent = t("Web.About.Suite");
    const close = () => {
      dismissSheet(backdrop);
      this.grid.focus();
    };
    backdrop.querySelector("button").addEventListener("click", close);
    backdrop.addEventListener("keydown", (event) => event.key === "Escape" && close());
    this.root.append(backdrop);
    backdrop.querySelector("button").focus();
  }

  /** A window-modal sheet asking for one line of text. Resolves with it, or null on Cancel. */
  askText(title, value, confirmLabel) {
    return new Promise((resolve) => {
      const backdrop = document.createElement("div");
      backdrop.className = "ds-sheet-backdrop app__sheet-backdrop";
      backdrop.innerHTML = `
        <form class="ds-sheet" role="dialog" aria-labelledby="ask-title">
          <div class="ds-sheet__body">
            <h2 class="ds-sheet__title" id="ask-title"></h2>
            <input class="ds-text-input" spellcheck="false" aria-labelledby="ask-title">
          </div>
          <div class="ds-sheet__buttons">
            <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Web.Common.Cancel"))}</button>
            <button class="ds-button ds-button--primary" type="submit"></button>
          </div>
        </form>`;
      backdrop.querySelector("#ask-title").textContent = title;
      backdrop.querySelector('[type="submit"]').textContent = confirmLabel;
      const input = backdrop.querySelector("input");
      input.value = value;
      const finish = (result) => {
        dismissSheet(backdrop);
        this.grid.focus();
        resolve(result);
      };
      backdrop.querySelector("form").addEventListener("submit", (event) => {
        event.preventDefault();
        finish(input.value.trim() || null);
      });
      backdrop.querySelector("[data-cancel]").addEventListener("click", () => finish(null));
      backdrop.addEventListener("keydown", (event) => event.key === "Escape" && finish(null));
      this.root.append(backdrop);
      input.focus();
      const dot = value.lastIndexOf(".");
      input.setSelectionRange(0, dot > 0 ? dot : value.length);
    });
  }

  applyAppearance(value) {
    if (value) document.documentElement.dataset.theme = value;
    else delete document.documentElement.dataset.theme;
    writeSetting("appearance", value);
  }

  // MARK: - Keyboard

  bindKeyboard() {
    window.addEventListener("keydown", (event) => {
      const mod = isApple ? event.metaKey : event.ctrlKey;
      if (!mod || event.altKey && event.key !== "-") return;
      const key = event.key.toLowerCase();
      const inField = event.target instanceof HTMLInputElement || (event.target instanceof HTMLTextAreaElement && event.target !== this.grid.editor)
        || (event.target === this.grid.editor && this.grid.isEditing);
      const map = {
        n: event.shiftKey ? "newSheet" : "new", o: "open", s: event.shiftKey ? "saveAs" : "save", w: "close",
        z: event.shiftKey ? "redo" : "undo", y: "redo", b: "bold", i: "italic", u: "underline", t: "showFonts",
        "=": "zoomIn", "+": "zoomIn", "-": event.altKey ? "zoomOut" : "smaller", "0": "actualSize", a: "selectAll",
      };
      const command = map[key];
      if (!command) return;
      // Text fields keep their own undo, select all and text styling.
      if (inField && ["undo", "redo", "selectAll", "bold", "italic", "underline"].includes(command)) return;
      event.preventDefault();
      if (command === "smaller" && !event.shiftKey && key === "-") {
        this.run("zoomOut");
        return;
      }
      this.run(command);
    });
  }

  // MARK: - Documents

  async refreshRecents() {
    this.recents = await storage.recentDocuments();
    if (!this.document) this.renderStart();
  }

  showStart() {
    this.document = null;
    this.root.classList.add("is-empty");
    this.start.hidden = false;
    this.updateTitle();
    this.refreshRecents();
  }

  renderStart() {
    const recents = this.recents ?? [];
    const relative = new Intl.RelativeTimeFormat(language, { numeric: "auto" });
    const when = (time) => {
      const minutes = Math.round((time - Date.now()) / 60000);
      if (Math.abs(minutes) < 60) return relative.format(minutes, "minute");
      const hours = Math.round(minutes / 60);
      if (Math.abs(hours) < 24) return relative.format(hours, "hour");
      return new Intl.DateTimeFormat(language, { dateStyle: "medium" }).format(time);
    };
    this.start.innerHTML = `
      <div class="app__start-inner">
        <h1 class="ds-heading-04">Tables</h1>
        <p class="ds-body app__start-intro"></p>
        <div class="app__start-actions">
          <button class="ds-button ds-button--primary" data-start="new">${escapeHTML(t("Web.Start.NewWorkbook"))}</button>
          <button class="ds-button ds-button--bordered" data-start="open">${escapeHTML(t("Mac.Menu.Open"))}</button>
        </div>
        <h2 class="ds-heading-compact app__start-heading">${escapeHTML(t("Mac.Menu.OpenRecent"))}</h2>
        ${recents.length ? `<table class="ds-table app__recents"><tbody>
          ${recents.map((record) => `<tr data-id="${record.id}" tabindex="0">
            <td>${icon("table")} <span>${escapeHTML(record.draftAt && !record.handle ? record.draftName ?? record.name : record.name)}</span></td>
            <td class="app__recent-note">${record.draftAt ? escapeHTML(t("Web.Start.Unsaved")) : ""}</td>
            <td class="ds-numeric app__recent-date">${escapeHTML(when(Math.max(record.openedAt, record.draftAt ?? 0)))}</td>
            <td class="app__recent-remove"><button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" data-remove="${record.id}" aria-label="${escapeHTML(t("Web.Start.Remove"))}" title="${escapeHTML(t("Web.Start.Remove"))}">${icon("close")}</button></td>
          </tr>`).join("")}</tbody></table>`
        : `<p class="ds-caption">${escapeHTML(t("Web.Start.NoRecent"))}</p>`}
      </div>`;
    this.start.querySelector(".app__start-intro").textContent = t("Web.Start.Intro");
    this.start.querySelector('[data-start="new"]').addEventListener("click", () => this.newDocument());
    this.start.querySelector('[data-start="open"]').addEventListener("click", () => this.openPicked());
    for (const row of this.start.querySelectorAll("tr[data-id]")) {
      const record = recents.find((r) => r.id === row.dataset.id);
      row.addEventListener("click", (event) => {
        if (event.target.closest("[data-remove]")) return;
        this.openRecord(record);
      });
      row.addEventListener("keydown", (event) => event.key === "Enter" && this.openRecord(record));
    }
    for (const button of this.start.querySelectorAll("[data-remove]")) {
      button.addEventListener("click", async () => {
        await storage.removeRecord(button.dataset.remove);
        this.refreshRecents();
      });
    }
  }

  showDocument(record) {
    this.document = record;
    this.keptVersion = this.engine.state?.versions.content;
    this.root.classList.remove("is-empty");
    this.start.hidden = true;
    this.banners.replaceChildren();
    this.updateTitle();
    this.grid.focus();
    storage.saveRecord({ ...record, openedAt: Date.now() });
    storage.persist();
  }

  async flushAutosave() {
    if (this.autosaveTimer) {
      clearTimeout(this.autosaveTimer);
      this.autosaveTimer = null;
      await this.autosave();
    }
  }

  async newDocument() {
    await this.flushAutosave();
    const name = t("Web.Document.Untitled");
    await this.engine.call("new", { name });
    this.showDocument({ id: crypto.randomUUID(), name, openedAt: Date.now() });
  }

  async openPicked() {
    try {
      const file = await files.pickFile();
      if (file) await this.openFile(file);
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  /** @param {{ name: string, bytes: Uint8Array, handle?: FileSystemFileHandle }} file */
  async openFile(file, { id = null, draftOf = null } = {}) {
    await this.flushAutosave();
    try {
      await this.engine.call("open", { name: file.name }, file.bytes);
    } catch (error) {
      this.showMessage(t("Web.Error.Open", file.name, error.message), "error");
      return;
    }
    const recents = await storage.recentDocuments();
    const existing = file.handle
      ? await (async () => {
        for (const record of recents) if (record.handle && (await record.handle.isSameEntry?.(file.handle))) return record;
        return null;
      })()
      : null;
    const record = draftOf ?? existing ?? { id: id ?? crypto.randomUUID() };
    this.showDocument({ ...record, name: file.name, handle: file.handle ?? record.handle, openedAt: Date.now() });
    this.showUnsupported();
  }

  async openRecord(record) {
    if (record.draftAt) {
      const bytes = await storage.readDraft(record.id);
      if (bytes) {
        await this.openFile({ name: record.draftName ?? record.name, bytes, handle: record.handle }, { draftOf: record });
        // The draft has unsaved changes: show it as edited.
        this.engine.state.dirty = true;
        this.updateTitle();
        return;
      }
    }
    if (!record.handle) {
      this.showMessage(t("Web.Error.Missing", record.name), "error");
      return;
    }
    try {
      const file = await files.readHandle(record.handle);
      if (file) await this.openFile(file, { draftOf: record });
    } catch (error) {
      this.showMessage(t("Web.Error.Open", record.name, error.message), "error");
    }
  }

  async closeDocument() {
    await this.grid.commitIfEditing();
    await this.flushAutosave();
    this.showStart();
  }

  /** Changes neither saved nor autosaved yet. */
  get hasUnkeptChanges() {
    const state = this.engine.state;
    return Boolean(this.document && state?.dirty && state.versions.content !== this.keptVersion);
  }

  scheduleAutosave() {
    if (!this.document) return;
    clearTimeout(this.autosaveTimer);
    this.autosaveTimer = setTimeout(() => {
      this.autosaveTimer = null;
      this.autosave();
    }, AUTOSAVE_DELAY);
  }

  /** Keeps a copy of the open document on this device, so closing the window loses nothing. */
  async autosave() {
    const record = this.document;
    if (!this.hasUnkeptChanges) return;
    const version = this.engine.state.versions.content;
    try {
      const { result, payload } = await this.engine.call("save", { keep: true });
      if (await storage.writeDraft(record.id, payload)) {
        record.draftAt = Date.now();
        record.draftName = result.fileName;
        this.keptVersion = version;
        await storage.saveRecord(record);
      }
    } catch {
      // A failed autosave leaves the last one in place; saving will report errors.
    }
  }

  async save() {
    const record = this.document;
    if (!record) return;
    await this.grid.commitIfEditing();
    const format = this.engine.info?.defaultSaveFormat ?? "xlsx";
    const sameKind = record.handle && record.handle.name.toLowerCase().endsWith(`.${format}`);
    if (!sameKind) return this.saveAs();
    try {
      const { payload } = await this.engine.call("save", { format });
      if (!(await files.writeHandle(record.handle, payload))) return;
      await this.saved(record);
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  async saveAs(format = this.engine.info?.defaultSaveFormat ?? "xlsx") {
    const record = this.document;
    if (!record) return;
    await this.grid.commitIfEditing();
    try {
      const { result, payload } = await this.engine.call("save", { format, keep: true });
      const saved = await files.saveFileAs(payload, result.fileName, format);
      if (!saved) return;
      await this.engine.call("rename", { name: saved.name });
      await this.engine.call("save", { format, keep: false }).catch(() => {});
      record.name = saved.name;
      if (saved.handle) record.handle = saved.handle;
      await this.saved(record);
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  /** Saves a copy in another format, leaving the open document as it is. */
  async exportAs(format) {
    if (!this.document) return;
    await this.grid.commitIfEditing();
    try {
      const { result, payload } = await this.engine.call("save", { format, keep: true });
      await files.saveFileAs(payload, result.fileName, format);
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  async saved(record) {
    clearTimeout(this.autosaveTimer);
    this.autosaveTimer = null;
    await storage.removeDraft(record.id);
    delete record.draftAt;
    delete record.draftName;
    await storage.saveRecord({ ...record, openedAt: Date.now() });
    if (this.engine.state) this.engine.state.dirty = false;
    this.keptVersion = this.engine.state?.versions.content;
    this.updateTitle();
    this.showMessage(t("Web.Document.SavedAs", record.name), "success");
  }

  async renameDocument() {
    const record = this.document;
    if (!record) return;
    const name = await this.askText(t("Web.Document.RenamePrompt"), record.name, t("Mac.Menu.Rename").replace("…", ""));
    if (!name || name === record.name) return;
    await this.engine.call("rename", { name });
    record.name = name;
    if (record.handle?.move) {
      try {
        await record.handle.move(name);
      } catch {
        // The file keeps its name on disk; the next save asks where.
        delete record.handle;
      }
    }
    await storage.saveRecord(record);
    this.updateTitle();
  }
}

/** "B3" or "B3:D9" as [row1, column1, row2, column2], or null. */
function parseReference(text) {
  const match = /^\s*\$?([A-Za-z]{1,3})\$?(\d+)(?:\s*:\s*\$?([A-Za-z]{1,3})\$?(\d+))?\s*$/.exec(text);
  if (!match) return null;
  const column = (letters) => [...letters.toUpperCase()].reduce((n, c) => n * 26 + c.charCodeAt(0) - 64, 0) - 1;
  const r1 = Number(match[2]) - 1, c1 = column(match[1]);
  const r2 = match[4] ? Number(match[4]) - 1 : r1, c2 = match[3] ? column(match[3]) : c1;
  if (r1 < 0 || r2 < 0) return null;
  return [Math.min(r1, r2), Math.min(c1, c2), Math.max(r1, r2), Math.max(c1, c2)];
}
