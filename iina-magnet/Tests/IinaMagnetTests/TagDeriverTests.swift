//
//  TagDeriverTests.swift
//  IinaMagnetTests
//
//  Pure-function tests for TagDeriver (Issue 12 subset).

import Testing
@testable import IinaMagnet

@Suite("TagDeriver")
struct TagDeriverTests {

    @Test("Derives year / ratingBucket / quality / releaseGroup")
    func full() {
        let tags = TagDeriver.derive(year: 2023, rating: 8.4, resolution: "1080p",
                                     releaseGroup: "喵萌奶茶屋")
        #expect(tags.contains(.init(name: "2023", category: .year)))
        #expect(tags.contains(.init(name: "8分+", category: .ratingBucket)))
        #expect(tags.contains(.init(name: "1080p", category: .quality)))
        #expect(tags.contains(.init(name: "喵萌奶茶屋", category: .releaseGroup)))
    }

    @Test("Genres map to .genre and are included")
    func genres() {
        let tags = TagDeriver.derive(year: nil, rating: nil, resolution: nil,
                                     releaseGroup: nil, genres: ["奇幻", "冒险"])
        #expect(tags == [.init(name: "奇幻", category: .genre), .init(name: "冒险", category: .genre)])
    }

    @Test("Countries map to .country")
    func countries() {
        let tags = TagDeriver.derive(year: nil, rating: nil, resolution: nil,
                                     releaseGroup: nil, countries: ["日本"])
        #expect(tags == [.init(name: "日本", category: .country)])
    }

    @Test("Missing/zero signals produce no tags")
    func empties() {
        #expect(TagDeriver.derive(year: nil, rating: 0, resolution: "", releaseGroup: "  ").isEmpty)
    }

    @Test("Rating buckets")
    func buckets() {
        #expect(TagDeriver.ratingBucket(9.2) == "9分+")
        #expect(TagDeriver.ratingBucket(8.0) == "8分+")
        #expect(TagDeriver.ratingBucket(6.8) == "6分+")
        #expect(TagDeriver.ratingBucket(4.0) == "6分以下")
        #expect(TagDeriver.ratingBucket(0) == nil)
        #expect(TagDeriver.ratingBucket(nil) == nil)
    }

    @Test("Dedups repeated derivations")
    func dedup() {
        let tags = TagDeriver.derive(year: 2020, rating: nil, resolution: nil,
                                     releaseGroup: nil, genres: ["剧情", "剧情"])
        #expect(tags.filter { $0.category == .genre }.count == 1)
    }
}
