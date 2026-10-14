import Foundation

/// Xbox One S Bluetooth-format input, independent of the platform HID API.
/// Layout checked against SDL's Xbox One Bluetooth 17-byte packet decoder.
/// Creating a device with this report does not prove OS/game compatibility.
public enum XboxCompatibleReport {
    public static let vendorID = 0x045e
    public static let productID = 0x02fd

    // Input-only descriptor: four unsigned 16-bit axes, two 10-bit triggers,
    // a hat, 15 button usages with the Xbox gaps, and a consumer Back bit.
    public static let descriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xa1, 0x01, 0x85, 0x01,
        0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
        0x15, 0x00, 0x27, 0xff, 0xff, 0x00, 0x00,
        0x75, 0x10, 0x95, 0x04, 0x81, 0x02,
        0x05, 0x02, 0x09, 0xc5, 0x15, 0x00, 0x26, 0xff, 0x03,
        0x75, 0x0a, 0x95, 0x01, 0x81, 0x02,
        0x75, 0x06, 0x95, 0x01, 0x81, 0x03,
        0x09, 0xc4, 0x75, 0x0a, 0x95, 0x01, 0x81, 0x02,
        0x75, 0x06, 0x95, 0x01, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x39, 0x15, 0x01, 0x25, 0x08,
        0x35, 0x00, 0x46, 0x3b, 0x01, 0x65, 0x14,
        0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
        0x75, 0x04, 0x95, 0x01, 0x81, 0x03,
        0x65, 0x00, 0x45, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x0f, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x0f, 0x81, 0x02,
        0x95, 0x01, 0x81, 0x03,
        0x05, 0x0c, 0x0a, 0x24, 0x02, 0x95, 0x01, 0x81, 0x02,
        0x95, 0x07, 0x81, 0x03, 0xc0,
    ]

    /// Axes use ControlLab's convention: positive Y is up. Buttons use the
    /// profile IDs from ControllerMappingInput (A=4, LB=10, Home=32, etc.).
    public static func encode(leftX: Int16, leftY: Int16, rightX: Int16, rightY: Int16,
                              leftTrigger: UInt8, rightTrigger: UInt8, dpad: UInt8,
                              buttons: Set<Int>) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 17)
        report[0] = 1
        func put(_ value: Int, at offset: Int) {
            report[offset] = UInt8(truncatingIfNeeded: value)
            report[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        put(Int(leftX) + 32768, at: 1)
        put(min(65535, 32768 - Int(leftY)), at: 3)
        put(Int(rightX) + 32768, at: 5)
        put(min(65535, 32768 - Int(rightY)), at: 7)
        put((Int(leftTrigger) * 1023 + 127) / 255, at: 9)
        put((Int(rightTrigger) * 1023 + 127) / 255, at: 11)
        report[13] = dpad < 8 ? dpad + 1 : 0
        for (source, bit) in [(4, 0), (5, 1), (7, 3), (8, 4), (10, 6), (11, 7)] {
            if buttons.contains(source) { report[14] |= UInt8(1 << bit) }
        }
        for (source, bit) in [(6, 2), (9, 3), (32, 4), (14, 5), (15, 6)] {
            if buttons.contains(source) { report[15] |= UInt8(1 << bit) }
        }
        return report
    }
}
