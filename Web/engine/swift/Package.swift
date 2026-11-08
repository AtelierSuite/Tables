// swift-tools-version:6.0
//
// The Tables engine for the web: the shared engine package (../../../Engine)
// built for WebAssembly behind a small C interface, plus the tool that turns
// string catalogues into the JSON the web app loads. Built by Web/build.sh.
//
// Requires the swift.org toolchain and its matching Swift SDK for WebAssembly
// (see Web/README.md).

import PackageDescription

let package = Package(
    name: "TablesWeb",
    // The strings tool runs on the Mac doing the build.
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TablesWasm", targets: ["TablesWasm"]),
        .executable(name: "strings-tool", targets: ["StringsTool"]),
    ],
    dependencies: [
        .package(path: "../../../Engine"),
    ],
    targets: [
        .executableTarget(
            name: "TablesWasm",
            dependencies: [
                .product(name: "TablesEngine", package: "Engine"),
                .product(name: "TablesMacros", package: "Engine"),
            ],
            linkerSettings: [
                // A reactor: no main entry point, just the exported functions.
                .unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"]),
                // Formula evaluation recurses once per cell in a chain of
                // references; the Apple apps give it a 256 MB thread for that.
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=33554432"]),
            ]
        ),
        .executableTarget(name: "StringsTool"),
    ]
)
