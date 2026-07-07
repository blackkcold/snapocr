// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HistoryCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "HistoryCore", targets: ["HistoryCore"])],
    dependencies: [.package(path: "../SharedKit")],
    targets: [
        .target(
            name: "HistoryCore",
            dependencies: ["SharedKit"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(name: "HistoryCoreTests", dependencies: ["HistoryCore"]),
    ]
)
