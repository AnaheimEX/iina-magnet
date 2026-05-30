//
//  PosterImageCacheTests.swift
//  IinaMagnetTests
//
//  The in-memory poster cache stores and returns decoded images by URL.

import Testing
import Foundation
import AppKit
@testable import IinaMagnet

@MainActor
@Suite("PosterImageCache")
struct PosterImageCacheTests {

    @Test("stores and retrieves by URL; unknown URLs miss")
    func roundtrip() {
        let cache = PosterImageCache()
        let url = URL(string: "https://example.com/a.jpg")!
        let other = URL(string: "https://example.com/b.jpg")!
        let image = NSImage(size: NSSize(width: 2, height: 3))

        #expect(cache.image(for: url) == nil)
        cache.insert(image, for: url)
        #expect(cache.image(for: url) === image)
        #expect(cache.image(for: other) == nil)
    }
}
