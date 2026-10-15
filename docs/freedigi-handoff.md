# FreeDigi handoff — 2026-10-15

## Stop state

The user requested a handoff, push, and a complete stop. Do not resume development
without a new request. The monitoring timeout below is **unresolved**; no fix was
implemented after the user reported it. This handoff preserves the next work.

Application baseline: `9c839d97efa457749d92fac885c9f9b39eaa625b`
(`Synchronize controller state automatically and refine native UI`).
All application changes at that revision are pushed to public `main`:
https://github.com/ruxxzebre/freedigi

Linux CI for that revision **passed**:
https://github.com/ruxxzebre/freedigi/actions/runs/38669894990

## First issue to fix: monitoring startup timeout

Latest user report, verbatim:

> Controller response timed out during starting input monitoring (command 0x01).

The running Mac revision, connection details at the moment of failure, frequency,
and whether automatic retry eventually succeeds have not been confirmed for this
report. Earlier user testing used a Vader 5 Pro and USB receiver on macOS 27.0
(Build 26A428). Do not assume every historical symptom is still present.

### What the code establishes

- `Sources/ControlLabService/main.swift`, `monitor(_:)`, opens a fresh `HIDChannel`
  and calls `ControllerProfileClient(..., operation: "starting input monitoring").identity()`.
- That sends command `0x01` and waits for a matching identity response. The default
  response deadline is two seconds in `Sources/ControllerProtocol/ControllerProfiles.swift`.
  Identity parsing and the Vader model check must succeed before stream setup.
- The error is therefore before this helper sends its subsequent setup commands
  (`0xa1`, `0x02`, `0x04`, then stream-enable `0x11`). It is not a profile-write
  timeout, nor proof that the USB interface has disappeared.
- `native/src/backend.rs`, `Worker::start`, starts the helper and reads its JSON
  events. Spawn success is not handshake success. A helper error becomes a
  visible monitor error; a successful monitor event clears that monitor error.
- `Worker::run` detects helper exit and already schedules reconnect with bounded
  backoff (1, 2, 4, 8, then 15 seconds). The exit path also clears cached settings,
  resets all read freshness, and immediately schedules discovery.
- `Worker::automatic` runs due visible-page reads before restarting monitoring.
  It stops and joins the monitoring helper before a configuration operation.
  Monitoring also stops when the window loses focus, then resumes on focus.
- The three-attempt `ControllerSettingReadRetry` only wraps standalone lighting,
  Turbo, calibration and firmware reads. It does not wrap monitor startup.
  Profile reads retain their separate five-attempt policy.
- The monitor JSON error includes service diagnostic events, but the Rust monitor
  reader currently retains the error string and does not import that `events`
  array into the app's log. This is a concrete observability gap to address.

### Next investigation and acceptance checks

1. Capture the app's Copy report, build revision and startup sequence. Preserve
   bounded helper diagnostic events (including unmatched response headers and
   elapsed time) on monitor failure, without dumping raw controller profiles.
2. Reproduce with one app instance on the Mac and actual receiver. Compare cold
   startup, settings-read-to-monitor handoff, focus loss/resume, and reconnect.
   Check other controller software only as a possible competing reader, not an
   established cause. The current worker prevents overlap inside this process;
   it does not coordinate with other app instances/processes.
3. Trace channel open/close, receive callback/read readiness, command send,
   identity response and stream-stop timing. Relevant transport code is in
   `Sources/DesktopHID/HIDTransport.swift` and the existing Swift implementation.
   Compare the proven earlier behavior before changing initialization ordering.
4. Investigate whether clearing every setting cache on a failed monitor handshake
   causes repeated read/start cycles. That behavior is confirmed in code; whether
   it contributes to this hardware timeout is **a hypothesis**, not a diagnosis.
5. Distinguish an identity-handshake failure, a stopped input stream, and actual
   device removal in state and UI. Keep failure diagnostics, avoid presenting a
   recoverable startup attempt as a physical disconnect, and verify recovery.
6. If evidence warrants retrying identity startup, keep retries bounded and use
   clean sessions as needed. Do not merely raise timeouts or remove identity
   validation. Never wrap writes or verification-after-write in a generic retry.
