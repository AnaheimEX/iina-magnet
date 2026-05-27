//
//  FeedParser.swift
//  IinaMagnet
//
//  Parses RSS 2.0 and Atom XML into a list of ParsedFeedItem (Issue 12).
//  Uses Foundation's XMLParser (no dependencies).

import Foundation

public struct ParsedFeedItem: Sendable, Equatable {
    public let guid: String
    public let title: String
    public let enclosureURL: URL
    public let publishedAt: Date?
    public let rawDescription: String?

    public init(guid: String, title: String, enclosureURL: URL, publishedAt: Date?, rawDescription: String?) {
        self.guid = guid
        self.title = title
        self.enclosureURL = enclosureURL
        self.publishedAt = publishedAt
        self.rawDescription = rawDescription
    }
}

public enum FeedFormat: Sendable {
    case rss2
    case atom
}

public enum FeedParseError: Error, Sendable {
    case invalidXML(message: String)
    case unsupportedFormat
}

public enum FeedParser {

    public static func parse(_ data: Data) throws -> (format: FeedFormat, items: [ParsedFeedItem]) {
        let handler = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.shouldProcessNamespaces = true

        guard parser.parse() else {
            let msg = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw FeedParseError.invalidXML(message: msg)
        }
        guard let fmt = handler.format else { throw FeedParseError.unsupportedFormat }
        return (fmt, handler.items)
    }

    // MARK: - Internal delegate

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var format: FeedFormat?
        var items: [ParsedFeedItem] = []

        private var inEntry = false
        private var entryTitle = ""
        private var entryGuid: String?
        private var entryURL: URL?
        private var entryDate: Date?
        private var entryDescription: String?
        private var currentText = ""

        // MARK: Element start

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            currentText = ""
            switch elementName.lowercased() {
            case "rss":
                format = .rss2
            case "feed":
                format = .atom
            case "item", "entry":
                inEntry = true
                entryTitle = ""
                entryGuid = nil
                entryURL = nil
                entryDate = nil
                entryDescription = nil
            case "enclosure":
                if inEntry, let s = attributeDict["url"], let u = URL(string: s) {
                    entryURL = u
                }
            case "link":
                // Atom enclosure: <link rel="enclosure" href="...">
                if inEntry,
                   let rel = attributeDict["rel"], rel == "enclosure",
                   let s = attributeDict["href"], let u = URL(string: s) {
                    entryURL = u
                }
            default:
                break
            }
        }

        // MARK: Character data

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let s = String(data: CDATABlock, encoding: .utf8) { currentText += s }
        }

        // MARK: Element end

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

            switch elementName.lowercased() {
            case "title" where inEntry:
                entryTitle = trimmed
            case "guid", "id":
                if inEntry { entryGuid = trimmed }
            case "pubdate":
                if inEntry { entryDate = Self.parseRFC822(trimmed) }
            case "published", "updated":
                if inEntry, entryDate == nil {
                    entryDate = Self.parseISO8601(trimmed)
                }
            case "description", "summary":
                if inEntry { entryDescription = trimmed }
            case "item", "entry":
                if let url = entryURL {
                    let guid = entryGuid ?? "\(url.absoluteString)#\(entryTitle)"
                    items.append(ParsedFeedItem(
                        guid: guid,
                        title: entryTitle,
                        enclosureURL: url,
                        publishedAt: entryDate,
                        rawDescription: entryDescription
                    ))
                }
                inEntry = false
            default:
                break
            }
            currentText = ""
        }

        // MARK: Date helpers

        private static let rfc822Formatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return f
        }()

        private static let iso8601Formatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        private static func parseRFC822(_ str: String) -> Date? {
            rfc822Formatter.date(from: str)
        }
        private static func parseISO8601(_ str: String) -> Date? {
            if let d = iso8601Formatter.date(from: str) { return d }
            // Fallback: try without fractional seconds.
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: str)
        }
    }
}
