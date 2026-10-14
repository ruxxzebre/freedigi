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
    @State private var confirmRead = false
    @State private var message = "Read the active PC profile from your connected controller."
    @State private var error: String?
    @State private var backupURL: URL?

    private let buttons: [(Int, String)] = [
        (0, "Up"), (1, "Right"), (2, "Down"), (3, "Left"),
        (4, "A"), (5, "B"), (6, "View"), (7, "X"), (8, "Y"), (9, "Menu"),
        (10, "LB"), (11, "RB"), (12, "LT"), (13, "RT"), (14, "L3"), (15, "R3"),
        (16, "C"), (17, "Z"), (18, "M1"), (19, "M2"), (20, "M3"), (21, "M4"),
    ]

    private var original: ControllerProfile? { try? snapshot?.profile() }
    private var hasStagedChanges: Bool {
        guard let original, let edited else { return false }
        return edited != original || title != original.title || vibration != original.vibrationEnabled
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                operationStatus
                if let snapshot, let edited {
                    profileDetails(snapshot)
                    ConfigurationCard(title: "Back buttons", subtitle: "Choose what M1–M4 should do. Selections are staged until you apply or save.", icon: "gamecontroller.fill") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(18..<22, id: \.self) { source in
                                mappingRow(source, profile: edited)
                            }
                        }
                    }
                    ConfigurationCard(title: "Other buttons", subtitle: "Remap face buttons, bumpers, triggers and stick clicks.", icon: "arrow.triangle.swap") {
                        DisclosureGroup("Show all button mappings") {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(0..<18, id: \.self) { source in
                                    mappingRow(source, profile: edited)
                                }
                            }
                            .padding(.top, 14)
                        }
                    }
                } else if !model.deviceBusy {
                    ConfigurationCard(title: "Start with your controller", subtitle: "Read its active PC profile to see current assignments and edit the back buttons.", icon: "gamecontroller") {
                        HStack(spacing: 12) {
                            ForEach(1..<5) { number in
                                Text("M\(number)").font(.title3.monospaced().bold())
                                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                                    .background(SpaceStationTheme.option, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        Text("Reading does not change your mappings. Active monitoring resumes afterward.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                CalibrationView(model: model)
                DisclosureGroup("Advanced local drafts · not sent to the controller") {
                    ControllerConfigurationView(state: model.state)
                }
                .font(.callout).foregroundStyle(.secondary).padding(4)
            }
            .padding(24)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if snapshot != nil { actionBar }
        }
        .confirmationDialog("Discard staged changes and read the controller again?", isPresented: $confirmRead) {
            Button("Discard and read", role: .destructive) { read() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your edits have not been sent to the controller.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Controller settings").font(.title2.bold())
                Text("Button assignments and calibration")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Export controller backup…") { export() }
                Button("Restore backup into editor…") { restore() }
                if let backupURL {
                    Button("Show last backup") { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) }
                }
            } label: { Label("Backups", systemImage: "clock.arrow.circlepath") }
            .disabled(snapshot == nil || model.operationInProgress)
            Button {
                if hasStagedChanges { confirmRead = true } else { read() }
            } label: {
                Label(snapshot == nil ? "Read active profile" : "Read again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.operationInProgress)
        }
    }

    private var operationStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if model.deviceBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: error == nil ? "info.circle" : "exclamationmark.triangle") }
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background((error == nil ? SpaceStationTheme.accent : Color.red).opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func profileDetails(_ snapshot: ControllerProfileSnapshot) -> some View {
        ConfigurationCard(title: "Profile \(Int(snapshot.slot) + 1)", subtitle: "The active PC profile on your controller", icon: "person.crop.rectangle") {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Profile name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $title).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Profile name")
                    Text("Included when you apply or save").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 280)
                Spacer()
                Toggle("Grip vibration", isOn: $vibration).toggleStyle(.switch).fixedSize()
            }
            .disabled(model.operationInProgress)
        }
    }

    private func buttonName(_ id: Int) -> String {
        buttons.first { $0.0 == id }?.1 ?? "Button \(id)"
    }

    private func mappingRow(_ source: Int, profile: ControllerProfile) -> some View {
        let target = profile.mapping(for: source)
        let changed = target != original?.mapping(for: source)
        return HStack(spacing: 12) {
            Text(buttonName(source)).font(.system(.body, design: .rounded).bold())
                .frame(width: 42, height: 42)
                .background(SpaceStationTheme.accent.opacity(source >= 18 ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(changed ? "Staged" : "Current assignment")
                    .font(.caption2).foregroundStyle(changed ? Color.orange : Color.secondary)
                if changed {
                    Text("Was \(original?.mapping(for: source).map(buttonName) ?? "custom")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if target == nil {
                    Text("Selecting a button replaces this custom mapping.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(buttons, id: \.0) { button in
                    Button { stageMapping(source, to: button.0) } label: {
                        if target == button.0 { Label(button.1, systemImage: "checkmark") }
                        else { Text(button.1) }
                    }
                }
            } label: {
                Text(target.map(buttonName) ?? "Custom").fontWeight(.semibold)
                    .frame(minWidth: 58)
            }
            .menuStyle(.borderedButton)
            .accessibilityLabel("Map \(buttonName(source)) to")
            .accessibilityValue(target.map(buttonName) ?? "Custom mapping")
            .disabled(model.operationInProgress)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(SpaceStationTheme.option, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(changed ? Color.orange.opacity(0.5) : Color.clear))
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(hasStagedChanges ? "Changes staged" : "Matches last read",
                      systemImage: hasStagedChanges ? "pencil.circle.fill" : "checkmark.circle")
                    .font(.callout.weight(.semibold))
                Text(model.dryRun ? "Dry run is on. Preview sends no changes." : "Apply is temporary. Save keeps changes after restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if hasStagedChanges {
                Button("Discard edits") {
                    guard let snapshot else { return }
                    do { try load(snapshot); error = nil; message = "Edits discarded. Showing the last controller read." }
                    catch { self.error = String(describing: error) }
                }
                .buttonStyle(.borderless)
            }
            Button(model.dryRun ? "Preview apply" : "Apply until restart") { apply(persist: false) }
                .buttonStyle(.bordered)
            Button(model.dryRun ? "Preview save" : "Save to controller") { apply(persist: true) }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .disabled(model.operationInProgress)
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(SpaceStationTheme.secondDark)
        .overlay(alignment: .top) { Rectangle().fill(SpaceStationTheme.line).frame(height: 1) }
    }

    private func stageMapping(_ source: Int, to destination: Int) {
        guard !model.operationInProgress, edited != nil else { return }
        guard edited?.mapping(for: source) != destination else { return }
        do {
            try edited?.map(source, to: destination)
            error = nil
            message = "\(buttonName(source)) → \(buttonName(destination)) staged. Apply or save when you're ready."
            ControllerDiagnostics.shared.record("Profile UI", stage: "staged", message: message)
        } catch {
            self.error = String(describing: error)
            ControllerDiagnostics.shared.record("Profile UI", stage: "failed", message: String(describing: error))
        }
    }

    private func load(_ snapshot: ControllerProfileSnapshot) throws {
        let profile = try snapshot.profile()
        self.snapshot = snapshot
        edited = profile
        title = profile.title
        vibration = profile.vibrationEnabled
    }

    private func read() {
        guard !model.operationInProgress else { return }
        model.deviceBusy = true
        let resumeMonitoring = model.pauseMonitoringForDeviceAccess()
        snapshot = nil
        edited = nil
        message = "Reading the active profile. Live monitoring is paused while the app accesses controller settings."
        error = nil
        Task {
            defer {
                model.deviceBusy = false
                model.resumeMonitoringAfterDeviceAccess(ifNeeded: resumeMonitoring)
            }
            do {
                let value = try await Task.detached(priority: .userInitiated) { try Vader5Profiles.readActive() }.value
                try load(value)
                message = "Read profile \(Int(value.slot) + 1). Changes below are staged until you apply or save."
            } catch {
                self.error = String(describing: error)
                message = "Profile read failed. Copy the error below or export the Diagnostics log."
                ControllerDiagnostics.shared.record("Profile UI", stage: "failed", message: String(describing: error))
            }
        }
    }

    private func apply(persist: Bool) {
        guard !model.operationInProgress, let snapshot, var profile = edited else { return }
        do { try profile.setTitle(title) }
        catch { self.error = String(describing: error); ControllerDiagnostics.shared.record("Profile UI", stage: "failed", message: String(describing: error)); return }
        profile.setVibrationEnabled(vibration)
        if model.dryRun {
            do {
                let count = try Vader5Profiles.preview(profile, replacing: snapshot, persist: persist)
                error = nil
                message = "Dry run: \(count) write reports planned from the last read profile. Nothing sent or saved. See Diagnostics."
            } catch { self.error = String(describing: error); ControllerDiagnostics.shared.record("Profile UI", stage: "failed", message: String(describing: error)) }
            return
        }
        let requested = profile
        model.deviceBusy = true
        let resumeMonitoring = model.pauseMonitoringForDeviceAccess()
        error = nil
        Task {
            var verified = false
            defer {
                model.deviceBusy = false
                model.resumeMonitoringAfterDeviceAccess(ifNeeded: resumeMonitoring && verified)
            }
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
                verified = true
                message = persist ? "Saved to controller and readback verified." : "Applied in RAM and readback verified. Not saved across restart."
            } catch {
                if let failure = error as? ControllerProfileFailure {
                    self.error = failure.description
                } else {
                    self.error = "\(error) Read the active profile to check its current state before another write."
                }
                message = "Profile changes could not be confirmed. Monitoring remains paused."
                ControllerDiagnostics.shared.record("Profile UI", stage: "failed", message: String(describing: error))
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
            ControllerDiagnostics.shared.record("Export profile", message: "Exported \(url.lastPathComponent).")
        } catch { self.error = String(describing: error); ControllerDiagnostics.shared.record("Profile UI", stage: "failed", message: String(describing: error)) }
    }

    private func restore() {
        guard !model.operationInProgress, let snapshot else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Load a backup for this controller and profile. Review it, then apply or save."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try JSONDecoder().decode(ControllerProfileSnapshot.self, from: Data(contentsOf: url))
            guard backup.identity == snapshot.identity, backup.slot == snapshot.slot else {
                throw ControllerProtocolError.conflict
            }
            let restored = try snapshot.profile().restoringContents(from: backup.profile())
            edited = restored
            title = restored.title
            vibration = restored.vibrationEnabled
            error = nil
            ControllerDiagnostics.shared.record("Restore profile", stage: "staged", message: "Loaded \(url.lastPathComponent). No device writes yet.")
            message = "Backup staged. Apply until restart or Save to controller to restore it."
        } catch { self.error = String(describing: error); ControllerDiagnostics.shared.record("Profile UI", stage: "failed", message: String(describing: error)) }
    }
}
