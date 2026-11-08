#!/bin/bash
# Builds and tests the web app on a Linux machine with no Swift, for CI
# (.github/workflows/web.yml). Installs the swift.org toolchain and its Swift
# SDK for WebAssembly unless they're already there (CI keeps them in its cache),
# builds the site into dist/ and runs the engine smoke tests.
#
# Needs x86_64 Ubuntu 24.04. TABLES_TOOLS_DIR says where to keep the toolchain.
set -euo pipefail

SWIFT_VERSION="6.4.2"
SWIFT_WASM_SDK_CHECKSUM="83baca83553f8c443cda7b84800912e6e709c3acd2e7ebf277794ca5836c0da5"

WEB="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${TABLES_TOOLS_DIR:-$HOME/.tables-build}"
NAME="swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04"
export SWIFT_TOOLCHAIN="$TOOLS/$NAME"
export SWIFT_SDK="swift-${SWIFT_VERSION}-RELEASE_wasm"
SWIFT="$SWIFT_TOOLCHAIN/usr/bin/swift"

if [[ ! -x "$SWIFT" ]]; then
    echo "Downloading Swift $SWIFT_VERSION…"
    mkdir -p "$TOOLS"
    curl -fsSL "https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/${NAME}.tar.gz" \
        | tar -xz -C "$TOOLS"
fi
if ! "$SWIFT" --version; then
    echo "Swift doesn't run here. Libraries it's missing:" >&2
    ldd "$SWIFT_TOOLCHAIN/usr/bin/swift-frontend" | grep "not found" >&2 || true
    exit 1
fi

if ! "$SWIFT" sdk list | grep -qx "$SWIFT_SDK"; then
    echo "Installing the Swift SDK for WebAssembly…"
    "$SWIFT" sdk install \
        "https://download.swift.org/swift-${SWIFT_VERSION}-release/wasm-sdk/swift-${SWIFT_VERSION}-RELEASE/${SWIFT_SDK}.artifactbundle.tar.gz" \
        --checksum "$SWIFT_WASM_SDK_CHECKSUM"
fi

"$WEB/build.sh"

echo "Testing the engine…"
node "$WEB/engine/tests/smoke.mjs"
