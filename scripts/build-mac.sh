#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo "The app needs macOS. On Linux, run: swift test --scratch-path .build-portable"
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Install Apple's tools with: xcode-select --install"
    exit 1
fi
major=$(swift --version | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)
if [[ -z "$major" || "$major" -lt 6 ]]; then
    echo "Swift 6 or newer is required. Select Xcode 16+ or current command-line tools."
    exit 1
fi
swift --version
configuration="${CONFIGURATION:-release}"
case "$configuration" in debug|release) ;; *) echo 'CONFIGURATION must be debug or release.' >&2; exit 1 ;; esac
build_args=(-c "$configuration")
if [[ "${SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then build_args+=(--disable-sandbox); fi
# One configuration and one build graph for the app, preview, CLI and tests.
# Keep .build in this checkout so subsequent updates reuse compiled modules.
swift build "${build_args[@]}" --build-tests
swift test "${build_args[@]}" --skip-build
CONFIGURATION="$configuration" CONTROLLAB_SKIP_BUILD=1 ./scripts/package-app.sh
echo "Ready: open build/ControlLab.app"
