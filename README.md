# Tables

Spreadsheet app with formulas, charts, and macros that works with Excel, Numbers, and CSV files.

- [Engine/](Engine/): the spreadsheet engine and VBA macro interpreter, a Swift package shared by every version of the app.
- [Apple/](Apple/): the iOS and macOS app (`Apple/Tables.xcodeproj`).
- [Web/](Web/): the offline web app, with the engine compiled to WebAssembly.
