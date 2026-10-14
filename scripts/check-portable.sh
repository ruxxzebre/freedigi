#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --scratch-path .build-portable
# Syntax checks cannot replace macOS type checking or linking.
while IFS= read -r source; do
    swiftc -frontend -parse "$source"
done < <(find Sources Tests -name '*.swift' -type f)
git diff --check
