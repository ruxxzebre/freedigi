import SwiftUI
import Vader5Core

@MainActor
struct TurboButtonView: View {
    @ObservedObject var model: BridgeViewModel
    @State private var setting: ControllerTurboSetting?
    @State private var enabled = false
    @State private var message = "Read the controller to check Turbo-button support."
    @State private var error: String?
    @State private var isAccessing = false

    var body: some View {
        ConfigurationCard(title: "Turbo button", subtitle: "Enable the physical Turbo button’s shortcuts. This setting is shared across profiles.", icon: "bolt.fill") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Enable Turbo button").font(.callout.weight(.semibold))
                    Text("Allows the Turbo button to configure rapid fire and extra-button assignments on the controller.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let setting, setting.supported {
                    Toggle("Enable Turbo button", isOn: $enabled)
                        .labelsHidden().toggleStyle(.switch).fixedSize()
                        .disabled(model.operationInProgress || model.transport != .usbReceiver)
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
                Button(setting == nil ? "Read Turbo setting" : "Read again") { access(write: false) }
                    .buttonStyle(.bordered)
                if let setting, setting.supported {
                    Button(model.dryRun ? "Preview setting" : "Apply setting") { access(write: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(enabled == setting.enabled)
                }
            }
            .controlSize(.large).disabled(model.operationInProgress || model.transport != .usbReceiver)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let setting, !setting.supported {
                Label("This firmware does not advertise Turbo-button support.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Text("After enabling, hold Turbo and press a button to toggle rapid fire for that button. Enabling this switch alone does not turn on rapid fire for every button.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.transport != .usbReceiver {
                Text("Connect the USB receiver to read or change this setting.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: enabled) { value in
            guard let setting, value != setting.enabled else { return }
            ControllerDiagnostics.shared.record("Turbo button UI", stage: "staged",
                message: "Turbo button features: \(value ? "On" : "Off"). Apply to send the change.")
        }
        .onChange(of: model.transport) { _ in
            setting = nil
            error = nil
            message = "Read the controller to check Turbo-button support."
        }
    }

    private func access(write: Bool) {
        guard !model.operationInProgress, model.transport == .usbReceiver else { return }
        let previous = setting
        let requested = enabled
        guard !write || previous != nil else { return }
        if write && model.dryRun {
            guard let previous, previous.supported else { return }
            do {
                try Vader5Turbo.preview(requested, replacing: previous)
                message = "Dry run: Turbo button features would be \(requested ? "enabled" : "disabled"). No command sent."
                error = nil
            } catch {
                self.error = String(describing: error)
                ControllerDiagnostics.shared.record("Turbo button UI", mode: .dryRun,
                    stage: "failed", message: String(describing: error))
            }
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
                        return try Vader5Turbo.setEnabled(requested, replacing: previous)
                    }
                    return try Vader5Turbo.read()
                }.value
                setting = result
                enabled = result.enabled
                verified = true
                message = write ? "Setting applied and readback verified. Reconnect and read again to check persistence." : "Read from controller. Changes are sent only when you click Apply."
            } catch {
                setting = nil
                self.error = String(describing: error); ControllerDiagnostics.shared.record("Turbo button UI", stage: "failed", message: String(describing: error))
                message = write ? "The result is unverified. Read the setting again before retrying." : "Could not read Turbo-button support."
            }
        }
    }
}