7. Add a regression that exercises failed handshake -> retry -> success, plus
   persistent failure and cancellation. The existing simulated lifecycle check
   exercised successful handoffs only and cannot establish hardware readiness.
8. Validate on the physical Mac/controller: inputs arrive, settings pages remain
   usable, no endless cache invalidation/read loop, no competing HID owners, and
   reconnect/focus changes recover without manual Read buttons.

No root cause or hardware fix has been demonstrated yet.

## What is implemented and pushed

- Active app: **Rust + egui 0.33.3, Glow/OpenGL**, in `native/`. Linux and macOS
  targets; Windows has groundwork only. No active Wails/webview dependency.
- Original ControlLab Swift source and the previous Wails/React preview in
  `desktop/` are preserved. FreeDigi credits ControlLab/dracinn in UI and docs.
  Historical `docs/mac-handoff.md` describes the original Swift app, not the
  current FreeDigi build/run path.
- Existing Swift protocol code powers a bundled JSON helper, `freedigi-service`
  (Swift product `controllab-service`). Native transport is Linux hidraw / macOS
  IOKit. No background daemon is required.
- One Rust worker owns selected device, cached snapshots, dry-run state, helper
  lifetimes, discovery, read freshness and serialized configuration operations.
  Screens declare settings they need through `Backend::watch`.
- Automatic discovery selects an accessible interface while preserving a valid
  current selection. Discovery polls every second when absent, five seconds
  when selected. Monitoring starts automatically while focused.
- Visible settings refresh every 30 seconds; firmware versions every 10 minutes.
  Read failures back off. One global Refresh remains; individual Read and
  Start-monitor buttons were removed from the active native interface.
- Live physical inputs, visual single-button mapping editor, temporary/persistent
  profile applies, solid lighting/off, physical Turbo-button enable toggle,
  automatic-calibration setting toggle, installed firmware version reads.
- Dry run starts enabled. Backend supplies authoritative device path, mode and
  snapshots. Live profile writes create backups and use existing preflight/
  verification logic. Background sync never automatically repeats a write.
- Failed/uncertain operations invalidate relevant cached snapshots. Mapping
  drafts survive rereads but are isolated by controller identity and profile
  slot. Lighting drafts survive background refresh and reset across identities.
- Lighting identity errors now name lighting rather than falsely referring to
  reading the active profile or asserting that no profile-write commands ran.
  This wording correction is separate from the new monitor timeout report.
- Dark theme default, updated dark repository screenshots, full-row sidebar
  navigation, adjusted footer/spacing, embedded Nunito font with OFL license.
  `native/src/controller_view.rs` draws a shared vector controller with held
  buttons, sticks, triggers and back-button selection.
- Diagnostics Copy/Export includes bounded logs, settings errors, renderer/font/
  texture/cache information, excluding raw cached profile data.

## RAM investigation and limits

The user observed approximately **121 MB for `freedigi`** in macOS Activity
Monitor, without a persistent helper visible at that moment. No obvious leak was
established. Do not claim this number is fixed or reproduced on Linux.

Implemented findings:

- State snapshots share the bounded log buffer via `Arc`, instead of copying up
  to 200 retained entries every frame.
- Input packets request repaint only on focused live-input/mapping pages.
- Monitoring releases its helper while unfocused.
- Diagnostics exposes atlas dimensions, texture bytes/count and image-cache bytes.
- Logs remain bounded; image/font caches are retained rather than rebuilt.

Glow is enabled; optional wgpu packages in Cargo.lock do not mean wgpu runs.
Cocoa/OpenGL/Retina buffers are a plausible remaining cost, not a measured cause.
On Mac, compare `vmmap -summary PID` idle and after monitoring/navigation. The UI
counters exclude OS/window/driver allocations. Linux software-rendering samples
were affected by swapping; include SwapPss with PSS. Lower resident PSS alone was
not evidence of reduced total memory. See `docs/freedigi-validation.md`.

## Shared theme and dependency policy

- Vendor only explicitly selected native Chaiky components, palette and gull.
  Do not copy the whole `@chaiky/theme` package or unused component implementations.
- Selection: `native/Cargo.toml`; updater: `native/scripts/vendor-theme.py`;
  provenance: `native/vendor/chaiky-theme/PROVENANCE.json`.
