# FreeDigi preview validation

Validated on a Linux amd64 Ubuntu 24.04 host with Swift 6.0.3, Go 1.26.2, Node 25.9.0, Wails 2.15.0 and WebKitGTK 4.1 (2.52.6).

## Completed checks

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
