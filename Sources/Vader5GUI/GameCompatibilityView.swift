import AppKit
import GameController
import SwiftUI
import Vader5Core

/// This observes Apple's game-facing API, independently of our receiver parser.
@MainActor
struct GameCompatibilityView: View {
    @ObservedObject var model: BridgeViewModel
    @State private var output = NativeGamepadDiagnostics.shared.snapshot()
    @State private var controllers: [ControllerRow] = []
    @State private var lastInventory: String?
    @State private var message = ""
    private let refresh = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private struct ControllerRow: Identifiable {
        let id: ObjectIdentifier
        let name: String
        let category: String
        let inputs: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ConfigurationCard(title: "Native gamepad output", subtitle: "Experimental · USB receiver", icon: "gamecontroller") {
                    Text("Forward receiver input to a macOS virtual gamepad. Start with the Xbox-compatible profile; generic HID is available for comparison. Keep ControlLab running while playing.")
                    HStack {
                        Picker("Output", selection: $model.mode) {
                            ForEach(Vader5BridgeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .disabled(model.isRunning || model.status == .connecting || model.operationInProgress || model.transport == .bluetooth)
                        Button(model.isRunning ? "Stop" : (model.dryRun ? "Start preview" : "Start output")) { model.toggle() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.operationInProgress || model.status == .connecting || model.transport == .bluetooth || (!model.isRunning && model.mode == .monitor))
                    }
                    if model.transport == .bluetooth {
                        Text("Select USB receiver in the sidebar. Bluetooth monitoring uses the controller's existing gamepad interface.")
                    }
                    Text(model.dryRun
                         ? "Dry run encodes reports and counts them without creating a virtual device. Turn Dry run off, then start output for a live test."
                         : "Live output is enabled. Turning Dry run on stops output; start it again to preview.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                ConfigurationCard(title: "Output diagnostics", subtitle: "Device creation and accepted input are separate checks", icon: "waveform.path") {
                    diagnostic("Signing", NativeGamepadDiagnostics.signingStatus)
                    diagnostic("Profile file", FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile").path)
                               ? "Embedded · authorization checked by macOS at launch" : "Not found in app bundle")
                    diagnostic("Output profile", output.profile)
                    diagnostic("State", output.phase)
                    diagnostic("Virtual device", output.created ? "Created" : "Not active")
                    diagnostic("Reports", "\(output.acceptedReports) accepted · \(output.rejectedReports) rejected · \(output.previewedReports) previewed")
                    if let error = output.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    Text("An entitlement in the signature does not prove that its provisioning profile authorizes it. Accepted reports mean the HID service accepted the data; they do not prove a game received it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ConfigurationCard(title: "Apple GameController test", subtitle: "All gamepads visible to this app through Apple's game API", icon: "checkmark.circle") {
                    if controllers.isEmpty {
                        Text("No controllers visible to GameController.").foregroundStyle(.orange)
                    }
                    ForEach(controllers) { controller in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(controller.name).font(.headline)
                            Text(controller.category).font(.caption).foregroundStyle(.secondary)
                            Text(controller.inputs).font(.caption.monospaced()).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Compare this list before and after starting output. Existing physical controllers also appear here. Move the sticks and press A/B with this window focused. Then test the game itself: games can use a different input API, and macOS may filter virtual controllers.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Copy game compatibility report") { copyReport() }
                    if !message.isEmpty { Text(message).font(.caption) }
                }
                Text("Xbox output currently carries the standard buttons, sticks, triggers and D-pad. C/Z and rear buttons have no separate Xbox outputs; whether saved mappings appear in the receiver stream needs a device test. Rumble and motion output are not implemented. No keyboard/mouse emulation or paid broker is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onAppear { reload() }
        .onReceive(refresh) { _ in reload() }
    }

    private func diagnostic(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }.font(.callout)
    }

    private func reload() {
        output = NativeGamepadDiagnostics.shared.snapshot()
        controllers = GCController.controllers().map { controller in
            let inputs: String
            if let pad = controller.extendedGamepad {
                let buttons: [(String, GCControllerButtonInput)] = [
                    ("A", pad.buttonA), ("B", pad.buttonB), ("X", pad.buttonX), ("Y", pad.buttonY),
                    ("LB", pad.leftShoulder), ("RB", pad.rightShoulder), ("Menu", pad.buttonMenu),
                ] + [("View", pad.buttonOptions), ("Home", pad.buttonHome),
                     ("L3", pad.leftThumbstickButton), ("R3", pad.rightThumbstickButton)]
                    .compactMap { name, button in button.map { (name, $0) } }
                let pressed = buttons.filter { $0.1.isPressed }.map { $0.0 }.joined(separator: ", ")
                inputs = String(format: "L %.2f, %.2f · R %.2f, %.2f · LT %.2f · RT %.2f · D-pad %.0f, %.0f",
                    pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value,
                    pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value,
                    pad.leftTrigger.value, pad.rightTrigger.value, pad.dpad.xAxis.value, pad.dpad.yAxis.value)
                    + "\nPressed: " + (pressed.isEmpty ? "none" : pressed)
            } else { inputs = "No extended gamepad profile available." }
            return ControllerRow(id: ObjectIdentifier(controller), name: controller.vendorName ?? "Unnamed controller",
                                 category: controller.productCategory, inputs: inputs)
        }
        let inventory = controllers.map { "\($0.name) [\($0.category)]" }.sorted().joined(separator: "; ")
        if inventory != lastInventory {
            ControllerDiagnostics.shared.record("GameController visibility", message: inventory.isEmpty ? "No controllers visible." : inventory)
            lastInventory = inventory
        }
    }

    private func copyReport() {
        let report = ControllerDiagnostics.shared.supportSummary(metadata: [
            "Build": Bundle.main.object(forInfoDictionaryKey: "ControlLabSourceRevision") as? String ?? "development",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "Signing": NativeGamepadDiagnostics.signingStatus,
            "Transport": model.transport.rawValue,
            "Bridge status": String(describing: model.status),
            "Native output": "\(output.profile); \(output.phase); dry run \(output.dryRun); created \(output.created)",
            "Reports": "accepted \(output.acceptedReports), rejected \(output.rejectedReports), previewed \(output.previewedReports)",
            "Output error": output.lastError ?? "none",
            "GameController": lastInventory ?? "Not checked",
            "Game compatibility": "Not established by this report; test the target game separately.",
        ])
        NSPasteboard.general.clearContents()
        message = NSPasteboard.general.setString(report, forType: .string) ? "Report copied." : "Could not copy report."
    }
}
