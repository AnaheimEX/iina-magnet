// swift-tools-version: 5.9
//
// Package.swift
// iina-magnet — Swift package for the new BT/RSS/Library modules layered on top of iina.
//
// Phase 0 baseline:
//   - macOS 14 deployment target (matches Configs/Deployment.xcconfig)
//   - IinaMagnet library + smoke test
//   - LibtorrentBridge Obj-C++ target (Phase 1 Issue 05)
//
// See ../docs/iina-hooks.md for the registry of changes to upstream iina files.

import PackageDescription
import Foundation

// Absolute path of this package's directory. SPM's relative-path -I/-L flags
// are evaluated from the build dir (not the package root), which can be
// surprising; computing absolute paths here keeps the build deterministic.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let libtorrentInclude = "\(packageDir)/../lib/libtorrent/include"
let libtorrentLib     = "\(packageDir)/../lib/libtorrent/lib"
let boostInclude      = "\(packageDir)/../lib/libtorrent/build/sources/boost"
let opensslPrefix     = "/opt/homebrew/opt/openssl@3"

let package = Package(
    name: "IinaMagnet",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "IinaMagnet",       targets: ["IinaMagnet"]),
        .library(name: "LibtorrentBridge", targets: ["LibtorrentBridge"]),
        .library(name: "AnitomyBridge",    targets: ["AnitomyBridge"]),
    ],
    targets: [
        // MARK: Obj-C++ wrapper around libtorrent 2.0.x (Issue 05).
        //
        // Requires the vendored libtorrent static library to be built first:
        //   ./lib/libtorrent/build.sh   (Issue 04)
        .target(
            name: "LibtorrentBridge",
            path: "Sources/LibtorrentBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(libtorrentInclude)",
                    "-I\(boostInclude)",
                    "-I\(opensslPrefix)/include",
                ]),
                .define("BOOST_ASIO_HAS_STD_CHRONO", to: "1"),
                .define("BOOST_ASIO_ENABLE_CANCELIO", to: "1"),
                .define("BOOST_ASIO_NO_DEPRECATED", to: "1"),
                .define("TORRENT_USE_OPENSSL", to: "1"),
                .define("TORRENT_USE_SSL", to: "1"),
                // Must match the .a build (cmake -Ddeprecated-functions=OFF):
                // TORRENT_NO_DEPRECATE picks ABI version 3, which wraps types in
                // 'inline namespace v2'. Without this, consumer mangles symbols
                // without v2 → linker errors.
                .define("TORRENT_NO_DEPRECATE", to: "1"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(libtorrentLib)",
                    "-L\(opensslPrefix)/lib",
                ]),
                .linkedLibrary("torrent-rasterbar"),
                .linkedLibrary("ssl"),
                .linkedLibrary("crypto"),
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),

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
                "LibtorrentBridge",
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
            name: "LibtorrentBridgeTests",
            dependencies: ["LibtorrentBridge"],
            path: "Tests/LibtorrentBridgeTests"
        ),

        .testTarget(
            name: "AnitomyBridgeTests",
            dependencies: ["AnitomyBridge"],
            path: "Tests/AnitomyBridgeTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
