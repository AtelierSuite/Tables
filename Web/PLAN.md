# Plan: Tables for the web (WebAssembly + offline PWA)

## Goal

Ship Tables as an installable Progressive Web App that runs **entirely on the device**: after the first visit it opens, edits, calculates and saves Excel, Numbers and CSV files with no network connection and no server. The spreadsheet engine is the same Swift code the Apple apps use, compiled to WebAssembly, so formulas, file formats and macros behave identically on every platform.

Constraints: **no Node packages** (the build is Swift and a shell script; the page is plain HTML, CSS and JavaScript modules), and **the web build reads nothing from `Apple/`**.

## Where things stand

The base app works end to end, including offline: start screen, new and opened workbooks (XLSX, XLSM, Numbers, CSV, TSV), typing and formulas, selection with the keyboard and mouse, formatting, borders, merging, rows and columns, freezing, sheets, undo and redo, clipboard, fill handle, saving and exporting, autosave and Open Recent, light and dark, five languages, and an installable PWA whose service worker serves every file offline.

| Part | Where | Notes |
| --- | --- | --- |
| Engine and macros | `Engine/` (Swift package) | Shared by the Xcode project (compiled in place) and the web build. Builds for WebAssembly unchanged in behaviour; 706 of 707 Apple tests pass after the port, and the one failure is a flaky App Intents test unrelated to the engine |
| WebAssembly interface | `Web/engine/` | C exports with JSON requests, a WASI host, the worker, a strings tool, Node smoke tests |
| Window | `Web/app/` | Canvas grid, menus, toolbar, inspector, files, storage |
| Design system | `Web/design/` | Tokens, components, menus, lint |

### What porting the engine took

| Problem | Fix |
| --- | --- |
| `Compression` (ZIP deflate) | Plain-Swift raw DEFLATE (`Engine/TablesEngine/Portable/RawDeflate.swift`), tested against Apple's on iOS |
| `CryptoKit` (comment author IDs) | Plain-Swift SHA-256, tested against CryptoKit |
| SwiftUI `Color`, `ColorScheme`, `Font` in the model | Stand-ins where SwiftUI doesn't exist; Apple builds unchanged |
| `#bundle`, `String(localized:bundle:)`, `String.LocalizationValue` | A module bundle on Apple platforms; elsewhere a string table the host loads, converted from the same catalogues |
| `Bundle.main` traps under WASI | Never touched outside Apple platforms |
| `%lld` with 32-bit `Int` (wasm32) | Integer placeholders rewritten to the platform's word size when the table loads |
| `FileWrapper`, `XMLParser` (in `FoundationXML`), CoreFoundation code pages | Stand-in, conditional import, explicit code-page table |
| Threads and semaphores (calculation stack, macro runner) | Run inline; the Wasm stack is sized at link time; the Apple macro runner stays Apple-only |
| `Int` overflow in a compile-time constant | Clamped |

## Architecture

```
┌─────────────────────────── Browser tab / installed app window ───────────────────────────┐
│ Main thread (plain JavaScript modules)                                                  │
│   app/window.js   menu bar · toolbar · formula bar · sheet tabs · status bar · inspector │
│   app/grid.js     canvas grid · headers · frozen panes · selection · editor · fill       │
│   app/paint.js    text layout for the engine's drawing operations                       │
│   app/files.js · app/storage.js   File System Access / picker / download · autosave     │
│             ▲  JSON requests + transferable bytes                                        │
│             ▼                                                                           │
│ Engine worker (engine/worker.js)                                                        │
│   tables-engine.wasm: Engine/TablesEngine + Engine/TablesMacros + engine/swift/Sources  │
│   engine/wasi.js: clocks, randomness, console; no file system, no network               │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│ Service worker (sw.js): caches every file listed in build/version.js at install and     │
│ answers every request from that cache. A new build waits until the user restarts.       │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

Decisions as built:

1. **One engine, in Swift.** `Engine/` is a Swift package. Xcode compiles its folders in place; the web build depends on it with `.package(path: "../../Engine")` and the swift.org toolchain with its matching Swift SDK for WebAssembly.
2. **A plain C interface, no JavaScriptKit.** A reactor module exports `tables_alloc`, `tables_free`, `tables_call` and response accessors. Requests and responses are JSON; files cross as raw bytes. About 60 commands, mirroring `EditorActions`.
3. **The editing session is Swift.** `WebSession.swift` ports `EditorState` and `EditorActions` (minus SwiftUI) and adds snapshot undo, so selection, merges, movement, paste and structure behave as on the Mac.
4. **Swift decides what to draw; the browser draws it.** `Renderer.swift` makes the Mac cell renderer's decisions and returns drawing operations for a rectangle of the sheet. The page rasterises 256-point tiles once, caches them, and only measures text itself.
5. **No framework, no bundler.** The page is ES modules served as they are. The design system's lint runs over all of it.
6. **Strings come from catalogues.** `Web/strings/Localizable.xcstrings` (the web's own, seeded from the Apple app's) plus the engine's catalogues are converted to per-language JSON at build time. The engine and the page share the same table.

## Next

### Engine quality

- [ ] Run the engine test suite under WASI. Most of `Apple/TablesTests` only needs `TablesEngine`/`TablesMacros`; give them a test target in `Engine/Package.swift` (with a stub for the app module they `@testable import`) and run it with the WASI host.
- [ ] Audit remaining 32-bit `Int` assumptions (row × column keys, serial dates, hashes) found by that suite.
- [ ] **Size.** The release module is 56 MB (about 20 MB gzipped), mostly ICU data that Foundation links. Options: `wasm-opt -Oz` (Binaryen, a native tool); move the engine to `FoundationEssentials` where possible and do locale formatting through `Intl`; or ship trimmed ICU data for the five languages.
- [ ] Deep recursion: the browser's own stack limits how deep a formula chain can recurse inside Wasm. Measure the deepest chain that works, and report a clean `#CIRC!`-style error past it rather than a trap.

### Feature parity

In the order users will notice them:

1. Find and replace; sorting and filtering.
2. Comments and notes (the engine reads and writes them; the grid already marks them).
3. Charts: port `ChartView` (Swift Charts) to a canvas or SVG renderer fed by the engine's chart data.
4. Conditional formats are drawn already; add their editor.
5. Function reference browser (the function catalogue should move into `Engine/` so the web needn't read `Apple/`).
6. Macros: VBA editor (system font, per the design rules) and a runner. `MsgBox` and `InputBox` need the engine to wait for an answer: run macros in their own worker and block on `Atomics.wait`, which needs cross-origin isolation (the service worker can add the headers).
7. Drawings and floating objects; printing.
8. Numbers documents saved as packages (folders), which need a directory picker.

### Release

- [ ] CI: design lint, engine build, smoke tests, browser tests in Chromium, WebKit and Firefox (no Node packages: run them with each browser's WebDriver).
- [ ] Accessibility: an ARIA grid that mirrors the visible cells for screen readers; keyboard-only and VoiceOver passes; contrast in both appearances.
- [ ] Hosting on a stable origin (users' autosaves and recents belong to it), with long-lived caching for `build/`.

## Open questions

1. **Browser support floor.** File System Access (save in place) is Chromium-only. Safari and Firefox open through a picker and save as downloads, with autosave on the device. Is that acceptable for launch?
2. **Hosting domain** for the PWA.
3. **Engine size.** Accept ~20 MB compressed for the first release, or do the `Intl` work first?
