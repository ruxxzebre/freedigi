# Vader 4 Pro Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add experimental Vader 4 Pro support through its DInput HID interface on macOS and Linux.

**Architecture:** Keep the existing Vader 5 protocol gated to its existing identities. Add an independent classic protocol client and route service operations by transport family, verifying the actual Vader 4 identity before using settings. Reuse the UI data contract and raw profile editing, with complete readback and conflict checks for writes.

**Tech Stack:** Swift protocol/service and IOKit/hidraw transports; Rust egui UI.

---

### Task 1: Implement and integrate classic DInput support

**Files:**
- Create `Sources/ControllerProtocol/ClassicController.swift` and protocol tests.
- Modify `Sources/ControllerProtocol/ControllerProfiles.swift` only as needed for classic profile decoding; preserve Vader 5 write gates.
- Modify `Sources/DesktopHID/HIDTransport.swift`, `MacHID.swift`, and `InputState.swift` for classic numbered reports and inputs.
- Modify `Sources/ControlLabService/main.swift` for classic routing and snapshots, splitting new helpers into a separate file if needed.
- Modify `native/src/pages.rs`, `native/assets/70-freedigi.rules`, README and validation documentation.

- [x] Test classic packet framing, identities 85/91/105, unrelated-device rejection, input decoding, blob assembly, ACK matching, conflict handling, readback and persistent saves.
- [x] Discover `04b4:2412` on usage page `FFA0`; retain classic report ID 4 on input and use report ID 5 on output. Keep new-protocol report framing unchanged.
- [x] Implement device-info `05 EC`, input `04 FE`, profile read/write `EB/EA/22`, LED read/write `E5/E7/33`, active-slot `EB A0`, and checked persistence `50 02/03`. Bound all receive loops. Reject unsupported layouts rather than truncating them.
- [x] Reuse the service's mapping/lighting data contract, dry-run behavior and backups. Check identity, slot and original bytes before writing; require matching ACK indexes and full readback. Never replay uncertain classic writes automatically.
- [x] Return unsupported capability values for unimplemented Turbo/calibration switches; reject writes to them. Explain DInput connection requirements and hardware validation limits.
- [x] Run Linux `FREEDIGI_BUILD=1 swift test` (99 tests), native Cargo tests (14 tests), Clippy, formatting and helper contract checks. All passed; no physical-device settings were changed. All 62 Swift files also passed syntax parsing.
- [x] Run macOS desktop and legacy Swift tests on a Mac. Hosted Intel and Apple silicon runners both passed during native 0.2.0 packaging; see `docs/freedigi-validation.md`.

### Task 2: Review

- [ ] Independent spec review of the complete integration against Task 1, including cross-model write isolation.
- [ ] Independent code-quality review after spec issues are resolved.
- [x] Record test results and hardware limitations in the validation documentation.

Protocol references: SDL's `SDL_hidapi_flydigi.c` for classic discovery, identities and input offsets; `uiltonlopes/flydigi-space-station-mac/docs/protocol.md` for classic DInput framing. The latter's hardware observations are from Apex 4, so Vader 4 support remains explicitly experimental until tested on that model.

Completion review (2026-10-15): single-agent protocol and integration review completed, including cross-model write gates. Fixed the Swift 6.0 packet-builder compilation failure, final pre-write identity/slot checks, lighting draft ownership and uncertain lighting-timeout reporting. Added discovery, monitor and complete lighting transaction regressions. Independent reviews above remain unperformed; physical Vader 4 testing remains required. See `docs/freedigi-validation.md` for evidence and `docs/vader4-testing.md` for hardware checks.
