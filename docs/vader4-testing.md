# Vader 4 Pro hardware test

This is the first hardware validation of FreeDigi's experimental Vader 4 Pro support. Use the build containing this change on Linux or macOS. Windows and Bluetooth configuration are not supported.

## Connect

1. Close other controller configuration apps. Start with a USB cable, then repeat discovery and input checks with the receiver.
2. Put the rear switch in PC mode. Hold **FN + A** to select DInput; the indicator should turn blue. Flydigi documents this combination in its [official shortcut guide](https://help.flydigi.com/docs/fk6fgtexhroeq72d). **FN + X** returns to XInput (white indicator) after testing.
3. On Linux, install the updated `70-freedigi.rules` supplied with this build, reload udev rules, and reconnect. An older rule may allow the Vader 5 but omit the Vader 4.
4. Launch FreeDigi with **Dry run enabled**. Record the operating system, controller edition, wired/receiver connection and installed firmware version.

## Read-only checks

- Discovery: the controller appears and stays connected. Unplug/replug it once and check that inputs resume.
- Live inputs: press A/B/X/Y, both bumpers, View/Menu, both stick clicks, every D-pad direction and diagonal, then C/Z and M1–M4 individually. Check that each extra button highlights independently.
- Sticks/triggers: check centering, direction and full travel. Move both sticks while holding an extra button.
- Mapping: the active profile and current mappings load. Compare them with the controller's existing configuration. Change the active profile on the controller and refresh; confirm the displayed slot changes.
- Lighting: the existing brightness/color loads. Firmware: the main version appears. Feature switches without a Vader 4 implementation should be unavailable.

If a read fails, export the Diagnostics report and note the page, connection type and exact error. Keep Dry run enabled until the reads succeed. An unsupported profile-format error is useful evidence; record it instead of trying to force a write.

## Preview and temporary changes

1. With Dry run still enabled, stage **M1 → A** and choose the temporary apply action. It should report a preview, with no change to the controller.
2. Disable Dry run and apply the same temporary mapping. Check the reported readback, then refresh the Mapping page and confirm M1 → A. FreeDigi saves a backup before a live profile write.
3. Return M1 to its original mapping and apply temporarily. Verify it again.
4. Try a solid lighting color at moderate brightness, then Off, then restore the original setting. Check both the physical light and the app's readback. Lighting persistence is separate from the mapping Save action; record what survives a power cycle.

## Persistent mapping

After temporary writes work, save one mapping change to the controller. Power-cycle it, reconnect in DInput, and confirm the mapping survives. Restore the original mapping with Save and confirm that also survives a power cycle.

If a write reports a timeout or a readback mismatch, record the error and read the current settings before another attempt. The controller may have accepted some of the operation.

## Send back

- OS/version, controller edition and firmware version.
- Wired or receiver, plus whether the DInput indicator was blue.
- Which checks passed, the first failing action and its exact error.
- Diagnostics export, and whether any requested setting actually changed despite an error.

Synthetic tests cannot establish that these commands work on every Vader 4 firmware. This checklist records that missing hardware evidence.
