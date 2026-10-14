import Foundation
import IOKit.hid
@_exported import ControllerProtocol

/// Lives on the calling thread for its entire lifetime. GUI callers use a
/// detached task and suspend the live bridge before opening this session.
final class ControllerHIDSession: ControllerChannel {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let runLoop: CFRunLoop
    private let buffer: UnsafeMutablePointer<UInt8>
    private var reports: [[UInt8]] = []
    private var readError: IOReturn?
    let locationID: UInt32?

    init(vendor: Int = 0x37d7, product: Int? = nil, usagePage: Int? = 0xffa0,
         expectedLocation: UInt32? = nil) throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = (product.map { [$0] } ?? [0x2401, 0x2502]).map { product in
            var match = [kIOHIDVendorIDKey: vendor, kIOHIDProductIDKey: product]
            if let usagePage {
                match[kIOHIDPrimaryUsagePageKey] = usagePage
                match[kIOHIDPrimaryUsageKey] = 1
            }
            return match
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw Vader5Error.managerOpen(result) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              devices.count == 1, let selected = devices.first else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw ControllerProtocolError.invalid("Connect exactly one matching controller interface and wake the controller.")
        }
        device = selected
        locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value
        guard expectedLocation == nil || locationID == expectedLocation else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw ControllerProtocolError.invalid("The update interface is on a different USB port. No firmware was written.")
        }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard opened == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw Vader5Error.deviceOpen(opened)
        }
        runLoop = CFRunLoopGetCurrent()
        buffer = .allocate(capacity: 512)
        buffer.initialize(repeating: 0, count: 512)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, { pointer, result, _, _, _, report, length in
            guard let pointer else { return }
            let session = Unmanaged<ControllerHIDSession>.fromOpaque(pointer).takeUnretainedValue()
            if result != kIOReturnSuccess { session.readError = result }
            else if length > 0 && length <= 512 {
                // A bounded queue prevents an input stream from exhausting memory.
                if session.reports.count < 1024 {
                    session.reports.append(Array(UnsafeBufferPointer(start: report, count: length)))
                } else { session.readError = kIOReturnOverrun }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }

    func send(_ report: [UInt8]) throws {
        try send(report, reportID: 0)
    }

    func send(_ report: [UInt8], reportID: CFIndex) throws {
        guard !report.isEmpty else { throw ControllerProtocolError.invalid("Empty HID report.") }
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, $0.baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else { throw Vader5FirmwareReadError.requestFailed(result) }
    }

    func receive(timeout: TimeInterval) throws -> [UInt8] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while reports.isEmpty {
            if let readError { throw Vader5FirmwareReadError.requestFailed(readError) }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ControllerProtocolError.timeout }
            CFRunLoopRunInMode(.defaultMode, min(remaining, 0.025), true)
        }
        return reports.removeFirst()
    }
}

extension ControllerHIDSession: FirmwareChannel {
    func write(_ report: [UInt8]) throws {
        guard let reportID = report.first, reportID != 0 else {
            throw ControllerProtocolError.invalid("Firmware report ID is missing.")
        }
        try send(report, reportID: CFIndex(reportID))
    }
    func read(timeout: TimeInterval) throws -> [UInt8] { try receive(timeout: timeout) }
}

extension ControllerHIDSession: FirmwareFeatureChannel {
    func setFeature(_ report: [UInt8]) throws {
        guard let id = report.first else { throw ControllerProtocolError.invalid("Empty feature report.") }
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(id), $0.baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else { throw Vader5FirmwareReadError.requestFailed(result) }
    }
    func getFeature(id: UInt8, length: Int) throws -> [UInt8] {
        var report = [UInt8](repeating: 0, count: length)
        report[0] = id
        var count = length
        let result = report.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), $0.baseAddress!, &count)
        }
        guard result == kIOReturnSuccess else { throw Vader5FirmwareReadError.requestFailed(result) }
        guard count == length else { throw ControllerProtocolError.invalid("Truncated bootloader feature report.") }
        return report
    }
}

public enum Vader5Profiles {
    public static func readActive() throws -> ControllerProfileSnapshot {
        try ControllerProfileClient(channel: ControllerHIDSession()).readActive()
    }

    /// The backup is written atomically before opening a device for mutation.
    public static func apply(_ profile: ControllerProfile, replacing snapshot: ControllerProfileSnapshot,
                             persist: Bool, backupURL: URL) throws -> ControllerProfileSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard !FileManager.default.fileExists(atPath: backupURL.path) else {
            throw ControllerProtocolError.invalid("Backup already exists. Choose a new backup filename.")
        }
        try encoder.encode(snapshot).write(to: backupURL, options: .atomic)
        return try ControllerProfileClient(channel: ControllerHIDSession())
            .apply(profile, replacing: snapshot, persist: persist)
    }
}
