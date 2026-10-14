import Foundation

/// Numbered HID output reports include their report ID as byte zero.
/// This differs from ControllerChannel's unnumbered configuration reports.
public protocol FirmwareChannel: AnyObject {
    func write(_ report: [UInt8]) throws
    func read(timeout: TimeInterval) throws -> [UInt8]
}

public enum FirmwareTransfer {
    static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]
    }
    static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
    static func padded(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count <= 64)
        return bytes + [UInt8](repeating: 0, count: 64 - bytes.count)
    }

    public static func validateTelink(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.count >= 32, bytes.count <= 524288 else {
            throw ControllerProtocolError.invalid("Invalid Telink image size.")
        }
        let size = Int(uint32(bytes, 24))
        guard size >= 32, size <= bytes.count, size.isMultiple(of: 16) else {
            throw ControllerProtocolError.invalid("Invalid Telink image length header.")
        }
        let crc = uint32(bytes, size - 4)
        guard crc != 0, crc != UInt32.max else {
            throw ControllerProtocolError.invalid("Telink image has no checksum.")
        }
        // Matches the vendor loader. This header check does not authenticate the
        // image; callers must bind it to the connected device's official catalog.
        return Data(bytes.prefix(size))
    }

    public static func telink(image: Data, channel: any FirmwareChannel,
                              progress: (Double) -> Void = { _ in }) throws {
        let image = try validateTelink(image)
        func acknowledgement(finishing: Bool = false) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + (finishing ? 15 : 5)
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw ControllerProtocolError.timeout }
                let report = try channel.read(timeout: remaining)
                switch Vader5HIDOTAProtocol.parseResponse(report) {
                case .failed(let code): throw ControllerProtocolError.invalid("Telink update failed: \(code).")
                case .completed:
                    guard finishing else { throw ControllerProtocolError.invalid("Premature Telink completion.") }
                    return
                case .acknowledgement:
                    // Do not let other numbered HID protocols advance this transfer.
                    if !finishing && report.count >= 4 && report[1] == 2 { return }
                default: break
                }
            }
        }
        try channel.write(Vader5HIDOTAProtocol.startReport())
        try acknowledgement()
        var block: UInt16 = 0
        while Int(block) * 16 < image.count {
            let packet = Vader5HIDOTAProtocol.dataReport(image: image, startingBlock: block)
            try channel.write(packet.report)
            try acknowledgement()
            block = packet.nextBlock
            progress(min(0.9, Double(block) * 16 / Double(image.count) * 0.9))
        }
        try channel.write(Vader5HIDOTAProtocol.finishReport(lastBlock: block - 1))
        // The original helper reports success after writing FINISH. We require
        // the device's completion response; the caller must then verify version.
        try acknowledgement(finishing: true)
        progress(0.95)
    }

    public static func crc16CCITT(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc << 1) ^ (crc & 0x8000 != 0 ? 0x1021 : 0) }
        }
        return crc
    }

    public static func jieli(image: Data, channel: any FirmwareChannel,
                             progress: (Double) -> Void = { _ in }) throws {
        guard !image.isEmpty, image.count <= 16 * 1024 * 1024 else {
            throw ControllerProtocolError.invalid("Invalid Jieli image size.")
        }
        let bytes = Array(image)
        func exchange(_ command: UInt8, _ payload: [UInt8] = []) throws -> [UInt8] {
            try channel.write(padded([0xa1, command] + payload))
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw ControllerProtocolError.timeout }
                let report = try channel.read(timeout: remaining)
                guard report.count >= 9, report[0] == 0xa2, report[1] == command else { continue }
                guard report[2] == 0 else {
                    throw ControllerProtocolError.invalid("Jieli command \(command) failed: status \(report[2]), error \(report[3]).")
                }
                return report
            }
        }
        var started = false
        do {
            let response = try exchange(1, le32(UInt32(bytes.count)) + le16(crc16CCITT(bytes)) + le16(256))
            started = true
            let accepted = Int(response[4]) | Int(response[5]) << 8
            let chunkSize = accepted == 0 ? 256 : min(256, accepted)
            for base in stride(from: 0, to: bytes.count, by: chunkSize) {
                let count = min(chunkSize, bytes.count - base)
                for part in stride(from: 0, to: count, by: 54) {
                    let length = min(54, count - part), offset = base + part
                    let last: UInt8 = part + length == count ? 1 : 0
                    _ = try exchange(2, [last] + le16(UInt16(count)) + le32(UInt32(offset))
                        + [UInt8(length)] + bytes[offset..<(offset + length)])
                    progress(Double(offset + length) / Double(bytes.count) * 0.9)
                }
            }
            _ = try exchange(3)
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while ProcessInfo.processInfo.systemUptime < deadline {
                let status = try exchange(4)
                guard status[4] == 0, status[3] != 6 else {
                    throw ControllerProtocolError.invalid("Jieli verification failed: \(status[4]).")
                }
                if status[3] == 5 || status[3] == 7 { progress(0.95); return }
                Thread.sleep(forTimeInterval: 0.2)
            }
            throw ControllerProtocolError.timeout
        } catch {
            if started { try? channel.write(padded([0xa1, 5])) }
            throw error
        }
    }

    public static func validateMegahunt(_ image: Data, fileName: String) throws -> Data {
        let bytes = Array(image)
        guard !fileName.uppercased().contains("_ALL"), bytes.count >= 8, bytes.count <= 2 * 1024 * 1024 else {
            throw ControllerProtocolError.invalid("Megahunt OTA requires an APP image, not a full flash image.")
        }
        let stack = uint32(bytes, 0), reset = uint32(bytes, 4)
        guard (0x20000000..<0x20010000).contains(stack), reset & 1 == 1,
              reset & ~1 >= 0x08005000, UInt64(reset & ~1) < 0x08005000 + UInt64(bytes.count) else {
            throw ControllerProtocolError.invalid("Image is not an MH2213 application at 0x08005000.")
        }
        return image + Data(repeating: 255, count: (4 - image.count % 4) % 4)
    }

    public static func megahunt(image: Data, fileName: String, channel: any FirmwareChannel,
                                progress: (Double) -> Void = { _ in }) throws {
        let bytes = Array(try validateMegahunt(image, fileName: fileName))
        var sequence: UInt16 = 0
        func packet(_ command: UInt8, _ payload: [UInt8]) throws -> [UInt8] {
            guard sequence < UInt16.max else { throw ControllerProtocolError.invalid("Megahunt sequence space exhausted.") }
            sequence += 1
            return padded([5, 75, 54, 85, 80, command] + le16(sequence) + payload)
        }
        func exchange(_ command: UInt8, _ payload: [UInt8] = [], timeout: Double = 3) throws -> [UInt8] {
            let request = try packet(command, payload)
            try channel.write(request)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw ControllerProtocolError.timeout }
                let report = try channel.read(timeout: remaining)
                guard report.count >= 64, report.prefix(5) == [5, 75, 54, 85, 80],
                      report[5] == command, report[6..<8] == request[6..<8] else { continue }
                guard report[8] == 0, report[9] != 3, report[22] == 0 else {
                    throw ControllerProtocolError.invalid("Megahunt command \(command) failed: status \(report[8]), state \(report[9]), error \(report[22]).")
                }
                return report
            }
        }
        let hello = try exchange(1)
        guard hello[42] <= 1 else { throw ControllerProtocolError.invalid("Unsupported K6UP protocol version.") }
        for offset in [24, 32] {
            let base = uint32(hello, offset), end = uint32(hello, offset + 4)
            guard base != 0, end >= base, UInt64(bytes.count) <= UInt64(end) - UInt64(base) + 1 else {
                throw ControllerProtocolError.invalid("Megahunt image exceeds the reported application/backup capacity.")
            }
        }
        let negotiated = Int(hello[40]) | Int(hello[41]) << 8
        let chunk = min(50, negotiated == 0 ? 50 : negotiated) & ~1
        guard chunk >= 2, (bytes.count + chunk - 1) / chunk * 2 + 10 < 65536 else {
            throw ControllerProtocolError.invalid("Invalid Megahunt chunk size or sequence capacity.")
        }
        var begun = false
        var endAttempted = false
        do {
            _ = try exchange(2, le32(UInt32(bytes.count)), timeout: 12)
            begun = true
            for offset in stride(from: 0, to: bytes.count, by: chunk) {
                let length = min(chunk, bytes.count - offset)
                try channel.write(packet(3, le32(UInt32(offset)) + le16(UInt16(length)) + bytes[offset..<(offset + length)]))
                // A small window avoids assuming every DATA packet has an ACK.
                // STATUS supplies the committed watermark used by the vendor updater.
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while true {
                    let status = try exchange(5)
                    let received = Int(uint32(status, 14))
                    guard received <= offset + length else { throw ControllerProtocolError.verification }
                    if received == offset + length { break }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw ControllerProtocolError.timeout }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                progress(Double(offset + length) / Double(bytes.count) * 0.9)
            }
            endAttempted = true
            let end = try exchange(4, timeout: 12)
            guard uint32(end, 10) == bytes.count, uint32(end, 14) == bytes.count else {
                throw ControllerProtocolError.verification
            }
            progress(0.95)
            // A reset can disconnect before ACK; caller must verify the normal
            // device's identity and target version before reporting success.
            try channel.write(packet(7, []))
        } catch {
            if begun && !endAttempted { try? channel.write(packet(6, [])) }
            throw error
        }
    }
}
