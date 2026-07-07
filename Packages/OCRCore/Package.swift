// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCRCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "OCRCore", targets: ["OCRCore"])],
    dependencies: [.package(path: "../SharedKit")],
    targets: [
        .target(
            name: "OCRCore",
            dependencies: ["SharedKit"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(name: "OCRCoreTests", dependencies: ["OCRCore"]),
    ]
)
