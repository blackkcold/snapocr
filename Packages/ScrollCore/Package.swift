// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScrollCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ScrollCore", targets: ["ScrollCore"])],
    dependencies: [
        .package(path: "../SharedKit"),
        .package(path: "../CaptureCore"),
    ],
    targets: [
        .target(
            name: "ScrollCore",
            dependencies: ["SharedKit", "CaptureCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(name: "ScrollCoreTests", dependencies: ["ScrollCore"]),
    ]
)
