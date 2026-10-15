import XCTest
@testable import ControllerProtocol

final class FirmwareVersionPolicyTests: XCTestCase {
    func testVersionOrderUsesEveryNumericComponent() throws {
        for (offered, installed) in [("6.0.0.0", "5.9.9.9"), ("5.10.0.0", "5.9.9.9"),
                                     ("5.0.10.0", "5.0.9.9"), ("5.0.0.10", "5.0.0.9")] {
            XCTAssertEqual(FirmwareVersionPolicy.compare(offered: offered, installed: installed), .orderedDescending)
            XCTAssertNoThrow(try FirmwareVersionPolicy.requireUpgrade(offered: offered, installed: installed))
            XCTAssertEqual(FirmwareVersionPolicy.compare(offered: installed, installed: offered), .orderedAscending)
            XCTAssertThrowsError(try FirmwareVersionPolicy.requireUpgrade(offered: installed, installed: offered))
        }
    }

    func testSameVersionAndAlternateZeroPaddingDoNotReinstall() {
        for offered in ["5.0.1.6", "05.00.01.06"] {
            XCTAssertEqual(FirmwareVersionPolicy.compare(offered: offered, installed: "5.0.1.6"), .orderedSame)
            XCTAssertThrowsError(try FirmwareVersionPolicy.requireUpgrade(offered: offered, installed: "5.0.1.6"))
        }
    }

    func testMalformedOrUnknownVersionsFailClosedInEitherPosition() {
        for invalid in ["", "unknown", "5.0.1", "5.0.1.6.1", "5..1.6", "5.0.1.",
                        "5.0.1.6-beta", " 5.0.1.6", "5.0.-1.6", "5.0.+1.6", "5.0.65536.6", "５.0.1.6"] {
            XCTAssertNil(FirmwareVersionPolicy.compare(offered: invalid, installed: "5.0.1.6"))
            XCTAssertNil(FirmwareVersionPolicy.compare(offered: "5.0.1.6", installed: invalid))
            XCTAssertThrowsError(try FirmwareVersionPolicy.requireUpgrade(offered: invalid, installed: "5.0.1.6"))
            XCTAssertThrowsError(try FirmwareVersionPolicy.requireUpgrade(offered: "5.0.1.6", installed: invalid))
        }
    }
}
