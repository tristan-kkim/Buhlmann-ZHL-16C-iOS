// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiveEngine",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DiveEngine",
            targets: ["DiveEngine"]
        ),
    ],
    dependencies: [],   // Bühlmann ZHL-16C implemented natively — no external deps
    targets: [
        .target(
            name: "DiveEngine",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DiveEngineTests",
            dependencies: ["DiveEngine"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
