// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIMeter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIMeter", targets: ["AIMeter"]),
        .library(name: "AIMeterCore", targets: ["AIMeterCore"])
    ],
    targets: [
        .target(
            name: "AIMeterCore",
            path: "Sources/AIMeterCore"
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
            dependencies: ["AIMeterCore"],
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
        )
    ]
)
