import Foundation

/// Reconciles each interrupted apply against a fresh read before issuing further
/// writes. Unknown changes abort instead of overwriting another editor/device.
public enum ControllerProfileWriteRetry {
    public static let maximumAttempts = 5

    public static func apply(
        _ edited: ControllerProfile, replacing original: ControllerProfileSnapshot, persist: Bool,
        retryTransportError: (Error) -> Bool = { _ in false },
        waitBeforeRetry: () -> Void = { Thread.sleep(forTimeInterval: 0.2) },
        makeChannel: () throws -> any ControllerChannel
    ) throws -> ControllerProfileSnapshot {
        let before = try original.profile()
        _ = try edited.writeReports(replacing: before, slot: original.slot, persist: persist)
        let operationID = UUID()
        var wrote = false
        var allowedVersions: Set<UInt16> = [before.dataVersion]
        var acknowledgedVersion: UInt16?

        // Scope the client here so each failed session closes before retrying.
        func attempt() throws -> ControllerProfileSnapshot {
            let client = ControllerProfileClient(channel: try makeChannel())
            let current = try client.readActive()
            guard current.identity == original.identity, current.slot == original.slot else {
                throw ControllerProtocolError.conflict
            }
            let actual = try current.profile()
            if !wrote {
                guard current == original else { throw ControllerProtocolError.conflict }
            } else {
                guard actual.bytes.count == before.bytes.count, allowedVersions.contains(actual.dataVersion) else {
                    throw ControllerProtocolError.conflict
                }
                for index in actual.bytes.indices where index != 225 && index != 226 {
                    guard actual.bytes[index] == before.bytes[index] || actual.bytes[index] == edited.bytes[index] else {
                        throw ControllerProtocolError.conflict
                    }
                }
            }
            let requested = try actual.restoringContents(from: edited)
            if wrote, actual == requested, !persist || acknowledgedVersion == actual.dataVersion {
                ControllerDiagnostics.shared.record("Profile write recovery", stage: "verified",
                    message: persist ? "Save acknowledgment and full readback verified; no duplicate save needed."
                                     : "Requested temporary profile already present; no duplicate writes needed.", operationID: operationID)
                return current
            }
            defer {
                wrote = wrote || client.writesAttempted
                if client.saveAttempted {
                    allowedVersions = [actual.dataVersion, actual.dataVersion &+ 1]
                }
                if client.saveAcknowledged { acknowledgedVersion = actual.dataVersion &+ 1 }
            }
            // writeReports sends only remaining differences. If a save ACK was
            // lost, exact RAM readback alone cannot prove persistence: issue a
            // fresh save/version and require its ACK plus matching readback.
            return try client.apply(requested, replacing: current, persist: persist)
        }

        for number in 1...maximumAttempts {
            ControllerDiagnostics.shared.record("Profile write attempt", stage: "started",
                message: "Attempt \(number)/\(maximumAttempts); persist: \(persist). Read and reconcile before writing.", operationID: operationID)
            do {
                let result = try attempt()
                ControllerDiagnostics.shared.record("Profile write attempt", stage: "completed",
                    message: "Attempt \(number) verified.", operationID: operationID)
                return result
            } catch {
                let retry: Bool
                switch error {
                case is ControllerProfileFailure, ControllerProtocolError.timeout, ControllerProtocolError.verification:
                    retry = true
                default: retry = retryTransportError(error)
                }
                let again = retry && number < maximumAttempts
                ControllerDiagnostics.shared.record("Profile write attempt", stage: again ? "retrying" : "failed",
                    message: "Attempt \(number): \(error)", operationID: operationID)
                guard again else {
                    if let failure = error as? ControllerProfileFailure, wrote, !failure.writesAttempted {
                        throw ControllerProfileFailure(phase: failure.phase, command: failure.command, writesAttempted: true)
                    }
                    throw error
                }
                waitBeforeRetry()
            }
        }
        preconditionFailure("The last attempt must return or throw")
    }
}
