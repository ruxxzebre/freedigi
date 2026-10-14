import AppKit
import SwiftUI
import Vader5Core

@MainActor
struct DeviceProfilesView: View {
    @ObservedObject var model: BridgeViewModel
    @State private var snapshot: ControllerProfileSnapshot?
    @State private var edited: ControllerProfile?
    @State private var title = ""
    @State private var vibration = true
    @State private var source = 18
    @State private var destination = 4
    @State private var message = "Read the active PC profile from your connected controller."
    @State private var error: String?
    @State private var backupURL: URL?

    private let buttons: [(Int, String)] = [
        (0, "Up"), (1, "Right"), (2, "Down"), (3, "Left"),
        (4, "A"), (5, "B"), (6, "View"), (7, "X"), (8, "Y"), (9, "Menu"),
        (10, "LB"), (11, "RB"), (12, "LT"), (13, "RT"), (14, "L3"), (15, "R3"),
        (16, "C"), (17, "Z"), (18, "M1"), (19, "M2"), (20, "M3"), (21, "M4"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Controller profiles").font(.title2.bold())
                Text(message).foregroundStyle(.secondary)
                HStack {
                    Button("Read active profile") { read() }
                    Button("Export backup…") { export() }.disabled(snapshot == nil)
                    if let backupURL {
                        Button("Show last backup") { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) }
                    }
                }
                .disabled(model.deviceBusy)
                if let snapshot, let edited {
                    Text("Profile \(Int(snapshot.slot) + 1) · Vader 5 device \(snapshot.identity.deviceID)")
                        .font(.headline)
                    TextField("Profile name (10 UTF-16 characters)", text: $title)
                    Toggle("Grip vibration", isOn: $vibration)
                    HStack {
                        Picker("Button", selection: $source) {
                            ForEach(buttons, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Picker("Maps to", selection: $destination) {
                            ForEach(buttons, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Button("Stage mapping") {
                            do {
                                try self.edited?.map(source, to: destination)
                                message = "Mapping staged. Apply or save to send it to the controller."
                            } catch { self.error = String(describing: error) }
                        }
                    }
                    Text(mappingDescription(edited)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Apply until restart") { apply(persist: false) }
                        Button("Save to controller") { apply(persist: true) }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("Each write creates a backup and verifies the result by reading it back. Live monitoring stops while profiles are accessed. Select another PC profile on the controller, then read it here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.deviceBusy { ProgressView("Accessing controller…") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                DisclosureGroup("Advanced local drafts (not sent to the controller)") {
                    ControllerConfigurationView(state: model.state)
                }
            }
            .disabled(model.deviceBusy)
            .padding(24)
        }
    }

    private func mappingDescription(_ profile: ControllerProfile) -> String {
        guard let target = profile.mapping(for: source) else {
            return "Selected button uses a macro, turbo or keyboard mapping. Staging a simple mapping replaces it."
        }
        return "Current staged mapping: \(buttons.first { $0.0 == target }?.1 ?? String(target))"
    }

    private func load(_ snapshot: ControllerProfileSnapshot) throws {
        let profile = try snapshot.profile()
        self.snapshot = snapshot
        edited = profile
        title = profile.title
        vibration = profile.vibrationEnabled
    }

    private func read() {
        guard !model.deviceBusy else { return }
        model.deviceBusy = true
        model.stop()
        error = nil
        Task {
            defer { model.deviceBusy = false }
            do {
                let value = try await Task.detached(priority: .userInitiated) { try Vader5Profiles.readActive() }.value
                try load(value)
                message = "Read profile \(Int(value.slot) + 1). Changes below are staged until you apply or save."
            } catch { self.error = String(describing: error) }
        }
    }

    private func apply(persist: Bool) {
        guard !model.deviceBusy, let snapshot, var profile = edited else { return }
        do { try profile.setTitle(title) }
        catch { self.error = String(describing: error); return }
        profile.setVibrationEnabled(vibration)
        let requested = profile
        model.deviceBusy = true
        model.stop()
        error = nil
        Task {
            defer { model.deviceBusy = false }
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("ControlLab/ProfileBackups", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let backup = directory.appendingPathComponent("profile-\(snapshot.slot + 1)-\(UUID().uuidString).json")
                backupURL = backup
                let value = try await Task.detached(priority: .userInitiated) {
                    try Vader5Profiles.apply(requested, replacing: snapshot, persist: persist, backupURL: backup)
                }.value
                try load(value)
                message = persist ? "Saved to controller and readback verified." : "Applied in RAM and readback verified. Not saved across restart."
            } catch {
                self.error = "\(error) The device may have partial changes; read its profile again."
                self.snapshot = nil
                self.edited = nil
            }
        }
    }

    private func export() {
        guard let snapshot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vader5-profile-\(snapshot.slot + 1).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            backupURL = url
        } catch { self.error = String(describing: error) }
    }
}
