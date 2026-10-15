import Foundation
#if os(Linux)
import Glibc
#endif
import ControllerProtocol

public struct HIDLayout: Equatable, Sendable {
    public let outputID: UInt8
    public let outputBytes: Int
    public let inputIDs: Set<UInt8>

    public static func parse(_ bytes: [UInt8]) throws -> HIDLayout {
        var page = 0, size = 0, count = 0, id: UInt8 = 0, index = 0
        var outputs: [UInt8: Int] = [:], inputs: Set<UInt8> = []
        var stack: [(Int, Int, Int, UInt8)] = []
        while index < bytes.count {
            let tag = bytes[index]; index += 1
            guard tag != 0xfe else { throw ControllerProtocolError.invalid("Unsupported long HID descriptor item.") }
            let length = (tag & 3) == 3 ? 4 : Int(tag & 3)
            guard index + length <= bytes.count else { throw ControllerProtocolError.invalid("Truncated HID descriptor.") }
            var value = 0
            for n in 0..<length { value |= Int(bytes[index + n]) << (8 * n) }
            index += length
            switch tag & 0xfc {
            case 0x04: page = value
            case 0x74: size = value
            case 0x94: count = value
            case 0x84:
                guard (1...255).contains(value) else { throw ControllerProtocolError.invalid("Invalid HID report ID.") }
                id = UInt8(value)
            case 0xa4: stack.append((page, size, count, id))
            case 0xb4:
                guard let state = stack.popLast() else { throw ControllerProtocolError.invalid("Invalid HID descriptor stack.") }
                (page, size, count, id) = state
            case 0x90 where page == 0xffa0:
                guard size <= 32, count <= 512 else { throw ControllerProtocolError.invalid("Unsupported HID report size.") }
                outputs[id, default: 0] += size * count
            case 0x80 where page == 0xffa0: inputs.insert(id)
            default: break
            }
        }
        let matches = outputs.filter { (248...512).contains($0.value) && $0.value.isMultiple(of: 8) }
        guard matches.count == 1, let output = matches.first, !inputs.isEmpty else {
            throw ControllerProtocolError.invalid("No unambiguous Flydigi configuration collection.")
        }
        return .init(outputID: output.key, outputBytes: output.value / 8, inputIDs: inputs)
    }

    public func output(_ report: [UInt8]) throws -> [UInt8] {
        guard report.count <= outputBytes || report.dropFirst(outputBytes).allSatisfy({ $0 == 0 }) else {
            throw ControllerProtocolError.invalid("Command exceeds HID output size.")
        }
        return [outputID] + Array(report.prefix(outputBytes)) + Array(repeating: 0, count: max(0, outputBytes - report.count))
    }
    public func input(_ report: [UInt8]) -> [UInt8]? {
        if inputIDs.contains(0), report.starts(with: [0x5a, 0xa5]) { return report }
        if let id = report.first, id != 0, inputIDs.contains(id), report.dropFirst().starts(with: [0x5a, 0xa5]) {
            return Array(report.dropFirst())
        }
        return nil
    }
}

#if os(Linux)
public struct HIDDevice: Codable, Sendable {
    public let path: String
    public let name: String
    public let product: String
    public let accessible: Bool

    public static func enumerate(root: String = "/sys/class/hidraw") -> [HIDDevice] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.sorted().compactMap { name in
            let base = "\(root)/\(name)/device"
            guard let text = try? String(contentsOfFile: base + "/uevent", encoding: .utf8),
                  let row = text.split(separator: "\n").first(where: { $0.hasPrefix("HID_ID=") }) else { return nil }
            let fields = row.dropFirst(7).split(separator: ":")
            guard fields.count == 3, UInt32(fields[1], radix: 16) == 0x37d7,
                  let product = UInt32(fields[2], radix: 16), [0x2401, 0x2502].contains(product),
                  let descriptor = try? Data(contentsOf: URL(fileURLWithPath: base + "/report_descriptor")),
                  (try? HIDLayout.parse(Array(descriptor))) != nil else { return nil }
            let label = text.split(separator: "\n").first(where: { $0.hasPrefix("HID_NAME=") }).map { String($0.dropFirst(9)) } ?? "Flydigi controller"
            let path = "/dev/\(name)"
            return .init(path: path, name: label, product: String(format: "%04x", product), accessible: access(path, R_OK | W_OK) == 0)
        }
    }
}

public final class HIDChannel: ControllerChannel {
    private let fd: Int32
    private let layout: HIDLayout
    public init(path: String) throws {
        guard HIDDevice.enumerate().contains(where: { $0.path == path }) else {
            throw ControllerProtocolError.invalid("Selected controller is no longer present. Refresh devices.")
        }
        let descriptor = try Data(contentsOf: URL(fileURLWithPath: "/sys/class/hidraw/\(URL(fileURLWithPath: path).lastPathComponent)/device/report_descriptor"))
        layout = try HIDLayout.parse(Array(descriptor))
        fd = Glibc.open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ControllerProtocolError.invalid("Cannot open \(path): \(String(cString: strerror(errno))). Install the supplied udev rule, then reconnect the receiver.") }
        // Cooperating ControlLab processes cannot interleave profile transactions.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Glibc.close(fd)
            throw ControllerProtocolError.invalid("Controller is busy in another FreeDigi operation.")
        }
    }
    deinit { _ = flock(fd, LOCK_UN); Glibc.close(fd) }
    public func send(_ report: [UInt8]) throws {
        let bytes = try layout.output(report)
        let sent = bytes.withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
        guard sent == bytes.count else { throw ControllerProtocolError.invalid("HID write failed: \(String(cString: strerror(errno))). Read the device before retrying.") }
    }
    public func receive(timeout: TimeInterval) throws -> [UInt8] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw ControllerProtocolError.timeout }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Glibc.poll(&pfd, 1, Int32(min(60_000, max(1, left * 1000))))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0, pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
                throw ControllerProtocolError.invalid("Controller disconnected or HID transport failed.")
            }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 512)
            let count = bytes.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw ControllerProtocolError.invalid("Controller input closed.") }
            if let report = layout.input(Array(bytes.prefix(count))) { return report }
        }
    }
}

#endif
