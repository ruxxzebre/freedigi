import Foundation
import XCTest
@testable import ControllerProtocol

final class FirmwareTransferTests: XCTestCase {
    func testLegacyMegahuntWritesThenVerifiesEveryByteAndMetadata() throws {
        XCTAssertEqual(LegacyMegahunt.crc32(Array("123456789".utf8)), 0x0376e6e7)
        let image = Data((0..<137).map { UInt8($0) })
        let channel = LegacySimulator()
        try LegacyMegahunt.transfer(image: image, fileName: "f5.bin", channel: channel)
        XCTAssertEqual(channel.image, Array(image))
        XCTAssertTrue(channel.finished)
        XCTAssertEqual(channel.readCount, 3)
        let corrupt = LegacySimulator()
        corrupt.corrupt = true
        XCTAssertThrowsError(try LegacyMegahunt.transfer(image: image, fileName: "f5.bin", channel: corrupt))
        XCTAssertFalse(corrupt.finished)
    }
    private func telinkImage() -> Data {
        var bytes = [UInt8](repeating: 0xa5, count: 64)
        bytes.replaceSubrange(24..<28, with: [64, 0, 0, 0])
        return Data(bytes)
    }

    func testTelinkRequiresCompletionAndStopsOnError() throws {
        let image = telinkImage()
        let channel = ScriptedFirmwareChannel([
            [5, 2, 0, 0], [5, 2, 0, 0], [5, 2, 0, 0], [5, 2, 3, 0, 6, 255, 0],
        ])
        try FirmwareTransfer.telink(image: image, channel: channel)
        XCTAssertEqual(channel.writes.count, 4)
        XCTAssertEqual(Array(channel.writes.last!.prefix(10)), [5, 2, 6, 0, 2, 255, 3, 0, 253, 255])
        let failure = ScriptedFirmwareChannel([[5, 2, 0, 0], [5, 2, 3, 0, 6, 255, 2]])
        XCTAssertThrowsError(try FirmwareTransfer.telink(image: image, channel: failure))
        XCTAssertEqual(failure.writes.count, 2)
        let noCompletion = ScriptedFirmwareChannel([[5, 2, 0, 0], [5, 2, 0, 0], [5, 2, 0, 0]])
        XCTAssertThrowsError(try FirmwareTransfer.telink(image: image, channel: noCompletion))
    }

    func testTelinkRejectsInvalidImageBeforeAnyWrite() {
        let channel = ScriptedFirmwareChannel([])
        XCTAssertThrowsError(try FirmwareTransfer.telink(image: Data(repeating: 255, count: 64), channel: channel))
        XCTAssertTrue(channel.writes.isEmpty)
    }

    func testUnrelatedAndPrematureTelinkResponsesDoNotAdvance() {
        let channel = ScriptedFirmwareChannel([[5, 0x99, 0, 0], [5, 2, 3, 0, 6, 255, 0]])
        XCTAssertThrowsError(try FirmwareTransfer.telink(image: telinkImage(), channel: channel))
        XCTAssertEqual(channel.writes.count, 1)
    }

    func testJieliCRCFragmentationAndFailureAbort() throws {
        XCTAssertEqual(FirmwareTransfer.crc16CCITT(Array("123456789".utf8)), 0x31c3)
        let channel = ScriptedFirmwareChannel([
            [0xa2, 1, 0, 0, 0, 1, 0, 0, 0], // 256-byte accepted chunk
            [0xa2, 2, 0, 0, 0, 54, 0, 0, 0],
            [0xa2, 2, 0, 0, 0, 60, 0, 0, 0],
            [0xa2, 3, 0, 0, 0, 0, 0, 0, 0],
            [0xa2, 4, 0, 5, 0, 100, 0, 0, 0],
        ])
        try FirmwareTransfer.jieli(image: Data(repeating: 42, count: 60), channel: channel)
        XCTAssertEqual(channel.writes.count, 5)
        XCTAssertEqual(Array(channel.writes[1].prefix(10)), [0xa1, 2, 0, 60, 0, 0, 0, 0, 0, 54])
        XCTAssertEqual(Array(channel.writes[2].prefix(10)), [0xa1, 2, 1, 60, 0, 54, 0, 0, 0, 6])
        let failure = ScriptedFirmwareChannel([
            [0xa2, 1, 0, 0, 0, 1, 0, 0, 0],
            [0xa2, 2, 1, 9, 0, 0, 0, 0, 0],
        ])
        XCTAssertThrowsError(try FirmwareTransfer.jieli(image: Data([1, 2]), channel: failure))
        XCTAssertEqual(Array(failure.writes.last!.prefix(2)), [0xa1, 5])
        XCTAssertFalse(failure.writes.contains { $0[1] == 3 })
    }

