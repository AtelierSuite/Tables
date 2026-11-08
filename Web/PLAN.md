# Plan: Tables for the web (WebAssembly + offline PWA)

## Goal

Ship Tables as an installable Progressive Web App that runs **entirely on the device**: after the first visit it opens, edits, calculates and saves Excel, Numbers and CSV files with no network connection and no server. The spreadsheet engine is the same Swift code the Apple apps use, compiled to WebAssembly, so formulas, file formats and macros behave identically on every platform.

## Starting point

| Part | Where | Size | Portable? |
| --- | --- | --- | --- |
| Engine: model, formulas, XLSX/Numbers/CSV I/O | `Apple/TablesEngine` | ~28k lines Swift in 82 files | Mostly. Five files use Apple-only frameworks (below) |
| Macros: VBA lexer, parser, interpreter, Excel object model | `Apple/TablesMacros` | Foundation + `Synchronization` | Yes, after checking `Mutex` on Wasm |
| Shared app logic: editor state and actions | `Apple/Shared/Session` | SwiftUI-coupled | Logic is reusable; needs separating from SwiftUI |
| UI | `Apple/Tables` (iOS), `Apple/TablesMac` (AppKit), `Apple/Shared/Views` | | No. Rebuilt for the web |
| Tests | `Apple/TablesTests` | Formula oracles, reader/writer and Excel-compatibility tests | Engine tests should run under WASI unchanged |

Apple-only imports in the engine and macros:

| File | Uses | Plan |
| --- | --- | --- |
| `TablesEngine/IO/ZipArchive.swift` | `Compression` (deflate) | Pure-Swift inflate/deflate behind `#if canImport(Compression)`; keep Apple's on Apple platforms |
| `TablesEngine/IO/CommentParts.swift` | `CryptoKit` | `swift-crypto` (`Crypto`), which has the same API and builds for Wasm |
| `TablesEngine/IO/NumbersPreview.swift` | SwiftUI, UIKit, AppKit, ImageIO, UTType | Apple-only; exclude from the Wasm target. The web reads the preview JPEG bytes and lets the browser decode them |
| `TablesEngine/Model/AdaptiveColor.swift`, `CellStyle.swift` | `SwiftUI` (`Color`) | Split the SwiftUI conversions into Apple-only extensions; the model keeps plain RGBA |
| `TablesMacros/MacroRunner.swift` | `Synchronization`, threads | Run macros synchronously inside the engine worker; cancellation via a shared flag the host checks |

## Architecture

