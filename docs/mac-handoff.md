# Mac build and device validation

The user built and opened revision `de74fc8` on a Mac and reported that connection
and controller lighting work through the USB dongle. That does not establish
profile persistence, calibration, firmware flashing or system-wide game input.
The subsequent diagnostics/calibration changes have portable Linux tests and
syntax checks; their Apple SDK build and hardware checks are still required.

## Build on the laptop

Install Xcode 16+ or Swift 6+ command-line tools, then run from the ControlLab
repository root (the `macos` directory if copying the whole decompilation workspace):

```sh
xcode-select --install  # only if the tools are absent
./scripts/build-mac.sh
open build/ControlLab.app
```

To install the built app and its updater into `~/Applications`, quit ControlLab
after any device operation completes and run `./scripts/install-mac.sh`. This
adds the ControlLab icon in Finder, the Dock and the sidebar. Installation stages
and verifies the app before replacing the previous installed copy.

For subsequent updates, run:

```sh
bash ~/Applications/update.sh
```

The updater downloads the latest installer over SSH from `nesko@chaiky.dev`
(an optional first argument overrides the SSH destination), verifies the source
bundle checksum, fast-forwards its existing checkout, runs the Mac build/tests,
installs and opens the app. SSH access to that server is required.
The source location is remembered in `~/Library/Application Support/ControlLab/source-directory`.
On migration, it can adopt the clean checkout matching the installed app's source
revision, keeping its `.build` directory at the same absolute path. Otherwise it
starts at `~/Developer/ControlLab-Updates`. Local edits, changed branches and
divergent commits stop the update instead of being overwritten. A second installer
argument can select a new, unused source directory. App settings are preserved. Updates are manual;
the script never force-quits the app or performs controller firmware updates.
Logs are in `~/Library/Logs/ControlLab/update.log` and the new checkout's
`build/install.log`. Packaging also places a copy of `update.sh` in `build/`.

The icon's editable source is `Resources/ControlLab.svg`; the checked-in PNG and
multi-resolution ICNS are bundled before code signing, so Mac builds do not need
an image conversion tool.

The script builds the app, preview, CLI and tests in one release build, runs the
already-built tests with `--skip-build`, then packages both GUI executables
and SDL, and verifies the app's ad-hoc signature. It needs no Windows installer,
decompilation tools, Go, Node, or research directory. Default signing does not
include Apple's restricted virtual-device entitlement. A Developer ID alone
does not grant it; `ENABLE_VIRTUAL_HID=1` requires an approved provisioning profile.

The checked-in GitHub Actions workflow runs the same Mac build on a hosted runner.
It does not exercise USB hardware.

Updates retain Swift's `.build` cache and use one configuration, avoiding the
previous fresh checkout and separate debug-test/release-app builds. Optimized
Swift may still rebuild an entire changed module; toolchain/SDK changes can also
invalidate caches. No Mac speedup has been measured here. For local development,
`CONFIGURATION=debug ./scripts/build-mac.sh` is available; normal updates remain
optimized release builds. Tests and signature verification remain enabled.

## First device checks

1. Connect one Vader 5 Pro, wake it, select its PC mode and choose **Monitor only**.
   Confirm buttons, sticks, triggers and motion. The GUI's HID worker forwards
   every virtual report before publishing UI state at up to 60 Hz. No end-to-end
   latency number has been measured.
2. Stop monitoring. In **Configuration**, read the active profile and export a
   backup. Verify the device ID (130, 144 or 145), slot and title.
3. Change one spare-button mapping and use **Apply until restart**. Confirm the
   effect physically, then read again. A readback failure leaves persistence
   unattempted; it does not imply automatic rollback of RAM changes.
4. Restore the backup or save the desired mapping. Reconnect and read again to
   check persistence. The app automatically keeps before-write backups under
   `~/Library/Application Support/ControlLab/ProfileBackups`.

Equivalent CLI commands (close the GUI first):

```sh
.build/release/controllab-cli --devices
.build/release/controllab-cli --profile-read before.json
.build/release/controllab-cli --profile-map 18 4       # M1 -> A, RAM only
.build/release/controllab-cli --profile-restore before.json
.build/release/controllab-cli --profile-map 18 4 --save
```