    func testMegahuntVectorsAndFullProtocol() throws {
        var image = Data([0x00, 0x10, 0x00, 0x20, 0x09, 0x50, 0x00, 0x08])
        image.append(Data(repeating: 0xab, count: 92))
        XCTAssertThrowsError(try FirmwareTransfer.validateMegahunt(image, fileName: "f5_ALL.bin"))
        XCTAssertThrowsError(try FirmwareTransfer.validateMegahunt(Data(repeating: 0, count: 32), fileName: "f5.bin"))
        let channel = MegahuntSimulator()
        try FirmwareTransfer.megahunt(image: image, fileName: "f5_APP.bin", channel: channel)
        XCTAssertEqual(channel.image, Array(image))
        XCTAssertEqual(channel.commands, [1, 2, 3, 5, 3, 5, 4, 7])
    }

    func testMegahuntBadWatermarkAbortsBeforeEnd() {
        let image = Data([0, 0x10, 0, 0x20, 9, 0x50, 0, 8] + [UInt8](repeating: 0xaa, count: 92))
        let channel = MegahuntSimulator()
        channel.badWatermark = true
        XCTAssertThrowsError(try FirmwareTransfer.megahunt(image: image, fileName: "f5_APP.bin", channel: channel))
        XCTAssertEqual(channel.commands.last, 6)
        XCTAssertFalse(channel.commands.contains(4))
        XCTAssertFalse(channel.commands.contains(7))
    }
}

private final class LegacySimulator: FirmwareFeatureChannel {
    var image: [UInt8] = []
    var flags: [UInt8] = []
    var readOffset = 0, readCount = 0
    var finished = false, corrupt = false
    func setFeature(_ report: [UInt8]) throws {
        switch report[0] {
        case 1: readOffset = 0
        case 4: image = []
        case 2:
            XCTAssertEqual(report.count, 63)
            let count = Int(report[1]) | Int(report[2]) << 8
            image += report[3..<(3 + count)]
        case 3: flags = report
        case 5: finished = true
        default: XCTFail("Unexpected feature ID")
        }
    }
    func getFeature(id: UInt8, length: Int) throws -> [UInt8] {
        if id == 3 { return flags }
        readCount += 1
        let count = min(60, image.count - readOffset)
        var report: [UInt8] = [2, UInt8(count), 0]
        report += image[readOffset..<(readOffset + count)]
        report += [UInt8](repeating: 0, count: 60 - count)
        if corrupt { report[3] ^= 1 }
        readOffset += count
        return report
    }
}

private final class ScriptedFirmwareChannel: FirmwareChannel {
    var responses: [[UInt8]]
    var writes: [[UInt8]] = []
    init(_ responses: [[UInt8]]) { self.responses = responses }
    func write(_ report: [UInt8]) throws { writes.append(report) }
    func read(timeout: TimeInterval) throws -> [UInt8] {
        guard !responses.isEmpty else { throw ControllerProtocolError.timeout }
        return responses.removeFirst()
    }
}

private final class MegahuntSimulator: FirmwareChannel {
    var commands: [UInt8] = []
    var image: [UInt8] = []
    var responses: [[UInt8]] = []
    var expected: [UInt8] = [0, 0, 0, 0]
    var badWatermark = false
    func write(_ report: [UInt8]) throws {
        let command = report[5]
        commands.append(command)
        if command == 3 {
            let offset = Int(FirmwareTransfer.uint32(report, 8))
            XCTAssertEqual(offset, image.count)
            let count = Int(report[12]) | Int(report[13]) << 8
            image.append(contentsOf: report[14..<(14 + count)])
            return // no per-DATA ACK; STATUS must be used
        }
        if command == 2 { expected = Array(report[8..<12]) }
        var response = FirmwareTransfer.padded(Array(report.prefix(8)))
        response.replaceSubrange(10..<14, with: expected)
        response.replaceSubrange(14..<18, with: FirmwareTransfer.le32(UInt32(image.count + (badWatermark ? 1 : 0))))
        response.replaceSubrange(24..<32, with: [0, 0x50, 0, 8, 255, 255, 1, 8])
        response.replaceSubrange(32..<40, with: [0, 0, 2, 8, 255, 255, 3, 8])
        response[40] = 50
        response[42] = 1
        var unrelated = response
        unrelated[6] &+= 1 // stale/unrelated sequence must not satisfy exchange
        responses += [unrelated, response]
    }
    func read(timeout: TimeInterval) throws -> [UInt8] {
        guard !responses.isEmpty else { throw ControllerProtocolError.timeout }
        return responses.removeFirst()
    }
}
