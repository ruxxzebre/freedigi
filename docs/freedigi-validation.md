# FreeDigi validation

## Native 0.2.0 packages (2026-10-15)

The release packages passed builds and automated checks on Linux amd64/arm64 and macOS Intel/Apple silicon. Evidence: [Linux package checks](https://github.com/ruxxzebre/freedigi/actions/runs/38801704109) and [Mac package checks](https://github.com/ruxxzebre/freedigi/actions/runs/38801704250).

- Linux: 99 Swift tests and 14 Rust tests on each architecture. Both `.deb` packages passed installation, helper self-test/contracts, graphical startup under Xvfb, and removal in clean Debian 13 and Ubuntu 24.04 containers.
- Arch x86_64: `makepkg` produced the `.pkg.tar.zst`, which passed installation with dependencies, helper/contracts, graphical startup and removal in a clean Arch container.
- macOS: 98 desktop Swift tests and 14 Rust tests on each architecture. The legacy integration suite also passed (86 XCTest and 48 Swift Testing tests). Both app bundles passed ad-hoc signature verification and both disk images passed `hdiutil verify`.
- Packages include their helper, notices, icon and installation instructions; Linux installers include menu entries and udev rules. Linux artifacts require glibc 2.39 or newer. Mac apps are ad-hoc signed, not Apple-notarized.

The clean Debian startup test caught and verified the fix for a missing `libxkbcommon-x11` runtime dependency. ARM64 setup now verifies and installs the official signed ARM Swift archive. One x64 container download failed with a registry HTTP 502; the retry passed all checks.

These checks establish packaging and software behavior, not physical-controller compatibility. No physical Vader 4 has been tested, and no settings were written to hardware. The earlier platform limitations below describe previous validation stages.

## Historical preview checks

Validated on a Linux amd64 Ubuntu 24.04 host with Swift 6.0.3, Go 1.26.2, Node 25.9.0, Wails 2.15.0 and WebKitGTK 4.1 (2.52.6).

## Experimental Vader 4 changes (2026-10-15)

Completion checks on Linux amd64 / Ubuntu 24.04 with Swift 6.0.3 and Rust 1.97.0:

- `FREEDIGI_BUILD=1 swift test -j 4`: 99 tests passed. Coverage includes classic identity rejection, exact v3.0/v3.1 blob assembly, reordered/duplicate/conflicting/missing parcels, indexed ACK matching, stale snapshot rejection, temporary versus persistent sequencing, little-endian version save, complete profile and lighting readback, and no automatic write replay. Discovery uses synthetic Linux sysfs entries to check USB identities, report IDs and usage pages. Classic monitor startup, live C/Z/M1–M4 inputs and percent-RGB lighting preservation are also covered.
- `cargo test --locked --manifest-path native/Cargo.toml -j 4`: 14 tests passed, including retaining lighting drafts during rereads and discarding them when the active classic profile or controller changes.
- Rust Clippy with `-D warnings` and formatting checks passed.
- The real helper's `native/scripts/check-service.py` checks passed: previews for both classic profile layouts and lighting, foreign-model and unsupported Turbo/calibration rejection, and live requests rejected without a device path.
- All 62 Swift source/test files passed syntax parsing, including macOS-only code. This is not macOS type checking or linking; the macOS app and legacy `Vader5CoreTests` were not rerun on this Linux host.

The WIP packet-builder expression failed to compile with Swift 6.0.3 and was split into typed steps. A regression reproduced writes reaching a different supported controller or a changed slot after snapshot validation; the final pre-write check now compares the full identity and active slot before sending the header. Lighting timeout messages distinguish uncertain writes from read-only failures. These checks use synthetic reports and mock channels, not captured Vader 4 sessions. No physical settings were changed.

**No physical Vader 4 has been tested.** The shared classic protocol documentation predominantly concerns Apex 4; DInput slot reply variants, write headers, LED off behavior and save persistence need the [friend's hardware checklist](vader4-testing.md). Current support accepts only exact 790-byte v3.0/840-byte v3.1 profiles and 500-byte v2.0 lighting. It rejects unknown versions and never silently truncates blobs. A 40 ms bounded receive window checks trailing parcels; real device timing remains to be measured.

Reference protocol facts: [SDL Flydigi driver](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_flydigi.c), [classic protocol observations](https://github.com/uiltonlopes/flydigi-space-station-mac/blob/main/docs/protocol.md), and [Space Station SDK analysis](https://github.com/uiltonlopes/flydigi-space-station-mac/blob/main/docs/spacestation4-analysis.md). The implementation was written independently; hardware validation is not implied by these sources.

## Completed checks (earlier Wails preview)

- 75 Swift tests: the 70 existing portable protocol tests plus five tests for HID descriptor/report framing, independent input buttons and lighting plans.
- Eight Go service-boundary tests under the race detector: authoritative dry-run state, cached snapshot ownership, invalidation after ambiguous writes, serialization, device-switch isolation, missing-helper errors, monitor-failure state, platform policy and bounded diagnostics.
- Real Swift executable: profile, Turbo, calibration and lighting previews succeed without any device path; corresponding live requests fail without a device.
- TypeScript check and production React build.
- Two Playwright interaction tests: disconnected/browser-preview state; full sidebar hit areas; visible upstream credit; read-before-edit; multiple staged mappings; dry runs retain edits; verified live-result handling clears them. The mapping test uses a simulated service and is not a hardware test.
- Native Linux Wails launch with Xvfb and the locally extracted GTK/WebKit dependencies. Verified the real interface renders, discovery reaches the bundled Swift helper, and navigation opens the About credit. The normal release expects system-installed GTK/WebKit; the server's temporary library-path setup is not shipped.
- Packaged executable `--self-test`: starts the real helper and successfully enumerates devices. No device was attached.

## Memory observation

One idle native Linux sample, after opening the UI, used approximately **234 MiB total PSS** across the main process and its two WebKit processes. Summed RSS was **387 MiB**, which counts shared pages in more than one process. No monitoring helper was active. Xvfb/proot were excluded from these totals.

This host used software rendering at 1280×900; this is not a macOS measurement or a guarantee for other desktops. Active hardware-monitor memory and CPU have not been measured. An earlier conversational estimate of 100–250 MB was only an estimate; use the measured figures above when assessing this build.

## Still unverified

- The new Linux hidraw transport against a physical receiver/controller, including profile writes and reconnect behavior.
- The FreeDigi macOS build and its new IOKit wrapper. The self-hosted Mac workflow must run before claiming macOS verification.
- Live hardware performance, latencies and behavior in games.

No firmware flashing, Bluetooth configuration, dock lighting, press-to-map, advanced mapping editors or virtual gamepad output is exposed in this preview. Reusing protocol tests does not establish hardware compatibility. The existing ControlLab Swift app remains in the repository.

The Go service boundary also cross-compiles for Windows amd64. This is a compile-only check; no Windows app or HID implementation is provided.


## Native egui preview (2026-10-15)

The native interface is in `native/`, using egui 0.33.3 with Glow (macOS later
moved to wgpu/Metal; see the memory note in `freedigi-handoff.md`). Linux launch against the real Swift helper passed under Xvfb with Mesa
software OpenGL; no controller was attached. Eight native state tests cover
request authority, failed-write snapshot invalidation, dry-run preservation,
profile draft identity/slot ownership, visible-page freshness/backoff, accessible
device selection, scoped errors and shared log storage. Shared
Chaiky light/dark component smoke testing also passed. Independent review found
and corrected the LED-off enum value and cross-profile draft carryover.

Initial debug idle measurement at 1100×820 was 110 MiB PSS / 135 MiB RSS including
the software graphics driver. Later lower resident-memory samples were affected by swapping;
RSS/PSS alone must not be interpreted as an optimization. A subsequent sample
had about 40.5 MiB SwapPss in addition to resident PSS. These are preliminary
measurements, not a promised budget or a macOS result. The previous Wails sample was 234 MiB aggregate PSS /
387 MiB summed RSS. Measurement environment and page residency affect comparison.

Linux packaging and GitHub CI are being checked for the new native path. Mac
compilation and actual controller interaction still require a Mac/controller.
The Wails preview and the SwiftUI ControlLab app were later removed from `main` after revision `51609d3`; the ControlLab protocol, core and CLI remain.

### Automatic sync and memory follow-up

78 portable Swift tests pass, including new regression checks for bounded setting
read retries, non-retryable conflicts/uncertain writes, and lighting identity
timeout wording. The profile client retains its existing write-exposure reporting
for profile operations. Native tests pass in release mode.

Confirmed allocation/repaint waste was removed: UI snapshots share the bounded
log buffer, input events repaint only live-input pages while focused, and an
unfocused window releases its monitoring helper. Diagnostics now reports font
atlas dimensions, tracked texture bytes and image-loader cache bytes.

The user's 121 MB macOS process-memory observation has not been reproduced here.
Cocoa/OpenGL/Retina buffer costs remain a hypothesis; the changes above are not a
claim of a measured macOS memory reduction. On Linux, include SwapPss from
`/proc/PID/smaps_rollup` alongside PSS. On Mac, `vmmap -summary PID` can separate
heap and graphics/window allocations more usefully than a single process total.

The updated Linux package passes its bundled real-helper self-test and dry-run
service checks. Dark overview/mapping screenshots were captured from the actual
Linux app with the real helper and no controller attached. A separate simulated
service exercised automatic discovery, first-page reads, cache reuse when
navigating, and monitor/read handoff under an exclusive lock; it detected no
overlapping configuration/monitor sessions. This is a lifecycle check, not
physical-device evidence.
