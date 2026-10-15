#if os(macOS)
import Foundation
import IOKit.hid
import ControllerProtocol

// Based on ControlLab's ControllerHIDSession. Each session stays on one thread,
// owns the configuration interface, and uses that thread's CFRunLoop.
public struct HIDDevice: Codable, Sendable {
    public let path: String, name: String, product: String
    public let accessible: Bool
    public let isClassic: Bool
    static func key(_ device: IOHIDDevice) -> String {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return "iokit:\(id)"
    }
    static func manager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatchingMultiple(manager, ([(0x37d7, 0x2401), (0x37d7, 0x2502)].map {
            [kIOHIDVendorIDKey: $0.0, kIOHIDProductIDKey: $0.1,
             kIOHIDPrimaryUsagePageKey: 0xffa0, kIOHIDPrimaryUsageKey: 1]
        } + [[kIOHIDVendorIDKey: 0x04b4, kIOHIDProductIDKey: 0x2412, kIOHIDPrimaryUsagePageKey: 0xffa0]]) as CFArray)
        return manager
    }
    public static func enumerate() -> [Self] {
        let manager = manager()
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else { return [] }
        defer { IOHIDManagerClose(manager, 0) }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        return devices.map { device in
            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Flydigi controller"
            return Self(path: key(device), name: name, product: String(format: "%04x", product), accessible: true, isClassic: product == 0x2412)
        }.sorted { $0.path < $1.path }
    }
}

public final class HIDChannel: ControllerChannel {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let runLoop: CFRunLoop
    private let buffer: UnsafeMutablePointer<UInt8>
    private var reports: [[UInt8]] = []
    private var readError: IOReturn?
    public let isClassic: Bool
    public init(path: String) throws {
        manager = HIDDevice.manager()
        let result = IOHIDManagerOpen(manager, 0)
        guard result == kIOReturnSuccess else { throw ControllerProtocolError.invalid("Cannot open HID manager: \(result)") }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let selected = devices.first(where: { HIDDevice.key($0) == path }) else {
            IOHIDManagerClose(manager, 0)
            throw ControllerProtocolError.invalid("Controller is no longer present. Refresh devices.")
        }
        device = selected
        isClassic = (IOHIDDeviceGetProperty(selected, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue == 0x04b4
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard opened == kIOReturnSuccess else {
            IOHIDManagerClose(manager, 0)
            throw ControllerProtocolError.invalid("Cannot open configuration interface: \(opened). Close other controller configuration apps and try again.")
        }
        runLoop = CFRunLoopGetCurrent()
        buffer = .allocate(capacity: 512)
        buffer.initialize(repeating: 0, count: 512)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, { pointer, result, _, _, _, report, length in
            guard let pointer else { return }
            let session = Unmanaged<HIDChannel>.fromOpaque(pointer).takeUnretainedValue()
            if result != kIOReturnSuccess { session.readError = result }
            else if length > 0 && length <= 512 {
                if session.reports.count < 1024 { session.reports.append(Array(UnsafeBufferPointer(start: report, count: length))) }
                else { session.readError = kIOReturnOverrun }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }
    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, 0); IOHIDManagerClose(manager, 0); buffer.deallocate()
    }
    public func send(_ report: [UInt8]) throws {
        guard !report.isEmpty, !isClassic || report.first == 5 else { throw ControllerProtocolError.invalid("Empty HID report") }
        let result = report.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, isClassic ? 5 : 0, $0.baseAddress!, $0.count) }
        guard result == kIOReturnSuccess else { throw ControllerProtocolError.invalid("Controller HID write failed: \(result). Read the setting before retrying.") }
    }
    public func receive(timeout: TimeInterval) throws -> [UInt8] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while reports.isEmpty {
            if let readError { throw ControllerProtocolError.invalid("Controller HID read failed: \(readError)") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ControllerProtocolError.timeout }
            CFRunLoopRunInMode(.defaultMode, min(remaining, 0.025), true)
        }
        return reports.removeFirst()
    }
}
#endif
