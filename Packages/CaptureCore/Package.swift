// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptureCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CaptureCore",
            targets: ["CaptureCore"]
        ),
    ],
    dependencies: [
        .package(path: "../SharedKit"),
    ],
    targets: [
        .target(
            name: "CaptureCore",
            dependencies: ["SharedKit"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"]
        ),
    ]
)