Profile edits currently expose simple button remaps, name and grip vibration.
The Configuration page gives M1–M4 individual mapping menus. Picking a destination
stages the assignment immediately; changed rows show the previous assignment.
Other mappings are in an expandable section. Apply/Save stay in a fixed bottom
bar; with Dry run enabled these become Preview actions. Discard edits restores
the last read snapshot locally, and rereading warns before discarding edits.
Calibration has its own card showing the last read device value separately from
the pending toggle. These SwiftUI changes require a Mac build and visual check;
Linux syntax checks do not validate rendering or Apple SDK type checking.
Other settings and unknown bytes are preserved. Stick/trigger curves, gyro,
turbo and macro editing in the advanced panel remain drafts. Backups are JSON
snapshots of raw wire bytes, not the vendor's protobuf `.dat` export format.

### Press to map and profile read retries

After reading a profile, start input monitoring if needed, then select **Start
press to map**. Press one source button, release everything, press its target,
and release again. Repeat for the next mapping. This only stages changes; Apply
or Save remains explicit, including in dry-run mode. Pressed rows light up and
the selected source is outlined. Stop capture or Escape exits the gesture.
Settings access, disconnection, leaving Configuration, manual menu edits and
Discard edits also stop capture.

Capture uses enhanced USB receiver button reports, including separate M1–M4
bits. Button transitions bypass the 60 Hz visual coalescer and arrive in order.
D-pad diagonals and simultaneous button presses are rejected as ambiguous;
Home/Fn/LM/RM cannot be mapped by this editor. Triggers engage at 160/255 and
release below 80/255 to prevent noise. If a rear button reports only its assigned
button or multiple buttons, explicitly choose M1–M4 in the fallback disclosure
before pressing the target. Bluetooth capture is disabled because its reports
may expose assigned outputs rather than physical buttons. Actual rear-button
report behavior still requires verification on the user's firmware/dongle.

Explicit profile reads make at most **five total attempts** for timeouts and
HID open/I/O failures, reopening the session with a 200 ms delay between attempts.
The UI stays in its reading state until success or terminal failure. Diagnostics
records every attempt. Unsupported data, identity/profile conflicts and validation
failures stop immediately. This read helper never replays a write.

Temporary Apply and Save use a separate recovery path, also limited to **five
total attempts**. Each attempt opens a fresh session and reads the profile before
writing. The identity, slot, format and version must agree with this operation;
each byte must still be an original or requested value. Unexpected changes abort.
Only differences still missing from the controller are resent. An exact temporary
readback completes the operation without duplicate writes. If a Save ACK was
received but final readback failed, matching readback completes it without another
save. If the Save ACK was lost, RAM readback alone does not prove persistence:
recovery issues a new save/version and requires an ACK and exact readback. This
can repeat a flash save, at most five times; firmware flashing is not retried.
One original backup covers the operation. Intermediate failures stay in Diagnostics
while the UI remains busy. Device validation is still required; simulator tests
cover partial writes, dropped ACKs, stale data, retry limits and version tracking.

## Firmware

The Firmware page prepares packages from the connected variant's official
catalog. A null release means the service offered no package for that query;
it does not prove the device is up to date. Controller chips require a wired
connection; a receiver update requires connection through the receiver.

The install action performs real writes. The native transports and bootloader
transition have not been hardware-validated. Test enumeration and metadata first.
The prepared package is held unchanged in memory, with a SHA-256 shown for
diagnostics. This hash is not a vendor signature or proof of authenticity.

| Chip | Implemented transfer | Remaining physical checks |
| --- | --- | --- |
| RF / receiver | Telink report 5, CRC16 blocks, completion response | Correct interface, ACK shape, reset and version |
| SI | Jieli A1/A2 HID `.bin`, CRC16, fragment ACKs, verify/status | Boot PID 2F09, USB location continuity, version |
| Main | Megahunt K6UP PID 2F05, vector/capacity checks, status watermarks | Actual Vader bootloader family, commit and reset |
| Main legacy | 0483:5720 feature reports, full byte and metadata readback | Boot transition, feature-report framing, USB location |

Unrecognized transitions (including a 2503-only device) stop without an image
write. The installer does not guess a second boot-mode command. Jieli `.ufw`
packages still require the vendor Windows updater. These are real remaining
compatibility gaps, not problems solved by compiling on macOS.

No update retries an ambiguous write automatically. A timeout after commit or
reset can mean the update succeeded but could not be verified. Keep the error,
reconnect normally and read the installed version before deciding what to do.
No automatic rollback or firmware recovery guarantee is provided. The app blocks
ordinary Quit and requests that macOS stay awake during an active update.

## Validation performed on Linux

`swift test --scratch-path .build-portable` builds the independent
`ControllerProtocol` target. Tests cover a factory profile serialized by the
actual shipped SDK, packet reordering/duplicates, stale snapshots, missing ACKs,
readback corruption, chip transfer failures, fragment boundaries, CRC vectors,
Megahunt watermarks and legacy full-image verification. The fixture's provenance
and hashes are in `Tests/ControllerProtocolTests/Fixtures`.

