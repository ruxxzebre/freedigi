import Foundation

/// Versions reported by the controller and official catalog have four decimal
/// components. Unknown formats must not silently become upgrade candidates.
public enum FirmwareVersionPolicy {
    public static func compare(offered: String, installed: String) -> ComparisonResult? {
        func components(_ value: String) -> [UInt16]? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var result: [UInt16] = []
            for part in parts {
                guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = UInt16(part) else { return nil }
                result.append(number)
            }
            return result
        }
        guard let target = components(offered), let current = components(installed) else { return nil }
        for (targetPart, currentPart) in zip(target, current) {
            if targetPart > currentPart { return .orderedDescending }
            if targetPart < currentPart { return .orderedAscending }
        }
        return .orderedSame
    }

    public static func requireUpgrade(offered: String, installed: String) throws {
        switch compare(offered: offered, installed: installed) {
        case .orderedDescending: return
        case .orderedSame:
            throw ControllerProtocolError.invalid("The offered firmware matches the installed version (\(installed)). No update is needed for this package.")
        case .orderedAscending:
            throw ControllerProtocolError.invalid("The catalog offered an older version (\(offered)) than the installed firmware (\(installed)). Downgrades are not supported.")
        default:
            throw ControllerProtocolError.invalid("Cannot compare firmware versions '\(installed)' and '\(offered)'. Installation is blocked until the version format is understood.")
        }
    }
}
