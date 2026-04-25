// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoadSenseNSBootstrap",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RoadSenseNSBootstrap",
            targets: ["RoadSenseNSBootstrap"]
        ),
    ],
    dependencies: [
        // Snapshot testing for SwiftUI views and Codable payloads.
        // Used by RoadSenseNSBootstrapTests for snapshot-based regression tests.
        // The Xcode app target (`RoadSenseNSTests`) needs this dependency added
        // via Xcode > File > Add Package Dependencies separately when snapshot
        // tests start landing on UI-tier code.
        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing.git",
            from: "1.17.0"
        ),
    ],
    targets: [
        .target(
            name: "RoadSenseNSBootstrap",
            path: "Sources/RoadSenseNSBootstrap"
        ),
        .testTarget(
            name: "RoadSenseNSBootstrapTests",
            dependencies: [
                "RoadSenseNSBootstrap",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/RoadSenseNSBootstrapTests",
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
