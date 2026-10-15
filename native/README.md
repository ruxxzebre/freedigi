# FreeDigi native

Rust + egui interface for Linux and macOS, using the existing ControlLab-derived
Swift controller service. The older Wails preview stays in `../desktop`.

## Run

With Rust and Swift 6 installed, from the repository root:

```sh
FREEDIGI_BUILD=1 swift build --product controllab-service
FREEDIGI_SERVICE="$(pwd)/.build/debug/controllab-service" cargo run --locked --manifest-path native/Cargo.toml
```

Or use `nix develop` for the pinned Rust compiler and Linux graphics libraries.
The flake uses the same nixpkgs revision as Chaiky/Core. `Cargo.lock` pins Rust
crates. Swift 6 is separate: Linux builds use Swift 6.0.3; macOS uses the laptop's
Xcode Swift compiler and SDK. The pinned nixpkgs Swift 5.10 is too old. This is
not a claim of a fully Nix-built Apple SDK or Swift service.

`native/scripts/build.sh` tests and packages the app with its helper. A normal
package finds `freedigi-service` beside its executable. Development can override
that using an absolute `FREEDIGI_SERVICE` path. `--self-test` verifies the real
helper can enumerate devices without a graphical display.

## Shared theme, selectively vendored

`vendor/chaiky-theme` contains only the opted-in native components and necessary
assets from Chaiky Core. It is not the full `@chaiky/theme` npm package. No CSS,
JavaScript, Tailwind, package registry login or private Git checkout is needed to
build FreeDigi from GitHub.

The `chaiky-egui` dependency's `features` in this directory's `Cargo.toml` is the
explicit selection. Defaults are disabled. Updating from a local Core checkout:

```sh
python3 native/scripts/vendor-theme.py /path/to/core
```

The script follows dependencies only for those selected components, copies their
source files and assets, removes stale vendored components, and generates a
minimal Cargo manifest. It records source revision, dirty-source status, component
selection and SHA-256 hashes in `PROVENANCE.json`. New upstream components are
never added automatically. Review that diff and commit it with `Cargo.lock`.
Make shared UI changes upstream, then re-vendor; keep app-specific logic here.

Chaiky palette and gull attribution: Chaiky project / Core shared theme.
ControlLab protocol attribution: © 2026 dracinn, MIT; see root LICENSE and NOTICE.

## Behavior and limits

Dry run starts enabled on every launch. Hardware reads remain live. Writes need
a previously read snapshot and run through the existing Swift retry/preflight/
readback implementation. Failed or ambiguous operations invalidate their snapshot;
the current page refreshes automatically before another apply is allowed. Live profile writes create a backup before applying.
One shared worker discovers controllers, starts monitoring, caches settings and
serializes all HID operations. Pages declare the settings they need: cached values
refresh every 30 seconds while visible (firmware versions every 10 minutes).
Failed reads back off; standalone lighting/Turbo/calibration/version reads also
retry transient timeouts up to three times. Profile reads retain their five-attempt
policy. Refresh forces discovery and fresh reads. Background refresh never
replays a write. Monitoring pauses while the window is unfocused and for configuration,
releases the interface and resumes afterward; it is not a disconnection indicator.
Logs retain 200 entries and Copy report/Export report omit raw profile bytes.

Includes live input display, individual button mappings, temporary/persistent
profile apply, solid lighting, physical Turbo-button toggle, automatic-calibration
toggle and installed firmware versions. Advanced mappings are preserved until
edited. Macro/combo editors, firmware installation, Bluetooth configuration and
virtual gamepad output are not included. Hardware I/O still needs validation on
an attached controller. Windows is explicit unsupported-transport groundwork.

## Build speed

The package script builds **release only**, including its tests. Release has
incremental compilation and 16 codegen units; whole-program LTO is disabled to
avoid a costly relink after small edits. Cargo and Swift reuse their build caches
in this checkout. Keep the same directory between updates. Do not delete
`native/target` or `.build` unless diagnosing a cache problem.

The script uses at most eight compiler jobs by default. Set
`FREEDIGI_BUILD_JOBS=4` to reduce peak memory on a smaller laptop, or increase it
explicitly on a larger machine. The first build downloads/compiles dependencies;
later builds reuse them. On Mac the ready-to-open result is
`native/dist/FreeDigi.app`, alongside the distributable zip.

## Interface and memory diagnostics

Dark Chaiky colors are the default. The controller diagram is shared by live
inputs and the mapping editor; selecting a physical button exposes its output
choices. Mapping drafts survive background reads and are cleared when controller
identity or profile slot changes. Nunito is embedded under the SIL Open Font
License (see `assets/fonts` and packaged third-party notices).

State snapshots share the bounded log buffer instead of copying it every frame.
Input packets trigger repaints only on visible input pages while focused.
Diagnostics includes font-atlas dimensions, texture allocations and image-loader
cache size in Copy/Export report. These counters exclude OS/window buffers and
graphics-driver allocations and do not equal Activity Monitor's process memory.
