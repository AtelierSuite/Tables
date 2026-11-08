// swift-tools-version:6.0
//
// The Tables engine: the workbook model, formulas, file formats and the VBA
// macro interpreter. Shared by the Apple apps (whose Xcode project compiles
// these folders directly) and the web app (Web/engine, which depends on this
// package and builds it for WebAssembly).

import PackageDescription

let package = Package(
    name: "TablesEngine",
    products: [
        .library(name: "TablesEngine", targets: ["TablesEngine"]),
        .library(name: "TablesMacros", targets: ["TablesMacros"]),
    ],
    targets: [
        .target(
            name: "TablesEngine",
            path: "TablesEngine",
            // Compiled into the Apple frameworks by Xcode; the web app loads
            // the same strings as JSON instead.
            exclude: ["Localizable.xcstrings"]
        ),
        .target(
            name: "TablesMacros",
            dependencies: ["TablesEngine"],
            path: "TablesMacros",
            exclude: ["Localizable.xcstrings"]
        ),
    ]
)
