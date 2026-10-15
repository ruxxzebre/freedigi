import Foundation
import ControllerProtocol

public struct InputState: Codable, Equatable, Sendable {
    public let buttons: [Int]
    public let leftX: Double, leftY: Double, rightX: Double, rightY: Double
    public let leftTrigger: Double, rightTrigger: Double
    public static func parse(_ report: [UInt8]) -> InputState? {
        if report.count >= 32, report[0] == 4, report[1] == 0xfe {
            var buttons = Set<Int>()
            for (bit, id) in [16, 17, 18, 19, 20, 21].enumerated() where report[7] & (1 << bit) != 0 { buttons.insert(id) }
            for (bit, id) in [0, 1, 2, 3, 4, 5, 6, 7].enumerated() where report[9] & (1 << bit) != 0 { buttons.insert(id) }
            for (bit, id) in [8, 9, 10, 11, 12, 13, 14, 15].enumerated() where report[10] & (1 << bit) != 0 { buttons.insert(id) }
            if report[8] & 8 != 0 { buttons.insert(32) }
            func axis(_ value: UInt8) -> Double { let n = Double(value) - 127; return n / (n < 0 ? 127 : 128) }
            return .init(buttons: buttons.sorted(), leftX: axis(report[17]), leftY: -axis(report[19]),
                         rightX: axis(report[21]), rightY: -axis(report[22]),
                         leftTrigger: Double(report[23])/255, rightTrigger: Double(report[24])/255)
        }
        guard let state = Vader5Protocol.parse(report) else { return nil }
        var input = ControllerMappingInput()
        _ = input.update(buttonBits: state.buttons.rawValue, dpad: state.dpad,
                         leftTrigger: state.leftTrigger, rightTrigger: state.rightTrigger)
        return .init(buttons: input.held.sorted(), leftX: Double(state.leftX)/32768, leftY: Double(state.leftY)/32768,
                     rightX: Double(state.rightX)/32768, rightY: Double(state.rightY)/32768,
                     leftTrigger: Double(state.leftTrigger)/255, rightTrigger: Double(state.rightTrigger)/255)
    }
}

public struct Vader5FirmwareVersions: Codable, Sendable, Equatable {
    public let main: String?, rf: String?, si: String?, dongle: String?
}

