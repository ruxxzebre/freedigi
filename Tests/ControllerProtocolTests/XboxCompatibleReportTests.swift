import XCTest
@testable import ControllerProtocol

final class XboxCompatibleReportTests: XCTestCase {
    private func report(buttons: Set<Int> = [], dpad: UInt8 = 8,
                        x: Int16 = 0, y: Int16 = 0, lt: UInt8 = 0, rt: UInt8 = 0) -> [UInt8] {
        XboxCompatibleReport.encode(leftX: x, leftY: y, rightX: x, rightY: y,
            leftTrigger: lt, rightTrigger: rt, dpad: dpad, buttons: buttons)
    }

    func testNeutralIsCenteredAndHatIsReleased() {
        XCTAssertEqual(report(), [1, 0, 128, 0, 128, 0, 128, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testAxesTriggersAndHatUseXboxRanges() {
        let low = report(dpad: 0, x: .min, y: .max, lt: 255, rt: 128)
        XCTAssertEqual(Array(low[1...8]), [0, 0, 1, 0, 0, 0, 1, 0])
        XCTAssertEqual(Array(low[9...13]), [255, 3, 2, 2, 1])
        let high = report(dpad: 7, x: .max, y: .min)
        XCTAssertEqual(Array(high[1...8]), [255, 255, 255, 255, 255, 255, 255, 255])
        XCTAssertEqual(high[13], 8)
        XCTAssertEqual(report(dpad: 255)[13], 0)
    }

    func testXboxButtonPositionsAndUnrepresentedExtraButtons() {
        let positions = [(4,14,0),(5,14,1),(7,14,3),(8,14,4),(10,14,6),(11,14,7),
                         (6,15,2),(9,15,3),(32,15,4),(14,15,5),(15,15,6)]
        for (button, offset, bit) in positions {
            var expected = report()
            expected[offset] = UInt8(1 << bit)
            XCTAssertEqual(report(buttons: [button]), expected, "Button \(button)")
        }
        XCTAssertEqual(report(buttons: [16,17,18,19,20,21,33,34,35]), report())
    }

    func testDescriptorDeclaresExactlySixteenPayloadBytes() {
        // Walk HID short items, counting Input bits per report ID. Also verify
        // the actual axis/trigger/hat field widths rather than just byte count.
        let bytes = XboxCompatibleReport.descriptor
        var offset = 0, size = 0, count = 0, bits = 0, id = 0
        var fields: [(Int, Int)] = []
        while offset < bytes.count {
            let prefix = Int(bytes[offset]); offset += 1
            let length = [0, 1, 2, 4][prefix & 3]
            XCTAssertLessThanOrEqual(offset + length, bytes.count)
            guard offset + length <= bytes.count else { return }
            let value = (0..<length).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
            offset += length
            switch prefix & 0xfc {
            case 0x74: size = value
            case 0x94: count = value
            case 0x84: id = value
            case 0x80:
                XCTAssertEqual(id, 1)
                bits += size * count
                if value & 1 == 0 { fields.append((size, count)) }
            default: break
            }
        }
        XCTAssertEqual(bits, 128)
        XCTAssertEqual(fields.map { "\($0.0)x\($0.1)" }, ["16x4", "10x1", "10x1", "4x1", "1x15", "1x1"])
    }
}
