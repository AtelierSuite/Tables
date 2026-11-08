# Tables design system

The web version of Tables uses **IBM Carbon's visual language** (colour, type scale, spacing, motion, square geometry, flat layers) on **macOS components** (toolbars, segmented controls, pop-up buttons, steppers, disclosure triangles, sheets, popovers, source lists, inspectors). It should feel like a Mac app, drawn by Carbon.

| File | Purpose |
| --- | --- |
| `tokens.css` | Every colour, type, spacing, size, motion and elevation value as `--ds-*` custom properties, with light and dark appearance. |
| `components.css` | The component classes (`.ds-*`). Built only from tokens. |
| `base.js` | Global behaviour every page imports first: cancels drags that start on UI images (Firefox ignores the CSS for it). |
| `menus.js` | Menu behaviour: pull-down, context and submenus that always fit the window, the in-window menu bar, and toolbar and menu-bar overflow. An ES module with no dependencies. |
| `index.html` | A specimen page showing every component and a complete, resizable workbook window. Run `npm run design` in `Web/` and open the printed address (browsers don't load ES modules from `file://`). |
| `serve.mjs` | The tiny static server behind `npm run design`. |
| `lint.mjs` | Checks every CSS, HTML and script file in `Web/` against the rules below. Run `node Web/design/lint.mjs`. |

## Rules

These are hard rules. `lint.mjs` enforces each one, and CI must fail when it fails.

### 1. The OS system font, sans-serif, everywhere

- All text uses `var(--ds-font)`: `system-ui, -apple-system, BlinkMacSystemFont, sans-serif`. That resolves to SF Pro on Apple platforms, Segoe UI on Windows, Roboto on Android and ChromeOS, and the desktop's UI font on Linux.
- No web fonts are bundled or loaded. IBM Plex, Carbon's typeface, is not used.
- **No monospace anywhere**, including formulas, the formula bar, cell contents, keyboard shortcuts, the VBA macro editor and error codes. Don't use `<code>`, `<pre>`, `<kbd>`, `<samp>`, `<tt>` or `<var>`, because browsers render them monospace.
- When digits must line up (cells, status bar, steppers, sizes in tables), use `font-variant-numeric: tabular-nums` (`.ds-numeric`).
- Set type with the `--ds-type-*` tokens through the `font` shorthand, never ad-hoc sizes or families. Form controls inherit the font (`font: inherit`), so native `<select>` and `<input>` also use the system font.

### 2. Default cursor, except on hyperlinks

- Every element keeps the arrow cursor (`cursor: default`), including buttons, segmented controls, tabs, menu items, list rows, swatches and toolbar items. This is how macOS controls behave.
- `cursor: pointer` is allowed **only** on `a[href]`: an underlined text link that navigates somewhere.
- Other cursors are fine where they describe a real operation: `text` in editable text, `col-resize`/`row-resize` on header dividers, `crosshair` on the fill handle, `grab`/`grabbing` when dragging objects, `cell` over the grid if wanted.
- Hover backgrounds (Carbon's `*-hover` tokens) are the affordance for "this is clickable", not the cursor.

### 3. No chips

No pill- or tag-shaped elements that hold a label, value, filter, status or removable token. Use instead:

| Instead of | Use |
| --- | --- |
| Filter chips | A segmented control, a pop-up button, or checkboxes |
| Token field / tag input | A list with Add and Remove buttons, or a multi-line text field |
| Status chip / badge / tag | Text with an icon, or a count in secondary text (`.ds-source-list__count`) |
| "New" or "Beta" pills | Say it in the sentence, or leave it out |

Class names containing `chip`, `pill`, `badge`, `tag`, `token` or `lozenge` are rejected by the linter.

### 4. No eyebrow text

No small label stacked above a heading to categorise or introduce it ("Overview" above "Quarterly budget", "Step 2" above a title). A heading stands alone; if context is needed, put it in the heading or in a sentence below it. Section headings in source lists and menus (`.ds-source-list__heading`, `.ds-menu__header`) are headings of their group, not eyebrows, and use the same weight as other compact headings. Class names containing `eyebrow`, `overline` or `kicker` are rejected.

### 5. No all caps

- `text-transform` is always `none`. `font-variant-caps` small caps, all small caps, petite caps, titling caps and unicase are not used.
- Strings appear exactly as written in the string catalogues. Never type a string in capitals to get the effect.
- Content the user typed and the spreadsheet itself (column letters, function names such as `SUM`, error values such as `#REF!`) are data and are shown as they are.
- Casing follows the Apple app so strings can be shared: button labels and menu items use the title case they already have in the `.xcstrings` catalogues ("Add Note", "More Colours…"); headings, descriptions and messages use sentence case.

### 6. No monospace or wide-kerned text

`letter-spacing` is always `0` (Carbon's own 0.16px/0.32px tracking on small sizes is dropped). No `font-stretch` expansion. Combined with rule 1, there is no spaced-out, typewriter-style text anywhere.

### 7. No fingernail colour strips

No coloured bar along a single edge of a card, list row, tab, notification, callout, table row or sidebar item. This includes Carbon's own left-edge accents on inline notifications, selected side-nav items and tiles, and its underline indicator on tabs.

- Selection fills the whole row or segment (`--ds-layer-selected-01`, `--ds-highlight`, `--ds-background-inverse`).
- Status uses an icon, words and a tinted background over the whole surface (`.ds-notification--warning`).
- Sheet tab colours tint the whole tab (`--ds-tab-tint`), not a stripe under it.
- Single-edge borders are allowed only when they are 1px and a neutral border token (`--ds-border-subtle-*`, `--ds-border-strong-01`, `--ds-grid-line`): dividers between toolbar and content, and Carbon's field underline. Inset shadows offset to one side are rejected.

### 8. UI text is not selectable

- The whole UI is `user-select: none` from `<html>` down, as in a native app: labels, headings, buttons, menus, tooltips, notifications, alerts and the status bar can't be selected or long-pressed for a callout.
- Selectable text is limited to what the user edits or authored: text inputs, `<textarea>`, `[contenteditable]`, and document content rendered as HTML, marked `.ds-document-content` (comment bodies, a printed sheet). Grid cells are drawn on a canvas and copied through the app's own copy command, not text selection.
- Text that people need to copy, such as an error code, gets a Copy button instead of being selectable.

### 9. UI images are not draggable

- Icons, images, `<svg>`, `<picture>`, `<video>` and `<canvas>` never start a drag: `-webkit-user-drag: none` in CSS for WebKit and Chromium, `draggable="false"` on every `<img>`, and `base.js` cancelling `dragstart` on them for Firefox.
- Only things the user moves on purpose (sheet tabs, floating charts and drawings, the fill handle) are draggable, and they opt in with `draggable="true"` or pointer-event handling.

## Foundations

### Colour

Carbon **White** theme in light appearance and **Gray 100** in dark, with one change: Carbon's blue is replaced by **the Tables app's accent colour**, the green in `Apple/Shared/Resources/Assets.xcassets/AccentColor.colorset` (`#2EA666`).

- `--ds-accent` holds that value and is the only place it is written. `lint.mjs` fails if it drifts from the Apple colour set, so changing the app's accent changes both apps.
- Every interactive colour is mixed from it with `color-mix()`: focus outlines, selection borders, switches, sliders, progress, the grid selection, highlights and links.
- Text never sits on the raw accent, because white on `#2EA666` is only 3.1:1. Fills that carry text (the default button, highlighted menu items) use `--ds-accent-strong`, the accent mixed with 25% black, which gives 5.1:1. Light-appearance links use the same shade; in dark appearance the raw accent passes (5.8:1 on the background).
- Status colours keep their meaning and are not accent-tinted: info stays blue, success green, warning yellow and error red. Appearance follows the OS (`prefers-color-scheme`); the app can force it with `data-theme="light"` or `"dark"` on `<html>`. Components only ever reference role tokens, never raw hex.

| Role | Tokens |
| --- | --- |
| Surfaces | `--ds-background`, `--ds-layer-01`, `--ds-layer-02`, `--ds-field-01`, `--ds-field-02`, plus `-hover`, `-active`, `-selected` |
| Borders | `--ds-border-subtle-00`, `--ds-border-subtle-01`, `--ds-border-strong-01`, `--ds-border-interactive` |
| Text and icons | `--ds-text-primary`, `-secondary`, `-helper`, `-placeholder`, `-on-color`, `-inverse`, `-disabled`, `-error`; `--ds-icon-*` |
| Accent | `--ds-accent`, `--ds-accent-strong` |
| Interaction | `--ds-interactive`, `--ds-focus`, `--ds-focus-inset`, `--ds-highlight`, `--ds-link-primary` |
| Buttons | `--ds-button-primary`, `-secondary`, `-danger`, `-disabled` with `-hover` and `-active` |
| Status | `--ds-support-error`, `-success`, `-warning`, `-info`; `--ds-notification-*` backgrounds |
| Grid | `--ds-grid-line`, `--ds-grid-header`, `--ds-grid-header-selected`, `--ds-grid-selection-fill`, `--ds-grid-selection-border` |

Layering follows Carbon: a surface placed on `--ds-layer-01` uses the next layer up. Inside an inspector, sheet or other layer-01 area, add `.ds-on-layer` so fields switch to `--ds-field-02`.

Cell fills, fonts and chart colours that come from a document are **content**, drawn as stored; they do not go through these tokens. Default chart series colours use Carbon's categorical palette.

### Type

Carbon's productive scale, in the system font, weights 400 and 600 only. Sizes are fixed in pixels like a desktop app and respect browser zoom.

| Token | Size / line | Weight | Used for |
| --- | --- | --- | --- |
| `--ds-type-heading-04` | 28 / 36 | 400 | Start screen title |
| `--ds-type-heading-03` | 20 / 28 | 400 | Window and panel titles |
| `--ds-type-heading-02` | 16 / 22 | 600 | Sheet and alert titles |
| `--ds-type-heading-compact` | 13 / 18 | 600 | Inspector sections, group boxes, list headings |
| `--ds-type-body` | 14 / 20 | 400 | Prose, descriptions |
| `--ds-type-body-compact` | 13 / 18 | 400 | Controls, menus, cells, list rows (macOS's 13pt control size) |
| `--ds-type-label` / `--ds-type-caption` | 12 / 16 | 400 | Field labels, helper text, status bar, small controls |

### Spacing, size and shape

- Spacing uses Carbon's 2× scale: 2, 4, 8, 12, 16, 24, 32, 40, 48 (`--ds-spacing-01` … `-09`).
- Control heights: 24 (`xs`, toolbars and inspectors), 32 (`sm`, default), 40 (`md`, sheet buttons). Toolbar 48.
- Everything is square (`--ds-radius: 0`), and **every button is square**: push, borderless, icon, segmented, stepper, help and menu-bar buttons alike. Only checkboxes (2px), radio buttons, switches, the slider thumb and the spinner are rounded, because their shape is their meaning. `lint.mjs` rejects a rounded corner anywhere else.
- Elevation: one shadow, `--ds-shadow-float`, for menus, popovers, sheets and tooltips. Everything else is flat and separated by layer colour or a 1px subtle border.

### Motion

Carbon productive durations (70, 110, 150, 240 ms) and easing curves. Motion is functional only (sheets entering, disclosure triangles rotating, switches sliding) and drops to zero under `prefers-reduced-motion`.

### Focus

Keyboard focus is Carbon's 2px inset outline in `--ds-focus` on all four sides, shown with `:focus-visible` only. Filled buttons add a 1px inner ring in `--ds-focus-inset` so the outline reads on any fill.

### Icons

16px and 20px, single colour (`currentColor`), outline style to match Carbon icons. SF Symbols are not redistributable, so the app ships Carbon icons (Apache 2.0) inlined as an SVG sprite, so they work offline with no requests. Every icon-only button has an `aria-label` and a `title` (the tooltip).

## Components

Each component is taken from macOS and styled with Carbon tokens. Class names follow `ds-block__element--modifier`.

| Component | macOS origin | Class | Notes |
| --- | --- | --- | --- |
| Document window | NSWindow with unified toolbar | `.ds-window` | Grid areas: toolbar, sidebar, accessory (formula bar), content, inspector, status |
| Toolbar | NSToolbar | `.ds-toolbar` | Borderless icon buttons, separators, flexible space, title with subtitle ("Edited") |
| Push button | NSButton, push | `.ds-button` | Neutral by default; `--primary` is the default (Return) button, at most one per view; `--danger` for destructive defaults; `--bordered` for secondary actions in panels |
| Borderless button | NSButton, borderless/toolbar | `.ds-button--ghost`, `--icon` | Toggle state with `aria-pressed` |
| Help button | NSButton, help | `.ds-help-button` | Opens help for the surrounding panel. Square, unlike the round macOS original |
| Segmented control | NSSegmentedControl | `.ds-segmented` | Replaces tabs, filter chips and toggle groups. Selected segment uses the inverse fill. Select-one: `role="radiogroup"` + `aria-checked`, or `role="tablist"` + `aria-selected`. Select-any: `aria-pressed`. Add `--icons` when segments hold an icon or a single glyph, so every segment is square |
| Pop-up button | NSPopUpButton | `.ds-popup` | A native `<select>`, so the OS draws the menu and handles accessibility |
| Text field | NSTextField | `.ds-text-input` | Carbon field fill + 1px neutral underline; `aria-invalid` shows the error outline |
| Search field | NSSearchField | `.ds-search` | Magnifier, field, clear button |
| Stepper | NSStepper beside a field | `.ds-stepper` | Arrow keys and the arrows step the value |
| Checkbox, radio | NSButton, check/radio | `.ds-check`, `.ds-radio` | Supports indeterminate |
| Switch | NSSwitch | `.ds-switch` | `role="switch"`; for settings that take effect immediately |
| Slider | NSSlider | `.ds-slider` | Shows its value beside it |
| Colour well | NSColorWell | `.ds-color-well` | An `<input type="color">`, so it opens the system colour picker: the Colours panel on macOS (directly in Chrome and Firefox; Safari first shows its swatch popover with "Show Colors…"), the system dialog in Firefox on Windows and Linux, and the browser's own picker elsewhere. Opacity is a separate slider because the native picker has no alpha. The colour popover's "More Colours…" opens the same picker with `showPicker()` |
| Disclosure | NSDisclosureButton | `.ds-disclosure` | `<details>`/`<summary>`; inspector sections |
| Group box | NSBox | `.ds-group-box` | Titled group on layer-01 |
| Form rows | Inspector / Settings layout | `.ds-form` | Right-aligned labels, controls to the right |
| Source list | NSOutlineView, source list | `.ds-source-list` | Sidebar; selection fills the row |
| Inspector | Inspector panel (Numbers/Pages) | `.ds-inspector` | Segmented pane switcher on top, disclosure sections |
| Table view | NSTableView | `.ds-table` | Optional zebra rows; selected rows filled with `--ds-highlight` |
| Menu bar | The macOS menu bar, drawn in the window | `.ds-menu-bar` | `attachMenuBar()`. Titles that don't fit move into a trailing » menu as submenus |
| Toolbar overflow | NSToolbar overflow (») | `.ds-toolbar__overflow` | `attachToolbarOverflow()`. Items that don't fit move into a » menu, from the trailing end. Mark items that must stay with `data-overflow="never"` |
| Menu | NSMenu | `.ds-menu`, `.ds-menu--floating` | Checkmark column, title, shortcut, submenu arrow. The highlighted item is filled with `--ds-button-primary`. Opened by `openMenu()` or `attachContextMenu()` |
| Popover | NSPopover | `.ds-popover` | Anchored with an arrow; closes on Escape or a click outside |
| Sheet / alert | NSWindow sheet, NSAlert | `.ds-sheet`, `.ds-alert` | Window-modal, enters from under the toolbar. Standard push buttons sit in the bottom-right corner, inset by the sheet's padding, never stretched to its edges; the default action is rightmost |
| Tooltip | Help tag | `.ds-tooltip` | Inverse fill, shown after a delay like macOS |
| Notification | Banner | `.ds-notification` | Icon + whole-surface tint, no edge strip |
| Progress | NSProgressIndicator | `.ds-progress`, `.ds-spinner` | Bar for determinate, spinner for indeterminate |

Spreadsheet-specific components, built from the same tokens:

| Component | Class | Notes |
| --- | --- | --- |
| Formula bar | `.ds-formula-bar` | Name box (pop-up), function icon, formula field (system font, not monospace) |
| Grid | `.ds-grid` (specimen) | The app draws the grid on `<canvas>` with the same tokens: grid lines, header fills, selection fill and 2px selection border on all sides, square fill handle |
| Sheet tabs | `.ds-sheet-tabs` | Like macOS window tabs; tab colour tints the whole tab |
| Status bar | `.ds-status-bar` | Sum, average, count of the selection; save state |

## Behaviour

- **Menus** open on mouse-down. A click chooses an item; pressing a title, dragging to an item and releasing also chooses it, as on macOS. Arrow keys move the highlight, Left and Right open and close submenus and move between menu-bar titles, typing a letter jumps to an item, and Escape closes one level. Prefer native `<select>` for pop-up buttons.
- **Menus always fit the window.** A menu is never wider than the window minus 8px on each side, and long titles ellipsise. A pull-down menu that runs past the bottom flips above its title if there is more room there, otherwise it scrolls. A submenu opens to the right and flips to the left at the window edge. A context menu opens at the pointer and flips left or up to stay inside. Menus close when the window resizes or loses focus, or when the page scrolls under them.
- **Bars overflow, they don't wrap or clip.** The menu bar and the toolbar recompute as the window width changes (`ResizeObserver`). Whatever no longer fits moves, from the trailing end, into a » menu at the end of that bar, and comes back as space returns. In the toolbar, the document title shrinks with an ellipsis before anything moves, and segmented groups appear in the » menu as checkable items under their group name.
- **Keyboard shortcuts** use ⌘ on Apple platforms and Ctrl elsewhere, shown in the menu in the system font.
- **Context menus** replace the browser's on the grid, sheet tabs and objects; elsewhere the browser's menu stays.
- **Windows and sheets**: one workbook per browser window or installed-app window. Alerts that need a decision are sheets, not browser `confirm()`.
- **Accessibility**: WCAG 2.1 AA contrast in both appearances (Carbon's token pairs meet it), full keyboard operation, ARIA roles on every custom control, and a visible focus outline.
