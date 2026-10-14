import Foundation

public struct Vader5FirmwareVersions: Sendable, Equatable {
    public var main: String?
    public var rf: String?
    public var si: String?
    public var dongle: String?

    public init(main: String? = nil, rf: String? = nil, si: String? = nil, dongle: String? = nil) {
        self.main = main
        self.rf = rf
        self.si = si
        self.dongle = dongle
    }
}

public struct Vader5FirmwareRelease: Codable, Sendable, Equatable {
    public let version: String
    public let url: URL
    public let info: String
    public let minimumAppVersion: String
    public let isPush: Int

    enum CodingKeys: String, CodingKey {
        case version, url, info
        case minimumAppVersion = "min_app_version"
        case isPush = "is_push"
    }
}

public struct Vader5FirmwareCatalog: Sendable, Equatable {
    public let main: Vader5FirmwareRelease?
    public let rf: Vader5FirmwareRelease?
    public let si: Vader5FirmwareRelease?
    public let dongle: Vader5FirmwareRelease?
}

public enum Vader5FirmwareUpdateError: Error, CustomStringConvertible {
    case invalidResponse
    case service(Int, String)

    public var description: String {
        switch self {
        case .invalidResponse:
            "Flydigi returned an invalid firmware response."
        case let .service(code, message):
            "Flydigi firmware service error \(code): \(message)"
        }
    }
}

public enum Vader5FirmwareDownloadError: Error, Sendable, Equatable, CustomStringConvertible {
    case insecureURL
    case invalidResponse
    case emptyFile

    public var description: String {
        switch self {
        case .insecureURL:
            "The firmware URL is not HTTPS and is not a recognized Flydigi download host."
        case .invalidResponse:
            "The firmware server returned an invalid download response."
        case .emptyFile:
            "The firmware server returned an empty file."
        }
    }
}

/// Downloads a firmware artifact to a user-selected file. This type has no HID
/// device access and cannot start, erase, or write a controller update.
public struct Vader5FirmwareDownloadClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(
        release: Vader5FirmwareRelease,
        to destination: URL
    ) async throws -> Vader5FirmwarePackageInfo {
        var request = URLRequest(url: try Self.secureURL(for: release.url))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        try Self.validate(data: data, response: response)
        try data.write(to: destination, options: .atomic)
        return Vader5FirmwarePackageInspector.inspect(
            data: data,
            fileName: destination.lastPathComponent)
    }

    static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else {
            throw Vader5FirmwareDownloadError.invalidResponse
        }
        guard !data.isEmpty else { throw Vader5FirmwareDownloadError.emptyFile }
    }

    static func secureURL(for url: URL) throws -> URL {
        if url.scheme?.lowercased() == "https" { return url }
        guard url.scheme?.lowercased() == "http",
              url.host?.lowercased() == "api-web.cdn.flydigi.com",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Vader5FirmwareDownloadError.insecureURL
        }
        components.scheme = "https"
        guard let secureURL = components.url else {
            throw Vader5FirmwareDownloadError.insecureURL
        }
        return secureURL
    }
}

public struct Vader5FirmwareUpdateClient: Sendable {
    public static let endpoint = URL(string: "https://api.flydigi.com/pc/Update/firmware")!
    // Space Station 4.2.0.9 and the current web catalog identify Vader 5 Pro
    // as f5 / 130. k5 / 128 belongs to Apex 5.
    public static let deviceCode = "f5"
    public static let standardDeviceID = 130

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(
        versions: Vader5FirmwareVersions,
        appVersion: String,
        deviceID: Int = standardDeviceID
    ) async throws -> Vader5FirmwareCatalog {
        guard [130, 144, 145].contains(deviceID) else {
            throw Vader5FirmwareUpdateError.invalidResponse
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en", forHTTPHeaderField: "language")
        request.setValue(appVersion, forHTTPHeaderField: "appVersion")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                deviceCode: Self.deviceCode,
                deviceID: deviceID,
                appVersion: appVersion,
                mainChip: versions.main,
                rfChip: versions.rf,
                siChip: versions.si,
                dongleChip: versions.dongle
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw Vader5FirmwareUpdateError.invalidResponse
        }
        return try Self.decodeResponse(data)
    }

    static func decodeResponse(_ data: Data) throws -> Vader5FirmwareCatalog {
        let response = try JSONDecoder().decode(ServiceResponse.self, from: data)
        guard response.code == 0, let payload = response.data else {
            throw Vader5FirmwareUpdateError.service(response.code, response.message)
        }
        guard payload.deviceCode == Self.deviceCode else {
            throw Vader5FirmwareUpdateError.invalidResponse
        }
        return Vader5FirmwareCatalog(
            main: payload.chipList.main,
            rf: payload.chipList.rf,
            si: payload.chipList.si,
            dongle: payload.chipList.dongle
        )
    }
}

private extension Vader5FirmwareUpdateClient {
    struct RequestBody: Encodable {
        let deviceCode: String
        let deviceID: Int
        let appVersion: String
        let mainChip: String?
        let rfChip: String?
        let siChip: String?
        let dongleChip: String?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case deviceID = "device_id"
            case appVersion = "app_version"
            case mainChip = "main_chip"
            case rfChip = "rf_chip"
            case siChip = "si_chip"
            case dongleChip = "dongle_chip"
        }
    }

    struct ServiceResponse: Decodable {
        let code: Int
        let message: String
        let data: Payload?
    }

    struct Payload: Decodable {
        let deviceCode: String
        let chipList: ChipList

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case chipList = "chip_list"
        }
    }

    struct ChipList: Decodable {
        let main: Vader5FirmwareRelease?
        let dongle: Vader5FirmwareRelease?
        let rf: Vader5FirmwareRelease?
        let si: Vader5FirmwareRelease?

        enum CodingKeys: String, CodingKey {
            case main = "main_chip"
            case dongle = "dongle_chip"
            case rf = "rf_chip"
            case si = "si_chip"
        }
    }
}
