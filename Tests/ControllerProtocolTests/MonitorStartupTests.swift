import XCTest
@testable import ControllerProtocol

final class MonitorStartupTests: XCTestCase {
    /// Answers identity only when `answers` is true; records every frame sent.
    private final class Channel: ControllerChannel {
        let answers: Bool
        var sent: [[UInt8]] = []
        private var pending: [[UInt8]] = []
        init(answers: Bool) { self.answers = answers }
        func send(_ report: [UInt8]) throws {
            sent.append(report)
            if answers && ControllerCommand.matches(report, 1) {
                pending.append(ControllerCommand.frame(1, payload: [130, 1, 1, 2, 3, 4]))
            }
        }
        func receive(timeout: TimeInterval) throws -> [UInt8] {
            guard !pending.isEmpty else { throw ControllerProtocolError.timeout }
            return pending.removeFirst()
        }
    }

    func testFailedHandshakeRetriesOnFreshChannelThenSucceeds() throws {
        var opened: [Channel] = []
        let result = try ControllerMonitorStartup.handshake(waitBeforeRetry: {}) {
            let channel = Channel(answers: opened.count == 2)
            opened.append(channel)
            return channel
        }
        XCTAssertEqual(opened.count, 3)
        XCTAssertTrue(result?.channel === opened.last)
        XCTAssertEqual(result?.identity.deviceID, 130)
        // Only identity queries are sent during startup; stream setup belongs to the caller.
        XCTAssertTrue(opened.allSatisfy { $0.sent.allSatisfy { ControllerCommand.matches($0, 1) } })
    }

    func testPersistentTimeoutStopsAtBoundWithPhaseAndCommand() {
        var attempts = 0
        XCTAssertThrowsError(try ControllerMonitorStartup.handshake(waitBeforeRetry: {}) { () -> Channel in
            attempts += 1
            return Channel(answers: false)
        }) { error in
            XCTAssertTrue(String(describing: error).contains("starting input monitoring"))
            XCTAssertTrue(String(describing: error).contains("0x01"))
        }
        XCTAssertEqual(attempts, ControllerMonitorStartup.maximumAttempts)
    }

    func testCancellationStopsRetriesWithoutError() throws {
        var attempts = 0, cancelled = false
        let result = try ControllerMonitorStartup.handshake(cancelled: { cancelled },
            waitBeforeRetry: { cancelled = true }) { () -> Channel in
            attempts += 1
            return Channel(answers: false)
        }
        XCTAssertNil(result)
        XCTAssertEqual(attempts, 1)
    }

    func testOpenFailureIsNotRetried() {
        var attempts = 0
        XCTAssertThrowsError(try ControllerMonitorStartup.handshake(waitBeforeRetry: {}) { () -> Channel in
            attempts += 1
            throw ControllerProtocolError.invalid("Selected controller is no longer present. Refresh devices.")
        })
        XCTAssertEqual(attempts, 1)
    }
}
