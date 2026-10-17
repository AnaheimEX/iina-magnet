// swift-tools-version: 5.9
// Mikan and PikPak integration for IINA.
import PackageDescription

let package = Package(
    name: "IinaMagnet",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IinaMagnet", targets: ["IinaMagnet"]),
        .executable(name: "IINACloud", targets: ["IINACloud"]),
    ],
    targets: [
        .target(
            name: "IinaMagnet",
            path: "Sources/IinaMagnet",
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "IINACloud", dependencies: ["IinaMagnet"]),
        .testTarget(
            name: "IinaMagnetTests",
            dependencies: ["IinaMagnet"],
            path: "Tests/IinaMagnetTests"
        ),
    ]
)
