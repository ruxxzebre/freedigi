import Foundation

public struct ControllerTurboSetting: Equatable, Codable, Sendable {
    public let identity: ControllerIdentity
    public let supported: Bool
    public let enabled: Bool

    public func reports(enabling requested: Bool) throws -> [[UInt8]] {
        try identity.requireVader5()
        guard supported else {
            throw ControllerProtocolError.invalid("This firmware does not advertise Turbo button features.")
        }
        return enabled == requested ? [] : [ControllerCommand.frame(0x13, payload: [4, requested ? 1 : 0])]
    }
}

public struct ControllerTurboFailure: Error, CustomStringConvertible, Sendable {
    public let phase: String
    public let command: UInt8
    public let writeAttempted: Bool

    public var description: String {
        let exposure = writeAttempted
            ? "The Turbo setting may have changed. Read it again before retrying."
            : "No Turbo-setting write was sent."
        return "Controller response timed out during \(phase) (command \(String(format: "0x%02X", command))). \(exposure)"
    }
}

/// Global Turbo-button feature gate, shared across profiles. Space Station 4.2.0.9
/// binds turbo_mapping_title to MappingSwitchEnabled / EnableMappingSwitch.
/// Engine 5.0.1.6 uses status bit 3 and command 0x13, subcommand 4.
/// This does not assign rapid fire to an individual button.
public final class ControllerTurboClient {
    private let channel: any ControllerChannel
    private var phase = "reading the Turbo setting"
    private var writeAttempted = false
    private let operationID = UUID()
    public init(channel: any ControllerChannel) { self.channel = channel }

    private func response(_ command: UInt8, subcommand: UInt8? = nil) throws -> [UInt8] {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var unmatched = 0
        var headers: Set<String> = []
        do {
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw ControllerProtocolError.timeout }
                let report = try channel.receive(timeout: remaining)
                if ControllerCommand.matches(report, command),
                   subcommand == nil || (report.count > 5 && report[5] == subcommand) {
                    return report
                }
                unmatched += 1
                if headers.count < 8, report.count >= 3 {
                    var header = String(format: "command 0x%02X", report[2])
                    if report.count > 5 { header += String(format: ", byte 5: 0x%02X", report[5]) }
                    headers.insert(header)
                }
            }
        } catch ControllerProtocolError.timeout {
            let failure = ControllerTurboFailure(phase: phase, command: command, writeAttempted: writeAttempted)
            ControllerDiagnostics.shared.record("Turbo response", stage: "timeout",
                message: "\(failure) Unmatched reports: \(unmatched); headers: \(headers.sorted().joined(separator: "; ")).",
                operationID: operationID)
            throw failure
        }
    }

    private func readIdentity() throws -> ControllerIdentity {
        do { return try ControllerProfileClient(channel: channel).identity() }
        catch let failure as ControllerProfileFailure {
            throw ControllerTurboFailure(phase: phase, command: failure.command, writeAttempted: writeAttempted)
        }
    }

    public func read() throws -> ControllerTurboSetting {
        writeAttempted = false
        phase = "reading the Turbo setting"
        return try readSetting()
    }

    private func readSetting() throws -> ControllerTurboSetting {
        ControllerDiagnostics.shared.record("Turbo setting", stage: "reading", message: phase, operationID: operationID)
        let identity = try readIdentity()
        try channel.send(ControllerCommand.frame(3))
        let report = try response(3)
        // The recovered status parser consumes fields through byte 12.
        guard report.count >= 13 else {
            throw ControllerProtocolError.invalid("Truncated hardware settings response.")
        }
        guard try readIdentity() == identity else { throw ControllerProtocolError.conflict }
        return .init(identity: identity, supported: report[5] & 0x08 != 0,
                     enabled: report[6] & 0x08 != 0)
    }

    public func setEnabled(_ enabled: Bool, replacing snapshot: ControllerTurboSetting) throws -> ControllerTurboSetting {
        writeAttempted = false
        phase = "checking the Turbo setting before writing"
        let current = try readSetting()
        guard current == snapshot else { throw ControllerProtocolError.conflict }
        guard let report = try current.reports(enabling: enabled).first else { return current }
        phase = "waiting for the Turbo write acknowledgement"
        ControllerDiagnostics.shared.record("Turbo setting", stage: "writing",
            message: "Command 0x13, subcommand 4, enabled: \(enabled).", operationID: operationID)
        writeAttempted = true
        try channel.send(report)
        do {
            _ = try response(0x13, subcommand: 4)
            phase = "verifying the Turbo setting after writing"
            let result = try readSetting()
            guard matches(result, current: current, enabled: enabled) else {
                throw ControllerProtocolError.invalid("Turbo button readback did not match. Read the setting again before retrying.")
            }
            return result
        } catch let failure as ControllerTurboFailure {
            // A lost ACK does not establish a failed write. Check the same
            // device once without repeating any setting-write command.
            phase = "read-only recovery after the Turbo apply timeout"
            ControllerDiagnostics.shared.record("Turbo recovery", stage: "started",
                message: "\(failure) Checking readback; no write will be repeated.", operationID: operationID)
            do {
                let recovered = try readSetting()
                if matches(recovered, current: current, enabled: enabled) {
                    ControllerDiagnostics.shared.record("Turbo recovery", stage: "verified",
                        message: "Requested setting confirmed on the same controller despite the timeout. No write repeated.",
                        operationID: operationID)
                    return recovered
                }
                ControllerDiagnostics.shared.record("Turbo recovery", stage: "unverified",
                    message: "Readback did not confirm the requested setting on the same controller.", operationID: operationID)
            } catch {
                ControllerDiagnostics.shared.record("Turbo recovery", stage: "failed",
                    message: String(describing: error), operationID: operationID)
            }
            throw failure
        }
    }

    private func matches(_ result: ControllerTurboSetting, current: ControllerTurboSetting, enabled: Bool) -> Bool {
        result.identity == current.identity && result.supported && result.enabled == enabled
    }
}