```
┌────────────────────────── Browser tab / installed app window ─────────────────────────┐
│ Main thread (TypeScript)                                                             │
│   App shell · toolbar · inspector · sheet tabs · menus      ← Web/design components  │
│   Canvas grid renderer · chart renderer · cell editor                                │
│   File System Access / OPFS / downloads · undo stack UI                              │
│             ▲  structured messages + transferable ArrayBuffers                        │
│             ▼                                                                        │
│ Engine worker (Web Worker)                                                           │
│   tables-engine.wasm  (TablesEngine + TablesMacros, Swift → wasm32-unknown-wasip1)    │
│   WASI shim in JS · JavaScriptKit bridge                                             │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ Service worker: precaches the app shell, wasm, icons and string tables; serves       │
│ everything from Cache Storage. No runtime network requests.                          │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

Key decisions:

1. **Engine in Swift, compiled with the official Swift SDK for WebAssembly** (Swift 6.2+, `wasm32-unknown-wasip1`). This keeps one engine for all platforms, and the existing formula oracles and compatibility tests validate the web build. Rewriting the engine in TypeScript or Rust was rejected: it would fork ~28k lines of tested behaviour.
2. **Engine runs in a Web Worker.** Opening a large Numbers file or recalculating never blocks input. The UI asks for what is visible (`viewport(sheet, rows, cols)`) and gets back a compact binary buffer of display strings, styles and spans, so cells never cross the bridge one at a time.
3. **Narrow command API instead of exposing the object model.** About 40 commands (`open`, `save`, `setCell`, `fill`, `insertRows`, `applyStyle`, `undo`, `runMacro`, `find`, `chartData`, …) modelled on `Shared/Session/EditorActions.swift`. Requests and events are versioned so the worker and UI can be updated independently in the cache.
4. **UI in TypeScript without a framework.** Native custom elements styled by `Web/design`, bundled with Vite. The heavy surface (the grid) is a `<canvas>`, so a virtual-DOM framework would add weight without benefit. No runtime dependencies beyond JavaScriptKit's runtime.
5. **Grid drawn on `<canvas>`**, porting the logic in `Apple/TablesMacShared/CellRenderer.swift` and `Apple/TablesMac/Grid`: virtualised rows and columns, device-pixel-ratio aware, frozen panes, merged cells, borders, conditional formats, text overflow, checkboxes. A hidden `<textarea>` handles editing and IME input. An offscreen ARIA grid mirrors the visible range for screen readers.
6. **Files stay on the device.** File System Access API where available (open, save in place, "Save As"); `<input type="file">` and downloads elsewhere. Autosave and recent documents live in the Origin Private File System. The manifest registers file handlers for `.xlsx`, `.xlsm`, `.numbers` and `.csv`, so the installed app opens them from the OS.
7. **Strings come from the Apple catalogues.** A build step converts `Apple/**/*.xcstrings` into per-language JSON (en, ja, ko, zh-Hans, zh-Hant) so both apps say the same thing in the same languages.

## Phases

Each phase ends in something that runs and is tested.

### Phase 0: Groundwork (this change)

- [x] Move the iOS and macOS app into `Apple/`. The Xcode project builds from its new location.
- [x] Create `Web/`.
- [x] Design system: tokens, components, specimen page, written rules and a linter (`Web/design`).

### Phase 1: Portable engine package

- [ ] Add a Swift package at `Core/` (root level, shared by Apple and Web) with `TablesEngine` and `TablesMacros` targets. The Xcode project consumes the package instead of compiling the folders directly. (`Packages/` is ignored by `.gitignore`, hence `Core/`.)
- [ ] Remove the Apple-only imports listed above behind `#if canImport(...)`, moving SwiftUI colour conversions into Apple-only extensions.
- [ ] Replace `Compression` with a pure-Swift deflate on non-Apple platforms; add `swift-crypto`.
- [ ] Build the package for Linux as a cheap first portability check, then for `wasm32-unknown-wasip1`.
- [ ] Run the engine tests under WASI with `wasmtime` (`swift test --swift-sdk …`). Target: the same pass rate as on macOS, including `FormulaReferenceCases` and Excel compatibility tests.
- [ ] Measure the binary: `wasm-opt -Oz`, strip, brotli. Record the size in this file.

Risk to verify early: **Foundation on Wasm**. Date, number and locale formatting (`DateFormatter`, `NumberFormatter`, `Locale`, `Calendar`) pull in ICU data, which is large. Options, in order: (a) check which of the 7 engine and macro files that use them actually need ICU and whether `FoundationEssentials` alone is enough; (b) move locale-sensitive formatting behind a protocol the host implements with `Intl` in JavaScript; (c) ship a trimmed ICU data file for the five supported locales.

### Phase 2: Engine bridge and worker

- [ ] `Web/engine/`: a Swift executable target exporting the command API through JavaScriptKit (BridgeJS), compiled to `tables-engine.wasm`.
- [ ] `Web/src/engine/`: TypeScript client that starts the worker, sends typed commands, receives events (`cellsChanged`, `sheetsChanged`, `recalcFinished`, `macroOutput`) and decodes the viewport buffer.
- [ ] Round-trip tests in Node: open every fixture in `Apple/TablesTests`, save, reopen, compare.
- [ ] Startup budget: worker ready in under 1 s on a mid-range laptop with a warm cache (streaming compile via `WebAssembly.compileStreaming`, module cached by the service worker).

### Phase 3: Web app shell

