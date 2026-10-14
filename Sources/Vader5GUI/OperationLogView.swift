import AppKit
import SwiftUI
import Vader5Core

@MainActor
struct OperationLogView: View {
    @ObservedObject var model: BridgeViewModel
    @State private var events: [ControllerOperationEvent] = []
    @State private var wireTracing = ControllerDiagnostics.shared.wireTracing
    @State private var message = ""
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title2.bold())
            DisclosureGroup("Feature support and validation") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Dongle connection and lighting: reported working on your Mac.")
                    Text("Profiles and automatic stick calibration: implemented; device readback required after writes. Manual calibration is not implemented.")
                    Text("Firmware: native transfer paths are experimental; real flashing remains unverified. Jieli .ufw and unknown bootloader transitions are unsupported.")
                    Text("Advanced stick/trigger curves, gyro and macros: local drafts only.")
                    Text("Virtual gamepad: requires Apple's approved virtual-HID entitlement. Lighting access does not establish game compatibility.")
                    Text("Dry run: validates and previews supported settings writes. Firmware preview describes the prepared update; it does not prove bootloader compatibility. The separate firmware simulator uses a simulated transport.")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Text("Session events include operation mode, outcome and duration. The log retains the latest 2,000 events; the view shows the latest 200. Logs stay in this app until you export them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Inspect connected interfaces") { inspect() }.disabled(model.deviceBusy)
                Button("Copy log") { copySummary() }
                    .help("Copy build, connection state and recent operation results without raw packet dumps.")
                Button("Export session log…") { export() }
                Button("Clear log") { ControllerDiagnostics.shared.clear(); reload() }
            }
            Toggle("Include configuration packet traces", isOn: $wireTracing)
                .onChange(of: wireTracing) { ControllerDiagnostics.shared.wireTracing = $0 }
            Text("Packet traces may contain profile names, mappings and device identifiers. Live button/stick reports are excluded. Review exported files before sharing.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Build: \(Bundle.main.object(forInfoDictionaryKey: "ControlLabSourceRevision") as? String ?? "development") · \(ProcessInfo.processInfo.operatingSystemVersionString)")
                .font(.caption.monospaced()).textSelection(.enabled)
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(events.suffix(200).reversed()) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(event.date, style: .time)
                                Text("\(event.operation) · \(event.mode.rawValue) · \(event.stage)")
                                if let elapsed = event.elapsedMilliseconds { Text(String(format: "%.0f ms", elapsed)) }
                            }.font(.caption.bold())
                            Text(event.message).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        .foregroundStyle(event.stage == "failed" ? .red : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }
        }
        .padding(24)
        .onAppear { reload() }
        .onReceive(refresh) { _ in reload() }
    }

    private func reload() { events = ControllerDiagnostics.shared.snapshot() }

    private func copySummary() {
        let summary = ControllerDiagnostics.shared.supportSummary(metadata: [
            "Build": Bundle.main.object(forInfoDictionaryKey: "ControlLabSourceRevision") as? String ?? "development",
            "App version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "Transport": model.transport.rawValue,
            "Input mode": model.mode.rawValue,
            "Bridge status": String(describing: model.status),
            "Monitoring paused": String(model.monitoringPaused),
            "Execution mode": model.executionMode.rawValue,
            "Operation in progress": String(model.operationInProgress),
            "App error": model.errorMessage ?? "none",
        ])
        NSPasteboard.general.clearContents()
        message = NSPasteboard.general.setString(summary, forType: .string)
            ? "Diagnostic summary copied to clipboard." : "Could not copy the summary. Use Export session log instead."
    }

    private func inspect() {
        Task {
            do {
                let interfaces = try await Task.detached(priority: .userInitiated) {
                    try ControllerDiagnostics.shared.perform("Inspect interfaces") {
                        let result = try Vader5DeviceProbe.enumerate()
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        ControllerDiagnostics.shared.record("Interfaces", message: String(decoding: try encoder.encode(result), as: UTF8.self))
                        return result.count
                    }
                }.value
                message = "Found \(interfaces) matching HID interfaces. Details are in the log."
            } catch { message = String(describing: error) }
            reload()
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "controllab-session-\(Int(Date().timeIntervalSince1970)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ControllerDiagnostics.shared.export(metadata: [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "sourceRevision": Bundle.main.object(forInfoDictionaryKey: "ControlLabSourceRevision") as? String ?? "development",
                "executionMode": model.executionMode.rawValue,
                "transport": String(describing: model.transport),
                "bridgeStatus": model.statusTitle,
                "hardwareValidation": "User reported dongle connection and lighting working; other write paths are not hardware-validated.",
            ])
            try data.write(to: url, options: .atomic)
            message = "Exported \(url.lastPathComponent)."
        } catch { message = String(describing: error) }
    }
}
