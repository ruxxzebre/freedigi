import Foundation

public enum ControllerProtocolError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    case timeout
    case conflict
    case verification

    public var description: String {
        switch self {
        case .invalid(let message): message
        case .timeout: "Controller response timed out. Read the device again before retrying."
        case .conflict: "The controller or active profile changed. Read it again before applying settings."
        case .verification: "The controller did not read back the requested settings. They have not been saved by ControlLab."
        }
    }
}

/// One exclusively owned, synchronous HID connection. receive must obey its timeout,
/// including when the controller disconnects. Reports exclude an unnumbered report ID.
public protocol ControllerChannel: AnyObject {
    func send(_ report: [UInt8]) throws
    func receive(timeout: TimeInterval) throws -> [UInt8]
}

public enum ControllerCommand {
    public static func frame(_ command: UInt8, payload: [UInt8] = []) -> [UInt8] {
        precondition(payload.count <= 26)
        var bytes: [UInt8] = [0x5a, 0xa5, command, UInt8(payload.count + 2)] + payload
        bytes.append(bytes.dropFirst(2).reduce(0, &+))
        return bytes + [UInt8](repeating: 0, count: 32 - bytes.count)
    }

    public static func matches(_ bytes: [UInt8], _ command: UInt8) -> Bool {
        bytes.count >= 5 && bytes[0] == 0x5a && bytes[1] == 0xa5 && bytes[2] == command
    }
}

public struct ControllerIdentity: Codable, Equatable, Sendable {
    public let deviceID: UInt8
    public let address: [UInt8]
    public let connection: UInt8

    public static func parse(_ report: [UInt8]) -> Self? {
        guard ControllerCommand.matches(report, 1), report.count >= 28 else { return nil }
        let segmented = report[4] < report[3]
        guard !segmented || report[4] == 0 else { return nil }
        let base = segmented ? 5 : 4
        return Self(deviceID: report[base], address: Array(report[(base + 2)..<(base + 6)]), connection: report[base + 1])
    }

    public func requireVader5() throws {
        guard [130, 144, 145].contains(deviceID) else {
            throw ControllerProtocolError.invalid("Device ID \(deviceID) is not a supported Vader 5 Pro variant.")
        }
    }
}

/// Raw profile bytes are the source of truth. Edits preserve every unknown field,
/// including macros, calibration and future extensions. No factory defaults are synthesized.
public struct ControllerProfile: Equatable, Sendable {
    public private(set) var bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 840, bytes.count <= 5100, bytes.count.isMultiple(of: 20),
              bytes[1] == 3, bytes[0] <= 2 else {
            throw ControllerProtocolError.invalid("Unsupported or truncated controller profile (expected protocol 3.0–3.2).")
        }
        self.bytes = bytes
    }

    public var title: String {
        let units = stride(from: 770, to: 790, by: 2).map {
            UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
        }.prefix { $0 != 0 && $0 != 0xffff }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func setTitle(_ title: String) throws {
        let units = Array(title.utf16)
        guard units.count <= 10, !units.contains(0), !units.contains(0xffff) else {
            throw ControllerProtocolError.invalid("Profile names allow up to 10 UTF-16 characters.")
        }
        var data = units.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
        data += [UInt8](repeating: 0, count: 20 - data.count)
        bytes.replaceSubrange(770..<790, with: data)
    }

    /// Nil denotes a macro, turbo or keyboard mapping which must be preserved
    /// until the user explicitly replaces it with a simple gamepad button.
    public func mapping(for source: Int) -> Int? {
        guard (0..<32).contains(source) else { return nil }
        let offset = 13 + source * 3
        guard bytes[offset + 1] == 0, bytes[offset + 2] == 0 else { return nil }
        if bytes[offset] == 255 { return source }
        return bytes[offset] < 32 ? Int(bytes[offset]) : nil
    }

    public mutating func map(_ source: Int, to destination: Int) throws {
        guard (0..<32).contains(source), (0..<32).contains(destination) else {
            throw ControllerProtocolError.invalid("Invalid button mapping.")
        }
        let offset = 13 + source * 3
        bytes.replaceSubrange(offset..<(offset + 3), with: [source == destination ? 255 : UInt8(destination), 0, 0])
    }

    public var vibrationEnabled: Bool { bytes[145] == 0 }
    public mutating func setVibrationEnabled(_ enabled: Bool) { bytes[145] = enabled ? 0 : 255 }
    public var dataVersion: UInt16 { UInt16(bytes[225]) | UInt16(bytes[226]) << 8 }
    public func restoringContents(from backup: ControllerProfile) throws -> ControllerProfile {
        guard bytes.count == backup.bytes.count, bytes.prefix(3) == backup.bytes.prefix(3) else {
            throw ControllerProtocolError.invalid("Backup format differs from the current controller profile.")
        }
        var restored = backup
        restored.setDataVersion(dataVersion)
        return restored
    }
    mutating func setDataVersion(_ version: UInt16) {
        bytes[225] = UInt8(truncatingIfNeeded: version)
        bytes[226] = UInt8(version >> 8)
    }
}

