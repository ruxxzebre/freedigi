import Foundation

public struct ControllerCalibrationSetting: Equatable, Codable, Sendable {
    public let identity: ControllerIdentity
    public let supported: Bool
    public let enabled: Bool

    public func reports(enabling requested: Bool) throws -> [[UInt8]] {
        try identity.requireVader5()
        guard supported else {
            throw ControllerProtocolError.invalid("This firmware does not advertise automatic stick calibration.")
        }
        return enabled == requested ? [] : [ControllerCommand.frame(0x13, payload: [6, requested ? 1 : 0])]
    }
}

/// Legacy NewXInput global setting recovered from Engine 5.0.1.6's
/// ReadHardwareFunctionStatus / EnableJoystickAutoCalibration factories.
/// This is not the factory ADC calibration command or a profile field.
public final class ControllerCalibrationClient {
    private let channel: any ControllerChannel
    public init(channel: any ControllerChannel) { self.channel = channel }

    private func response(_ command: UInt8, subcommand: UInt8? = nil) throws -> [UInt8] {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ControllerProtocolError.timeout }
            let report = try channel.receive(timeout: remaining)
            guard ControllerCommand.matches(report, command) else { continue }
            if let subcommand {
                guard report.count > 5, report[5] == subcommand else { continue }
            }
            return report
        }
    }

    public func read() throws -> ControllerCalibrationSetting {
        let identityClient = ControllerProfileClient(channel: channel)
        let identity = try identityClient.identity()
        try channel.send(ControllerCommand.frame(3))
        let report = try response(3)
        // The recovered status parser consumes fields through byte 12.
        guard report.count >= 13 else {
            throw ControllerProtocolError.invalid("Truncated hardware settings response.")
        }
        guard try identityClient.identity() == identity else { throw ControllerProtocolError.conflict }
        return .init(identity: identity, supported: report[5] & 0x20 != 0,
                     enabled: report[6] & 0x20 != 0)
    }

    public func setEnabled(_ enabled: Bool, replacing snapshot: ControllerCalibrationSetting) throws -> ControllerCalibrationSetting {
        let current = try read()
        guard current == snapshot else { throw ControllerProtocolError.conflict }
        guard let report = try current.reports(enabling: enabled).first else { return current }
        try channel.send(report)
        _ = try response(0x13, subcommand: 6)
        let result = try read()
        guard result.identity == current.identity, result.supported, result.enabled == enabled else {
            throw ControllerProtocolError.invalid("Automatic calibration readback did not match. Read the setting again before retrying.")
        }
        return result
    }
}
