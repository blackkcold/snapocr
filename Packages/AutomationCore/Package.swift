// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutomationCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "AutomationCore", targets: ["AutomationCore"])],
    dependencies: [
        .package(path: "../SharedKit"),
        .package(path: "../CaptureCore"),
        .package(path: "../OCRCore"),
        .package(path: "../BarcodeCore"),
    ],
    targets: [
        .target(
            name: "AutomationCore",
            dependencies: ["SharedKit", "CaptureCore", "OCRCore", "BarcodeCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(name: "AutomationCoreTests", dependencies: ["AutomationCore"]),
    ]
)
