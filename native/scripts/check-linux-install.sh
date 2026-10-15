#!/usr/bin/env bash
# Run inside a disposable distro container after package installation.
set -euo pipefail
repo="${1:?repository path required}"
test -x /usr/bin/freedigi
test -x /usr/lib/freedigi/freedigi-service
test -f /usr/lib/udev/rules.d/70-freedigi.rules
test -f /usr/share/licenses/freedigi/THIRD_PARTY_NOTICES.txt
desktop-file-validate /usr/share/applications/freedigi.desktop
freedigi --self-test
python3 "$repo/native/scripts/check-service.py" /usr/lib/freedigi/freedigi-service
# Exercise loading the graphics backend, not only the command-line helper.
export LIBGL_ALWAYS_SOFTWARE=1
export XDG_RUNTIME_DIR
XDG_RUNTIME_DIR="$(mktemp -d)"
trap 'rm -rf "$XDG_RUNTIME_DIR"' EXIT
set +e
xvfb-run -a timeout 5 freedigi
result=$?
set -e
if [ "$result" -ne 124 ]; then
  printf 'Expected app to remain running until timeout; exit status was %s\n' "$result" >&2
  exit 1
fi
