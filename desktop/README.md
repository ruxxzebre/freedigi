# FreeDigi desktop

Wails + React interface for Linux and macOS, based on the ControlLab Swift app by dracinn.

## Linux: run the release

The initial Linux amd64 package targets **Ubuntu 24.04 or compatible distributions with glibc 2.39+, GTK 3 and WebKitGTK 4.1**. It is not an AppImage and does not bundle the system WebView.

```sh
sudo apt-get install libgtk-3-0t64 libwebkit2gtk-4.1-0
tar -xzf FreeDigi-linux-amd64.tar.gz
cd FreeDigi
./freedigi
```

Keep `freedigi-service` beside `freedigi`. Optionally run `./install.sh` to install into your user applications folder. The installer uses Python 3 and does not need root.

For HID permissions on a desktop using systemd-logind, install the supplied rule once:

```sh
sudo install -m 644 70-freedigi.rules /etc/udev/rules.d/70-freedigi.rules
sudo udevadm control --reload-rules
```

Unplug and reconnect the receiver/controller. The rule grants the active local desktop user access to Flydigi USB product IDs 2401 and 2502; it does not grant world-write permissions. Do not run FreeDigi as root. On other session managers, configure equivalent hidraw access using your distribution's instructions.

## macOS: run the build

Requires macOS 13 or newer. Build on your Mac or download the artifact from your manually triggered macOS workflow. Unzip `FreeDigi-macos-arm64.zip` and move `FreeDigi.app` to Applications. Close the old ControlLab app before accessing the same controller.

The build script signs the helper and app **ad hoc** for local development. It does not notarize the app. macOS may require you to allow this downloaded app in Privacy & Security. No paid developer account is required for ordinary controller configuration. This build does not implement restricted virtual-gamepad output.

## Build from source

Install Go 1.25+ (1.26 recommended), Node 22.12+ (24 recommended), npm, and Swift 6+. macOS needs Xcode command-line tools; Linux needs the Swift toolchain from swift.org.

Ubuntu 24.04 build packages:

```sh
sudo apt-get install build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev libcurl4-openssl-dev libxml2-dev
```

On macOS, `brew install go node` can supply Go and Node. Select your Xcode toolchain before building.

From the repository root:

```sh
./desktop/scripts/build.sh
```

The script installs pinned Wails 2.15.0 if it is missing, runs Swift and Go tests, builds the frontend and native app, and packages:

- Linux: `desktop/dist/FreeDigi-linux-amd64.tar.gz` (or arm64 when built on arm64).
- macOS: `desktop/dist/FreeDigi-macos-arm64.zip` (or amd64 on Intel).

The current architecture is built; these are not universal macOS binaries. Linux statically links the Swift runtime, while GTK/WebKit and normal system libraries remain dynamic. macOS uses the system Swift runtime. `FREEDIGI_BUILD=1` selects only the service and portable tests in Package.swift, avoiding the original app's SDL dependencies.

For browser development:

```sh
cd desktop/frontend
npm ci
npm run dev
```

The browser explicitly shows a hardware-unavailable preview; it never simulates a connected controller. For desktop development, first build the Swift helper, set `FREEDIGI_SERVICE` to its absolute path, and run `wails dev` in `desktop` (`-tags webkit2_41` on Linux).

## Using the app

1. Connect a Vader 5 Pro through the USB receiver or cable, refresh devices and select it.
2. Read the setting or profile you want to change.
3. Make edits and preview them with dry run enabled.
4. Disable dry run to apply to hardware. Profile saves use a preflight read and verify the result before reporting success.

Monitoring is optional. Configuration temporarily stops the monitor to prevent overlapping HID commands; the selected device stays selected, and monitoring resumes afterward. These stream-control commands remain live even in dry-run mode.

Profile backups are JSON files under `$XDG_STATE_HOME/freedigi/backups` or `~/.local/state/freedigi/backups`. The backup path is included in the diagnostic state. There is no backup-import UI yet. A failed write invalidates the cached setting, so read it again before retrying.

Automatic calibration toggles a feature in controller firmware; it is not a stick-calibration wizard. The Turbo toggle enables the physical button's features; it does not configure per-button rapid fire.

Firmware installation, Bluetooth configuration, press-to-map, dock lighting, advanced mapping editors and virtual gamepad output are not included in this preview. No hardware verification has been performed for the new Linux transport yet.

## Attribution

FreeDigi is based on [ControlLab](https://github.com/dracinn/ControlLab), the original Swift controller app by **dracinn**. Copyright (c) 2026 dracinn; MIT License. The original source and license remain in the repository, and LICENSE/NOTICE accompany packaged builds.
