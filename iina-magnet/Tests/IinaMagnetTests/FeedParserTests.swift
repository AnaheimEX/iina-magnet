//
//  FeedParserTests.swift
//  IinaMagnetTests
//
//  Inline fixtures cover RSS 2.0, Atom, magnet enclosures, and malformed inputs.

import Testing
import Foundation
@testable import IinaMagnet

@Suite("FeedParser")
struct FeedParserTests {

    @Test("Parses RSS 2.0 with magnet enclosures")
    func rss2Magnet() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>mikanani feed</title>
            <item>
              <title>[LoliHouse] Show 01 1080p CHS</title>
              <guid>guid-1</guid>
              <enclosure url="magnet:?xt=urn:btih:9f9165d9a281a9b8e782cd5176bbcc8256fd1871" length="0" type="application/x-bittorrent"/>
              <pubDate>Sun, 01 Sep 2024 12:00:00 +0000</pubDate>
            </item>
            <item>
              <title>[LoliHouse] Show 02 1080p CHT</title>
              <guid>guid-2</guid>
              <enclosure url="magnet:?xt=urn:btih:1111111111111111111111111111111111111111"/>
              <pubDate>Mon, 02 Sep 2024 12:00:00 +0000</pubDate>
            </item>
          </channel>
        </rss>
        """
        let result = try FeedParser.parse(xml.data(using: .utf8)!)
        guard case .rss2 = result.format else { Issue.record("expected rss2"); return }
        #expect(result.items.count == 2)
        #expect(result.items[0].title.contains("Show 01"))
        #expect(result.items[0].enclosureURL.absoluteString.hasPrefix("magnet:"))
        #expect(result.items[0].publishedAt != nil)
    }

    @Test("Parses Atom feed")
    func atom() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>example</title>
          <entry>
            <title>Atom Entry 1</title>
            <id>https://example.org/1</id>
            <link rel="enclosure" href="magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"/>
            <published>2024-09-01T12:00:00Z</published>
          </entry>
        </feed>
        """
        let result = try FeedParser.parse(xml.data(using: .utf8)!)
        guard case .atom = result.format else { Issue.record("expected atom"); return }
        #expect(result.items.count == 1)
        #expect(result.items[0].guid == "https://example.org/1")
        #expect(result.items[0].publishedAt != nil)
    }

    @Test("Empty channel returns empty items, format detected")
    func emptyChannel() throws {
        let xml = "<?xml version='1.0'?><rss><channel><title>t</title></channel></rss>"
        let result = try FeedParser.parse(xml.data(using: .utf8)!)
        guard case .rss2 = result.format else { Issue.record("expected rss2"); return }
        #expect(result.items.isEmpty)
    }

    @Test("Malformed XML throws")
    func malformedThrows() {
        let xml = "<rss><channel><item><title>broken"
        #expect(throws: (any Error).self) {
            _ = try FeedParser.parse(xml.data(using: .utf8)!)
        }
    }

    @Test("Missing guid falls back to enclosure-URL+title hash")
    func guidFallback() throws {
        let xml = """
        <rss><channel>
          <item>
            <title>NoGuid</title>
            <enclosure url="magnet:?xt=urn:btih:cccccccccccccccccccccccccccccccccccccccc"/>
          </item>
        </channel></rss>
        """
        let result = try FeedParser.parse(xml.data(using: .utf8)!)
        #expect(result.items.count == 1)
        #expect(result.items[0].guid.contains("magnet:"))
    }
}
