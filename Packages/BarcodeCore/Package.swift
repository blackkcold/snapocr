// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BarcodeCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "BarcodeCore", targets: ["BarcodeCore"])],
    dependencies: [.package(path: "../SharedKit")],
    targets: [
        .target(
            name: "BarcodeCore",
            dependencies: ["SharedKit"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(name: "BarcodeCoreTests", dependencies: ["BarcodeCore"]),
    ]
)
