// swift-tools-version: 6.0
import PackageDescription
import Foundation

#if os(Linux)
let desktopServiceBuild = true
#else
let desktopServiceBuild = ProcessInfo.processInfo.environment["FREEDIGI_BUILD"] == "1"
#endif

let package: Package
if desktopServiceBuild {
package = Package(
    name: "ControlLab",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ControllerProtocol", targets: ["ControllerProtocol"]),
        .executable(name: "controllab-service", targets: ["ControlLabService"]),
    ],
    targets: [
        .target(name: "ControllerProtocol"),
        .target(name: "DesktopHID", dependencies: ["ControllerProtocol"],
                linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]),
        .executableTarget(name: "ControlLabService", dependencies: ["DesktopHID", "ControllerProtocol"]),
        .testTarget(name: "DesktopHIDTests", dependencies: ["DesktopHID"]),
        .testTarget(name: "ControllerProtocolTests", dependencies: ["ControllerProtocol"],
                    resources: [.copy("Fixtures")]),
    ]
)
} else {
package = Package(
    name: "ControlLab",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Vader5Core", targets: ["Vader5Core"]),
        .executable(name: "controllab-cli", targets: ["Vader5CLI"]),
    ],
    targets: [
        .target(name: "ControllerProtocol"),
        .testTarget(name: "ControllerProtocolTests", dependencies: ["ControllerProtocol"],
                    resources: [.copy("Fixtures")]),
        .binaryTarget(
            name: "SDL3",
            path: "Vendor/SDL3.xcframework"
        ),
        .target(
            name: "SDLGamepadC",
            dependencies: ["SDL3"],
            path: "Sources/SDLGamepadC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Vader5CoreC",
            path: "Sources/Vader5CoreC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "Vader5Core",
            dependencies: ["Vader5CoreC", "SDLGamepadC", "ControllerProtocol"],
            path: "Sources/Vader5Core",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "Vader5CLI",
            dependencies: ["Vader5Core"],
            path: "Sources/Vader5CLI",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "Vader5CoreTests",
            dependencies: ["Vader5Core"],
            path: "Tests/Vader5CoreTests"
        ),
    ]
)
}
