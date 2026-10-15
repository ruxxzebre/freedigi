import Foundation
import CryptoKit
import ControllerProtocol

public enum Vader5FirmwareModule: String, CaseIterable, Sendable {
    case main, rf, si, dongle
    var target: UInt8 {
        switch self { case .main: 0; case .rf: 1; case .si: 2; case .dongle: 6 }
    }
    func version(in versions: Vader5FirmwareVersions) -> String? {
        switch self { case .main: versions.main; case .rf: versions.rf; case .si: versions.si; case .dongle: versions.dongle }
    }
    func release(in catalog: Vader5FirmwareCatalog) -> Vader5FirmwareRelease? {
        switch self { case .main: catalog.main; case .rf: catalog.rf; case .si: catalog.si; case .dongle: catalog.dongle }
    }
}

public struct Vader5PreparedFirmware: Sendable {
    public let module: Vader5FirmwareModule
    public let release: Vader5FirmwareRelease
    public let identity: ControllerIdentity
    public let installedVersion: String
    public let sha256: String
    public var byteCount: Int { image.count }
    fileprivate let location: UInt32
    fileprivate let image: Data
}

public struct Vader5FirmwareDeviceInfo: Sendable {
    public let identity: ControllerIdentity
    public let versions: Vader5FirmwareVersions
    let location: UInt32
}

/// Live firmware flow: identify -> official catalog -> download -> validate ->
/// re-identify -> bootloader -> transfer -> normal identity/version verification.
/// There is deliberately no entry point for flashing an arbitrary local file.
public enum Vader5FirmwareInstaller {
    private static let appVersion = "4.2.0.9"

    public static func readDeviceInfo() throws -> Vader5FirmwareDeviceInfo {
        try ControllerDiagnostics.shared.perform("Read firmware inventory") {
            let info = try readInfo(ControllerHIDSession())
            ControllerDiagnostics.shared.record("Firmware inventory", stage: "read",
                message: "Device ID: \(info.identity.deviceID); connection: \(info.identity.connection); versions: \(info.versions).")
            return info
        }
    }

