import Foundation

extension ControllerIdentity {
    public var isVader4: Bool { [85, 91, 105].contains(deviceID) }
    public func requireVader4() throws {
        guard isVader4, address.count == 4 else {
            throw ControllerProtocolError.invalid("Classic device ID \(deviceID) is not a supported Vader 4 Pro variant.")
        }
    }
}

/// Experimental DInput protocol. These commands deliberately do not share the
/// Vader 5 command framing or its authorization gate. USB IDs alone are not identity.
public enum ClassicControllerProtocol {
    public static func command(_ command: UInt8, _ arguments: [UInt8] = []) -> [UInt8] {
        precondition(arguments.count <= 10)
        let bytes: [UInt8] = [5, command] + arguments
        return bytes + Array(repeating: 0, count: 12 - bytes.count)
    }
    public static func info(_ report: [UInt8]) -> (identity: ControllerIdentity, firmware: String)? {
        guard report.count >= 16, report[0] == 4, report[1] != 0xfe, report[15] == 0xec else { return nil }
        return (ControllerIdentity(deviceID: report[3], address: Array(report[5..<9]), connection: report[13]),
                "\(report[10] >> 4).\(report[10] & 15).\(report[9] >> 4).\(report[9] & 15)")
    }
    public static func tagged(_ report: [UInt8], _ command: UInt8) -> Bool {
        report.count >= 16 && report[0] == 4 && report[1] != 0xfe && report[15] == command
    }
    public static func validateProfile(_ bytes: [UInt8]) throws {
        // SDK parsers fix v3.0 at 79 parcels and v3.1 at 84; byte 2 is
        // legacy metadata, not a reliable transferred parcel count.
        guard (bytes.count == 790 && Array(bytes.prefix(2)) == [0, 3]) ||
              (bytes.count == 840 && Array(bytes.prefix(2)) == [1, 3]) else {
            throw ControllerProtocolError.invalid("Unsupported classic profile: expected complete 790-byte v3.0 or 840-byte v3.1 layout; received \(bytes.count) bytes, header \(Array(bytes.prefix(3))). No writes allowed.")
        }
    }
    public static func validateLighting(_ bytes: [UInt8]) throws {
        guard bytes.count == 500, Array(bytes.prefix(2)) == [0, 2], (1...16).contains(bytes[7]), bytes[6] <= 100 else {
            throw ControllerProtocolError.invalid("Unsupported classic lighting: expected complete 500-byte v2.0 layout.")
        }
    }
    public static func packets(_ bytes: [UInt8], slot: UInt8, lighting: Bool = false) throws -> [[UInt8]] {
        guard slot < 4 else { throw ControllerProtocolError.invalid("Unsupported classic profile slot.") }
        if lighting { try validateLighting(bytes) } else { try validateProfile(bytes) }
        let count = bytes.count / 10
        var header: [UInt8] = lighting ? [5, 0xe7, slot, UInt8(count)] : [5, 0xea, UInt8(count), 0xa0, slot]
        header += Array(repeating: 0, count: 14 - header.count)
        let command: UInt8 = lighting ? 0x33 : 0x22
        let parcels: [[UInt8]] = (0..<count).map { index in
            var packet: [UInt8] = [5, command]
            packet += bytes[(index * 10)..<(index * 10 + 10)]
            packet += [0xa0, UInt8(index)]
            return packet
        }
        return [header] + parcels
    }
    public static func profilePlan(_ edited: ControllerProfile, replacing snapshot: ControllerProfileSnapshot, persist: Bool) throws -> [[UInt8]] {
        try snapshot.identity.requireVader4()
        let original = try snapshot.profile()
        try validateProfile(edited.bytes)
        guard edited.bytes.prefix(3) == original.bytes.prefix(3), edited.dataVersion == original.dataVersion else {
            throw ControllerProtocolError.invalid("Classic profile layout or version changed.")
        }
        var plan = try packets(edited.bytes, slot: snapshot.slot)
        if persist {
            plan.append(randomQuery(slot: snapshot.slot))
            plan.append(save(version: original.dataVersion &+ 1))
        }
        return plan
    }
    public static func randomQuery(slot: UInt8) -> [UInt8] {
        command(0x50, [2, slot, UInt8(5) &+ 0x50 &+ 2 &+ slot])
    }
    public static func save(version: UInt16) -> [UInt8] {
        let high = UInt8(version >> 8), low = UInt8(truncatingIfNeeded: version)
        return command(0x50, [3, low, high, UInt8(5) &+ 0x50 &+ 3 &+ high &+ low])
    }
    public static func ack(_ report: [UInt8], for packet: [UInt8]) -> Bool {
        guard packet.count == 14, report.count >= 16, report[0] == 4, report[1] != 0xfe else { return false }
        let command = packet[1]
        guard [0xea, 0x22, 0xe7, 0x33].contains(command) else { return false }
        let header = command == 0xea || command == 0xe7
        let family: Set<UInt8> = (command == 0xea || command == 0x22) ? [0xea, 0x22] : [0xe7, 0x33]
        return family.contains(report[15]) && report[3] == (header ? 255 : packet[13] + 1)
    }
}

