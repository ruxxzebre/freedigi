import SwiftUI
import Vader5Core

@MainActor
struct FirmwareInstallView: View {
    @ObservedObject var bridge: BridgeViewModel
    @State private var module: Vader5FirmwareModule = .main
    @State private var prepared: Vader5PreparedFirmware?
    @State private var message = "Connect by USB cable for controller updates, or through the receiver for a receiver update."
    @State private var error: String?
    @State private var progress = 0.0
    @State private var confirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Firmware updates").font(.title2.bold())
                Text(message).foregroundStyle(.secondary)
                Picker("Chip", selection: $module) {
                    Text("Controller main").tag(Vader5FirmwareModule.main)
                    Text("Controller radio").tag(Vader5FirmwareModule.rf)
                    Text("SI / Bluetooth").tag(Vader5FirmwareModule.si)
                    Text("USB receiver").tag(Vader5FirmwareModule.dongle)
                }
                .onChange(of: module) { _ in prepared = nil }
                Button("Check and prepare official update") { prepare() }
                if let prepared {
                    Text("\(prepared.installedVersion) → \(prepared.release.version)").font(.headline)
                    Text(prepared.release.info)
                    Text("\(prepared.byteCount) bytes · SHA-256 \(prepared.sha256)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button(bridge.dryRun ? "Preview update plan" : "Install prepared update…") {
                        if bridge.dryRun { install() } else { confirmation = true }
                    }
                        .buttonStyle(.borderedProminent)
                }
                if bridge.deviceBusy { ProgressView(value: progress) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Text("Firmware flashing has not yet been hardware-validated. Jieli .ufw and unrecognized bootloader transitions remain unsupported. Installation is only reported as successful after the device returns with the expected firmware version.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Package inspection and protocol simulator") {
                    FirmwareDiagnosticsView(bridge: bridge)
                }
            }
            .padding(24)
            .disabled(bridge.operationInProgress)
        }
        .confirmationDialog("Install \(prepared?.release.version ?? "") firmware?", isPresented: $confirmation) {
            Button("Install firmware", role: .destructive) { install() }
        } message: {
            Text("Keep the device connected and the Mac awake until verification finishes. Do not close ControlLab during the update.")
        }
    }

    private func prepare() {
        guard !bridge.operationInProgress else { return }
        bridge.pauseMonitoringForDeviceAccess()
        bridge.deviceBusy = true
        prepared = nil
        error = nil
        progress = 0
        let module = self.module
        Task {
            defer { bridge.deviceBusy = false }
            do {
                prepared = try await Vader5FirmwareInstaller.prepare(module: module)
                message = "Official update downloaded for this device. Review it before installing."
            } catch { self.error = String(describing: error); ControllerDiagnostics.shared.record("Firmware UI", stage: "failed", message: String(describing: error)) }
        }
    }

    private func install() {
        guard !bridge.operationInProgress, let prepared else { return }
        bridge.pauseMonitoringForDeviceAccess()
        bridge.deviceBusy = true
        error = nil
        let mode = bridge.executionMode
        if mode == .live { self.prepared = nil }
        Task {
            defer { bridge.deviceBusy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Vader5FirmwareInstaller.install(prepared, mode: mode) { stage, fraction in
                        Task { @MainActor in message = stage; progress = fraction }
                    }
                }.value
                message = mode == .dryRun ? "Update plan previewed. No firmware written; see Diagnostics." : "Installed \(prepared.release.version); device identity and version verified."
            } catch {
                self.error = "\(error) Installation is not confirmed. Keep the device connected and retain this message."
            }
        }
    }
}
