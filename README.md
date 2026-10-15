# FreeDigi

A desktop controller app for **Linux and macOS**, built with **Rust + egui** (Metal via wgpu on macOS, OpenGL on Linux).
Configure your Flydigi Vader 5 Pro, inspect live inputs, and see exactly what the app is doing. Experimental Vader 4 Pro support is available in DInput mode.

**Based on [ControlLab](https://github.com/dracinn/ControlLab), the original Swift controller app by dracinn.** FreeDigi reuses its controller protocol implementation and tests. The original MIT copyright and license are preserved, and the app includes an About credit. See [NOTICE](NOTICE) and [LICENSE](LICENSE).

![FreeDigi live input with a connected Vader 5 Pro, dark theme](docs/freedigi-native-overview.png)

[See the visual mapping editor](docs/freedigi-native-mapping.png)

## Status

This is an early desktop preview. The Linux executable builds and the portable protocol and native state/safety tests pass. **The new Linux transport has not yet been tested against a physical controller.** The macOS transport adapts the original ControlLab IOKit session; a FreeDigi macOS build must be run and verified on a Mac.

- Automatic controller discovery and live input monitoring on a controller diagram, including extra face and back buttons.
- Settings are read in the background once a controller connects, so pages open with data; opening a page re-checks it and the view changes only if the controller reports something different.
- Visual single-button mapping editor; temporary apply or persistent save.
- Profile backups, conflict checks, verified readback and the existing bounded retry logic.
- Physical Turbo-button feature toggle and automatic stick-calibration toggle.
- Controller solid-color lighting, brightness and off.
- Installed firmware versions, diagnostics, copy/export report.
- Dry runs enabled at startup. Reads are live; setting writes are only planned until dry run is disabled.

**Not included in this preview:** firmware flashing, Bluetooth configuration, macro/combo/rapid-fire editors, dock lighting, press-to-map, and virtual gamepad output. Existing advanced profile bytes are preserved. This app does not change how games or macOS recognize the dongle, and does not remove Apple's virtual-HID entitlement restriction.

Windows has [minimal groundwork](docs/freedigi-windows.md) only; no Windows controller backend or release is available yet.

The original SwiftUI ControlLab app and the earlier Wails preview have been removed; the ControlLab protocol core, tests and CLI remain ([ControlLab documentation](CONTROLLAB.md)). FreeDigi is not yet feature-complete relative to the original app, whose UI is available upstream.

## Experimental Vader 4 Pro support

Vader 4 Pro uses a separate classic protocol implementation. Set the rear switch to **PC**, then hold **FN+A** until the LED is blue (DInput). Use USB for the first test. The app discovers the `04b4:2412` configuration interface and checks the controller model ID (85, 91 or 105); the USB IDs alone also identify other models.

Supported experimentally: live buttons including C/Z and M1–M4, sticks/triggers, main firmware version, profile mappings, temporary apply, explicit persistent save, and per-profile solid/off/brightness lighting. Turbo and automatic calibration are reported unsupported. Only complete v3.0 (790-byte) and v3.1 (840-byte) profiles and v2.0 (500-byte) lighting are accepted; unknown layouts fail closed. Classic writes require a fresh matching snapshot, indexed acknowledgements and complete readback, and are never automatically replayed. Profile and classic lighting backups are stored under `$XDG_STATE_HOME/freedigi/backups` (default `~/.local/state/freedigi/backups`). Lighting apply is temporary; persistent saving is available for profiles.

**Vader 4 hardware has not been tested with this implementation.** Protocol sources include SDL's Flydigi input support and shared-classic protocol observations mainly made on Apex 4; controller-specific validation remains necessary. Follow the [Vader 4 hardware test checklist](docs/vader4-testing.md), starting with live reads and dry runs. This support does not cover XInput, Bluetooth configuration or firmware flashing.

## Download and install

Download FreeDigi from [Releases](https://github.com/ruxxzebre/freedigi/releases). Choose the package for your computer:

| System | Package | Install |
| --- | --- | --- |
| Debian 13+ / Ubuntu 24.04+ | `.deb` (`amd64` or `arm64`) | `sudo apt install ./freedigi_*.deb` |
| Arch Linux | `x86_64.pkg.tar.zst` | `sudo pacman -U ./freedigi-*.pkg.tar.zst` |
| macOS, Apple silicon | `macos-arm64.dmg` | Drag FreeDigi into Applications |
| macOS, Intel | `macos-amd64.dmg` | Drag FreeDigi into Applications |
| Other Linux | `.tar.gz` (`amd64` or `arm64`) | Extract and run `FreeDigi/freedigi` |

Debian and Arch packages include controller permissions and an applications-menu entry. Reconnect your controller after installation. Mac builds are ad-hoc signed and may require allowing the first launch in Privacy & Security. See the [installation guide](native/packaging/README.md) for details.

The older `v0.1.0-preview` release uses the previous Wails interface.

## Build from source

```sh
git clone https://github.com/ruxxzebre/freedigi.git
cd freedigi
./native/scripts/build.sh
```

See the [native build instructions](native/README.md) to build FreeDigi on Linux or macOS.

## Architecture

```text
egui interface → Rust operation worker → Swift command service
                                                    ├─ Linux: hidraw
                                                    └─ macOS: IOKit
```

The protocol stays in Swift to preserve ControlLab's tested behavior. One Rust worker owns device selection, automatic discovery/read freshness, dry-run state, cached snapshots and process lifetimes. Pages share this state, with one Refresh button for recovery. It pauses the input stream during configuration operations and resumes it afterward. The helper exits after each operation; monitoring keeps one helper alive. No background daemon or paid dependency is needed.

The Chaiky gull is vendored under `native/vendor/chaiky-theme` and is the only
shared component compiled in (Cargo feature `mascot`); FreeDigi's own controls and
palette live in `native/src/ui`. New upstream components are not copied automatically. See the
[native theme update instructions](native/README.md#shared-theme-selectively-vendored).
The app icon source is `native/assets/freedigi.svg`.

Use `nix develop` for the pinned Rust tools and Linux graphics libraries.
`flake.lock` uses the same nixpkgs revision as Chaiky/Core; `native/Cargo.lock`
pins crates. Swift 6 remains an external toolchain (6.0.3 on Linux, Xcode on Mac).

[Validation and known limits](docs/freedigi-validation.md) documents what has actually been tested.

FreeDigi is independent community software, not affiliated with Flydigi. Controller names and artwork identify the supported hardware.