/// Rejects missing, conflicting or out-of-range parcels. Identical duplicates and
/// out-of-order delivery are allowed, but no unsupported layout is truncated.
public struct ClassicBlobAssembler {
    private let lighting: Bool
    private var parcels: [Int: [UInt8]] = [:]
    public init(lighting: Bool = false) { self.lighting = lighting }
    private var count: Int? {
        if lighting { return 50 }
        guard let first = parcels[0] else { return nil }
        return first[0] == 0 ? 79 : 84
    }
    public var complete: Bool { count != nil && parcels.count == count }
    public mutating func add(_ report: [UInt8]) throws {
        guard ClassicControllerProtocol.tagged(report, lighting ? 0xe5 : 0xeb) else {
            throw ControllerProtocolError.invalid("Malformed classic blob parcel.")
        }
        let index = Int(report[3]), data = Array(report[5..<15])
        guard index < (count ?? 84) else { throw ControllerProtocolError.invalid("Unsupported classic blob length; refusing to truncate.") }
        if index == 0 {
            guard lighting ? Array(data.prefix(2)) == [0, 2] : (data[1] == 3 && data[0] <= 1) else {
                throw ControllerProtocolError.invalid("Unsupported classic blob header \(Array(data.prefix(3))); expected v3.0 or v3.1 profile / v2.0 lighting.")
            }
        }
        guard parcels[index] == nil || parcels[index] == data else { throw ControllerProtocolError.invalid("Conflicting classic parcels; read again.") }
        parcels[index] = data
        if let count, parcels.keys.contains(where: { $0 >= count }) {
            throw ControllerProtocolError.invalid("Classic parcels exceed version-defined length; refusing to truncate.")
        }
    }
    public func bytes() throws -> [UInt8] {
        guard complete else { throw ControllerProtocolError.invalid("Incomplete classic blob.") }
        let bytes = (0..<parcels.count).flatMap { parcels[$0]! }
        if lighting { try ClassicControllerProtocol.validateLighting(bytes) } else { try ClassicControllerProtocol.validateProfile(bytes) }
        return bytes
    }
}

