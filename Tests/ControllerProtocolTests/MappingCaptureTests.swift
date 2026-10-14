import XCTest
@testable import ControllerProtocol

final class MappingCaptureTests: XCTestCase {
    func testRepeatedPairsRequireReleaseAndEmitOnce() {
        var capture = ControllerMappingCapture()
        capture.start(held: [18])
        XCTAssertNil(capture.receive([18]))
        XCTAssertEqual(capture.phase, .releaseForSource)
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([18]))
        XCTAssertEqual(capture.phase, .releaseForTarget(18))
        XCTAssertNil(capture.receive([18, 4]))
        XCTAssertNil(capture.receive([4]))
        XCTAssertNil(capture.receive([]))
        let first = capture.receive([4])
        XCTAssertEqual(first?.source, 18)
        XCTAssertEqual(first?.destination, 4)
        XCTAssertNil(capture.receive([4]))
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([19]))
        XCTAssertNil(capture.receive([]))
        XCTAssertEqual(capture.receive([5])?.source, 19)
    }

    func testChordsAndUnsupportedButtonsNeverGuess() {
        var capture = ControllerMappingCapture()
        capture.start(held: [])
        XCTAssertNil(capture.receive([18, 4]))
        XCTAssertNotNil(capture.issue)
        XCTAssertNil(capture.receive([18]))
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([32]))
        XCTAssertNotNil(capture.issue)
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([18]))
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([4, 5]))
        XCTAssertEqual(capture.phase, .releaseForTarget(18))
        XCTAssertNil(capture.receive([4]))
        XCTAssertNil(capture.receive([]))
        XCTAssertEqual(capture.receive([7])?.destination, 7)
    }

    func testManualSourceCancelAndSelfMapping() {
        var capture = ControllerMappingCapture()
        capture.start(held: [4], source: 21)
        XCTAssertNil(capture.receive([4]))
        XCTAssertNil(capture.receive([]))
        XCTAssertEqual(capture.receive([21])?.destination, 21)
        capture.cancel()
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([18]))
        XCTAssertEqual(capture.phase, .idle)
        capture.start(held: [], source: 99)
        XCTAssertFalse(capture.isActive)
    }

    func testInputConvertsIndependentBitsAndDiagonalDpad() {
        var input = ControllerMappingInput()
        // A + M1 + M4, then the Vader-specific C/Z buttons.
        XCTAssertEqual(input.update(buttonBits: 0x2401, dpad: 8, leftTrigger: 0, rightTrigger: 0), [4, 18, 21])
        XCTAssertEqual(input.update(buttonBits: 0xc0000, dpad: 8, leftTrigger: 0, rightTrigger: 0), [16, 17])
        // Home/Fn remain visible so capture rejects them instead of ignoring them.
        XCTAssertEqual(input.update(buttonBits: 0xc000, dpad: 8, leftTrigger: 0, rightTrigger: 0), [32, 33])
        XCTAssertEqual(input.update(buttonBits: 0, dpad: 1, leftTrigger: 0, rightTrigger: 0), [0, 1])
        XCTAssertEqual(input.update(buttonBits: 0, dpad: 7, leftTrigger: 0, rightTrigger: 0), [3, 0])
    }

    func testAllSupportedSourcesCanBeCapturedWithoutSendingWrites() {
        var capture = ControllerMappingCapture()
        capture.start(held: [])
        for source in 0..<22 {
            XCTAssertNil(capture.receive([]))
            XCTAssertNil(capture.receive([source]))
            XCTAssertNil(capture.receive([]))
            let assignment = capture.receive([4])
            XCTAssertEqual(assignment?.source, source)
            XCTAssertEqual(assignment?.destination, 4)
        }
    }

    func testTriggerNoiseAndFastPressRelease() {
        var input = ControllerMappingInput()
        XCTAssertNil(input.update(buttonBits: 0, dpad: 8, leftTrigger: 159, rightTrigger: 0))
        XCTAssertEqual(input.update(buttonBits: 0, dpad: 8, leftTrigger: 160, rightTrigger: 0), [12])
        XCTAssertNil(input.update(buttonBits: 0, dpad: 8, leftTrigger: 100, rightTrigger: 0))
        XCTAssertEqual(input.update(buttonBits: 0, dpad: 8, leftTrigger: 79, rightTrigger: 0), [])
        // Independent updates preserve a tap even if it falls between UI frames.
        XCTAssertEqual(input.update(buttonBits: 1 << 10, dpad: 8, leftTrigger: 0, rightTrigger: 255), [18, 13])
        XCTAssertEqual(input.update(buttonBits: 0, dpad: 8, leftTrigger: 0, rightTrigger: 0), [])
    }
}
