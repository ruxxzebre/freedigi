import Foundation

/// Input monitoring starts with a read-only identity query (0x01). A late reply is
/// retried a bounded number of times, each on a freshly opened channel so a stale
/// session never carries over. Stream setup commands are sent only after success
/// and are never retried here.
public enum ControllerMonitorStartup {
    public static let maximumAttempts = 3

    /// Returns nil when cancelled between attempts.
    public static func handshake<Channel: ControllerChannel>(
        cancelled: () -> Bool = { false },
        waitBeforeRetry: () -> Void = { Thread.sleep(forTimeInterval: 0.2) },
        identify: (Channel) throws -> ControllerIdentity = { try ControllerProfileClient(channel: $0, operation: "starting input monitoring").identity() },
        open: () throws -> Channel
    ) throws -> (channel: Channel, identity: ControllerIdentity)? {
        let start = ProcessInfo.processInfo.systemUptime
        for number in 1...maximumAttempts {
            if cancelled() { return nil }
            do {
                let channel = try open()
                let identity = try identify(channel)
                if number > 1 {
                    ControllerDiagnostics.shared.record("Monitor handshake", stage: "completed",
                        message: "Identity answered on attempt \(number)/\(maximumAttempts).",
                        elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                return (channel, identity)
            } catch {
                let retryable: Bool
                if case ControllerProtocolError.timeout = error { retryable = true }
                else if let failure = error as? ControllerProfileFailure { retryable = !failure.writesAttempted }
                else { retryable = false }
                let again = retryable && number < maximumAttempts && !cancelled()
                ControllerDiagnostics.shared.record("Monitor handshake", stage: again ? "retrying" : "failed",
                    message: "Attempt \(number)/\(maximumAttempts): \(error)",
                    elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
                guard again else {
                    if cancelled() { return nil }
                    throw error
                }
                waitBeforeRetry()
            }
        }
        preconditionFailure("Final attempt returns or throws")
    }
}
