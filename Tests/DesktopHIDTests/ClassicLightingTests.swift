import Foundation
import XCTest
import ControllerProtocol
@testable import DesktopHID

private final class LightingChannel: ControllerChannel {
    var bytes = [UInt8](repeating: 42, count: 500)
    var slot: UInt8 = 1
    var model: UInt8 = 85
    var queued: [[UInt8]] = [], sent: [[UInt8]] = [], incoming: [UInt8] = []
    var failAck = false, wrongAck = false, mismatchReadback = false
    init() {
        bytes[0] = 0; bytes[1] = 2; bytes[6] = 60; bytes[7] = 2; bytes[8] = 5
    }
    func send(_ report: [UInt8]) throws {
        sent.append(report)
        var reply = [UInt8](repeating: 0, count: 32); reply[0] = 4
        switch report[1] {
        case 0xec:
            reply[3] = model; reply[5...8] = [1, 2, 3, 4]; reply[13] = 1; reply[15] = 0xec
            queued.append(reply)
        case 0xeb:
            // Exercise the alternate slot response used by the classic SDK.
            reply[3] = 0xaa; reply[4] = 0xac; reply[5] = slot
            queued.append(reply)
        case 0xe5:
            for index in (0..<50).reversed() {
                reply[3] = UInt8(index); reply[15] = 0xe5
                reply.replaceSubrange(5..<15, with: bytes[(index * 10)..<(index * 10 + 10)])
                queued.append(reply)
            }
        case 0xe7:
            incoming = []; reply[15] = 0xe7; reply[3] = 255
            if !failAck { queued.append(reply) }
        case 0x33:
            incoming += report[2..<12]
            reply[15] = wrongAck ? 0xea : 0xe7; reply[3] = report[13] + 1
            if !failAck { queued.append(reply) }
            if incoming.count == 500 {
                bytes = incoming
                if mismatchReadback { bytes[400] ^= 1 }
            }
        default: XCTFail("Unexpected lighting command \(report)")
        }
    }
    func receive(timeout: TimeInterval) throws -> [UInt8] {
        guard !queued.isEmpty else { throw ControllerProtocolError.timeout }
        return queued.removeFirst()
    }
    var mutations: [[UInt8]] { sent.filter { [0xe7, 0x33].contains($0[1]) } }
}

final class ClassicLightingTests: XCTestCase {
    func testTemporaryApplyAndOffVerifyWholeBlobAndKeepSlot() throws {
        let channel = LightingChannel()
        var snapshot = try LightingSnapshot.readClassic(channel)
        XCTAssertEqual(snapshot.slot, 1)
        for off in [false, true] {
            let reports = try snapshot.plan(color: "#ff8000", brightness: 70, off: off)
            snapshot = try snapshot.apply(channel, reports: reports)
            XCTAssertEqual(snapshot.slot, 1)
            XCTAssertEqual(snapshot.brightness, off ? 0 : 70)
            XCTAssertEqual(snapshot.mode, off ? 6 : 5)
            XCTAssertEqual(snapshot.bytes, reports.dropFirst().flatMap { Array($0[2..<12]) })
            XCTAssertEqual(snapshot.bytes[400], 42)
        }
        XCTAssertEqual(channel.mutations.count, 102)
        XCTAssertFalse(channel.sent.contains { $0[1] == 0x50 }, "Lighting apply must not save to flash")
    }

    func testStaleBytesSlotAndModelRejectBeforeLightingMutation() throws {
        for failure in 0..<3 {
            let channel = LightingChannel(), snapshot = try LightingSnapshot.readClassic(channel)
            let reports = try snapshot.plan(color: "#ff8000", brightness: 70, off: false)
            if failure == 0 { channel.bytes[400] ^= 1 }
            if failure == 1 { channel.slot = 2 }
            if failure == 2 { channel.model = 84 }
            XCTAssertThrowsError(try snapshot.apply(channel, reports: reports))
            XCTAssertTrue(channel.mutations.isEmpty)
        }
    }

    func testMissingOrWrongAckAndReadbackMismatchNeverReplay() throws {
        for failure in 0..<3 {
            let channel = LightingChannel(), snapshot = try LightingSnapshot.readClassic(channel)
            let reports = try snapshot.plan(color: "#ff8000", brightness: 70, off: false)
            channel.failAck = failure == 0
            channel.wrongAck = failure == 1
            channel.mismatchReadback = failure == 2
            XCTAssertThrowsError(try snapshot.apply(channel, reports: reports))
            XCTAssertEqual(channel.sent.filter { $0[1] == 0xe7 }.count, 1)
            XCTAssertEqual(channel.mutations.count, [1, 2, 51][failure])
        }
    }

    func testMalformedPlanAndUnsupportedLightingFailBeforeMutation() throws {
        let channel = LightingChannel(), snapshot = try LightingSnapshot.readClassic(channel)
        var reports = try snapshot.plan(color: "#ff8000", brightness: 70, off: false)
        reports[1][13] = 3
        XCTAssertThrowsError(try snapshot.apply(channel, reports: reports))
        channel.bytes[7] = 17
        XCTAssertThrowsError(try LightingSnapshot.readClassic(channel))
        XCTAssertTrue(channel.mutations.isEmpty)
    }
}
