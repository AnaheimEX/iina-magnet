//
//  PerformanceTests.swift
//  IinaMagnetTests
//
//  Coarse perf gates — verify "this isn't catastrophically slow" so regressions
//  surface before manual profiling. (BT/RSS gates removed with Phase 3.)
//

import Testing
import Foundation
@testable import IinaMagnet

@Suite("Performance gates")
struct PerformanceTests {

    @Test("FilenameParser: 1000 parses under 100ms")
    func filenameParserPerformance() {
        let names = (0..<1000).map { i in
            "[喵萌奶茶屋][葬送的芙莉莲][\(String(format: "%02d", i % 24 + 1))][1080p][简日双语].mkv"
        }
        // Warm — Anitomy keyword tables / regex compile.
        _ = names.map { FilenameParser.parse($0) }

        let t0 = Date()
        for n in names { _ = FilenameParser.parse(n) }
        let elapsedMs = Date().timeIntervalSince(t0) * 1000
        #expect(elapsedMs < 100, "FilenameParser 1000 parses took \(elapsedMs)ms; budget 100ms")
    }
}
