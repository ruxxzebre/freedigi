import Foundation
import Vader5CoreC

public struct NativeGamepadSnapshot: Sendable {
    public var profile = "None"
    public var phase = "Not started"
    public var dryRun = false
    public var created = false
    public var acceptedReports: UInt64 = 0
    public var rejectedReports: UInt64 = 0
    public var previewedReports: UInt64 = 0
    public var lastError: String?
    public var lastAcceptedAt: Date?
}

/// Report delivery counters, never raw high-frequency game input.
public final class NativeGamepadDiagnostics: @unchecked Sendable {
    public static let shared = NativeGamepadDiagnostics()
    private let lock = NSLock()
    private var state = NativeGamepadSnapshot()
    public func snapshot() -> NativeGamepadSnapshot { lock.withLock { state } }
    public static let signingStatus: String = {
        switch V5VirtualHIDHasEntitlement() {
        case 1: "Virtual-HID entitlement present in running signature"
        case 0: "Virtual-HID entitlement absent from running signature"
        default: "Unable to inspect virtual-HID entitlement"
        }
    }()
    func begin(profile: String, dryRun: Bool) {
        lock.withLock {
            state = NativeGamepadSnapshot()
            state.profile = profile
            state.dryRun = dryRun
            state.phase = dryRun ? "Previewing · no virtual device" : "Creating virtual device"
        }
    }
    func created() { lock.withLock { state.created = true; state.phase = "Device created · game recognition unverified" } }
    func preview() { lock.withLock { state.previewedReports += 1 } }
    func accepted() { lock.withLock { state.acceptedReports += 1; state.lastAcceptedAt = Date() } }
    func failed(_ error: String, report: Bool = false) {
        lock.withLock {
            if report { state.rejectedReports += 1 }
            state.lastError = error
            state.phase = "Failed"
        }
    }
    func stopped() {
        lock.withLock {
            state.created = false
            if state.lastError == nil { state.phase = "Stopped" }
        }
    }
}
