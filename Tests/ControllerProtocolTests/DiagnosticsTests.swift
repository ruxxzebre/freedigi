import Foundation
import XCTest
@testable import ControllerProtocol

final class DiagnosticsTests: XCTestCase {
    func testFirmwareProgressDoesNotFloodUIAndKeepsStageChanges() {
        let filter = ControllerProgressFilter()
        XCTAssertTrue(filter.accept(stage: "Write", fraction: 0))
        for value in 1..<100 { XCTAssertFalse(filter.accept(stage: "Write", fraction: Double(value) / 10_000)) }
        XCTAssertTrue(filter.accept(stage: "Write", fraction: 0.01))
        XCTAssertTrue(filter.accept(stage: "Verify", fraction: 0.01))
        XCTAssertTrue(filter.accept(stage: "Done", fraction: 1))
    }
    func testDryRunNeverInvokesHardwareAndLiveFailureIsCorrelated() throws {
        let log = ControllerDiagnostics()
        var writes = 0
        log.write("Test", mode: .dryRun, reports: [[1, 2, 3]]) { writes += 1 }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(log.snapshot().last?.stage, "previewed")
        XCTAssertThrowsError(try log.write("Test", mode: .live, reports: [[1]]) {
            writes += 1
            throw ControllerProtocolError.timeout
        })
        XCTAssertEqual(writes, 1)
        let failure = try XCTUnwrap(log.snapshot().last)
        XCTAssertEqual(failure.stage, "failed")
        XCTAssertNotNil(failure.elapsedMilliseconds)
        XCTAssertEqual(log.snapshot().filter { $0.operationID == failure.operationID }.count, 2)
    }

    func testExportBoundsHistoryAndPacketTracingIsOptIn() throws {
        let log = ControllerDiagnostics(capacity: 2)
        let id = UUID()
        log.trace("USB", direction: "send", report: [0x5a, 0xa5], operationID: id)
        XCTAssertTrue(log.snapshot().isEmpty)
        log.wireTracing = true
        log.trace("USB", direction: "send", report: [0x5a, 0xa5], operationID: id)
        XCTAssertEqual(log.snapshot().first?.message, "2 bytes: 5a a5")
        log.record("A", message: "first")
        log.record("B", message: "second")
        let data = try log.export(metadata: ["os": "test"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["omittedEvents"] as? Int, 1)
        XCTAssertEqual((json["events"] as? [Any])?.count, 2)
        log.clear()
        XCTAssertTrue(log.snapshot().isEmpty)
    }

    func testProfilePreviewIsOfflineAndRestoreKeepsCurrentVersion() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vader5-default-sdk", withExtension: "bin", subdirectory: "Fixtures"))
        let original = try ControllerProfile(bytes: Array(Data(contentsOf: url)))
        var edited = original
        try edited.map(18, to: 4)
        let reports = try edited.writeReports(replacing: original, slot: 2, persist: true)
        XCTAssertEqual(reports.map { $0[2] }, [0xa4, 0xa5, 0xa6])
        XCTAssertEqual(reports[0][5], 3)
        XCTAssertEqual(Array(reports[2][4...5]), [0, 0]) // version wrap
        var current = original
        current.setDataVersion(10)
        let restored = try current.restoringContents(from: edited)
        XCTAssertEqual(restored.dataVersion, 10)
        XCTAssertEqual(restored.mapping(for: 18), 4)
        XCTAssertThrowsError(try restored.writeReports(replacing: original, slot: 2, persist: false))
    }
}