- Current shared source revision: `2e57c4b1fe4be08272bbcdd42bd027f56a9d8ee4`.
  Shared theme changes were pushed upstream; local Core worktree used during this
  work was `/srv/stacks-ssd/mainframe/worktrees/chaiky-egui`, theme under
  `js/packages/theme`. FreeDigi builds without access to that private repository.
- App-specific controller logic and diagrams stay in FreeDigi.
- Root Rust toolchain is pinned to 1.97.0. Cargo.lock pins crates; flake.lock pins
  nixpkgs. Swift 6 remains external (Linux validation: 6.0.3; Mac: Xcode toolchain).

## Validation and build

At application revision `9c839d9`:

- 78 portable Swift tests and 8 Rust release tests passed.
- Rust Clippy with `-D warnings` passed.
- Real Swift helper dry-run checks and packaged `--self-test` passed on Linux.
- Local Linux release package and GitHub Linux CI passed.
- Actual Linux GUI inspected under Xvfb/software OpenGL, including minimum window
  size, full-row navigation, default dark theme and controller/mapping layouts.
- Separate temporary simulated helper exercised discovery, visible-page reads,
  cached reuse and monitor/read handoffs under an exclusive lock. No overlapping
  sessions or automatic writes were observed. This was not a physical HID test.
- Physical controller behavior under the latest automatic flow and macOS RAM
  reduction are not validated. The new user timeout supersedes any impression
  that successful Linux checks establish Mac hardware reliability.

Mac, from an existing current-history FreeDigi checkout:

```sh
git pull
./native/scripts/build.sh
open native/dist/FreeDigi.app
```

The package script tests and builds release, reuses caches, caps jobs at eight by
default (override `FREEDIGI_BUILD_JOBS`), and leaves a ready-to-open Mac bundle.
Rust release uses incremental compilation, 16 codegen units and no LTO. Linux
packaging removes Nix-only loader/runtime paths and checks the bundled helper.
Keep `.build` and `native/target` for incremental rebuilds. A Mac and Xcode are
required for the Mac package; the Linux CI result is not a Mac build result.

## Remaining product scope

Not implemented in the current native UI: firmware installation/flashing,
advanced macro/combo editors, press-to-map capture, Bluetooth configuration,
dock lighting and system-wide virtual gamepad output. Installed firmware reads
are available; do not describe them as firmware updates. Legacy Swift research/
features do not automatically imply native-UI support.

The user wants free dependencies, native gamepad output rather than keyboard/
mouse fallback, Linux/macOS targets, and minimal Windows groundwork. Earlier
virtual-gamepad work encountered Apple's restricted capability/provisioning
requirements. Ad-hoc or self-signed signing does not supply the missing approved
capability. Do not promise that this app makes the dongle a system-wide Xbox
controller. Steam seeing inputs is not proof of compatibility with every game.

Earlier conversation included Engine decompilation and firmware research, but
those artifacts were not re-audited during this batch. Consult repository research
and protocol docs before making claims about updater completeness or replaying
packets. Prioritize the reported monitoring failure when work resumes.

## Git and operational notes

- Workspace git root: `/srv/stacks-ssd/projects/decofly/macos`.
- Local branch: `agent/macos-native-port`; public remote: **freedigi**, public
  branch: **main**. `origin` points at the original upstream; do not push there.
- Git identity must remain **ruxxzebre <paullaboratory@gmail.com>**. An inherited
  `admin@admin.com` identity caused erroneous GitHub attribution to lordlezehaf.
  History was already rewritten with explicit user authorization; original
  upstream authors were preserved. Do not repeat that rewrite or push old backups.
- Earlier rewritten app commits: `aa4a9ac` (egui), `d38ea5b` (release/build speed).
  Old pre-rewrite commit IDs in legacy docs may no longer name public history.
- `v0.1.0-preview` belongs to the older Wails preview; no new native release tag
  was created in this batch. Use current main or its CI artifact.
- Final application working tree was clean. Temporary GUI, simulated helper and
  owned Xvfb processes were stopped. RAM-analysis/review agents completed; none
  is running. No additional fix or release operation is being left in progress.
