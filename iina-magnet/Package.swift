// swift-tools-version: 5.9
//
// Package.swift
// iina-magnet — Swift package for the new BT/RSS/Library modules layered on top of iina.
//
// Phase 0 baseline:
//   - macOS 14 deployment target (matches Configs/Deployment.xcconfig)
//   - Empty IinaMagnet library + smoke test
//   - Not yet linked into the iina Xcode target (deferred to Issue 03, the AppDelegate hook)
//
// See ../docs/iina-hooks.md for the registry of changes to upstream iina files.
// See ../../DEVELOPMENT_PLAN.md (in the planning branch) for the broader strategy.

import PackageDescription

let package = Package(
    name: "IinaMagnet",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "IinaMagnet", targets: ["IinaMagnet"]),
    ],
    dependencies: [
        // Phase 1 will add: libtorrent bridge, Anitomy bridge.
        // Phase 2 will add: SwiftData @Models (no external deps).
    ],
    targets: [
        .target(
            name: "IinaMagnet",
            path: "Sources/IinaMagnet",
            resources: [
                .process("Resources")  // Disclaimer.{zh-Hans,en}.md (Issue 02)
            ]
        ),
        .testTarget(
            name: "IinaMagnetTests",
            dependencies: ["IinaMagnet"],
            path: "Tests/IinaMagnetTests"
        ),
    ]
)
