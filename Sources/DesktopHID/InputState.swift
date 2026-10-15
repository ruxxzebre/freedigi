import Foundation
import ControllerProtocol

public struct InputState: Codable, Equatable, Sendable {
    public let buttons: [Int]
    public let leftX: Double, leftY: Double, rightX: Double, rightY: Double
    public let leftTrigger: Double, rightTrigger: Double
    public static func parse(_ report: [UInt8]) -> InputState? {
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
    public var color: String {
        guard let config = Vader5Protocol.parseLightingConfiguration(bytes), let c = config.colors.first else { return "#0074ff" }
        return String(format: "#%02x%02x%02x", c.red, c.green, c.blue)
    }
    public var brightness: Int { bytes.count > 6 ? Int(bytes[6]) : 0 }
    public var mode: Int { bytes.count > 8 ? Int(bytes[8]) : 0 }
    public func plan(color: String, brightness: Int, off: Bool) throws -> [[UInt8]] {
        guard color.count == 7, color.first == "#", let rgb = UInt32(color.dropFirst(), radix: 16), (0...100).contains(brightness) else {
            throw ControllerProtocolError.invalid("Invalid lighting color or brightness.")
        }
        let value = Vader5LightingConfiguration(mode: off ? .off : .steady,
            colors: [.init(red: UInt8((rgb >> 16) & 255), green: UInt8((rgb >> 8) & 255), blue: UInt8(rgb & 255))], brightness: UInt8(brightness))
        guard let reports = Vader5Protocol.lightingPackets(basedOn: bytes, configuration: value) else {
            throw ControllerProtocolError.invalid("Unsupported lighting format.")
        }
        return reports
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
