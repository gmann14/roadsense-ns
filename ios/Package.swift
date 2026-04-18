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
    targets: [
        .target(
            name: "RoadSenseNSBootstrap",
            path: "Sources/RoadSenseNSBootstrap"
        ),
        .testTarget(
            name: "RoadSenseNSBootstrapTests",
            dependencies: ["RoadSenseNSBootstrap"],
            path: "Tests/RoadSenseNSBootstrapTests"
        ),
    ]
)
