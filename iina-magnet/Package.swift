// swift-tools-version: 5.9
//
// Package.swift
// iina-magnet — Swift package for the new BT/RSS/Library modules layered on top of iina.
//
// Phase 0 baseline:
//   - macOS 14 deployment target (matches Configs/Deployment.xcconfig)
//   - IinaMagnet library + smoke test
//
// The Phase-1 BT/RSS pipeline (and its LibtorrentBridge Obj-C++ target) was
// removed when the project pivoted to PikPak; see ../docs/UPSTREAM_SYNC.md.
//
// See ../docs/iina-hooks.md for the registry of changes to upstream iina files.

import PackageDescription
import Foundation

let package = Package(
    name: "IinaMagnet",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "IinaMagnet",    targets: ["IinaMagnet"]),
        .library(name: "AnitomyBridge", targets: ["AnitomyBridge"]),
    ],
    targets: [
        // MARK: Obj-C++ wrapper around the vendored classic Anitomy (Phase 2 Issue 02).
        //
        // Anitomy C++14 sources live under Sources/AnitomyBridge/anitomy/ and are
        // compiled as part of this target (header-search path "." resolves the
        // "anitomy/foo.h" includes). See lib/anitomy/README.md + ADR-0006.
        .target(
            name: "AnitomyBridge",
            path: "Sources/AnitomyBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."),
            ]
        ),

        .target(
            name: "IinaMagnet",
            dependencies: [
                "AnitomyBridge",
            ],
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

        .testTarget(
            name: "AnitomyBridgeTests",
            dependencies: ["AnitomyBridge"],
            path: "Tests/AnitomyBridgeTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
