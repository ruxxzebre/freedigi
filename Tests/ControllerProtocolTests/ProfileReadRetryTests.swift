import XCTest
@testable import ControllerProtocol

final class ProfileReadRetryTests: XCTestCase {
    private func snapshot() throws -> ControllerProfileSnapshot {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vader5-default-sdk", withExtension: "bin", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: url)
        return try .init(identity: .init(deviceID: 130, address: [0, 0, 0, 0], connection: 0), slot: 0,
                         profile: ControllerProfile(bytes: Array(bytes)))
    }

    func testSuccessOnFifthAttempt() throws {
        let expected = try snapshot()
        var calls = 0
        var waits = 0
        let result = try ControllerProfileReadRetry.read(waitBeforeRetry: { waits += 1 }) {
            calls += 1
            if calls < 5 { throw ControllerProtocolError.timeout }
            return expected
        }
        XCTAssertEqual(result, expected)
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(waits, 4)
    }

    func testFailureStopsAtFiveAndPropagatesLastError() {
        var calls = 0
        var waits = 0
        XCTAssertThrowsError(try ControllerProfileReadRetry.read(waitBeforeRetry: { waits += 1 }) {
            calls += 1
            throw ControllerProtocolError.timeout
        }) { error in
            guard case ControllerProtocolError.timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(waits, 4)
    }

    func testValidationAndConflictDoNotRetry() {
        for failure in [ControllerProtocolError.invalid("Unsupported profile"), .conflict, .verification] {
            var calls = 0
            XCTAssertThrowsError(try ControllerProfileReadRetry.read(waitBeforeRetry: { XCTFail("Should not wait") }) {
                calls += 1
                throw failure
            })
            XCTAssertEqual(calls, 1)
        }
    }

    func testTransientTransportFailureAndFirstAttemptSuccess() throws {
        enum TransportFailure: Error { case busy }
        let expected = try snapshot()
        var calls = 0
        let result = try ControllerProfileReadRetry.read(retryTransportError: { $0 is TransportFailure }, waitBeforeRetry: {}) {
            calls += 1
            if calls == 1 { throw TransportFailure.busy }
            return expected
        }
        XCTAssertEqual(result, expected)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try ControllerProfileReadRetry.read(waitBeforeRetry: { XCTFail("Should not wait") }) { expected }, expected)
    }
}
