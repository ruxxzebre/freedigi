# Windows groundwork

Windows is a future target, not a supported release in this preview.

The Go operation coordinator and JSON service contract are platform-neutral. Executable lookup uses `freedigi-service.exe` on Windows. Platform policy explicitly marks Windows controller support unavailable, and hardware entry points return a clear error rather than trying to open a Unix transport. The React UI can display that state.

A compile-only check builds the Go service-boundary test executable for Windows amd64. It does not run those tests, build a Windows GUI, or establish controller support.

A future Windows service must implement:

- Configuration-interface discovery for the supported Flydigi USB IDs, followed by controller identity validation.
- Correct HID report framing, bounded reads, cancellation and exclusive operation ownership.
- The existing JSON actions and snapshot semantics so dry runs, profile conflict checks and verified writes retain their behavior.

The current Swift helper supports Linux and macOS only. The build script deliberately does not produce Windows packages. There is no Windows driver, installer, firmware updater or self-hosted Windows runner. This keeps the initial groundwork small and leaves the same service boundary usable by a future Rust/egui frontend as well.
