import Foundation

/// Converts the bridge's button bits to profile button IDs. Reserved IDs 32–35
/// retain unsupported buttons so capture cannot mistake a chord for one button.
public struct ControllerMappingInput: Sendable {
    public private(set) var held: Set<Int> = []
    public init() {}

    public mutating func update(buttonBits: UInt32, dpad: UInt8,
                                leftTrigger: UInt8, rightTrigger: UInt8) -> Set<Int>? {
        let profileIDs = [4, 5, 7, 8, 10, 11, 6, 9, 14, 15, 18, 19, 20, 21, 32, 33, 34, 35, 16, 17]
        var next = Set(profileIDs.enumerated().compactMap { bit, id in
            buttonBits & (UInt32(1) << bit) != 0 ? id : nil
        })
        let directions: [[Int]] = [[0], [0, 1], [1], [1, 2], [2], [2, 3], [3], [3, 0]]
        if dpad < 8 { next.formUnion(directions[Int(dpad)]) }
        // Hysteresis prevents small trigger noise from becoming extra presses.
        if leftTrigger >= (held.contains(12) ? 80 : 160) { next.insert(12) }
        if rightTrigger >= (held.contains(13) ? 80 : 160) { next.insert(13) }
        guard next != held else { return nil }
        held = next
        return next
    }
}

/// A local-only editor gesture. Requires neutral input between each press and
/// continues with the next source after emitting one assignment.
public struct ControllerMappingCapture: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, releaseForSource, source
        case releaseForTarget(Int), target(Int)
    }
    public struct Assignment: Equatable, Sendable {
        public let source: Int
        public let destination: Int
    }
    public private(set) var phase: Phase = .idle
    public private(set) var issue: String?
    public init() {}
    public var isActive: Bool { phase != .idle }
    public var selectedSource: Int? {
        switch phase {
        case .releaseForTarget(let source), .target(let source): source
        default: nil
        }
    }

    public mutating func start(held: Set<Int>, source: Int? = nil) {
        issue = nil
        if let source {
            guard (0..<22).contains(source) else { cancel(); return }
            phase = held.isEmpty ? .target(source) : .releaseForTarget(source)
        } else {
            phase = held.isEmpty ? .source : .releaseForSource
        }
    }

    public mutating func cancel() { phase = .idle; issue = nil }

    public mutating func receive(_ held: Set<Int>) -> Assignment? {
        switch phase {
        case .idle: return nil
        case .releaseForSource:
            if held.isEmpty { phase = .source; issue = nil }
        case .releaseForTarget(let source):
            if held.isEmpty { phase = .target(source); issue = nil }
        case .source, .target:
            guard !held.isEmpty else { return nil }
            let source = selectedSource
            guard held.count == 1, let button = held.first, (0..<22).contains(button) else {
                issue = held.count > 1 ? "More than one button detected. Release everything and try one button." : "This button cannot be mapped here. Release it and choose another."
                phase = source.map(Phase.releaseForTarget) ?? .releaseForSource
                return nil
            }
            if let source {
                phase = .releaseForSource
                issue = nil
                return Assignment(source: source, destination: button)
            }
            phase = .releaseForTarget(button)
            issue = nil
        }
        return nil
    }
}
