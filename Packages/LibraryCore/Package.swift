// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibraryCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "LibraryCore", targets: ["LibraryCore"])],
    dependencies: [
        .package(path: "../SharedKit"),
        .package(path: "../CaptureCore"),
        .package(path: "../HistoryCore"),
    ],
    targets: [
        .target(
            name: "LibraryCore",
            dependencies: ["SharedKit", "CaptureCore", "HistoryCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "LibraryCoreTests",
            dependencies: ["LibraryCore", "CaptureCore"]
        ),
    ]
)
