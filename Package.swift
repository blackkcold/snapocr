// swift-tools-version: 6.0
import PackageDescription

/// SnapGlass SPM Workspace Configuration
///
/// Defines all packages and their inter-dependencies.
/// Each package under Packages/ also has its own Package.swift for standalone builds.
///
/// Use `swift build` from root to build all packages,
/// or `swift build --package-path Packages/<PackageName>` for individual packages.
let package = Package(
    name: "SnapGlass",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SharedKit", targets: ["SharedKit"]),
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .library(name: "OCRCore", targets: ["OCRCore"]),
        .library(name: "BarcodeCore", targets: ["BarcodeCore"]),
        .library(name: "AnnotationCore", targets: ["AnnotationCore"]),
        .library(name: "ScrollCore", targets: ["ScrollCore"]),
        .library(name: "HistoryCore", targets: ["HistoryCore"]),
        .library(name: "AutomationCore", targets: ["AutomationCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        // MARK: - SharedKit (foundation)
        .target(
            name: "SharedKit",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Packages/SharedKit/Sources",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),

        // MARK: - CaptureCore
        .target(
            name: "CaptureCore",
            dependencies: ["SharedKit"],
            path: "Packages/CaptureCore/Sources",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),

        // MARK: - OCRCore
        .target(
            name: "OCRCore",
            dependencies: ["SharedKit"],
            path: "Packages/OCRCore/Sources",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),

        // MARK: - BarcodeCore
        .target(
            name: "BarcodeCore",
            dependencies: ["SharedKit"],
            path: "Packages/BarcodeCore/Sources",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),

        // MARK: - AnnotationCore
        .target(
            name: "AnnotationCore",
            dependencies: ["SharedKit"],
            path: "Packages/AnnotationCore/Sources",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),

        // MARK: - ScrollCore
        .target(
            name: "ScrollCore",
            dependencies: ["SharedKit", "CaptureCore"],
            path: "Packages/ScrollCore/Sources",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),

        // MARK: - HistoryCore
        .target(
            name: "HistoryCore",
            dependencies: ["SharedKit"],
            path: "Packages/HistoryCore/Sources",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),

        // MARK: - AutomationCore
        .target(
            name: "AutomationCore",
            dependencies: ["SharedKit", "CaptureCore", "OCRCore", "BarcodeCore"],
            path: "Packages/AutomationCore/Sources",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
