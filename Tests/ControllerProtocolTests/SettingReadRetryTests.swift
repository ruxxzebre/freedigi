import XCTest
@testable import ControllerProtocol

final class SettingReadRetryTests: XCTestCase {
    func testTransientTimeoutRecoversWithinBoundAndPermanentTimeoutStops() throws {
        var attempts = 0
        let result: Int = try ControllerSettingReadRetry.read(action: "lightingRead", waitBeforeRetry: {}) {
            attempts += 1
            if attempts < 3 { throw ControllerProtocolError.timeout }
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(attempts, 3)
        attempts = 0
        XCTAssertThrowsError(try ControllerSettingReadRetry.read(action: "lightingRead", waitBeforeRetry: {}) { () -> Int in
            attempts += 1
            throw ControllerProtocolError.timeout
        })
        XCTAssertEqual(attempts, 3)
    }
    func testConflictAndUncertainWriteAreNeverRetried() {
        for error: Error in [ControllerProtocolError.conflict,
            ControllerProfileFailure(phase: "verification", command: 1, writesAttempted: true)] {
            var attempts = 0
            XCTAssertThrowsError(try ControllerSettingReadRetry.read(action: "lightingRead", waitBeforeRetry: {}) { () -> Int in
                attempts += 1
                throw error
            })
            XCTAssertEqual(attempts, 1)
        }
    }
    func testIdentityTimeoutUsesCallingOperationWithoutFalseWriteClaim() {
        final class Channel: ControllerChannel {
            func send(_ bytes: [UInt8]) throws {}
            func receive(timeout: TimeInterval) throws -> [UInt8] { throw ControllerProtocolError.timeout }
        }
        XCTAssertThrowsError(try ControllerProfileClient(channel: Channel(), operation: "checking lighting identity").identity()) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("checking lighting identity"))
            XCTAssertTrue(message.contains("0x01"))
            XCTAssertFalse(message.contains("profile"))
            XCTAssertFalse(message.contains("No"))
        }
    }
}
