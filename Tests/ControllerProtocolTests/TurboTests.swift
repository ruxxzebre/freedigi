import Foundation
import XCTest
@testable import ControllerProtocol

final class TurboTests: XCTestCase {
    func testReadAndVerifiedWritePreserveOtherFlags() throws {
        let channel = TurboController()
        let client = ControllerTurboClient(channel: channel)
        let before = try client.read()
        XCTAssertTrue(before.supported)
        XCTAssertFalse(before.enabled)
        let after = try client.setEnabled(true, replacing: before)
        XCTAssertTrue(after.enabled)
        XCTAssertEqual(channel.flags, 0x8d)
        // Independent wire vector from the recovered SDK (excluding report ID).
        XCTAssertEqual(channel.writes.map { Array($0.prefix(7)) }, [[0x5a, 0xa5, 0x13, 4, 4, 1, 0x1c]])
    }

    func testDisableAndPreviewPreserveUnrelatedFlags() throws {
        let channel = TurboController()
        channel.flags = 0xff
        let client = ControllerTurboClient(channel: channel)
        let before = try client.read()
        XCTAssertTrue(before.enabled)
        let reports = try before.reports(enabling: false)
        XCTAssertEqual(Array(try XCTUnwrap(reports.first).prefix(7)), [0x5a, 0xa5, 0x13, 4, 4, 0, 0x1b])
        XCTAssertTrue(channel.writes.isEmpty, "Preview must not send anything")
        let after = try client.setEnabled(false, replacing: before)
        XCTAssertFalse(after.enabled)
        XCTAssertEqual(channel.flags, 0xf7)
        XCTAssertEqual(channel.writes, reports)
    }

    func testUnsupportedStaleAndWrongDeviceNeverWrite() throws {
        for scenario in 0..<3 {
            let channel = TurboController()
            if scenario == 0 { channel.supported = false }
            let client = ControllerTurboClient(channel: channel)
            let before = try client.read()
            if scenario == 1 { channel.flags |= 0x08 }
            if scenario == 2 { channel.deviceID = 128 }
            XCTAssertThrowsError(try client.setEnabled(true, replacing: before))
            XCTAssertTrue(channel.writes.isEmpty)
        }
    }

    func testMissingAckOrWrongSubcommandRecoversByReadingWithoutRewriting() throws {
        for wrongSubcommand in [false, true] {
            let channel = TurboController()
            let client = ControllerTurboClient(channel: channel)
            let before = try client.read()
            channel.ack = wrongSubcommand
            channel.wrongSubcommand = wrongSubcommand
            XCTAssertTrue(try client.setEnabled(true, replacing: before).enabled)
            XCTAssertEqual(channel.writes.count, 1)
        }
    }

    func testLostVerificationReadRecoversWithoutRewriting() throws {
        let channel = TurboController()
        let client = ControllerTurboClient(channel: channel)
        let before = try client.read()
        channel.dropStatusAfterWrite = 1
        XCTAssertTrue(try client.setEnabled(true, replacing: before).enabled)
        XCTAssertEqual(channel.writes.count, 1)
    }

    func testRecoveryDoesNotClaimSuccessForUnchangedOrDifferentController() throws {
        for scenario in 0..<3 {
            let channel = TurboController()
            let client = ControllerTurboClient(channel: channel)
            let before = try client.read()
            channel.ack = false
            channel.acceptWrite = scenario != 0
            channel.changeIdentityAfterWrite = scenario == 1
            channel.dropStatusAfterWrite = scenario == 2 ? 10 : 0
            XCTAssertThrowsError(try client.setEnabled(true, replacing: before))
            XCTAssertEqual(channel.writes.count, 1)
        }
    }

    func testReadbackMismatchWithAckDoesNotClaimSuccess() throws {
        let channel = TurboController()
        let client = ControllerTurboClient(channel: channel)
        let before = try client.read()
        channel.acceptWrite = false
        XCTAssertThrowsError(try client.setEnabled(true, replacing: before))
        XCTAssertEqual(channel.writes.count, 1)
    }

    func testTimeoutBeforeWriteNamesPhaseAndDoesNotMutate() throws {
        let channel = TurboController()
        let client = ControllerTurboClient(channel: channel)
        let before = try client.read()
        channel.suppressStatus = true
        XCTAssertThrowsError(try client.setEnabled(true, replacing: before)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("before writing"), message)
            XCTAssertTrue(message.contains("0x03"), message)
            XCTAssertTrue(message.contains("No Turbo-setting write"), message)
        }
        XCTAssertTrue(channel.writes.isEmpty)
    }

    func testTruncatedStatusFailsAndUnchangedSettingDoesNotWrite() throws {
        let channel = TurboController()
        let client = ControllerTurboClient(channel: channel)
        let before = try client.read()
        XCTAssertEqual(try client.setEnabled(false, replacing: before), before)
        XCTAssertTrue(channel.writes.isEmpty)
        channel.truncated = true
        XCTAssertThrowsError(try client.read())
    }
}

private final class TurboController: ControllerChannel {
    var supported = true, ack = true, acceptWrite = true, wrongSubcommand = false, truncated = false
    var suppressStatus = false, changeIdentityAfterWrite = false
    var dropStatusAfterWrite = 0
    var deviceID: UInt8 = 130
    var flags: UInt8 = 0x85
    var writes: [[UInt8]] = []
    var queue: [[UInt8]] = []

    func send(_ report: [UInt8]) throws {
        switch report[2] {
        case 1:
            queue.append([0x5a, 0xa5, 1, 1, 0, deviceID, 2, 1, 2, 3, 4] + Array(repeating: 0, count: 21))
        case 3:
            if suppressStatus { return }
            if !writes.isEmpty, dropStatusAfterWrite > 0 { dropStatusAfterWrite -= 1; return }
            let status: [UInt8] = [0x5a, 0xa5, 3, 1, 0, supported ? 0xff : 0xf7, flags, 0, 0, 0, 0, 0, 0]
            queue.append(truncated ? Array(status.prefix(7)) : status)
        case 0x13:
            writes.append(report)
            if changeIdentityAfterWrite { deviceID = 144 }
            if acceptWrite { flags = (flags & ~0x08) | (report[5] == 1 ? 0x08 : 0) }
            queue.append([0, 1, 2, 3, 4]) // unrelated live input
            if ack { queue.append([0x5a, 0xa5, 0x13, 1, 0, wrongSubcommand ? 6 : 4]) }
        default: XCTFail("Unexpected command")
        }
    }
    func receive(timeout: TimeInterval) throws -> [UInt8] {
        guard !queue.isEmpty else { throw ControllerProtocolError.timeout }
        return queue.removeFirst()
    }
}
