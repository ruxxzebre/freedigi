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
