// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnnotationCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "AnnotationCore", targets: ["AnnotationCore"])],
    dependencies: [.package(path: "../SharedKit")],
    targets: [
        .target(
            name: "AnnotationCore",
            dependencies: ["SharedKit"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(name: "AnnotationCoreTests", dependencies: ["AnnotationCore"]),
    ]
)
