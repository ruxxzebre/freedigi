#!/usr/bin/env bash
set -euo pipefail
native_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
repo_dir="$(cd -- "$native_dir/.." && pwd)"
cd "$repo_dir"
export FREEDIGI_BUILD=1
# Bound concurrency for laptop RAM while using more than Cargo's former 2 jobs.
if [ "$(uname -s)" = Darwin ]; then cores="$(sysctl -n hw.ncpu)"; else cores="$(getconf _NPROCESSORS_ONLN)"; fi
if [ "$cores" -gt 8 ]; then cores=8; fi
jobs="${FREEDIGI_BUILD_JOBS:-${CARGO_BUILD_JOBS:-$cores}}"
case "$jobs" in ''|*[!0-9]*|0) printf 'Build jobs must be a positive integer.\n' >&2; exit 1 ;; esac
printf 'FreeDigi: incremental release build, up to %s compiler jobs\n' "$jobs"
export FREEDIGI_REVISION="$(git rev-parse --short HEAD)"
arch="$(uname -m)"
case "$arch" in x86_64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) exit 1 ;; esac
case "$(uname -s)" in
  Linux) platform=linux; swift_flags=(--build-system native -c release -Xswiftc -enable-testing --static-swift-stdlib) ;;
  Darwin) platform=macos; swift_flags=(--build-system native -c release -Xswiftc -enable-testing) ;;
  *) printf 'Native packages support Linux and macOS.\n' >&2; exit 1 ;;
esac
# Swift's official Linux toolchain must use system binutils, not Nix's linker.
# Cargo still uses the pinned Nix environment below.
swift_program="$(command -v swift)"
run_swift() {
  if [ "$platform" = linux ]; then
    env -u LD_LIBRARY_PATH -u LIBRARY_PATH -u NIX_LDFLAGS -u NIX_CFLAGS_COMPILE -u NIX_CFLAGS_LINK -u CC -u CXX -u SDKROOT \
      PATH="$(dirname "$swift_program"):/usr/bin:/bin" "$swift_program" "$@"
  else
    "$swift_program" "$@"
  fi
}
run_swift test --build-system native -c release -Xswiftc -enable-testing -j "$jobs"
run_swift build "${swift_flags[@]}" -j "$jobs" --product controllab-service
helper_dir="$(run_swift build "${swift_flags[@]}" --show-bin-path)"
python3 native/scripts/check-service.py "$helper_dir/controllab-service"
cargo test --locked --release --manifest-path native/Cargo.toml -j "$jobs"
cargo build --locked --release --manifest-path native/Cargo.toml -j "$jobs"
mkdir -p native/dist
stage="$(mktemp -d "$native_dir/dist/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
if [ "$platform" = macos ]; then
  app="$stage/FreeDigi.app"
  bin="$app/Contents/MacOS"
  resources="$app/Contents/Resources"
  mkdir -p "$bin" "$resources"
  python3 - "$app/Contents/Info.plist" <<'PYTHON'
import plistlib
import sys
with open("native/assets/Info.plist", "rb") as source:
    info = plistlib.load(source)
info.update(CFBundleExecutable="freedigi", CFBundleVersion="0.2.0", CFBundleShortVersionString="0.2.0", CFBundleIconFile="freedigi")
with open(sys.argv[1], "wb") as target:
    plistlib.dump(info, target)
PYTHON
else
  bin="$stage/FreeDigi"
  resources="$bin"
  mkdir -p "$bin"
fi
install -m 755 native/target/release/freedigi "$bin/freedigi"
install -m 755 "$helper_dir/controllab-service" "$bin/freedigi-service"
cp LICENSE NOTICE native/README.md "$resources/"
python3 native/scripts/collect-notices.py > "$resources/THIRD_PARTY_NOTICES.txt"
cp native/vendor/chaiky-theme/PROVENANCE.json "$resources/CHAIKY_PROVENANCE.json"
if [ "$platform" = linux ]; then
  # Nix dev builds carry store paths. Package against the host ABI and verify
  # below with the real executable, not a wrapper requiring Nix on users' PCs.
  if command -v patchelf >/dev/null && patchelf --print-interpreter "$bin/freedigi" | grep -q '^/nix/store/'; then
    case "$arch" in amd64) loader=/lib64/ld-linux-x86-64.so.2 ;; arm64) loader=/lib/ld-linux-aarch64.so.1 ;; esac
    patchelf --set-interpreter "$loader" --remove-rpath "$bin/freedigi"
  fi
  if env -u LD_LIBRARY_PATH /usr/bin/ldd "$bin/freedigi" | grep -E 'not found|/nix/store/'; then
    printf 'Package still has unavailable or Nix-only runtime links.
' >&2
    exit 1
  fi
fi
env -u LD_LIBRARY_PATH "$bin/freedigi" --self-test
if [ "$platform" = macos ]; then
  iconset="$stage/freedigi.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" native/assets/freedigi.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" native/assets/freedigi.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$resources/freedigi.icns"
  codesign --force --sign - "$bin/freedigi-service"
  codesign --force --deep --sign - "$app"
  codesign --verify --deep --strict "$app"
  # Keep a ready-to-open bundle; users do not need to extract the archive.
  ditto "$app" "$native_dir/dist/FreeDigi.app"
  ditto -c -k --sequesterRsrc --keepParent "$app" "native/dist/FreeDigi-macos-$arch.zip"
  printf '\nOpen it with: open native/dist/FreeDigi.app\n'
else
  strip --strip-unneeded "$bin/freedigi-service"
  cp native/assets/70-freedigi.rules native/assets/freedigi.png "$bin/"
  install -m 755 native/scripts/install-linux.sh "$bin/install.sh"
  tar -czf "native/dist/FreeDigi-linux-$arch.tar.gz" -C "$stage" FreeDigi
fi
printf '\nBuilt FreeDigi for %s/%s in native/dist\n' "$platform" "$arch"
