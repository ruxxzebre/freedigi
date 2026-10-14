import XCTest
@testable import ControllerProtocol

final class MappingCaptureTests: XCTestCase {
    func testBothBumpersToggleCaptureOnceUntilFullyReleased() {
        var capture = ControllerMappingCapture()
        XCTAssertNil(capture.receive([10]))
        XCTAssertNil(capture.receive([10, 11]))
        XCTAssertTrue(capture.isActive)
        XCTAssertNil(capture.receive([10, 11]))
        XCTAssertNil(capture.receive([11]))
        XCTAssertNil(capture.receive([10, 11]))
        XCTAssertTrue(capture.isActive)
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([11]))
        XCTAssertNil(capture.receive([10, 11]))
        XCTAssertFalse(capture.isActive)
        XCTAssertNil(capture.receive([10]))
        XCTAssertNil(capture.receive([]))
        XCTAssertFalse(capture.isActive)
    }

    func testStopChordDoesNotStageItsFirstBumperAsTarget() {
        var capture = ControllerMappingCapture()
        capture.start(held: [], source: 18)
        XCTAssertNil(capture.receive([10]))
        XCTAssertNil(capture.receive([10, 11]))
        XCTAssertNil(capture.receive([11]))
        XCTAssertNil(capture.receive([]))
        XCTAssertFalse(capture.isActive)
    }

    func testRepeatedPairsRequireReleaseAndEmitOnce() {
        var capture = ControllerMappingCapture()
        capture.start(held: [18])
        XCTAssertNil(capture.receive([18]))
        XCTAssertEqual(capture.phase, .releaseForSource)
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([18]))
        XCTAssertEqual(capture.phase, .holdingSource(18))
        XCTAssertNil(capture.receive([18]))
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([4]))
        XCTAssertNil(capture.receive([4]))
        let first = capture.receive([])
        XCTAssertEqual(first?.source, 18)
        XCTAssertEqual(first?.destination, 4)
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([19]))
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([5]))
        XCTAssertEqual(capture.receive([])?.source, 19)
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
        XCTAssertNil(capture.receive([7]))
        XCTAssertEqual(capture.receive([])?.destination, 7)
    }

    func testManualSourceCancelAndSelfMapping() {
        var capture = ControllerMappingCapture()
        capture.start(held: [4], source: 21)
        XCTAssertNil(capture.receive([4]))
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([21]))
        XCTAssertEqual(capture.receive([])?.destination, 21)
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
            XCTAssertNil(capture.receive([4]))
            let assignment = capture.receive([])
            XCTAssertEqual(assignment?.source, source)
            XCTAssertEqual(assignment?.destination, 4)
        }
    }

    func testIndividualBumpersRemainMappableInBothRoles() {
        for bumper in [10, 11] {
            var capture = ControllerMappingCapture()
            capture.start(held: [])
            XCTAssertNil(capture.receive([bumper]))
            XCTAssertNil(capture.receive([]))
            XCTAssertNil(capture.receive([4]))
            XCTAssertEqual(capture.receive([])?.source, bumper)
            XCTAssertNil(capture.receive([18]))
            XCTAssertNil(capture.receive([]))
            XCTAssertNil(capture.receive([bumper]))
            XCTAssertEqual(capture.receive([])?.destination, bumper)
            XCTAssertTrue(capture.isActive)
        }
    }

    func testStaggeredUnsupportedChordCannotStageFirstButton() {
        var capture = ControllerMappingCapture()
        capture.start(held: [], source: 20)
        XCTAssertNil(capture.receive([4]))
        XCTAssertNil(capture.receive([4, 5]))
        XCTAssertNotNil(capture.issue)
        XCTAssertNil(capture.receive([5]))
        XCTAssertNil(capture.receive([]))
        XCTAssertEqual(capture.selectedSource, 20)
        XCTAssertNil(capture.receive([7]))
        XCTAssertEqual(capture.receive([])?.destination, 7)
    }

    func testShortcutWhileSelectingSourceAndRestartAfterCancel() {
        var capture = ControllerMappingCapture()
        capture.start(held: [])
        XCTAssertNil(capture.receive([11]))
        XCTAssertNil(capture.receive([11, 10]))
        XCTAssertFalse(capture.isActive)
        XCTAssertNil(capture.receive([]))
        XCTAssertNil(capture.receive([10, 11]))
        XCTAssertTrue(capture.isActive)
        XCTAssertNil(capture.receive([]))
        capture.cancel()
        XCTAssertNil(capture.receive([18]))
        XCTAssertNil(capture.receive([]))
        XCTAssertFalse(capture.isActive)
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
