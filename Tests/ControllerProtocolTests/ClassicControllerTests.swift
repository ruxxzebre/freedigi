import Foundation
import XCTest
@testable import ControllerProtocol

private func classicProfile(_ minor: UInt8 = 0) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: minor == 0 ? 790 : 840)
    bytes[0] = minor; bytes[1] = 3; bytes[2] = 77
    bytes[225] = 0x34; bytes[226] = 0x12
    return bytes
}
private func parcel(_ index: Int, _ bytes: [UInt8], tag: UInt8 = 0xeb) -> [UInt8] {
    var report = [UInt8](repeating: 0, count: 32)
    report[0] = 4; report[3] = UInt8(index); report[15] = tag
    report.replaceSubrange(5..<15, with: bytes[(index * 10)..<(index * 10 + 10)])
    return report
}
private final class ClassicMock: ControllerChannel {
    var blob = classicProfile()
    var slot: UInt8 = 1, model: UInt8 = 85
    var sent: [[UInt8]] = [], queued: [[UInt8]] = []
    var failAck = false, wrongAck = false, mismatchReadback = false, wrongVersion = false
    var slotQuery = true
    var address: [UInt8] = [1, 2, 3, 4]
    var infoQueries = 0
    var beforeInfo: ((Int) -> Void)?
    var incoming = [UInt8]()
    func send(_ report: [UInt8]) throws {
        sent.append(report)
        var reply = [UInt8](repeating: 0, count: 32); reply[0] = 4
        switch report[1] {
        case 0xec:
            infoQueries += 1; beforeInfo?(infoQueries)
            reply[3] = model; reply.replaceSubrange(5...8, with: address); reply[9] = 0x30; reply[10] = 0x68
            reply[13] = 1; reply[15] = 0xec; queued.append(reply)
        case 0xeb where report[2] == 0xa0:
            if slotQuery { reply[1] = 0xeb; reply[2] = 0xa0; reply[3] = slot; queued.append(reply) }
        case 0xeb:
            queued += (0..<(blob.count / 10)).reversed().map { parcel($0, blob) }
        case 0xea:
            incoming = []; reply[15] = 0xea; reply[3] = 255
            if !failAck { queued.append(reply) }
        case 0x22:
            incoming += report[2..<12]
            reply[15] = wrongAck ? 0x33 : 0xea; reply[3] = report[13] + 1
            if !failAck { queued.append(reply) }
            if incoming.count == blob.count { blob = incoming; if mismatchReadback { blob[150] ^= 1 } }
        case 0x50 where report[2] == 2:
            reply[3] = 0x50; reply[4] = 2; reply[5] = blob[225]; reply[6] = blob[226]; reply[7] = slot
            if wrongVersion { reply[5] ^= 1 }
            queued.append(reply)
        case 0x50 where report[2] == 3:
            blob[225] = report[3]; blob[226] = report[4]
            reply[3] = 0x50; reply[4] = 3; reply[5] = 1; queued.append(reply)
        default: XCTFail("Unexpected classic command \(report)")
        }
    }
    func receive(timeout: TimeInterval) throws -> [UInt8] {
        guard !queued.isEmpty else { throw ControllerProtocolError.timeout }
        return queued.removeFirst()
    }
    var mutations: [[UInt8]] { sent.filter { [0xea, 0x22].contains($0[1]) || ($0[1] == 0x50 && $0[2] == 3) } }
}

