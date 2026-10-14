import SwiftUI
import Vader5Core

@MainActor
struct CalibrationView: View {
    @ObservedObject var model: BridgeViewModel
    @State private var setting: ControllerCalibrationSetting?
    @State private var enabled = false
    @State private var message = "Read the controller to check automatic stick-calibration support."
    @State private var error: String?

    var body: some View {
        GroupBox("Calibration") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Automatic calibration adjusts stick centering in the controller. This setting applies across profiles.")
                    .foregroundStyle(.secondary)
                Button("Read calibration setting") { access(write: false) }
                if let setting {
                    if setting.supported {
                        Toggle("Automatic stick calibration", isOn: $enabled)
                        Button(model.dryRun ? "Preview calibration setting" : "Apply calibration setting") { access(write: true) }
                            .disabled(enabled == setting.enabled)
                    } else {
                        Text("This firmware does not advertise automatic stick calibration.")
                    }
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Text("Manual stick, trigger and gyro calibration is not available in this build. Changing this setting does not run a manual calibration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .disabled(model.operationInProgress)
        }
    }

    private func access(write: Bool) {
        guard !model.operationInProgress else { return }
        let previous = setting
        let requested = enabled
        guard !write || previous != nil else { return }
        if write && model.dryRun {
            guard let previous, previous.supported else { return }
            do {
                try Vader5Calibration.preview(requested, replacing: previous)
                message = "Dry run: automatic calibration would be \(requested ? "enabled" : "disabled"). No command sent."
                error = nil
            } catch { self.error = String(describing: error) }
            return
        }
        model.deviceBusy = true
        let resumeMonitoring = model.pauseMonitoringForDeviceAccess()
        error = nil
        message = write ? "Applying and checking the setting…" : "Reading controller…"
        Task {
            var verified = false
            defer {
                model.deviceBusy = false
                model.resumeMonitoringAfterDeviceAccess(ifNeeded: resumeMonitoring && (!write || verified))
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    if write, let previous {
                        return try Vader5Calibration.setEnabled(requested, replacing: previous)
                    }
                    return try Vader5Calibration.read()
                }.value
                setting = result
                enabled = result.enabled
                verified = true
                message = write ? "Setting applied and readback verified. Reconnect and read again to check persistence." : "Read from controller. Changes are sent only when you click Apply."
            } catch {
                setting = nil
                self.error = String(describing: error); ControllerDiagnostics.shared.record("Calibration UI", stage: "failed", message: String(describing: error))
                message = write ? "The result is unverified. Read the setting again before retrying." : "Could not read calibration support."
            }
        }
    }
}
