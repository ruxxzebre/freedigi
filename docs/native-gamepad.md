# Native gamepad output and Xcode signing

ControlLab can now encode standard Xbox-style input from the USB receiver, create
a virtual HID device, check each report submission, and show what Apple's
GameController API sees. This is experimental: portable report tests pass, but
the Xcode project, restricted signing, device recognition and Transistor have not
been tested on a Mac in this environment. There is no paid broker or
keyboard/mouse output dependency.

## Open and sign in Xcode

Open **ControlLab.xcodeproj**, rather than Package.swift, to get an app target
with Signing & Capabilities and the bundled RGB preview helper. The core remains
a local Swift package; SDL is bundled from the existing vendored framework.
No project generator needs installing to open this checked-in project.

1. Select the **ControlLab** scheme for a normal app build. Set your signing team
   on both the **ControlLab** and **ControlLabRGBPreview** targets. Set the app's
   bundle identifier to an App ID registered to your team. Build and run.
2. For live virtual output, obtain Apple's authorization for
   `com.apple.developer.hid.virtual.device` on that App ID, and regenerate a
   matching macOS provisioning profile. An ordinary signing certificate or
   selecting a team does **not** grant this capability.
3. Select the **ControlLab Native Gamepad** scheme. Its **NativeGamepad** build
   configuration uses `ControlLab.entitlements`. Set the same team and app bundle
   identifier for this configuration. Use automatic signing if Xcode resolves
   the authorized profile, or select the matching profile manually for the app.
   Keep the preview helper on ordinary signing; it does not create virtual HIDs.
4. Run. In **Game compatibility**, inspect the running entitlement, embedded
   profile presence, virtual-device creation and report counters separately.

The normal scheme deliberately has no restricted entitlement. It supports
controller settings and an output dry run without claiming authorization it
doesn't have. The native scheme can fail signing/launch until Apple approves the
capability and the profile matches your team, certificate, App ID and Mac.
Do not change macOS security settings to bypass provisioning.

Xcode signing choices edit the project. Keep those local changes: the updater
stops on a modified checkout rather than overwriting them. The normal Terminal
updater does not reuse Xcode signing choices. To retain native signing, rebuild
in Xcode, or pass the signing variables below when using the scripts.

The shared schemes build the app and preview helper. They do not run the Swift
package test suites; `./scripts/build-mac.sh` runs those. Project regeneration is
only needed after changing target file membership:
`python3 scripts/generate-xcode-project.py` (this resets project-level signing
edits; preserve them first).

## Scripted signing

With a matching approved profile and certificate already installed:

```sh
ENABLE_VIRTUAL_HID=1 \
APP_BUNDLE_IDENTIFIER="dev.yourname.controllab" \
PROVISIONING_PROFILE="/absolute/path/ControlLab.provisionprofile" \
SIGNING_IDENTITY="Apple Development: Your Name (CERTIFICATEID)" \
./scripts/build-mac.sh
open build/ControlLab.app
```

Use the exact certificate label shown by `security find-identity -v -p codesigning`.
A matching Developer ID Application certificate/profile also works for packaging;
the script does not notarize or distribute the app. Packaging checks the profile's
expiration, virtual-HID permission, App ID, team and signing-certificate membership,
and generates the required app/team entitlements. macOS still validates actual
authorization at launch. The normal ad-hoc build remains the default.

## Test on the Mac

1. Quit other copies of ControlLab. Connect the USB receiver, wake the controller,
   and confirm normal input in Monitor only. Stop monitoring before changing mode.
2. Open **Game compatibility** and choose **Xbox-compatible gamepad**.
   Leave **Dry run** on and start preview. Previewed reports should increase as
   inputs arrive. No virtual device is created in this mode.
3. Stop preview, turn Dry run off, then start output. Creation must succeed and
   accepted reports must increase with zero rejected reports. On any report
   error, output stops and logs the IOKit error. Stopping or unplugging sends a
   neutral report where possible and releases the virtual device.
4. Compare the **Apple GameController test** list before and after starting
   output. It includes physical controllers too, so a nonempty list alone proves
   nothing about ControlLab's device. With this window focused, move both sticks
   and press buttons; confirm the values in that section change.
5. Keep ControlLab running and launch Transistor. Test direct game input with
   Steam Input disabled for that game first, then compare with it enabled if
   needed. Record which setting worked. GameController visibility and Steam's
   tester cannot establish what the game itself receives.
6. If it fails, use **Copy game compatibility report**, and include what happened
   in the game. Try the generic **Virtual gamepad** profile as a comparison.

The output path forwards reports on the HID worker immediately; UI refresh does
not pace virtual input. No end-to-end latency measurement has been made.
USB removal is handled; controller sleep while the receiver remains plugged in
still needs hardware validation. Configuration access temporarily destroys the
virtual device and recreates it on resume, which can require a game to reconnect.
Make settings changes before starting a game.

## Limits and evidence

The Xbox profile uses an input-only 17-byte Xbox One S Bluetooth-style report and
the Xbox VID/PID `045e:02fd`. It describes the virtual device as Bluetooth; the
physical source remains the Flydigi USB receiver. This identity/report combination
is a compatibility experiment, not an assertion that a real Xbox is attached.
Standard buttons, sticks, analog triggers and D-pad are represented. The format
was checked against the [SDL Xbox One decoder](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_xboxone.c).

C/Z, M1–M4, LM/RM and Fn have no independent Xbox outputs. Whether firmware-saved
mappings appear as standard buttons in the enhanced receiver stream needs a
hardware test. ControlLab does not yet apply a separate software remapping layer
to virtual output. Rumble, motion and battery reporting are not implemented.

Apple documents the [virtual-HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device)
and how [provisioning profiles authorize restricted entitlements](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).
An [Apple GameController engineer](https://developer.apple.com/forums/thread/812774)
also explains that virtual HID controllers can be filtered and are not a
guaranteed compatibility path. Successful signing and accepted HID reports are
therefore intermediate checks, not a promise of support in every game.