final class ClassicControllerTests: XCTestCase {
    func testClassicMonitorHandshakeUsesOnlyClassicIdentityAndRejectsOtherModels() throws {
        let channel = ClassicMock()
        let result = try ControllerMonitorStartup.handshake(waitBeforeRetry: {},
            identify: { (channel: ClassicMock) in try ClassicControllerClient(channel: channel).info().identity }, open: { channel })
        XCTAssertEqual(result?.identity.deviceID, 85)
        XCTAssertEqual(channel.sent, [ClassicControllerProtocol.command(0xec)])
        channel.model = 84
        var attempts = 0
        XCTAssertThrowsError(try ControllerMonitorStartup.handshake(waitBeforeRetry: {},
            identify: { (channel: ClassicMock) in try ClassicControllerClient(channel: channel).info().identity },
            open: { attempts += 1; return channel }))
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(channel.mutations.isEmpty)
    }
    func testControllerOrSlotChangedImmediatelyBeforeWriteNeverMutates() throws {
        for change in 0..<3 {
            let channel = ClassicMock(), client = ClassicControllerClient(channel: channel)
            let snapshot = try client.readActive()
            var edited = try snapshot.profile(); try edited.map(18, to: 4)
            channel.beforeInfo = { [weak channel] query in
                guard query == 5 else { return }
                if change == 0 { channel?.address = [5, 6, 7, 8] }
                if change == 1 { channel?.model = 91 }
                if change == 2 { channel?.slot = 2 }
            }
            XCTAssertThrowsError(try client.apply(edited, replacing: snapshot, persist: true))
            XCTAssertTrue(channel.mutations.isEmpty, "A changed controller or slot must fail before the write header")
        }
    }
    func testIdentityFirmwareForeignAndLiveFrameRejection() throws {
        let channel = ClassicMock(), client = ClassicControllerClient(channel: ClassicMock())
        XCTAssertEqual(try client.info().firmware, "6.8.3.0")
        for model: UInt8 in [85, 91, 105] { channel.model = model; XCTAssertEqual(try ClassicControllerClient(channel: channel).info().identity.deviceID, model) }
        channel.model = 54
        XCTAssertThrowsError(try ClassicControllerClient(channel: channel).info())
        XCTAssertTrue(channel.mutations.isEmpty)
        var report = parcel(0, classicProfile(), tag: 0xec); report[1] = 0xfe
        XCTAssertNil(ClassicControllerProtocol.info(report))
        XCTAssertFalse(ClassicControllerProtocol.tagged(report, 0xec))
        XCTAssertNil(ClassicControllerProtocol.info([4, 0, 0, 85]))
    }
    func testAssemblerBothVersionsDuplicatesOrderingAndExtensions() throws {
        for minor: UInt8 in [0, 1] {
            let bytes = classicProfile(minor)
            var assembler = ClassicBlobAssembler()
            for index in (0..<(bytes.count / 10)).reversed() { try assembler.add(parcel(index, bytes)) }
            try assembler.add(parcel(0, bytes))
            XCTAssertEqual(try assembler.bytes(), bytes)
            var conflicting = parcel(0, bytes); conflicting[8] ^= 1
            XCTAssertThrowsError(try assembler.add(conflicting))
            var extra = parcel(0, bytes); extra[3] = UInt8(bytes.count / 10)
            XCTAssertThrowsError(try assembler.add(extra))
        }
        var missing = ClassicBlobAssembler(); try missing.add(parcel(0, classicProfile()))
        XCTAssertFalse(missing.complete); XCTAssertThrowsError(try missing.bytes())
        var unknown = classicProfile(); unknown[0] = 2
        XCTAssertThrowsError(try missing.add(parcel(0, unknown)))
        XCTAssertThrowsError(try missing.add([4, 0, 0]))
    }
    func testAckMatchesFamilyAndOneBasedIndexNotInput() throws {
        let packets = try ClassicControllerProtocol.packets(classicProfile(), slot: 1)
        var reply = [UInt8](repeating: 0, count: 32); reply[0] = 4; reply[15] = 0xea; reply[3] = 255
        XCTAssertTrue(ClassicControllerProtocol.ack(reply, for: packets[0]))
        reply[3] = 1
        XCTAssertTrue(ClassicControllerProtocol.ack(reply, for: packets[1]))
        XCTAssertFalse(ClassicControllerProtocol.ack(reply, for: packets[2]))
        reply[15] = 0xe7
        XCTAssertFalse(ClassicControllerProtocol.ack(reply, for: packets[1]))
        reply[15] = 0x22; reply[1] = 0xfe
        XCTAssertFalse(ClassicControllerProtocol.ack(reply, for: packets[1]))
    }
    func testTemporaryAndPersistentFullReadbackBothLayouts() throws {
        for minor: UInt8 in [0, 1] { for persist in [false, true] {
            let channel = ClassicMock(); channel.blob = classicProfile(minor)
            let client = ClassicControllerClient(channel: channel), snapshot = try client.readActive()
            var edited = try snapshot.profile(); try edited.map(18, to: 4)
            let result = try client.apply(edited, replacing: snapshot, persist: persist)
            XCTAssertEqual(try result.profile().mapping(for: 18), 4)
            XCTAssertEqual(try result.profile().dataVersion, persist ? 0x1235 : 0x1234)
            XCTAssertEqual(channel.sent.filter { $0[1] == 0xea }.count, 1)
            let saves = channel.sent.filter { $0[1] == 0x50 && $0[2] == 3 }
            XCTAssertEqual(saves.count, persist ? 1 : 0)
            if persist { XCTAssertEqual(Array(saves[0].prefix(6)), [5, 0x50, 3, 0x35, 0x12, 0x9f]) }
        } }
    }
    func testStaleSnapshotSlotAndForeignModelNeverWrite() throws {
        for failure in 0..<3 {
            let channel = ClassicMock(), client = ClassicControllerClient(channel: ClassicMock())
            let snapshot = try client.readActive()
            var edited = try snapshot.profile(); try edited.map(18, to: 4)
            if failure == 0 { channel.blob[100] = 42 }
            if failure == 1 { channel.slot = 2 }
            if failure == 2 { channel.model = 54 }
            XCTAssertThrowsError(try ClassicControllerClient(channel: channel).apply(edited, replacing: snapshot, persist: true))
            XCTAssertTrue(channel.mutations.isEmpty)
        }
    }
    func testNoSlotFallbackNoReplayAndNeverSaveUnverified() throws {
        let absent = ClassicMock(); absent.slotQuery = false
        XCTAssertThrowsError(try ClassicControllerClient(channel: absent).readActive()); XCTAssertTrue(absent.mutations.isEmpty)
        for failure in 0..<4 {
            let channel = ClassicMock(), client = ClassicControllerClient(channel: channel)
            let snapshot = try client.readActive()
            var edited = try snapshot.profile(); try edited.map(18, to: 4)
            channel.failAck = failure == 0; channel.wrongAck = failure == 1
            channel.mismatchReadback = failure == 2; channel.wrongVersion = failure == 3
            XCTAssertThrowsError(try client.apply(edited, replacing: snapshot, persist: true))
            XCTAssertEqual(channel.sent.filter { $0[1] == 0xea }.count, 1)
            XCTAssertFalse(channel.sent.contains { $0[1] == 0x50 && $0[2] == 3 })
        }
    }
    func testClassicSnapshotsDoNotWeakenVader5WriteGate() throws {
        let channel = ClassicMock(), snapshot = try ClassicControllerClient(channel: channel).readActive()
        let profile = try snapshot.profile()
        XCTAssertThrowsError(try snapshot.identity.requireVader5())
        XCTAssertThrowsError(try profile.writeReports(replacing: profile, slot: 0, persist: true))
        let plan = try ClassicControllerProtocol.profilePlan(profile, replacing: snapshot, persist: true)
        XCTAssertEqual(plan.count, 82)
        XCTAssertEqual(plan[80], ClassicControllerProtocol.randomQuery(slot: 1))
        XCTAssertEqual(Array(plan.last!.prefix(6)), [5, 0x50, 3, 0x35, 0x12, 0x9f])
        let setting = ControllerTurboSetting(identity: snapshot.identity, supported: true, enabled: false)
        XCTAssertThrowsError(try setting.reports(enabling: true))
        let calibration = ControllerCalibrationSetting(identity: snapshot.identity, supported: true, enabled: false)
        XCTAssertThrowsError(try calibration.reports(enabling: true))
    }
}
