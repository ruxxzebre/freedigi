import Foundation
import IOKit.hid

public enum Vader5DeviceProbe {
    public struct Interface: Codable, Sendable {
        public let vendorID: Int
        public let productID: Int
        public let usagePage: Int
        public let usage: Int
        public let locationID: UInt32?
        public let product: String?
        public let inputReportLength: Int
        public let outputReportLength: Int
        public let featureReportLength: Int
    }

    /// Enumerates normal and known bootloader interfaces without sending reports.
    public static func enumerate() throws -> [Interface] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: 0x37d7],
            [kIOHIDVendorIDKey: 0x0483, kIOHIDProductIDKey: 0x5720],
        ] as CFArray)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw Vader5Error.managerOpen(result) }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        return devices.map { device in
            func number(_ key: String) -> Int {
                (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
            }
            return Interface(vendorID: number(kIOHIDVendorIDKey), productID: number(kIOHIDProductIDKey),
                usagePage: number(kIOHIDPrimaryUsagePageKey), usage: number(kIOHIDPrimaryUsageKey),
                locationID: (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value,
                product: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String,
                inputReportLength: number(kIOHIDMaxInputReportSizeKey),
                outputReportLength: number(kIOHIDMaxOutputReportSizeKey),
                featureReportLength: number(kIOHIDMaxFeatureReportSizeKey))
        }.sorted { ($0.productID, $0.usagePage, $0.locationID ?? 0) < ($1.productID, $1.usagePage, $1.locationID ?? 0) }
    }
}