public struct LightingSnapshot: Codable, Sendable {
    public let identity: ControllerIdentity
    public let bytes: [UInt8]
    public let slot: UInt8?
    public init(identity: ControllerIdentity, bytes: [UInt8], slot: UInt8? = nil) {
        self.identity = identity; self.bytes = bytes; self.slot = slot
    }
    public var color: String {
        if identity.isVader4, bytes.count == 500 {
            let rgb = bytes[20..<23].map { min(255, Int($0) * 255 / 100) }
            return String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2])
        }
        guard let config = Vader5Protocol.parseLightingConfiguration(bytes), let c = config.colors.first else { return "#0074ff" }
        return String(format: "#%02x%02x%02x", c.red, c.green, c.blue)
    }
    public var brightness: Int { bytes.count > 6 ? Int(bytes[6]) : 0 }
    public var mode: Int {
        if identity.isVader4, bytes.count > 8, bytes[8] == 0 || bytes[8] == 6 || bytes[6] == 0 { return 6 }
        return bytes.count > 8 ? Int(bytes[8]) : 0
    }
    public func plan(color: String, brightness: Int, off: Bool) throws -> [[UInt8]] {
        guard color.count == 7, color.first == "#", let rgb = UInt32(color.dropFirst(), radix: 16), (0...100).contains(brightness) else {
            throw ControllerProtocolError.invalid("Invalid lighting color or brightness.")
        }
        if identity.isVader4 {
            try identity.requireVader4()
            try ClassicControllerProtocol.validateLighting(bytes)
            guard let slot, slot < 4 else { throw ControllerProtocolError.invalid("Classic lighting snapshot has no valid slot.") }
            var edited = bytes
            edited[2] = 0; edited[3] = 0; edited[4] = 0
            edited[6] = off ? 0 : UInt8(brightness); edited[8] = off ? 6 : 5
            if !off {
                let color: [UInt8] = [UInt8((rgb >> 16) & 255), UInt8((rgb >> 8) & 255), UInt8(rgb & 255)].map { UInt8(Int($0) * 100 / 255) }
                for group in 0..<Int(bytes[7]) {
                    for unit in 0..<10 {
                        let offset = 20 + group * 30 + unit * 3
                        edited.replaceSubrange(offset..<(offset + 3), with: color)
                    }
                }
            }
            return try ClassicControllerProtocol.packets(edited, slot: slot, lighting: true)
        }
        try identity.requireVader5()
        let value = Vader5LightingConfiguration(mode: off ? .off : .steady,
            colors: [.init(red: UInt8((rgb >> 16) & 255), green: UInt8((rgb >> 8) & 255), blue: UInt8(rgb & 255))], brightness: UInt8(brightness))
        guard let reports = Vader5Protocol.lightingPackets(basedOn: bytes, configuration: value) else {
            throw ControllerProtocolError.invalid("Unsupported lighting format.")
        }
        return reports
    }
    public static func readClassic(_ channel: any ControllerChannel) throws -> Self {
        let client = ClassicControllerClient(channel: channel)
        let identity = try client.info().identity, slot = try client.activeSlot()
        let bytes = try client.readBlob(slot: slot, lighting: true)
        guard try client.activeSlot() == slot, try client.info().identity == identity else { throw ControllerProtocolError.conflict }
        return .init(identity: identity, bytes: bytes, slot: slot)
    }
    public static func read(_ channel: any ControllerChannel) throws -> Self {
        let identity = try ControllerProfileClient(channel: channel, operation: "checking lighting identity").identity()
        try channel.send(Vader5Protocol.ledConfigReadCommand())
        var chunks: [Int: [UInt8]] = [:], total: Int?
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            let report = try channel.receive(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            guard let chunk = Vader5Protocol.parseLEDConfigChunk(report) else { continue }
            guard report[5] == 0, total == nil || total == chunk.total,
                  chunks[chunk.index] == nil || chunks[chunk.index] == chunk.bytes else { throw ControllerProtocolError.conflict }
            total = chunk.total; chunks[chunk.index] = chunk.bytes
        } while chunks.count != total
        let bytes = (0..<total!).flatMap { chunks[$0]! }
        guard Vader5Protocol.parseLightingConfiguration(bytes) != nil else { throw ControllerProtocolError.invalid("Unsupported lighting format.") }
        guard try ControllerProfileClient(channel: channel, operation: "checking lighting identity").identity() == identity else { throw ControllerProtocolError.conflict }
        return .init(identity: identity, bytes: bytes)
    }
    public func apply(_ channel: any ControllerChannel, reports: [[UInt8]]) throws -> Self {
        if identity.isVader4 {
            let current = try Self.readClassic(channel)
            guard current.identity == identity, current.slot == slot, current.bytes == bytes, let slot else { throw ControllerProtocolError.conflict }
            guard !reports.isEmpty, reports.allSatisfy({ $0.count == 14 }) else { throw ControllerProtocolError.invalid("Malformed classic lighting packets.") }
            let expected = reports.dropFirst().flatMap { Array($0[2..<12]) }
            guard try ClassicControllerProtocol.packets(expected, slot: slot, lighting: true) == reports else { throw ControllerProtocolError.invalid("Invalid classic lighting plan.") }
            let client = ClassicControllerClient(channel: channel)
            do {
                try client.write(reports, identity: identity)
                let result = try Self.readClassic(channel)
                guard result.identity == identity, result.slot == slot, result.bytes == expected else { throw ControllerProtocolError.verification }
                return result
            } catch ControllerProtocolError.timeout {
                guard client.writesAttempted else { throw ControllerProtocolError.timeout }
                throw ControllerProtocolError.invalid("Classic lighting write timed out; its result is uncertain. No writes were replayed. Read lighting before another apply.")
            }
        }
        let current = try Self.read(channel)
        guard current.identity == identity, current.bytes == bytes else { throw ControllerProtocolError.conflict }
        for report in reports {
            try channel.send(report)
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while true {
                let response = try channel.receive(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
                if ControllerCommand.matches(response, report[2]) { break }
            }
        }
        let result = try Self.read(channel)
        let expected = reports.dropFirst().flatMap { Array($0[5..<(5 + Int($0[3]) - 3)]) }
        guard result.identity == identity, Array(result.bytes.prefix(expected.count)) == expected else { throw ControllerProtocolError.verification }
        return result
    }
}
