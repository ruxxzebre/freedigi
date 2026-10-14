import Foundation

public enum Vader5HIDOTAProtocol {
    public static let reportLength = 64
    public static let controllerUsagePage = 0xffef
    public static let moduleUsagePage = 0xffee

    public enum Response: Sendable, Equatable {
        case acknowledgement
        case completed
        case failed(UInt8)
        case firmwareInfo(version: UInt32, crc: UInt32)
        case unknown
    }

    public static func startReport() -> [UInt8] {
        report([0x02, 0x02, 0x00, 0x01, 0xff])
    }

    public static func dataReport(image: Data, startingBlock: UInt16) -> (report: [UInt8], nextBlock: UInt16) {
        var records: [UInt8] = []
        var block = startingBlock

        for _ in 0..<3 {
            let offset = Int(block) * 16
            guard offset < image.count else { break }

            let bytes = (0..<16).map { index -> UInt8 in
                let position = offset + index
                return position < image.count ? image[position] : 0xff
            }
            var crcInput = littleEndian(block)
            crcInput.append(contentsOf: bytes)
            let crc = crc16(crcInput)

            records.append(contentsOf: littleEndian(block))
            records.append(contentsOf: bytes)
            records.append(contentsOf: littleEndian(crc))
            block &+= 1
        }

        return (report([0x02, UInt8(records.count), 0x00] + records), block)
    }

    public static func finishReport(lastBlock: UInt16) -> [UInt8] {
        let complement = 0 &- lastBlock
        return report([0x02, 0x06, 0x00, 0x02, 0xff]
            + littleEndian(lastBlock)
            + littleEndian(complement))
    }

    public static func parseResponse(_ bytes: [UInt8]) -> Response {
        guard bytes.count >= 4, bytes[0] == 0x05 else { return .unknown }
        if bytes.count >= 7, Array(bytes[0..<6]) == [0x05, 0x02, 0x03, 0x00, 0x06, 0xff] {
            return bytes[6] == 0 ? .completed : .failed(bytes[6])
        }
        if bytes.count >= 12, Array(bytes[0..<4]) == [0x05, 0x01, 0x08, 0x00] {
            return .firmwareInfo(version: uint32(bytes, 4), crc: uint32(bytes, 8))
        }
        return .acknowledgement
    }

    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        bytes.reduce(UInt16(0xffff)) { partial, byte in
            var crc = partial
            var value = UInt16(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (((crc ^ value) & 1) == 1 ? 0xa001 : 0)
                value >>= 1
            }
            return crc
        }
    }

    private static func report(_ payload: [UInt8]) -> [UInt8] {
        Array(([0x05] + payload + Array(repeating: 0, count: reportLength)).prefix(reportLength))
    }

    private static func littleEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8(value >> 8)]
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