    private static func readInfo(_ channel: ControllerHIDSession) throws -> Vader5FirmwareDeviceInfo {
        try channel.send(ControllerCommand.frame(1))
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            let report = try channel.receive(timeout: deadline - ProcessInfo.processInfo.systemUptime)
            guard let identity = ControllerIdentity.parse(report),
                  let versions = Vader5Protocol.parseFirmwareVersions(report) else { continue }
            try identity.requireVader5()
            guard let location = channel.locationID, location != 0 else {
                throw ControllerProtocolError.invalid("USB location is unavailable; cannot bind an update to this device.")
            }
            return Vader5FirmwareDeviceInfo(identity: identity, versions: versions, location: location)
        }
        throw ControllerProtocolError.timeout
    }

    public static func prepare(module: Vader5FirmwareModule) async throws -> Vader5PreparedFirmware {
        let id = UUID(), start = ProcessInfo.processInfo.systemUptime
        ControllerDiagnostics.shared.record("Prepare firmware", stage: "started", message: "Module: \(module.rawValue). Read device and download official package; no firmware write.", operationID: id)
        do {
            let result = try await preparePackage(module: module)
            ControllerDiagnostics.shared.record("Prepare firmware", stage: "completed", message: "\(result.installedVersion) -> \(result.release.version); \(result.byteCount) bytes; SHA-256 \(result.sha256).", operationID: id, elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
            return result
        } catch {
            ControllerDiagnostics.shared.record("Prepare firmware", stage: "failed", message: String(describing: error), operationID: id, elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
            throw error
        }
    }

    private static func preparePackage(module: Vader5FirmwareModule) async throws -> Vader5PreparedFirmware {
        let device = try await Task.detached(priority: .userInitiated) {
            try readInfo(ControllerHIDSession())
        }.value
        guard let current = module.version(in: device.versions) else {
            throw ControllerProtocolError.invalid("The connected device did not report its \(module.rawValue) firmware version.")
        }
        guard module == .dongle || device.identity.connection == 1 else {
            throw ControllerProtocolError.invalid("Connect the controller by USB cable for controller-chip updates. Use the receiver connection for a receiver update.")
        }
        if module == .dongle && device.identity.connection != 2 {
            throw ControllerProtocolError.invalid("Connect through the receiver to update receiver firmware.")
        }
        let catalog = try await Vader5FirmwareUpdateClient().check(versions: device.versions,
            appVersion: appVersion, deviceID: Int(device.identity.deviceID))
        guard let release = module.release(in: catalog) else {
            throw ControllerProtocolError.invalid("The catalog offered no \(module.rawValue) package for this query. This does not establish that the device is up to date.")
        }
        try FirmwareVersionPolicy.requireUpgrade(offered: release.version, installed: current)
        guard release.minimumAppVersion.isEmpty || release.minimumAppVersion.compare(appVersion, options: .numeric) != .orderedDescending else {
            throw ControllerProtocolError.invalid("This firmware requires a newer catalog client (\(release.minimumAppVersion)).")
        }
        let url = try Vader5FirmwareDownloadClient.secureURL(for: release.url)
        func official(_ url: URL?) -> Bool {
            guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
            return host == "flydigi.com" || host.hasSuffix(".flydigi.com")
        }
        guard official(url) else { throw ControllerProtocolError.invalid("Firmware download is not on an official Flydigi HTTPS host.") }
        let (download, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard official(response.url) else { throw ControllerProtocolError.invalid("Firmware download redirected outside Flydigi HTTPS.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: download.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024 else {
            throw ControllerProtocolError.invalid("Firmware download exceeds the supported size.")
        }
        let image = try Data(contentsOf: download)
        try Vader5FirmwareDownloadClient.validate(data: image, response: response)
        switch module {
        case .rf, .dongle: _ = try FirmwareTransfer.validateTelink(image)
        case .main: try LegacyMegahunt.validate(image, fileName: url.lastPathComponent)
        case .si:
            guard url.pathExtension.lowercased() == "bin", image.count <= 16 * 1024 * 1024 else {
                throw ControllerProtocolError.invalid("This SI release needs the Windows .ufw updater; only the recovered Jieli HID .bin protocol is supported.")
            }
        }
        return Vader5PreparedFirmware(module: module, release: release, identity: device.identity,
            installedVersion: current, sha256: SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined(),
            location: device.location, image: image)
    }

    /// Synchronous, run on a dedicated background thread. Progress is 0...1.
    /// A transfer completing is not success until the normal firmware version matches.
    public static func install(_ prepared: Vader5PreparedFirmware, mode: ControllerExecutionMode = .live,
                               progress: @Sendable (String, Double) -> Void = { _, _ in }) throws {
        try ControllerDiagnostics.shared.perform("Install firmware", mode: mode,
            details: "Module: \(prepared.module.rawValue); \(prepared.installedVersion) -> \(prepared.release.version); \(prepared.byteCount) bytes; SHA-256 \(prepared.sha256).") {
            if mode == .dryRun {
                ControllerDiagnostics.shared.record("Firmware plan", mode: .dryRun, stage: "previewed", message: "Would recheck identity/version/USB port, enter the matching bootloader, transfer and verify, then wait for the expected installed version. No device opened, no boot command or image sent. This preview cannot validate bootloader compatibility or acknowledgements.")
                progress("Update plan previewed; no firmware written", 1)
                return
            }
            let filter = ControllerProgressFilter()
            try installLive(prepared) { stage, fraction in
                guard filter.accept(stage: stage, fraction: fraction) else { return }
                ControllerDiagnostics.shared.record("Firmware progress", stage: "progress", message: "\(stage): \(Int(fraction * 100))%")
                progress(stage, fraction)
            }
        }
    }

    private static func installLive(_ prepared: Vader5PreparedFirmware,
                               progress: @Sendable (String, Double) -> Void) throws {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Controller firmware update")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try enterUpdateMode(prepared)
        progress("Waiting for update interface", 0)
        try transfer(prepared, progress: progress)
        progress("Waiting for controller and verifying installed version", 0.96)
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        var lastError = "Device has not reconnected."
        while ProcessInfo.processInfo.systemUptime < deadline {
            do {
                let device = try readInfo(ControllerHIDSession(expectedLocation: prepared.location))
                guard device.identity == prepared.identity else { throw ControllerProtocolError.conflict }
                let version = prepared.module.version(in: device.versions)
                guard version == prepared.release.version else {
                    throw ControllerProtocolError.invalid("Read version \(version ?? "unknown"); expected \(prepared.release.version).")
                }
                progress("Installed version verified", 1)
                return
            } catch { lastError = String(describing: error) }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ControllerProtocolError.invalid("Transfer finished, but installation could not be verified: \(lastError)")
    }

    private static func enterUpdateMode(_ prepared: Vader5PreparedFirmware) throws {
        let channel = try ControllerHIDSession(expectedLocation: prepared.location)
        let device = try readInfo(channel)
        guard device.identity == prepared.identity,
              prepared.module.version(in: device.versions) == prepared.installedVersion else {
            throw ControllerProtocolError.conflict
        }
        guard prepared.module != .dongle else { return } // Engine skips receiver mode switch.
        // Native Engine 5.0.1.6 writes an unnumbered 32-byte frame with checksum
        // at byte 31. This is distinct from the old SDK's variable checksum offset.
        var report = [UInt8](repeating: 0, count: 32)
        report.replaceSubrange(0..<5, with: [0x5a, 0xa5, 0x1f, 3, prepared.module.target])
        report[31] = report[2..<31].reduce(0, &+)
        try channel.send(report)
    }

    private static func transfer(_ prepared: Vader5PreparedFirmware,
                                  progress: @Sendable (String, Double) -> Void) throws {
        let product: Int? = switch prepared.module { case .main: 0x2f05; case .si: 0x2f09; default: nil }
        let usage = prepared.module == .dongle ? 0xffee : 0xffef
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var channel: ControllerHIDSession?
        var legacy = false
        while channel == nil && ProcessInfo.processInfo.systemUptime < deadline {
            channel = try? ControllerHIDSession(product: product, usagePage: usage, expectedLocation: prepared.location)
            if channel == nil && prepared.module == .main {
                channel = try? ControllerHIDSession(vendor: 0x0483, product: 0x5720,
                    usagePage: nil, expectedLocation: prepared.location)
                legacy = channel != nil
            }
            if channel == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard let channel else {
            throw ControllerProtocolError.invalid("Expected update interface did not appear on the same USB port. No image was sent. A 2503-only bootloader or a different transition still needs a hardware capture.")
        }
        let update: (Double) -> Void = { progress("Writing and verifying \(prepared.module.rawValue) firmware", $0) }
        switch prepared.module {
        case .rf, .dongle: try FirmwareTransfer.telink(image: prepared.image, channel: channel, progress: update)
        case .si: try FirmwareTransfer.jieli(image: prepared.image, channel: channel, progress: update)
        case .main:
            if legacy {
                try LegacyMegahunt.transfer(image: prepared.image,
                    fileName: prepared.release.url.lastPathComponent, channel: channel, progress: update)
            } else {
                try FirmwareTransfer.megahunt(image: prepared.image,
                    fileName: prepared.release.url.lastPathComponent, channel: channel, progress: update)
            }
        }
    }
}
