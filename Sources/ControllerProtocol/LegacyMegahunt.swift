import Foundation

public protocol FirmwareFeatureChannel: AnyObject {
    func setFeature(_ report: [UInt8]) throws
    func getFeature(id: UInt8, length: Int) throws -> [UInt8]
}

/// Port of hid_boot_command's feature-report protocol (0483:5720).
/// No automatic retries: an ambiguous write must not advance the device pointer twice.
public enum LegacyMegahunt {
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = (crc << 1) ^ (crc & 0x80000000 != 0 ? 0x04c11db7 : 0) }
        }
        return crc // CRC-32/MPEG-2: no reflection or final XOR.
    }

    public static func validate(_ image: Data, fileName: String) throws {
        guard fileName.lowercased().hasSuffix(".bin"), !fileName.uppercased().contains("_ALL"),
              image.count >= 8, image.count <= 2 * 1024 * 1024 else {
            throw ControllerProtocolError.invalid("Megahunt update requires an official application .bin image.")
        }
    }

    public static func transfer(image: Data, fileName: String, channel: any FirmwareFeatureChannel,
                                progress: (Double) -> Void = { _ in }) throws {
        try validate(image, fileName: fileName)
        let bytes = Array(image)
        let resetAddress: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 0]
        try channel.setFeature(resetAddress)
        try channel.setFeature([4] + FirmwareTransfer.le32(UInt32(bytes.count)))
        for offset in stride(from: 0, to: bytes.count, by: 60) {
            let length = min(60, bytes.count - offset)
            var packet: [UInt8] = [2, UInt8(length), 0]
            packet.append(contentsOf: bytes[offset..<(offset + length)])
            packet.append(contentsOf: repeatElement(0, count: 60 - length))
            try channel.setFeature(packet)
            progress(Double(offset + length) / Double(bytes.count) * 0.45)
        }
        let metadata = FirmwareTransfer.le32(0xa5a5a5a5)
            + FirmwareTransfer.le32(crc32(bytes)) + FirmwareTransfer.le32(UInt32(bytes.count))
        try channel.setFeature([3] + metadata)
        try channel.setFeature(resetAddress)
        for offset in stride(from: 0, to: bytes.count, by: 60) {
            let length = min(60, bytes.count - offset)
            let report = try channel.getFeature(id: 2, length: 63)
            guard report.count == 63, report[0] == 2,
                  Array(report[3..<(3 + length)]) == Array(bytes[offset..<(offset + length)]) else {
                throw ControllerProtocolError.verification
            }
            progress(0.45 + Double(offset + length) / Double(bytes.count) * 0.45)
        }
        let flags = try channel.getFeature(id: 3, length: 13)
        guard flags == [3] + metadata else { throw ControllerProtocolError.verification }
        try channel.setFeature([5, 0xa5, 0xa5, 0xa5, 0xa5])
        progress(0.95)
    }
}
