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

The native interface is in `native/`, using egui 0.33.3 with Glow. Wgpu is not
enabled. Linux launch against the real Swift helper passed under Xvfb with Mesa
software OpenGL; no controller was attached. Four native state tests cover
request authority, failed-write snapshot invalidation, dry-run preservation,
profile draft identity/slot ownership and bounded diagnostic reports. Shared
Chaiky light/dark component smoke testing also passed. Independent review found
and corrected the LED-off enum value and cross-profile draft carryover.

Initial debug idle measurement at 1100×820 was 110 MiB PSS / 135 MiB RSS including
the software graphics driver. Later idle samples fell to roughly 51 / 58 MiB
as pages were reclaimed; these are preliminary measurements, not a promised
budget or a macOS result. The previous Wails sample was 234 MiB aggregate PSS /
387 MiB summed RSS. Measurement environment and page residency affect comparison.

Linux packaging and GitHub CI are being checked for the new native path. Mac
compilation and actual controller interaction still require a Mac/controller.
The existing Wails and original ControlLab source are preserved.
