// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIMeter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIMeter", targets: ["AIMeter"]),
        .library(name: "AIMeterCore", targets: ["AIMeterCore"]),
        .executable(name: "AIMeterWidgetQAHost", targets: ["AIMeterWidgetQAHost"]),
        .executable(name: "AIMeterWidgetQAExtension", targets: ["AIMeterWidgetQAExtension"])
    ],
    targets: [
        .target(
            name: "AIMeterCore",
            path: "Sources/AIMeterCore"
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