`scripts/check-portable.sh` also syntax-parses every Swift file. Syntax parsing
does not validate SwiftUI APIs, IOKit linking, Apple SDK concurrency annotations,
code signing, entitlements, or hardware behavior. The Mac script resolves the
build portion of that remaining work.


## Diagnostics and dry runs

New app sessions start with **Dry run** enabled in the sidebar. A persistent
banner distinguishes preview mode. Profile apply/save/restore, automatic
calibration, controller lighting, dock lighting/behavior, and prepared firmware
installation have preview paths. Turn Dry run off to enable actual writes.
Read operations, firmware downloads, live input monitoring and its handshake
still communicate with devices/services. This is a write-preview mode, not an
offline emulator. Profile and calibration previews use the last-read snapshot;
controller lighting uses the current lighting configuration. Firmware preview
requires a prepared package and does not enter a bootloader or prove hardware
compatibility. The separate protocol simulator remains explicitly simulated.

**Diagnostics** shows bounded session history (2,000 entries, latest 200 displayed)
with modes, outcomes, operation IDs and durations, plus interface enumeration and
JSON export. Packet tracing is opt-in, bounded to 64 bytes per event, and excludes
live gamepad input reports. Profile names, mappings and identifiers may appear
in traces; review the export before sharing. Logs live in memory until exported
and are lost when the app quits. Firmware UI progress is coalesced by stage and
whole percent so block-level transfers do not flood the main actor.

Automatic stick calibration reads NewXInput command 0x03 support/enabled bit 5,
and writes command 0x13/subcommand 6 only when supported. Live writes recheck
identity and the previous setting, then verify readback. Reconnect and read again
to validate persistence. Source: Engine 5.0.1.6 recovered SDK factories
`ReadHardwareFunctionStatusCommandFactory` and
`EnableJoystickAutoCalibrationCommandFactory`.

Manual ADC calibration is not exposed: the recovered SDK has a factory 0xF0
start/stop command, while the current web UI uses a newer protocol and additional
readiness indicators. The correct Vader 5 workflow and completion verification
still need validation. Advanced curves, gyro and macro editing remain drafts.

The requested Wails/React rewrite is deferred until backend feature work and
validation are complete. No replacement frontend agent has been started. Keep
native HID timing/firmware work behind a stable backend interface when that phase
begins; do not move report forwarding onto the web UI thread.

For the next Mac check: click the empty/right side of each sidebar row; read a
profile; stage a mapping/restore and preview both temporary and saved writes;
read/preview automatic calibration if advertised; preview lighting with Dry run
on and confirm the LEDs do not change; inspect/export the session log. Physical
writes remain separately unverified beyond the previously reported lighting.

## Temporary mapping timeout follow-up

On October 15 the user reported that Read active profile succeeds, Apply until
restart times out, and a subsequent read shows the requested new mapping. This
establishes that the mapping reached the controller; the old generic error does
not identify whether its ACK or a later readback was lost. Other bytes and flash
persistence were not established by that observation.

The factory SDK fixture also exposed an unnecessary-write bug: Apply passed an
unchanged profile name through the title encoder, replacing vendor 0xffff padding
with zero bytes. The encoder now preserves the original bytes when the displayed
name has not changed, so a single-button remap does not also write title segments.
This is a confirmed packet-plan defect; it does not establish the exact cause of
the controller's timeout without a hardware trace.

Temporary Apply now performs one complete read-only recovery check after a
timeout following a profile write. It reports success only if identity, slot and
all requested bytes match. Partial changes, a different device/slot and failed
recovery reads remain errors. No write is replayed, and Save operations do not use
this recovery to guess flash persistence. Errors and Diagnostics now name the
phase and command (identity 0x01, slot 0xA1, read 0xA3, start 0xA4, data 0xA5,
save 0xA6), whether profile writes were attempted, and incomplete read counts.

The sidebar shows Settings access during profile/calibration operations, with
an amber indicator. Previously active monitoring resumes after profile/calibration
reads (including failed reads) and verified writes. Unverified writes leave
monitoring paused for recovery; use Read again or Resume monitoring. A user who
was not monitoring stays stopped. Firmware operations retain their explicit
resume behavior. A failed fresh profile read clears the previous
editable snapshot. These changes still require a Mac build and hardware check;
portable tests cover lost ACKs/readbacks and reject unsafe recovery outcomes.
