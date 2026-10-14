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
    private let traceID = UUID()
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
        ControllerDiagnostics.shared.record("HID session", message: "Opened vendor \(vendor), product \(product.map { String($0) } ?? "auto"), usage page \(usagePage.map { String($0) } ?? "any").", operationID: traceID)
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
        ControllerDiagnostics.shared.trace("HID session", direction: "send", report: report, operationID: traceID)
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
        let report = reports.removeFirst()
        if (report.count >= 3 && report.starts(with: [0x5a, 0xa5]) && report[2] != 0xef) || report.first == 5 {
            ControllerDiagnostics.shared.trace("HID session", direction: "receive", report: report, operationID: traceID)
        }
        return report
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
        ControllerDiagnostics.shared.trace("HID session", direction: "send", report: report, operationID: traceID)
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
        ControllerDiagnostics.shared.trace("HID session", direction: "feature receive", report: report, operationID: traceID)
        return report
    }
}

public enum Vader5Profiles {
    private static func retryTransportError(_ error: Error) -> Bool {
        if let error = error as? Vader5Error {
            switch error {
            case .managerOpen, .deviceOpen: return true
            default: return false
            }
        }
        if case Vader5FirmwareReadError.requestFailed = error { return true }
        return false
    }

    public static func readActive() throws -> ControllerProfileSnapshot {
        try ControllerDiagnostics.shared.perform("Read profile") {
            try ControllerProfileReadRetry.read(retryTransportError: retryTransportError) {
                // Each failed attempt closes its session before the next starts,
                // so partial packet queues are never reused.
                try ControllerProfileClient(channel: ControllerHIDSession()).readActive()
            }
        }
    }

    public static func preview(_ profile: ControllerProfile, replacing snapshot: ControllerProfileSnapshot, persist: Bool) throws -> Int {
        try ControllerDiagnostics.shared.perform("Write profile", mode: .dryRun, details: "Profile \(snapshot.slot + 1); persist: \(persist). Uses the last read snapshot; no fresh device check.") {
            let reports = try profile.writeReports(replacing: snapshot.profile(), slot: snapshot.slot, persist: persist)
            let id = UUID()
            for report in reports {
                ControllerDiagnostics.shared.trace("Profile plan", direction: "planned send", report: report, operationID: id, mode: .dryRun)
            }
            ControllerDiagnostics.shared.record("Profile plan", mode: .dryRun, message: "\(reports.count) write reports planned; \(reports.filter { $0[2] == 0xa5 }.count) changed segments. Live execution verifies the current profile before writing and reads back before saving.")
            return reports.count
        }
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
        return try ControllerDiagnostics.shared.perform("Write profile", details: "Profile \(snapshot.slot + 1); persist: \(persist); backup: \(backupURL.lastPathComponent).") {
            try ControllerProfileWriteRetry.apply(profile, replacing: snapshot, persist: persist,
                                                  retryTransportError: retryTransportError) {
                try ControllerHIDSession()
            }
        }
    }
}

public enum Vader5Calibration {
    public static func preview(_ enabled: Bool, replacing snapshot: ControllerCalibrationSetting) throws {
        let reports = try snapshot.reports(enabling: enabled)
        ControllerDiagnostics.shared.write("Set automatic calibration", mode: .dryRun, reports: reports,
            details: "Enabled: \(enabled). Uses last-read support/identity; live execution rechecks them and verifies readback.") {}
    }

    public static func read() throws -> ControllerCalibrationSetting {
        try ControllerDiagnostics.shared.perform("Read calibration") {
            try ControllerCalibrationClient(channel: ControllerHIDSession()).read()
        }
    }

    public static func setEnabled(_ enabled: Bool, replacing snapshot: ControllerCalibrationSetting) throws -> ControllerCalibrationSetting {
        try ControllerDiagnostics.shared.perform("Set automatic calibration", details: "Enabled: \(enabled).") {
            try ControllerCalibrationClient(channel: ControllerHIDSession()).setEnabled(enabled, replacing: snapshot)
        }
    }
}