public struct ControllerProfileSnapshot: Codable, Equatable, Sendable {
    public let identity: ControllerIdentity
    /// Wire IDs are zero-based. The UI shows these as profiles 1–4.
    public let slot: UInt8
    public let data: Data

    public init(identity: ControllerIdentity, slot: UInt8, profile: ControllerProfile) {
        self.identity = identity
        self.slot = slot
        self.data = Data(profile.bytes)
    }

    public func profile() throws -> ControllerProfile {
        try identity.requireVader5()
        guard slot < 4 else { throw ControllerProtocolError.invalid("Unsupported profile slot.") }
        return try ControllerProfile(bytes: Array(data))
    }
}

/// The A3 protocol has no request token. A session must have exclusive ownership
/// and may not automatically retry timed-out writes (late ACKs are ambiguous).
public final class ControllerProfileClient {
    private let channel: any ControllerChannel
    public init(channel: any ControllerChannel) { self.channel = channel }

    private func response(_ command: UInt8, timeout: TimeInterval = 2) throws -> [UInt8] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ControllerProtocolError.timeout }
            let report = try channel.receive(timeout: remaining)
            if ControllerCommand.matches(report, command) { return report }
        }
    }

    public func identity() throws -> ControllerIdentity {
        try channel.send(ControllerCommand.frame(1))
        guard let identity = ControllerIdentity.parse(try response(1)) else {
            throw ControllerProtocolError.invalid("Malformed controller identity response.")
        }
        try identity.requireVader5()
        return identity
    }

    private func activeSlot() throws -> UInt8 {
        try channel.send(ControllerCommand.frame(0xa1))
        let report = try response(0xa1)
        guard report.count >= 14, report[5] < 4 else {
            throw ControllerProtocolError.invalid("Select a PC profile on the controller (Switch profiles are not supported).")
        }
        return report[5]
    }

    private func read(slot: UInt8) throws -> ControllerProfile {
        try channel.send(ControllerCommand.frame(0xa3, payload: [slot, 20]))
        var packets: [Int: [UInt8]] = [:]
        var count: Int?
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ControllerProtocolError.timeout }
            let report = try response(0xa3, timeout: remaining)
            guard report.count >= 26, report[5] == slot, report[3] >= 42,
                  report[4] < report[3] else {
                throw ControllerProtocolError.invalid("Malformed profile packet.")
            }
            let total = Int(report[3]), index = Int(report[4])
            let payload = Array(report[6..<26])
            guard count == nil || count == total,
                  packets[index] == nil || packets[index] == payload else {
                throw ControllerProtocolError.invalid("Conflicting profile packets; read again.")
            }
            count = total
            packets[index] = payload
        } while packets.count != count
        return try ControllerProfile(bytes: (0..<count!).flatMap { packets[$0]! })
    }

    public func readActive() throws -> ControllerProfileSnapshot {
        let identity = try identity()
        let slot = try activeSlot()
        let profile = try read(slot: slot)
        guard try activeSlot() == slot, try self.identity() == identity else {
            throw ControllerProtocolError.conflict
        }
        return .init(identity: identity, slot: slot, profile: profile)
    }

    /// Callers must persist the original snapshot before invoking this operation.
    /// Saving is explicit; applying alone changes the active configuration in RAM.
    public func apply(_ edited: ControllerProfile, replacing snapshot: ControllerProfileSnapshot,
                      persist: Bool) throws -> ControllerProfileSnapshot {
        let original = try snapshot.profile()
        guard edited.bytes.count == original.bytes.count,
              edited.bytes.prefix(3) == original.bytes.prefix(3),
              edited.dataVersion == original.dataVersion else {
            throw ControllerProtocolError.invalid("Profile format or version changed.")
        }
        guard try readActive() == snapshot else { throw ControllerProtocolError.conflict }
        for index in 0..<(edited.bytes.count / 20) {
            let range = (index * 20)..<(index * 20 + 20)
            guard edited.bytes[range] != original.bytes[range] else { continue }
            // A4 starts a segment; A5 indices restart at zero within that segment.
            try channel.send(ControllerCommand.frame(0xa4, payload: [snapshot.slot, UInt8(index), 1, 20]))
            _ = try response(0xa4)
            try channel.send(ControllerCommand.frame(0xa5, payload: [0] + edited.bytes[range]))
            _ = try response(0xa5)
        }
        guard try read(slot: snapshot.slot) == edited else { throw ControllerProtocolError.verification }
        guard try activeSlot() == snapshot.slot, try identity() == snapshot.identity else {
            throw ControllerProtocolError.conflict
        }
        var expected = edited
        if persist {
            let version = original.dataVersion &+ 1
            try channel.send(ControllerCommand.frame(0xa6, payload: [UInt8(truncatingIfNeeded: version), UInt8(version >> 8)]))
            _ = try response(0xa6, timeout: 12)
            expected.setDataVersion(version)
        }
        let result = try readActive()
        guard result.identity == snapshot.identity, result.slot == snapshot.slot,
              try result.profile() == expected else { throw ControllerProtocolError.verification }
        return result
    }
}
