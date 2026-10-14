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
swift test
swift build -c release --product controllab-cli
./scripts/package-app.sh
echo "Ready: open build/ControlLab.app"