- [ ] Vite + TypeScript project in `Web/`; `Web/design` CSS imported as-is.
- [ ] Start screen: New, Open, recent documents from OPFS.
- [ ] Workbook window: toolbar, formula bar, canvas grid, sheet tabs, status bar, inspector (Cell, Text, Sheet panes after `Apple/TablesMac/Panels`).
- [ ] Editing: selection, keyboard navigation, typing and formula entry with reference highlighting, fill handle, copy/paste (plain text, TSV and HTML in and out), undo/redo, insert and delete rows/columns, resize, freeze panes, find and replace.
- [ ] Menus: an in-window menu bar (File, Edit, Insert, Format, Data, View, Window, Help) drawn with `.ds-menu`, plus context menus.
- [ ] Keyboard shortcuts matching `Apple/TablesMac/App/MainMenu.swift`, with ⌘ on Apple platforms and Ctrl elsewhere.
- [ ] Localisation from the converted `.xcstrings`.

### Phase 4: Offline PWA

- [ ] Web app manifest: name, icons generated from `Apple/Assets/Tables.icon`, `display: standalone`, `file_handlers`, `launch_handler`, `share_target` for incoming files.
- [ ] Service worker, hand-written (no Workbox runtime): precache a versioned manifest of every build output at install, cache-first for all requests, delete old caches on activate. The app makes **no** network requests after install; a strict CSP (`default-src 'self'; connect-src 'self'`) makes that verifiable.
- [ ] Updates: a new version installs in the background and the app offers "Restart to Update" in a notification; open documents are autosaved first.
- [ ] Persistence: request `navigator.storage.persist()` once a document is saved locally so the browser does not evict autosaves.
- [ ] Offline test in CI: Playwright loads the app, goes offline, reloads, creates a workbook, enters formulas, saves to OPFS, reloads again and checks the workbook is intact.

### Phase 5: Feature parity

In the order users will notice them:

1. Number, date, currency and percentage formats; cell styles and borders.
2. Conditional formats and data bars (engine already reads them from XLSX and Numbers).
3. Charts: port `Shared/Views/ChartView.swift` (Swift Charts) to a canvas or SVG renderer fed by the engine's chart data.
4. Comments and notes.
5. Drawings and floating objects (canvas layer).
6. Function reference browser (`Shared/Resources/FunctionReference.json`).
7. Macros: VBA editor (system font, per the design rules), run, step, output; same interpreter as Apple.
8. Printing via a print stylesheet that renders the used range as an HTML table.

Not carried over: App Intents/Shortcuts (`Shared/Automation`), the Quick Look preview extension, iCloud documents, and App Store screenshot automation.

### Phase 6: Quality and release

- [ ] CI (GitHub Actions): design lint, TypeScript checks, Wasm build, engine tests under WASI, Playwright end-to-end tests in Chromium, WebKit and Firefox.
- [ ] Port the UI test scenarios in `Apple/TablesUITests` (cell editing, sheet tabs, charts, comments, budget workbook) to Playwright.
- [ ] Accessibility audit (keyboard-only, VoiceOver, NVDA) and contrast checks in both appearances.
- [ ] Performance budgets: first load (cold, over network) under 5 MB transferred; 100k-cell workbook scrolls at 60 fps; recalculation of the budget fixture under 50 ms.
- [ ] Static hosting (GitHub Pages or Cloudflare Pages) with immutable hashed assets. No cross-origin isolation headers needed unless Wasm threads are adopted later.

## Repository layout

```
Apple/            iOS and macOS app, Xcode project, tests, App Store assets
Core/             (Phase 1) Swift package: TablesEngine, TablesMacros, shared by Apple and Web
Web/
  design/         design system: tokens, components, specimen, rules, linter
  engine/         (Phase 2) Swift → Wasm entry point and command API
  src/            (Phase 3) TypeScript app: shell, grid, inspector, menus, file handling
  public/         (Phase 4) manifest, icons, service worker
  tests/          (Phase 6) Playwright tests
```

## Open questions

1. **Browser support floor.** File System Access (save in place) is Chromium-only. Safari and Firefox get open-via-picker and save-via-download, with OPFS autosave. Is that acceptable for launch?
2. **Hosting domain** for the PWA, which decides the install origin and must stay stable so users keep their local documents.
3. **Engine size vs. ICU.** If Foundation's ICU makes the module much larger than ~5 MB brotli, do we accept it, or move locale formatting to `Intl` (adds a bridge, keeps size down)?
