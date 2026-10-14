#!/bin/bash
set -euo pipefail
revision=$(git -C "$SRCROOT" rev-parse --short HEAD 2>/dev/null || echo development)
if [[ -n "$(git -C "$SRCROOT" status --porcelain 2>/dev/null)" ]]; then revision="$revision-modified"; fi
info="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c 'Delete :ControlLabSourceRevision' "$info" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :ControlLabSourceRevision string $revision" "$info"
