import Foundation

public enum ControllerExecutionMode: String, Codable, Sendable {
    case live, dryRun
}

/// Coalesce firmware progress before logging or dispatching UI tasks. Protocol
/// transfers still run every block; the UI receives stage/whole-percent changes.
public final class ControllerProgressFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var previousStage = ""
    private var previousPercent = -1
    public init() {}
    public func accept(stage: String, fraction: Double) -> Bool {
        let percent = Int(max(0, min(1, fraction)) * 100)
        return lock.withLock {
            guard stage != previousStage || percent != previousPercent else { return false }
            previousStage = stage
            previousPercent = percent
            return true
        }
    }
}

public struct ControllerOperationEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let operationID: UUID
    public let operation: String
    public let mode: ControllerExecutionMode
    public let stage: String
    public let message: String
    public let elapsedMilliseconds: Double?
}

/// Bounded session history; no logging of high-rate input reports. Export is an
/// explicit user action. The lock is never held during hardware work or encoding.
public final class ControllerDiagnostics: @unchecked Sendable {
    public static let shared = ControllerDiagnostics()
    private let lock = NSLock()
    private let capacity: Int
    private var events: [ControllerOperationEvent] = []
    private var omitted = 0
    private var tracing = false

    public init(capacity: Int = 2000) { self.capacity = max(1, capacity) }
    public var wireTracing: Bool {
        get { lock.withLock { tracing } }
        set { lock.withLock { tracing = newValue } }
    }

    public func record(_ operation: String, mode: ControllerExecutionMode = .live,
                       stage: String = "info", message: String,
                       operationID: UUID = UUID(), elapsedMilliseconds: Double? = nil) {
        let event = ControllerOperationEvent(id: UUID(), date: Date(), operationID: operationID,
            operation: operation, mode: mode, stage: stage, message: String(message.prefix(4096)),
            elapsedMilliseconds: elapsedMilliseconds)
        lock.withLock {
            if events.count == capacity { events.removeFirst(); omitted += 1 }
            events.append(event)
        }
    }

    public func snapshot() -> [ControllerOperationEvent] { lock.withLock { events } }
    public func clear() { lock.withLock { events.removeAll(); omitted = 0 } }

    /// Compact clipboard report: bounded event text, without raw packet dumps.
    public func supportSummary(metadata: [String: String]) -> String {
        let state = lock.withLock { (events, omitted) }
        let traceStages: Set<String> = ["send", "receive", "feature receive", "planned send"]
        let useful = state.0.filter { !traceStages.contains($0.stage) && $0.operation != "Interfaces" }
        let formatter = ISO8601DateFormatter()
        var lines = ["ControlLab diagnostic summary", "Captured: \(formatter.string(from: Date()))"]
        lines += metadata.keys.sorted().map { "\($0): \(metadata[$0] ?? "")" }
        lines.append("Earlier events dropped: \(state.1)")
        if let failure = useful.last(where: { $0.stage == "failed" }) {
            lines.append("Last failure: \(failure.operation) — \(failure.message.prefix(1000))")
        }
        lines.append("Recent events (up to 80; packet dumps excluded):")
        for event in useful.suffix(80) {
            let duration = event.elapsedMilliseconds.map { String(format: " %.0f ms", $0) } ?? ""
            lines.append("\(formatter.string(from: event.date)) [\(event.operationID.uuidString.prefix(8))] \(event.operation) | \(event.mode.rawValue) | \(event.stage)\(duration): \(event.message.prefix(700))")
        }
        return lines.joined(separator: "\n")
    }

    public func export(metadata: [String: String]) throws -> Data {
        struct Archive: Encodable {
            let schemaVersion = 1
            let metadata: [String: String]
            let omittedEvents: Int
            let events: [ControllerOperationEvent]
        }
        let state = lock.withLock { (events, omitted) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Archive(metadata: metadata, omittedEvents: state.1, events: state.0))
    }

    public func perform<T>(_ operation: String, mode: ControllerExecutionMode = .live,
                           details: String = "", _ body: () throws -> T) rethrows -> T {
        let id = UUID(), start = ProcessInfo.processInfo.systemUptime
        record(operation, mode: mode, stage: "started", message: details, operationID: id)
        do {
            let result = try body()
            record(operation, mode: mode, stage: mode == .dryRun ? "previewed" : "completed",
                   message: mode == .dryRun ? "Preview only; no hardware write performed." : "Operation returned successfully.",
                   operationID: id, elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
            return result
        } catch {
            record(operation, mode: mode, stage: "failed", message: String(describing: error), operationID: id,
                   elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
            throw error
        }
    }

    public func trace(_ operation: String, direction: String, report: [UInt8], operationID: UUID,
                      mode: ControllerExecutionMode = .live) {
        guard wireTracing else { return }
        let hex = report.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
        record(operation, mode: mode, stage: direction, message: "\(report.count) bytes: \(hex)\(report.count > 64 ? " …" : "")", operationID: operationID)
    }

    /// The same report encoder is used for preview and live writes. The body is
    /// never invoked in dry mode, including opening/seizing the device.
    public func write(_ operation: String, mode: ControllerExecutionMode, reports: [[UInt8]],
                      details: String = "", _ body: () throws -> Void) rethrows {
        try perform(operation, mode: mode, details: "\(details) Reports: \(reports.count); bytes: \(reports.reduce(0) { $0 + $1.count }).") {
            if mode == .live { try body() }
            else {
                let id = UUID()
                for report in reports { trace(operation, direction: "planned send", report: report, operationID: id, mode: .dryRun) }
            }
        }
    }
}
