import Testing
@testable import Vader5Core

// Runs without a controller or restricted entitlement on the Mac build runner.
// Both output profiles must remain usable for preview in the ordinary app build.
@Test func nativeGamepadDryRunDoesNotCreateAHIDDevice() throws {
    for xbox in [false, true] {
        let output = VirtualGamepad(xboxCompatible: xbox, dryRun: true)
        try output.start()
        try output.send(.neutral)
        let running = NativeGamepadDiagnostics.shared.snapshot()
        #expect(running.dryRun)
        #expect(!running.created)
        #expect(running.previewedReports == 2)
        #expect(running.acceptedReports == 0)
        #expect(running.rejectedReports == 0)
        #expect(running.lastError == nil)
        output.stop()
        output.stop()
        let stopped = NativeGamepadDiagnostics.shared.snapshot()
        #expect(stopped.phase == "Stopped")
        #expect(!stopped.created)
        #expect(stopped.previewedReports == 2)
    }
}
