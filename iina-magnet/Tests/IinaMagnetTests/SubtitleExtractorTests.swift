//
//  SubtitleExtractorTests.swift
//  IinaMagnetTests
//
//  Unit tests for SubtitleExtractor using a mock FileSystemAccessor.

import Testing
import Foundation
@testable import IinaMagnet

// MARK: - Mock filesystem

final class MockFS: FileSystemAccessor, @unchecked Sendable {
    var files: Set<URL> = []
    var copied: [(URL, URL)] = []

    func enumerate(directory: URL) throws -> [URL] {
        files.filter { $0.path.hasPrefix(directory.path) }.sorted { $0.path < $1.path }
    }
    func fileExists(at url: URL) -> Bool {
        files.contains(url) || copied.contains(where: { $0.1 == url })
    }
    func copy(from source: URL, to destination: URL) throws {
        copied.append((source, destination))
    }
}

private func u(_ path: String) -> URL { URL(fileURLWithPath: path) }

@Suite("SubtitleExtractor")
struct SubtitleExtractorTests {

    @Test("Empty directory returns no plans")
    func emptyDir() throws {
        let fs = MockFS()
        let plans = try SubtitleExtractor.plan(rootDirectory: u("/tmp/x"), fs: fs)
        #expect(plans.isEmpty)
    }

    @Test("Same-basename match: video.mkv + video.ass")
    func sameBasename() throws {
        let fs = MockFS()
        fs.files = [u("/dl/Show.mkv"), u("/dl/Show.ass")]

        let plans = try SubtitleExtractor.plan(rootDirectory: u("/dl"), fs: fs)
        #expect(plans.count == 1)
        let copy = try #require(plans.first?.copies.first)
        #expect(copy.source == u("/dl/Show.ass"))
        #expect(copy.destination == u("/dl/Show.und.ass"))
    }

    @Test("Language detection: .chs.ass → zh-Hans")
    func langDetection() throws {
        let fs = MockFS()
        fs.files = [u("/dl/Show.mkv"),
                    u("/dl/Show.chs.ass"),
                    u("/dl/Show.cht.ass"),
                    u("/dl/Show.jp.ass")]

        let plans = try SubtitleExtractor.plan(rootDirectory: u("/dl"), fs: fs)
        #expect(plans.count == 1)
        let langs = plans.first!.copies.map(\.detectedLanguage).sorted()
        #expect(langs == ["ja", "zh-Hans", "zh-Hant"])
    }

    @Test("Single video in directory: auto-matches stray subs")
    func sameDirAutoMatch() throws {
        let fs = MockFS()
        fs.files = [u("/dl/series-e01.mkv"),
                    u("/dl/subs-only.srt")]

        let plans = try SubtitleExtractor.plan(rootDirectory: u("/dl"), fs: fs)
        #expect(plans.count == 1)
        #expect(plans.first?.copies.count == 1)
    }

    @Test("Episode-number match across files")
    func episodeNumberMatch() throws {
        let fs = MockFS()
        fs.files = [u("/dl/Show.S01E01.mkv"),
                    u("/dl/Show.S01E02.mkv"),
                    u("/dl/Subs/01.chs.ass"),
                    u("/dl/Subs/02.chs.ass")]

        let plans = try SubtitleExtractor.plan(rootDirectory: u("/dl"), fs: fs)
        #expect(plans.count == 2)

        let map = Dictionary(uniqueKeysWithValues: plans.map { ($0.video.lastPathComponent, $0.copies) })
        #expect(map["Show.S01E01.mkv"]?.count == 1)
        #expect(map["Show.S01E02.mkv"]?.count == 1)
    }

    @Test("Destination uniqueness when two subs collide on same name")
    func uniqueDestinationOnCollision() throws {
        let fs = MockFS()
        fs.files = [u("/dl/Show.mkv"),
                    u("/dl/Show.ass"),
                    u("/dl/Show2/Show.ass")]   // same basename "Show", in subdir

        let plans = try SubtitleExtractor.plan(rootDirectory: u("/dl"), fs: fs)
        #expect(plans.count == 1)
        // Both subs map to Show.mkv (same basename); the second should get a unique name.
        let dests = plans.first!.copies.map(\.destination)
        #expect(Set(dests).count == dests.count)
    }

    @Test("execute() copies non-existing destinations and skips existing ones")
    func executeCopies() throws {
        let fs = MockFS()
        fs.files = [u("/dl/A.mkv"), u("/dl/A.chs.ass")]

        let plans = try SubtitleExtractor.plan(rootDirectory: u("/dl"), fs: fs)
        try SubtitleExtractor.execute(plans, fs: fs)
        #expect(fs.copied.count == 1)

        // Second execute is a no-op (destination already exists in mock).
        try SubtitleExtractor.execute(plans, fs: fs)
        #expect(fs.copied.count == 1)
    }

    @Test("detectLanguage helper: standalone testing")
    func languageHelper() {
        #expect(SubtitleExtractor.detectLanguage(filename: "Show.S01E03.chs.ass") == "zh-Hans")
        #expect(SubtitleExtractor.detectLanguage(filename: "Show.S01E03.cht.ass") == "zh-Hant")
        #expect(SubtitleExtractor.detectLanguage(filename: "Show.S01E03.jp.srt") == "ja")
        #expect(SubtitleExtractor.detectLanguage(filename: "Show.S01E03.eng.srt") == "en")
        #expect(SubtitleExtractor.detectLanguage(filename: "no-marker.ass") == "und")
    }
}