public final class ClassicControllerClient {
    private let channel: any ControllerChannel
    public private(set) var writesAttempted = false
    public init(channel: any ControllerChannel) { self.channel = channel }
    private func response(timeout: TimeInterval = 2, matching: ([UInt8]) -> Bool) throws -> [UInt8] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ControllerProtocolError.timeout }
            let report = try channel.receive(timeout: remaining)
            if matching(report) { return report }
        }
    }
    public func info() throws -> (identity: ControllerIdentity, firmware: String) {
        ControllerDiagnostics.shared.record("Classic identity", stage: "request", message: "Query EC; validating Vader 4 model ID.")
        try channel.send(ClassicControllerProtocol.command(0xec))
        let report = try response { ClassicControllerProtocol.tagged($0, 0xec) }
        guard let info = ClassicControllerProtocol.info(report) else { throw ControllerProtocolError.invalid("Malformed classic identity.") }
        try info.identity.requireVader4()
        return info
    }
    public func activeSlot() throws -> UInt8 {
        ControllerDiagnostics.shared.record("Classic slot", stage: "request", message: "Query EB A0; no default slot on timeout.")
        try channel.send(ClassicControllerProtocol.command(0xeb, [0xa0]))
        let report = try response {
            guard $0.count >= 6, $0[0] == 4, $0[1] != 0xfe else { return false }
            return ($0[1] == 0xeb && $0[2] == 0xa0) || ($0[3] == 0xaa && $0[4] == 0xac)
        }
        let slot = report[1] == 0xeb ? report[3] : report[5]
        guard slot < 4 else { throw ControllerProtocolError.invalid("Select a classic PC profile (1–4).") }
        return slot
    }
    /// A fixed window, not a wait-for-silence loop: live input may be continuous.
    private func drain() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.04
        while ProcessInfo.processInfo.systemUptime < deadline {
            do { _ = try channel.receive(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) }
            catch ControllerProtocolError.timeout { return }
        }
    }
    public func readBlob(slot: UInt8, lighting: Bool = false) throws -> [UInt8] {
        guard slot < 4 else { throw ControllerProtocolError.invalid("Unsupported classic slot.") }
        try drain()
        let command: UInt8 = lighting ? 0xe5 : 0xeb
        try channel.send(ClassicControllerProtocol.command(command, [slot]))
        ControllerDiagnostics.shared.record("Classic blob", stage: "request", message: "Read \(lighting ? "E5 lighting" : "EB profile") slot \(slot + 1).")
        var assembler = ClassicBlobAssembler(lighting: lighting)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !assembler.complete {
            let report = try response(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) { ClassicControllerProtocol.tagged($0, command) }
            try assembler.add(report)
        }
        // Inspect trailing duplicates as well: silently discarding an extension
        // would turn an unsupported profile into a writable truncated profile.
        let tailDeadline = ProcessInfo.processInfo.systemUptime + 0.04
        while ProcessInfo.processInfo.systemUptime < tailDeadline {
            do {
                let report = try channel.receive(timeout: max(0, tailDeadline - ProcessInfo.processInfo.systemUptime))
                if ClassicControllerProtocol.tagged(report, command) { try assembler.add(report) }
            } catch ControllerProtocolError.timeout { break }
        }
        let bytes = try assembler.bytes()
        ControllerDiagnostics.shared.record("Classic blob", stage: "received", message: "Received \(bytes.count / 10) parcels; header \(Array(bytes.prefix(3))).")
        return bytes
    }
    public func readActive() throws -> ControllerProfileSnapshot {
        let identity = try info().identity, slot = try activeSlot()
        // The first config read after an LED read can contain a stale slot.
        _ = try readBlob(slot: slot)
        let profile = try ControllerProfile(bytes: readBlob(slot: slot))
        guard try activeSlot() == slot, try info().identity == identity else { throw ControllerProtocolError.conflict }
        return .init(identity: identity, slot: slot, profile: profile)
    }
    public func write(_ packets: [[UInt8]], identity: ControllerIdentity) throws {
        writesAttempted = false
        try identity.requireVader4()
        guard let header = packets.first, header.count == 14, [0xea, 0xe7].contains(header[1]),
              packets.allSatisfy({ $0.count == 14 }) else { throw ControllerProtocolError.invalid("Invalid classic write plan.") }
        let lighting = header[1] == 0xe7, slot = header[header[1] == 0xe7 ? 2 : 4]
        let blob = packets.dropFirst().flatMap { Array($0[2..<12]) }
        guard try ClassicControllerProtocol.packets(blob, slot: slot, lighting: lighting) == packets else {
            throw ControllerProtocolError.invalid("Invalid classic write parcels.")
        }
        // A receiver can reconnect to another supported controller between the
        // snapshot read and this query. Model membership alone is insufficient.
        guard try info().identity == identity, try activeSlot() == slot else {
            throw ControllerProtocolError.conflict
        }
        ControllerDiagnostics.shared.record("Classic write", stage: "started", message: "Writing \(packets.count - 1) \(lighting ? "lighting" : "profile") parcels to slot \(slot + 1); indexed acknowledgements required.")
        for packet in packets {
            writesAttempted = true
            try channel.send(packet)
            _ = try response { ClassicControllerProtocol.ack($0, for: packet) }
        }
    }
    public func apply(_ edited: ControllerProfile, replacing snapshot: ControllerProfileSnapshot, persist: Bool) throws -> ControllerProfileSnapshot {
        writesAttempted = false
        let plan = try ClassicControllerProtocol.profilePlan(edited, replacing: snapshot, persist: persist)
        guard try readActive() == snapshot else { throw ControllerProtocolError.conflict }
        do {
            try write(Array(plan.prefix(edited.bytes.count / 10 + 1)), identity: snapshot.identity)
            guard try readActive() == ControllerProfileSnapshot(identity: snapshot.identity, slot: snapshot.slot, profile: edited) else { throw ControllerProtocolError.verification }
            var expected = edited
            if persist {
                try channel.send(ClassicControllerProtocol.randomQuery(slot: snapshot.slot))
                let random = try response { $0.count >= 8 && $0[0] == 4 && $0[1] != 0xfe && $0[3] == 0x50 && $0[4] == 2 }
                let version = UInt16(random[5]) | UInt16(random[6]) << 8
                guard random[7] == snapshot.slot, version == edited.dataVersion,
                      try activeSlot() == snapshot.slot, try info().identity == snapshot.identity else { throw ControllerProtocolError.conflict }
                ControllerDiagnostics.shared.record("Classic save", stage: "started", message: "Temporary profile verified; saving version \(version &+ 1) to flash.")
                try channel.send(ClassicControllerProtocol.save(version: version &+ 1))
                let saved = try response(timeout: 12) { $0.count >= 6 && $0[0] == 4 && $0[1] != 0xfe && $0[3] == 0x50 && $0[4] == 3 }
                guard saved[5] == 1 else { throw ControllerProtocolError.verification }
                expected.setDataVersion(version &+ 1)
            }
            let result = try readActive()
            guard result == ControllerProfileSnapshot(identity: snapshot.identity, slot: snapshot.slot, profile: expected) else { throw ControllerProtocolError.verification }
            return result
        } catch ControllerProtocolError.timeout {
            guard writesAttempted else { throw ControllerProtocolError.timeout }
            throw ControllerProtocolError.invalid("Classic write timed out; its result is uncertain. No writes were replayed. Read the profile before another apply.")
        }
    }
}
