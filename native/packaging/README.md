# Install FreeDigi

Download the package for your computer from [FreeDigi releases](https://github.com/ruxxzebre/freedigi/releases).

## Debian and Ubuntu

Use the `.deb` package for your processor (`amd64` for Intel/AMD, `arm64` for ARM):

```sh
sudo apt install ./freedigi_*.deb
```

The package installs the app, menu entry and controller permissions. Reconnect your controller after installation, then open **FreeDigi** from your applications menu.

## Arch Linux

Use the `x86_64.pkg.tar.zst` package:

```sh
sudo pacman -U ./freedigi-*.pkg.tar.zst
```

Reconnect your controller, then open **FreeDigi** from your applications menu.

## macOS

Choose `arm64` for Apple silicon or `amd64` for an Intel Mac. Open the `.dmg` and drag **FreeDigi** into **Applications**. A `.zip` is also available.

The app is ad-hoc signed, not Apple-notarized. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway** after trying to open it. No paid developer account is needed to use FreeDigi.

## Other Linux distributions

Extract the `.tar.gz` for your processor and run `FreeDigi/freedigi`. `FreeDigi/install.sh` installs it into your user account and adds a menu entry. The app needs glibc, the GCC C++ runtime, OpenGL/EGL and X11/Wayland libraries from your distribution.

For controller permissions with the archive installation:

```sh
sudo cp FreeDigi/70-freedigi.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

Reconnect the controller afterward. Debian and Arch packages install this rule automatically.

## Controllers

Dry run is enabled initially. Vader 5 Pro is supported; Vader 4 Pro support is experimental and requires DInput mode (PC switch, hold FN+A, blue indicator). Start with read-only checks before applying changes. Firmware flashing and Windows are not supported.
