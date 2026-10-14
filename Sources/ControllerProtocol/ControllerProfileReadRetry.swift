import Foundation

/// Only for an explicit, read-only profile refresh. Never wrap apply/save or
/// their verification reads in this helper: retrying a write is not equivalent.
public enum ControllerProfileReadRetry {
    public static let maximumAttempts = 5

    public static func read(
        retryTransportError: (Error) -> Bool = { _ in false },
        waitBeforeRetry: () -> Void = { Thread.sleep(forTimeInterval: 0.2) },
        attempt: () throws -> ControllerProfileSnapshot
    ) throws -> ControllerProfileSnapshot {
        let operationID = UUID()
        for number in 1...maximumAttempts {
            ControllerDiagnostics.shared.record("Profile read attempt", stage: "started",
                message: "Attempt \(number)/\(maximumAttempts).", operationID: operationID)
            do {
                let snapshot = try attempt()
                ControllerDiagnostics.shared.record("Profile read attempt", stage: "completed",
                    message: "Attempt \(number) succeeded.", operationID: operationID)
                return snapshot
            } catch {
                let retry: Bool
                if case ControllerProtocolError.timeout = error { retry = true }
                else { retry = retryTransportError(error) }
                let again = retry && number < maximumAttempts
                ControllerDiagnostics.shared.record("Profile read attempt", stage: again ? "retrying" : "failed",
                    message: "Attempt \(number): \(error)", operationID: operationID)
                guard again else { throw error }
                waitBeforeRetry()
            }
        }
        preconditionFailure("The last attempt must return or throw")
    }
}
