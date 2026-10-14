// Invoked after `security cms -D` by package-app.sh. This checks profile contents;
// macOS still validates authorization at launch. It cannot grant an entitlement.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Native gamepad signing: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 || args.count == 5 else {
    fail("Expected decoded profile, bundle identifier, output entitlements, and optional signing certificate.")
}
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    guard let profile = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let allowed = profile["Entitlements"] as? [String: Any] else { fail("Invalid provisioning profile.") }
    guard let expires = profile["ExpirationDate"] as? Date, expires > Date() else { fail("Profile has expired or has no expiration date.") }
    guard allowed["com.apple.developer.hid.virtual.device"] as? Bool == true else {
        fail("Profile does not authorize com.apple.developer.hid.virtual.device. Request Apple's capability and regenerate the profile.")
    }
    let bundleID = args[2]
    guard bundleID.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { fail("Invalid bundle identifier.") }
    guard let appID = allowed["com.apple.application-identifier"] as? String,
          let separator = appID.firstIndex(of: ".") else { fail("Profile is missing its macOS application identifier.") }
    let claimedID = String(appID[..<separator]) + "." + bundleID
    guard claimedID == appID || (appID.hasSuffix(".*") && claimedID.hasPrefix(String(appID.dropLast()))) else {
        fail("Bundle identifier \(bundleID) does not match profile App ID \(appID). Set APP_BUNDLE_IDENTIFIER to your registered ID.")
    }
    guard let team = allowed["com.apple.developer.team-identifier"] as? String,
          let teams = profile["TeamIdentifier"] as? [String], teams.contains(team) else {
        fail("Profile team identifier is missing or inconsistent.")
    }
    if args.count == 5 {
        let certificate = try Data(contentsOf: URL(fileURLWithPath: args[4]))
        guard let certificates = profile["DeveloperCertificates"] as? [Data], certificates.contains(certificate) else {
            fail("The signing certificate is not authorized by this profile. Select a matching SIGNING_IDENTITY.")
        }
    }
    // Claim only the entitlements used by this app, not every capability in the profile.
    let entitlements: [String: Any] = [
        "com.apple.developer.hid.virtual.device": true,
        "com.apple.application-identifier": claimedID,
        "com.apple.developer.team-identifier": team,
    ]
    let encoded = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
    try encoded.write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    print("Native profile: \(profile["Name"] as? String ?? "unnamed"); App ID \(claimedID); expires \(expires).")
} catch { fail(String(describing: error)) }
