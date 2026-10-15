import Foundation

/// Only standalone setting reads belong here. Each attempt opens a fresh channel;
/// writes and their verification reads must never be replayed by this helper.
public enum ControllerSettingReadRetry {
    public static func read<T>(action: String,
        waitBeforeRetry: () -> Void = { Thread.sleep(forTimeInterval: 0.2) },
        attempt: () throws -> T
    ) throws -> T {
        for number in 1...3 {
            do { return try attempt() }
            catch {
                let retryable: Bool
                if case ControllerProtocolError.timeout = error { retryable = true }
                else if let failure = error as? ControllerProfileFailure { retryable = !failure.writesAttempted }
                else { retryable = false }
                let retry = retryable && number < 3
                ControllerDiagnostics.shared.record(action, stage: retry ? "retrying read" : "read failed",
                    message: "Attempt \(number)/3: \(error)")
                guard retry else { throw error }
                waitBeforeRetry()
            }
        }
        preconditionFailure("Final attempt returns or throws")
    }
}
