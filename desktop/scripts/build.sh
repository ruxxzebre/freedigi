#!/usr/bin/env bash
set -euo pipefail
desktop_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
repo_dir="$(cd -- "$desktop_dir/.." && pwd)"
export FREEDIGI_BUILD=1
revision="$(git -C "$repo_dir" rev-parse --short HEAD)"
platform="$(uname -s)"
arch="$(uname -m)"
case "$arch" in x86_64) arch=amd64;; arm64|aarch64) arch=arm64;; *) printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 1;; esac
case "$platform" in
 Linux) swift_flags=(-c release --static-swift-stdlib); wails_flags=(-tags webkit2_41); target=linux;;
 Darwin) swift_flags=(-c release); wails_flags=(-platform "darwin/$arch"); target=macos;;
 *) printf 'FreeDigi currently builds on Linux and macOS.\n' >&2; exit 1;;
esac
command -v swift >/dev/null
command -v go >/dev/null
command -v npm >/dev/null
wails_bin="${WAILS_BIN:-$(go env GOPATH)/bin/wails}"
if [ ! -x "$wails_bin" ]; then go install github.com/wailsapp/wails/v2/cmd/wails@v2.15.0; fi
cd "$repo_dir"
swift test
swift build "${swift_flags[@]}" --product controllab-service
helper_dir="$(swift build "${swift_flags[@]}" --show-bin-path)"
python3 "$desktop_dir/scripts/check-service.py" "$helper_dir/controllab-service"
cd "$desktop_dir"
go test -race ./internal/bridge
"$wails_bin" build "${wails_flags[@]}" -ldflags "-X main.build=$revision"
python3 scripts/collect-notices.py build/THIRD_PARTY_NOTICES.txt
mkdir -p dist
if [ "$target" = macos ]; then
 app="$desktop_dir/build/bin/FreeDigi.app"
 install -m 755 "$helper_dir/controllab-service" "$app/Contents/MacOS/freedigi-service"
 cp "$repo_dir/LICENSE" "$repo_dir/NOTICE" build/THIRD_PARTY_NOTICES.txt "$app/Contents/Resources/"
 codesign --force --sign - "$app/Contents/MacOS/freedigi-service"
 codesign --force --deep --sign - "$app"
 codesign --verify --deep --strict "$app"
 "$app/Contents/MacOS/freedigi" --self-test
 ditto -c -k --sequesterRsrc --keepParent "$app" "dist/FreeDigi-macos-$arch.zip"
 printf '\nBuilt %s\n' "$desktop_dir/dist/FreeDigi-macos-$arch.zip"
else
 stage="$(mktemp -d "$desktop_dir/dist/package.XXXXXX")"
 trap 'rm -rf "$stage"' EXIT
 mkdir "$stage/FreeDigi"
 install -m 755 build/bin/freedigi "$stage/FreeDigi/freedigi"
 install -m 755 "$helper_dir/controllab-service" "$stage/FreeDigi/freedigi-service"
 strip --strip-unneeded "$stage/FreeDigi/freedigi-service"
 python3 scripts/check-service.py "$stage/FreeDigi/freedigi-service"
 cp assets/freedigi.png assets/70-freedigi.rules "$repo_dir/LICENSE" "$repo_dir/NOTICE" README.md build/THIRD_PARTY_NOTICES.txt "$stage/FreeDigi/"
 install -m 755 scripts/install-linux.sh "$stage/FreeDigi/install.sh"
 "$stage/FreeDigi/freedigi" --self-test
 tar -czf "dist/FreeDigi-linux-$arch.tar.gz" -C "$stage" FreeDigi
 printf '\nBuilt %s\n' "$desktop_dir/dist/FreeDigi-linux-$arch.tar.gz"
fi
