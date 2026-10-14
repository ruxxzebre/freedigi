import Foundation
import XCTest
@testable import ControllerProtocol

final class ControllerProfileTests: XCTestCase {
    private func fixture() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vader5-default-sdk", withExtension: "bin", subdirectory: "Fixtures"))
        return Array(try Data(contentsOf: url))
    }

    func testRecoveredSDKFixtureAndLosslessEdits() throws {
        let original = try fixture()
        var profile = try ControllerProfile(bytes: original)
        XCTAssertEqual(profile.bytes[0..<3], [2, 3, 77])
        try profile.map(18, to: 4)
        try profile.setTitle("My profile")
        profile.setVibrationEnabled(false)
        XCTAssertEqual(profile.mapping(for: 18), 4)
        XCTAssertEqual(profile.title, "My profile")
        let allowed = Set([67, 68, 69, 145] + Array(770..<790))
        for index in original.indices where !allowed.contains(index) {
            XCTAssertEqual(original[index], profile.bytes[index], "Changed unknown byte \(index)")
        }
        XCTAssertThrowsError(try profile.setTitle("123456789😀"))
        XCTAssertThrowsError(try ControllerProfile(bytes: Array(original.prefix(100))))
    }

    func testReadReorderedPacketsIgnoresInputAndIdenticalDuplicates() throws {
        let channel = try SimulatedController(bytes: fixture())
        channel.reorder = true
        let snapshot = try ControllerProfileClient(channel: channel).readActive()
        XCTAssertEqual(Array(snapshot.data), channel.bytes)
        XCTAssertEqual(snapshot.slot, 2)
    }

    func testUnchangedTitlePreservesFactoryPaddingAndOnlyMapsRequestedButton() throws {
        let original = try ControllerProfile(bytes: fixture())
        var edited = original
        try edited.setTitle(edited.title) // The GUI supplies its unchanged name on Apply.
        XCTAssertEqual(edited, original, "An unchanged title must preserve the vendor's 0xffff padding.")
        try edited.map(18, to: 4)
        let reports = try edited.writeReports(replacing: original, slot: 2, persist: false)
        XCTAssertEqual(reports.map { $0[2] }, [0xa4, 0xa5])
    }

    func testWriteVerifyPersistAndReadBack() throws {
        let channel = try SimulatedController(bytes: fixture())
        let client = ControllerProfileClient(channel: channel)
        let before = try client.readActive()
        var edited = try before.profile()
        try edited.map(18, to: 4)
        let result = try client.apply(edited, replacing: before, persist: true)
        XCTAssertEqual(try result.profile().mapping(for: 18), 4)
        XCTAssertEqual(try result.profile().dataVersion, 0) // Factory 65535 wraps.
        XCTAssertEqual(channel.mutations, [0xa4, 0xa5, 0xa6])
        XCTAssertEqual(channel.segmentStarts, [3])
    }

    func testConflictDoesNotWrite() throws {
        let channel = try SimulatedController(bytes: fixture())
        let client = ControllerProfileClient(channel: channel)
        let before = try client.readActive()
        channel.bytes[100] ^= 1
        XCTAssertThrowsError(try client.apply(before.profile(), replacing: before, persist: true))
        XCTAssertTrue(channel.mutations.isEmpty)
    }

    func testMissingOrConflictingPacketFails() throws {
        for conflict in [false, true] {
            let channel = try SimulatedController(bytes: fixture())
            channel.missing = !conflict
            channel.conflicting = conflict
            XCTAssertThrowsError(try ControllerProfileClient(channel: channel).readActive())
            XCTAssertTrue(channel.mutations.isEmpty)
        }
    }

    func testFailedWriteOrCorruptReadbackNeverSaves() throws {
        for lostACK in [false, true] {
            let channel = try SimulatedController(bytes: fixture())
            let client = ControllerProfileClient(channel: channel)
            let before = try client.readActive()
            var edited = try before.profile()
            try edited.map(18, to: 4)
            channel.loseWriteACK = lostACK
            channel.discardWrites = !lostACK
            XCTAssertThrowsError(try client.apply(edited, replacing: before, persist: true))
            XCTAssertFalse(channel.mutations.contains(0xa6))
            XCTAssertEqual(channel.mutations.filter { $0 == 0xa5 }.count, 1)
        }
    }

    func testWrongControllerFailsBeforeProfileAccess() throws {
        let channel = try SimulatedController(bytes: fixture())
        channel.deviceID = 128 // Apex 5, not Vader 5.
        XCTAssertThrowsError(try ControllerProfileClient(channel: channel).readActive())
        XCTAssertEqual(channel.commands, [1])
    }

    func testTimeoutIdentifiesPhaseCommandAndWriteExposure() throws {
        for scenario in 0..<4 {
            let channel = try SimulatedController(bytes: fixture())
            let client = ControllerProfileClient(channel: channel)
            let before = try client.readActive()
            var edited = try before.profile()
            try edited.map(18, to: 4)
            channel.suppressIdentity = scenario == 0
            channel.loseStartACK = scenario == 1
            channel.loseWriteACK = scenario == 2
            channel.suppressReadback = scenario == 3
            XCTAssertThrowsError(try client.apply(edited, replacing: before, persist: true)) { error in
                let text = String(describing: error)
                let command = ["0x01", "0xA4", "0xA5", "0xA3"][scenario]
                XCTAssertTrue(text.contains(command), text)
                XCTAssertTrue(text.contains(scenario == 0 ? "No profile-write commands" : "Profile-write commands were sent"), text)
            }
            XCTAssertFalse(channel.mutations.contains(0xa6))
            if scenario == 0 { XCTAssertTrue(channel.mutations.isEmpty) }
        }
    }

    func testTemporaryApplyRecoversLostAckByReadingBackWithoutRewriting() throws {
        for lostACK in [true, false] {
            let channel = try SimulatedController(bytes: fixture())
            let client = ControllerProfileClient(channel: channel)
            let before = try client.readActive()
            var edited = try before.profile()
            try edited.map(18, to: 4)
            channel.loseWriteACK = lostACK
            channel.readbacksToDrop = lostACK ? 0 : 1
            let after = try client.apply(edited, replacing: before, persist: false)
            XCTAssertEqual(try after.profile(), edited)
            XCTAssertEqual(channel.mutations, [0xa4, 0xa5])
        }
    }

    func testTemporaryRecoveryRejectsPartialWritesAndDifferentDeviceOrSlot() throws {
        for scenario in 0..<3 {
            let channel = try SimulatedController(bytes: fixture())
            let client = ControllerProfileClient(channel: channel)
            let before = try client.readActive()
            var edited = try before.profile()
            try edited.map(18, to: 4)
            if scenario == 0 { try edited.setTitle("Two edits") }
            if scenario == 1 { channel.deviceAfterWrite = 144 }
            if scenario == 2 { channel.slotAfterWrite = 1 }
            channel.loseWriteACK = true
            XCTAssertThrowsError(try client.apply(edited, replacing: before, persist: false))
            XCTAssertEqual(channel.mutations, [0xa4, 0xa5])
        }
    }

    func testCommandMatchesRecoveredWireBytes() {
        XCTAssertEqual(Array(ControllerCommand.frame(0xa3, payload: [2, 20]).prefix(7)),
                       [0x5a, 0xa5, 0xa3, 4, 2, 20, 0xbd])
    }
}

