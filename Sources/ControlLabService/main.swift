import Foundation

import ControllerProtocol
import DesktopHID

struct Request: Decodable {
    let action: String
    var path: String = ""
    var dryRun: Bool = true
    var snapshot: ControllerProfileSnapshot?
    var mappings: [String: Int]?
    var persist: Bool?
    var turbo: ControllerTurboSetting?
    var calibration: ControllerCalibrationSetting?
    var enabled: Bool?
    var lighting: LightingSnapshot?
    var color: String?
    var brightness: Int?
    var off: Bool?
    enum CodingKeys: String, CodingKey { case action, path, dryRun, snapshot, mappings, persist, turbo, calibration, enabled, lighting, color, brightness, off }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? true
        snapshot = try c.decodeIfPresent(ControllerProfileSnapshot.self, forKey: .snapshot)
        mappings = try c.decodeIfPresent([String: Int].self, forKey: .mappings)
        persist = try c.decodeIfPresent(Bool.self, forKey: .persist)
        turbo = try c.decodeIfPresent(ControllerTurboSetting.self, forKey: .turbo)
        calibration = try c.decodeIfPresent(ControllerCalibrationSetting.self, forKey: .calibration)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        lighting = try c.decodeIfPresent(LightingSnapshot.self, forKey: .lighting)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        brightness = try c.decodeIfPresent(Int.self, forKey: .brightness)
        off = try c.decodeIfPresent(Bool.self, forKey: .off)
    }
}
func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
func output(_ value: [String: Any]) {
    do {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        data.append(10)
        FileHandle.standardOutput.write(data)
    } catch { FileHandle.standardError.write(Data("Output encoding failed: \(error)\n".utf8)) }
}
func backup<T: Encodable>(_ value: T, name: String) throws {
    let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state").path
    let folder = URL(fileURLWithPath: base).appendingPathComponent("freedigi/backups")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: folder.appendingPathComponent("\(name)-\(UUID().uuidString).json"), options: .atomic)
}
func profileResult(_ snapshot: ControllerProfileSnapshot) throws -> [String: Any] {
    let p = try snapshot.profile()
    return ["snapshot": try object(snapshot), "title": p.title, "slot": Int(snapshot.slot) + 1,
            "mappings": Dictionary(uniqueKeysWithValues: (0..<22).map { (String($0), p.mapping(for: $0) as Any? ?? NSNull()) })]
}
func lightingResult(_ value: LightingSnapshot) throws -> [String: Any] {
    ["lighting": try object(value), "color": value.color, "brightness": value.brightness, "mode": value.mode]
}
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func stop() { lock.lock(); value = true; lock.unlock() }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
func monitor(_ request: Request) throws {
    // EOF on stdin cancels startup retries as well as a running stream.
    let stop = StopFlag()
    Thread.detachNewThread { _ = readLine(); stop.stop() }
    guard let (channel, _) = try ControllerMonitorStartup.handshake(cancelled: { stop.stopped },
        identify: { channel in
            if channel.isClassic { return try ClassicControllerClient(channel: channel).info().identity }
            return try ControllerProfileClient(channel: channel, operation: "starting input monitoring").identity()
        }, open: { try HIDChannel(path: request.path) }) else { return }
    if !channel.isClassic {
    for cmd: UInt8 in [0xa1, 2, 4] { try channel.send(ControllerCommand.frame(cmd)) }
    try channel.send(ControllerCommand.frame(0x11, payload: [255, 1, 255, 255, 255]))
    }
    defer { if !channel.isClassic { try? channel.send(ControllerCommand.frame(0x11, payload: [255, 0, 255, 255, 255])) } }
    output(["event": "monitor", "running": true])
    var last: InputState?, published: TimeInterval = 0
    while !stop.stopped {
        do {
            let report = try channel.receive(timeout: 0.2)
            guard let state = InputState.parse(report) else { continue }
            let now = ProcessInfo.processInfo.systemUptime
            if state != last, now - published >= 1.0/60 {
                output(["event": "input", "state": try object(state)])
                last = state; published = now
            }
        } catch ControllerProtocolError.timeout { continue }
    }
}
func run(_ request: Request) throws -> [String: Any] {
    switch request.action {
    case "devices": return ["devices": try object(HIDDevice.enumerate())]
    case "profileRead":
        let value = try ControllerProfileReadRetry.read {
            let channel = try HIDChannel(path: request.path)
            return try channel.isClassic ? ClassicControllerClient(channel: channel).readActive() : ControllerProfileClient(channel: channel).readActive()
        }
        return try profileResult(value)
    case "profileApply":
        guard let snapshot = request.snapshot, let mappings = request.mappings else { throw ControllerProtocolError.invalid("Read a profile before editing.") }
        var profile = try snapshot.profile()
        for (source, target) in mappings {
            guard let button = Int(source), (0..<22).contains(button), (0..<22).contains(target) else { throw ControllerProtocolError.invalid("Invalid mapping.") }
            if profile.mapping(for: button) != target { try profile.map(button, to: target) }
        }
        let persist = request.persist ?? false
        let plan = try snapshot.identity.isVader4
            ? ClassicControllerProtocol.profilePlan(profile, replacing: snapshot, persist: persist)
            : profile.writeReports(replacing: snapshot.profile(), slot: snapshot.slot, persist: persist)
        if request.dryRun { return ["preview": true, "reports": plan.count, "message": "Profile plan validated. No device opened or writes sent."] }
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state").path
        let folder = URL(fileURLWithPath: base).appendingPathComponent("freedigi/backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("profile-\(UUID().uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        let result: ControllerProfileSnapshot
        if snapshot.identity.isVader4 {
            let channel = try HIDChannel(path: request.path)
            guard channel.isClassic else { throw ControllerProtocolError.conflict }
            result = try ClassicControllerClient(channel: channel).apply(profile, replacing: snapshot, persist: persist)
        } else {
            result = try ControllerProfileWriteRetry.apply(profile, replacing: snapshot, persist: persist) {
                let channel = try HIDChannel(path: request.path)
                guard !channel.isClassic else { throw ControllerProtocolError.conflict }
                return channel
            }
        }
        var response = try profileResult(result); response["backup"] = file.path
        return response
    case "turboRead", "calibrationRead":
        let channel = try HIDChannel(path: request.path)
        if channel.isClassic {
            let identity = try ClassicControllerClient(channel: channel).info().identity
            return [request.action == "turboRead" ? "turbo" : "calibration": ["identity": try object(identity), "supported": false, "enabled": false]]
        }
        if request.action == "turboRead" { return ["turbo": try object(ControllerTurboClient(channel: channel).read())] }
        return ["calibration": try object(ControllerCalibrationClient(channel: channel).read())]
    case "turboApply":
        guard let value = request.turbo, let enabled = request.enabled else { throw ControllerProtocolError.invalid("Read the Turbo setting first.") }
        let plan = try value.reports(enabling: enabled)
        if request.dryRun { return ["preview": true, "reports": plan.count, "message": "Turbo plan validated. No device opened or writes sent."] }
        return ["turbo": try object(ControllerTurboClient(channel: HIDChannel(path: request.path)).setEnabled(enabled, replacing: value))]
    case "calibrationApply":
        guard let value = request.calibration, let enabled = request.enabled else { throw ControllerProtocolError.invalid("Read the calibration setting first.") }
        let plan = try value.reports(enabling: enabled)
        if request.dryRun { return ["preview": true, "reports": plan.count, "message": "Calibration plan validated. No writes sent."] }
        return ["calibration": try object(ControllerCalibrationClient(channel: HIDChannel(path: request.path)).setEnabled(enabled, replacing: value))]
    case "lightingRead":
        let channel = try HIDChannel(path: request.path)
        return try lightingResult(channel.isClassic ? LightingSnapshot.readClassic(channel) : LightingSnapshot.read(channel))
    case "lightingApply":
        guard let value = request.lighting, let color = request.color, let brightness = request.brightness else { throw ControllerProtocolError.invalid("Read lighting first.") }
        let plan = try value.plan(color: color, brightness: brightness, off: request.off ?? false)
        if request.dryRun { return ["preview": true, "reports": plan.count, "message": "Lighting plan validated. No writes sent."] }
        let channel = try HIDChannel(path: request.path)
        guard channel.isClassic == value.identity.isVader4 else { throw ControllerProtocolError.conflict }
        if value.identity.isVader4 { try backup(value, name: "lighting") }
        return try lightingResult(value.apply(channel, reports: plan))
    case "firmwareRead":
        let channel = try HIDChannel(path: request.path)
        if channel.isClassic {
            let info = try ClassicControllerClient(channel: channel).info()
            return ["identity": try object(info.identity), "versions": ["main": info.firmware, "rf": NSNull(), "si": NSNull(), "dongle": NSNull()]]
        }
        try channel.send(ControllerCommand.frame(1))
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while true {
            let report = try channel.receive(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            guard let identity = ControllerIdentity.parse(report), let versions = Vader5Protocol.parseFirmwareVersions(report) else { continue }
            try identity.requireVader5()
            return ["identity": try object(identity), "versions": try object(versions)]
        }
    default: throw ControllerProtocolError.invalid("Unsupported action.")
    }
}
do {
    guard let line = readLine(), line.utf8.count <= 128_000 else { throw ControllerProtocolError.invalid("Missing or oversized request.") }
    let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
    if request.action == "monitor" { try monitor(request) }
    else {
        let result = try ControllerDiagnostics.shared.perform(request.action, mode: request.dryRun ? .dryRun : .live) {
            if ["lightingRead", "turboRead", "calibrationRead", "firmwareRead"].contains(request.action) {
                return try ControllerSettingReadRetry.read(action: request.action) { try run(request) }
            }
            return try run(request)
        }
        output(["ok": true, "result": result, "events": try object(ControllerDiagnostics.shared.snapshot())])
    }
} catch {
    output(["ok": false, "error": String(describing: error), "events": (try? object(ControllerDiagnostics.shared.snapshot())) ?? []])
    exit(1)
}
