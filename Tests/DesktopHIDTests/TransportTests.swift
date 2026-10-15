import Foundation
import XCTest
@testable import DesktopHID
import ControllerProtocol

final class TransportTests: XCTestCase {
    let numbered: [UInt8] = [0x06, 0xa0, 0xff, 0x85, 3, 0x75, 8, 0x95, 31, 0x91, 2, 0x85, 4, 0x81, 2]
    func testLinuxNumberedReportsPreserveProtocolFrame() throws {
        let layout = try HIDLayout.parse(numbered)
        XCTAssertEqual(layout.outputID, 3)
        XCTAssertEqual(layout.outputBytes, 31)
        let command = ControllerCommand.frame(1)
        let output = try layout.output(command)
        XCTAssertEqual(output.count, 32)
        XCTAssertEqual(output.first, 3)
        XCTAssertEqual(Array(output.dropFirst().prefix(5)), Array(command.prefix(5)))
        XCTAssertEqual(layout.input([4, 0x5a, 0xa5, 1]), [0x5a, 0xa5, 1])
        XCTAssertNil(layout.input([3, 0x5a, 0xa5, 1]))
        XCTAssertNil(layout.input([0x5a, 0xa5, 1]))
    }
    func testUnnumberedReportsNeedLeadingZeroOnLinuxWritesOnly() throws {
        let layout = try HIDLayout.parse([0x06, 0xa0, 0xff, 0x75, 8, 0x95, 32, 0x91, 2, 0x81, 2])
        XCTAssertEqual(try layout.output([0x5a, 0xa5, 1]).prefix(4), [0, 0x5a, 0xa5, 1])
        XCTAssertEqual(layout.input([0x5a, 0xa5, 1]), [0x5a, 0xa5, 1])
    }
    func testRejectsAmbiguousAndTruncatedDescriptorsAndNonzeroTruncation() throws {
        XCTAssertThrowsError(try HIDLayout.parse(numbered + [0x85, 5, 0x91, 2]))
        XCTAssertThrowsError(try HIDLayout.parse([0x06, 0xa0]))
        XCTAssertThrowsError(try HIDLayout.parse([0x05, 1, 0x75, 8, 0x95, 32, 0x91, 2, 0x81, 2]))
        let layout = try HIDLayout.parse(numbered)
        XCTAssertThrowsError(try layout.output(Array(repeating: 1, count: 32)))
    }
    func testInputKeepsFaceAndBackButtonsIndependent() throws {
        var report = [UInt8](repeating: 0, count: 32)
        report[0...2] = [0x5a, 0xa5, 0xef]
        report[11] = 0x10; report[13] = 0x24
        let state = try XCTUnwrap(InputState.parse(report))
        XCTAssertEqual(state.buttons, [4, 18, 21])
        report[11] = 0
        XCTAssertEqual(InputState.parse(report)?.buttons, [18, 21])
        XCTAssertNil(InputState.parse([0x5a, 0xa5, 0xef]))
    }
    func testLightingPlanPreservesOpaqueHeaderAndRejectsInvalidColor() throws {
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[1] = 3; bytes[2] = 79; bytes[7] = 4; bytes[19] = 123
        let identity = try JSONDecoder().decode(ControllerIdentity.self, from: Data(#"{"deviceID":130,"connection":0,"address":[1,2,3,4]}"#.utf8))
        let value = LightingSnapshot(identity: identity, bytes: bytes)
        let reports = try value.plan(color: "#123456", brightness: 70, off: false)
        XCTAssertEqual(reports.first?[2], 0xa8)
        XCTAssertEqual(reports[1][7], 79)
        XCTAssertEqual(reports[1][24], 123)
        XCTAssertThrowsError(try value.plan(color: "red", brightness: 70, off: false))
        XCTAssertThrowsError(try value.plan(color: "#123456", brightness: 101, off: false))
    }
}

extension TransportTests {
    #if os(Linux)
    func testDiscoveryRequiresKnownUSBIdentityAndConfigurationCollection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let classic: [UInt8] = [0x06, 0xa0, 0xff, 0x85, 5, 0x75, 8, 0x95, 63, 0x91, 2, 0x85, 4, 0x81, 2]
        let candidates: [(String, String, [UInt8])] = [
            ("hidraw0", "000004B4:00002412", classic),
            ("hidraw1", "000037D7:00002401", numbered),
            ("hidraw2", "000004B4:00002412", numbered),
            ("hidraw3", "000004B4:00002413", classic),
            ("hidraw4", "00001234:00002412", classic),
            ("hidraw5", "000004B4:00002412", [0x06, 0xef, 0xff] + Array(classic.dropFirst(3))),
        ]
        for (name, id, descriptor) in candidates {
            let device = root.appendingPathComponent(name).appendingPathComponent("device")
            try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
            try Data("HID_ID=0003:\(id)\nHID_NAME=Flydigi test\n".utf8).write(to: device.appendingPathComponent("uevent"))
            try Data(descriptor).write(to: device.appendingPathComponent("report_descriptor"))
        }
        let devices = HIDDevice.enumerate(root: root.path)
        XCTAssertEqual(devices.map(\.path), ["/dev/hidraw0", "/dev/hidraw1"])
        XCTAssertEqual(devices.map(\.isClassic), [true, false])
        XCTAssertEqual(devices.map(\.product), ["2412", "2401"])
    }
    #endif

    func testClassicNumberedDescriptorDoesNotDuplicateReportID() throws {
        let descriptor: [UInt8] = [0x06, 0xa0, 0xff, 0x85, 5, 0x75, 8, 0x95, 31, 0x91, 2, 0x85, 4, 0x81, 2]
        let layout = try HIDLayout.parse(descriptor, isClassic: true)
        let command = ClassicControllerProtocol.command(0xec)
        let packet = try layout.output(command)
        XCTAssertEqual(packet.count, 32)
        XCTAssertEqual(Array(packet.prefix(3)), [5, 0xec, 0])
        XCTAssertEqual(layout.input([4, 0xfe, 0]), [4, 0xfe, 0])
        XCTAssertNil(layout.input([5, 0xfe, 0]))
        XCTAssertThrowsError(try layout.output(ControllerCommand.frame(1)))
        XCTAssertThrowsError(try HIDLayout.parse(numbered, isClassic: true))
        let short: [UInt8] = [0x06, 0xa0, 0xff, 0x85, 5, 0x75, 8, 0x95, 13, 0x91, 2, 0x85, 4, 0x81, 2]
        XCTAssertEqual(try HIDLayout.parse(short, isClassic: true).output(command).count, 14)
    }
    func testClassicInputsExtraButtonsAxesAndTriggers() throws {
        var report = [UInt8](repeating: 0, count: 32)
        report[0] = 4; report[1] = 0xfe
        for index in [17, 19, 21, 22] { report[index] = 127 }
        let neutral = try XCTUnwrap(InputState.parse(report))
        XCTAssertTrue(neutral.buttons.isEmpty); XCTAssertEqual(neutral.leftX, 0); XCTAssertEqual(neutral.leftY, 0)
        report[7] = 0x3f; report[9] = 0x31; report[10] = 0xff; report[8] = 8
        report[17] = 255; report[19] = 0; report[21] = 0; report[22] = 255; report[23] = 255; report[24] = 128
        let state = try XCTUnwrap(InputState.parse(report))
        XCTAssertEqual(state.buttons, [0, 4, 5, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 32])
        XCTAssertEqual(state.leftX, 1); XCTAssertEqual(state.leftY, 1)
        XCTAssertEqual(state.rightX, -1); XCTAssertEqual(state.rightY, -1)
        XCTAssertEqual(state.leftTrigger, 1); XCTAssertEqual(state.rightTrigger, 128.0/255)
        XCTAssertNil(InputState.parse(Array(report.prefix(31))))
    }
    func testClassicLightingPercentColorsOpaqueBytesAndSlot() throws {
        let identity = try JSONDecoder().decode(ControllerIdentity.self, from: Data(#"{"deviceID":85,"connection":1,"address":[1,2,3,4]}"#.utf8))
        var bytes = [UInt8](repeating: 42, count: 500)
        bytes[0] = 0; bytes[1] = 2; bytes[7] = 2; bytes[6] = 60; bytes[8] = 5
        let value = LightingSnapshot(identity: identity, bytes: bytes, slot: 2)
        let reports = try value.plan(color: "#ff8000", brightness: 70, off: false)
        XCTAssertEqual(Array(reports[0].prefix(4)), [5, 0xe7, 2, 50])
        let edited = reports.dropFirst().flatMap { Array($0[2..<12]) }
        XCTAssertEqual(Array(edited[20..<23]), [100, 50, 0])
        XCTAssertEqual(edited[6], 70); XCTAssertEqual(edited[8], 5)
        XCTAssertEqual(Array(edited[9..<20]), Array(bytes[9..<20]))
        XCTAssertEqual(Array(edited[80..<500]), Array(bytes[80..<500]))
        let off = try value.plan(color: "#ff8000", brightness: 70, off: true).dropFirst().flatMap { Array($0[2..<12]) }
        XCTAssertEqual(off[6], 0); XCTAssertEqual(off[8], 6)
        XCTAssertEqual(Array(off[20..<500]), Array(bytes[20..<500]))
        XCTAssertThrowsError(try LightingSnapshot(identity: identity, bytes: bytes).plan(color: "#ff8000", brightness: 70, off: false))
        bytes[1] = 3
        XCTAssertThrowsError(try LightingSnapshot(identity: identity, bytes: bytes, slot: 0).plan(color: "#ff8000", brightness: 70, off: false))
    }
}
