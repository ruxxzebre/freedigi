#!/bin/bash
# Install a completed build into the current user's Applications folder.
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
apps_dir="$HOME/Applications"
app="$apps_dir/ControlLab.app"
[[ "$(uname -s)" == Darwin ]] || { echo 'Installation requires macOS.' >&2; exit 1; }
[[ -d "$repo_dir/build/ControlLab.app" ]] || { echo 'Run ./scripts/build-mac.sh first.' >&2; exit 1; }
if pgrep -x ControlLab >/dev/null; then
    echo 'Quit ControlLab after any device operation finishes, then rerun ./scripts/install-mac.sh. The completed build is preserved.' >&2
    exit 1
fi
mkdir -p "$apps_dir"
stage=$(mktemp -d "$apps_dir/.controllab-install.XXXXXX")
cleanup() {
    if [[ -d "$stage/previous.app" && ! -e "$app" ]]; then
        mv "$stage/previous.app" "$app" || { echo "Previous app preserved at $stage/previous.app" >&2; return; }
    fi
    rm -rf -- "$stage"
}
trap cleanup EXIT
ditto "$repo_dir/build/ControlLab.app" "$stage/ControlLab.app"
codesign --verify --deep --strict "$stage/ControlLab.app"
cp "$repo_dir/scripts/update.sh" "$stage/update.sh"
chmod +x "$stage/update.sh"
if pgrep -x ControlLab >/dev/null; then
    echo 'ControlLab is running. Quit it, then rerun ./scripts/install-mac.sh.' >&2
    exit 1
fi
if [[ -e "$app" || -L "$app" ]]; then mv "$app" "$stage/previous.app"; fi
mv "$stage/ControlLab.app" "$app"
mv "$stage/update.sh" "$apps_dir/update.sh"
printf 'Installed: %s\nUpdate next time: bash %q\n' "$app" "$apps_dir/update.sh"
open "$app"