private final class SimulatedController: ControllerChannel {
    var bytes: [UInt8]
    var queue: [[UInt8]] = []
    var commands: [UInt8] = []
    var mutations: [UInt8] = []
    var segmentStarts: [UInt8] = []
    var reorder = false, missing = false, conflicting = false
    var loseWriteACK = false, discardWrites = false
    var suppressIdentity = false, loseStartACK = false, suppressReadback = false
    var readbacksToDrop = 0
    var deviceID: UInt8 = 130
    var slot: UInt8 = 2
    var deviceAfterWrite: UInt8?, slotAfterWrite: UInt8?
    private var segment = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    func send(_ report: [UInt8]) throws {
        let command = report[2]
        commands.append(command)
        switch command {
        case 1:
            if suppressIdentity { return }
            var result = [UInt8](repeating: 0, count: 32)
            result.replaceSubrange(0..<11, with: [0x5a, 0xa5, 1, 1, 0, deviceID, 2, 1, 2, 3, 4])
            queue.append(result)
        case 0xa1:
            var result = [UInt8](repeating: 0, count: 32)
            result.replaceSubrange(0..<6, with: [0x5a, 0xa5, 0xa1, 12, 0, slot])
            queue.append(result)
        case 0xa3:
            if suppressReadback && !mutations.isEmpty { return }
            if readbacksToDrop > 0 && !mutations.isEmpty { readbacksToDrop -= 1; return }
            var packets: [[UInt8]] = []
            for offset in stride(from: 0, to: bytes.count, by: 20) {
                var packet: [UInt8] = [0x5a, 0xa5, 0xa3, UInt8(bytes.count / 20), UInt8(offset / 20), report[4]]
                packet.append(contentsOf: bytes[offset..<(offset + 20)])
                packets.append(packet)
            }
            if missing { packets.removeFirst() }
            if conflicting {
                var other = packets[0]
                other[10] ^= 1
                packets.insert(other, at: 1)
            }
            if reorder { packets.reverse(); packets.insert(packets[0], at: 1) }
            queue.append([0, 1, 2, 3, 4]) // unrelated input
            queue += packets
        case 0xa4:
            mutations.append(command)
            segment = Int(report[5])
            segmentStarts.append(report[5])
            if !loseStartACK { queue.append(ControllerCommand.frame(command)) }
        case 0xa5:
            mutations.append(command)
            XCTAssertEqual(report[4], 0)
            if !discardWrites { bytes.replaceSubrange((segment * 20)..<(segment * 20 + 20), with: report[5..<25]) }
            if let deviceAfterWrite { deviceID = deviceAfterWrite }
            if let slotAfterWrite { slot = slotAfterWrite }
            if !loseWriteACK { queue.append(ControllerCommand.frame(command)) }
        case 0xa6:
            mutations.append(command)
            bytes[225] = report[4]; bytes[226] = report[5]
            queue.append(ControllerCommand.frame(command))
        default: XCTFail("Unexpected command \(command)")
        }
    }
    func receive(timeout: TimeInterval) throws -> [UInt8] {
        guard !queue.isEmpty else { throw ControllerProtocolError.timeout }
        return queue.removeFirst()
    }
}
