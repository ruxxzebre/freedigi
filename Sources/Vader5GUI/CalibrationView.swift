import SwiftUI
import Vader5Core

@MainActor
struct CalibrationView: View {
    @ObservedObject var model: BridgeViewModel
    @State private var setting: ControllerCalibrationSetting?
    @State private var enabled = false
    @State private var message = "Read the controller to check automatic stick-calibration support."
    @State private var error: String?
    @State private var isAccessing = false

    var body: some View {
        ConfigurationCard(title: "Stick calibration", subtitle: "Automatic centering is a controller setting shared across profiles.", icon: "scope") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Automatic stick calibration").font(.callout.weight(.semibold))
                    Text("Lets the controller firmware adjust stick centering. Applying this setting changes whether the feature is enabled.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let setting, setting.supported {
                    Toggle("Automatic stick calibration", isOn: $enabled)
                        .labelsHidden().toggleStyle(.switch).fixedSize()
                        .disabled(model.operationInProgress)
                } else {
                    Text(setting == nil ? "NOT READ" : "UNAVAILABLE")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(SpaceStationTheme.option, in: Capsule())
                }
            }
            Divider()
            HStack(spacing: 12) {
                if isAccessing { ProgressView().controlSize(.small) }
                else if let setting, setting.supported {
                    Label("On controller: \(setting.enabled ? "On" : "Off")", systemImage: "gamecontroller")
                        .font(.callout).foregroundStyle(.secondary)
                    if enabled != setting.enabled {
                        Text("Change staged").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(setting == nil ? "Read calibration setting" : "Read again") { access(write: false) }
                    .buttonStyle(.bordered)
                if let setting, setting.supported {
                    Button(model.dryRun ? "Preview setting" : "Apply setting") { access(write: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(enabled == setting.enabled)
                }
            }
            .controlSize(.large).disabled(model.operationInProgress)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let setting, !setting.supported {
                Label("This firmware does not advertise automatic calibration support.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Looking for manual calibration?").font(.callout.weight(.medium))
                    Text("The guided stick, trigger and gyro calibration procedure is not available in ControlLab yet. This switch does not start that procedure.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(SpaceStationTheme.option, in: RoundedRectangle(cornerRadius: 10))
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
        isAccessing = true
        model.deviceBusy = true
        let resumeMonitoring = model.pauseMonitoringForDeviceAccess()
        error = nil
        message = write ? "Applying and checking the setting…" : "Reading controller…"
        Task {
            var verified = false
            defer {
                isAccessing = false
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
