// swift-tools-version: 5.9
import PackageDescription
import Foundation

// The Mac App Store project (AppStore/AIMeterStore.xcodeproj) gives its own
// targets the AIMETER_APP_STORE compilation condition through Store.xcconfig,
// but Xcode does not propagate that build setting into this local package.
// Store builds therefore export AIMETER_APP_STORE=1 in the environment while
// this manifest is evaluated (for example,
// `AIMETER_APP_STORE=1 xcodebuild -project AppStore/AIMeterStore.xcodeproj ...`),
// which adds the matching define to AIMeterCore below so that
// DistributionConfiguration resolves in App Store mode. Direct (GitHub)
// builds never set the variable, so their behavior is unchanged.
let appStoreCoreSwiftSettings: [SwiftSetting] = ProcessInfo.processInfo.environment["AIMETER_APP_STORE"] == "1"
    ? [.define("AIMETER_APP_STORE")]
    : []

let package = Package(
    name: "AIMeter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIMeter", targets: ["AIMeter"]),
        .library(name: "AIMeterCore", targets: ["AIMeterCore"]),
        .library(name: "AIMeterWidgetUI", targets: ["AIMeterWidgetUI"]),
        .executable(name: "AIMeterWidgetQAHost", targets: ["AIMeterWidgetQAHost"]),
        .executable(name: "AIMeterWidgetQAExtension", targets: ["AIMeterWidgetQAExtension"])
    ],
    targets: [
        .target(
            name: "AIMeterCore",
            path: "Sources/AIMeterCore",
            swiftSettings: appStoreCoreSwiftSettings
        ),
        .target(
            name: "AIMeterWidgetUI",
            dependencies: ["AIMeterCore"],
            path: "Sources/AIMeterWidgetUI"
        ),
        .target(
            name: "AIMeterWidgetFixtures",
            dependencies: ["AIMeterCore"],
            path: "Sources/AIMeterWidgetFixtures"
        ),
        .executableTarget(
            name: "AIMeterWidgetQAHost",
            path: "Sources/AIMeterWidgetQAHost"
        ),
        .executableTarget(
            name: "AIMeterWidgetQAExtension",
            dependencies: ["AIMeterCore", "AIMeterWidgetUI", "AIMeterWidgetFixtures"],
            path: "Sources/AIMeterWidgetQAExtension",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "AIMeter",
            dependencies: ["AIMeterCore"],
            path: "Sources/AIMeter",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "AIMeterWidgetExtension",
            dependencies: ["AIMeterCore", "AIMeterWidgetUI"],
            path: "Sources/AIMeterWidgetExtension",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-e",
                    "-Xlinker", "_NSExtensionMain"
                ])
            ]
        ),
        .testTarget(
            name: "AIMeterTests",
            dependencies: ["AIMeter", "AIMeterCore"],
            path: "Tests/AIMeterTests"
        ),
        .testTarget(
            name: "AIMeterWidgetUITests",
            dependencies: ["AIMeterWidgetUI", "AIMeterCore"],
            path: "Tests/AIMeterWidgetUITests"
        )
    ]
)
