//
//  WebLoginNavigationPolicyTests.swift
//  IinaMagnetTests
//

import Foundation
import Testing
@testable import IinaMagnet

@Suite struct WebLoginNavigationPolicyTests {
    @Test func pikPakUsesTheDedicatedLoginRoute() throws {
        let url = PikPakLoginWebView.loginURL
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "https")
        #expect(components.host == "mypikpak.com")
        #expect(components.path == "/drive/login")
        #expect(components.queryItems?.first { $0.name == "redirect" }?.value == "/all")
    }

    @Test func pikPakKeepsTheWebClientUserAgentRequiredByItsSPA() {
        let userAgent = PikPakConfig.web.userAgent
        #expect(userAgent.contains("Chrome/"))
        #expect(userAgent.contains("Safari/"))
    }

    @Test func pikPakCredentialBridgeAndTopLevelNavigationAreOriginRestricted() throws {
        let pikPak = try #require(URL(string: "https://mypikpak.com/drive/login"))
        let google = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth"))
        let evilSuffix = try #require(URL(string: "https://evil-mypikpak.com/"))
        let external = try #require(URL(string: "https://example.com/"))
        let data = try #require(URL(string: "data:text/html,evil"))

        #expect(PikPakLoginNavigationPolicy.allowsNavigation(to: pikPak))
        #expect(PikPakLoginNavigationPolicy.allowsNavigation(to: google))
        #expect(!PikPakLoginNavigationPolicy.allowsNavigation(to: evilSuffix))
        #expect(!PikPakLoginNavigationPolicy.allowsNavigation(to: external))
        #expect(!PikPakLoginNavigationPolicy.allowsNavigation(to: data))
        #expect(PikPakLoginNavigationPolicy.isCredentialOrigin(host: "mypikpak.com", isMainFrame: true))
        #expect(!PikPakLoginNavigationPolicy.isCredentialOrigin(host: "mypikpak.com", isMainFrame: false))
        #expect(!PikPakLoginNavigationPolicy.isCredentialOrigin(host: "accounts.google.com", isMainFrame: true))
    }

    @Test func mikanNewWindowsStayUsableWithoutTrustingArbitrarySchemes() throws {
        let detail = try #require(URL(string: "https://mikanani.me/Home/Bangumi/123"))
        let torrent = try #require(URL(string: "https://download.example/file.torrent"))
        let magnet = try #require(URL(string: "magnet:?xt=urn:btih:abc"))
        let external = try #require(URL(string: "https://example.com/help"))
        let file = try #require(URL(string: "file:///tmp/test"))

        #expect(MikanNewWindowDestination.resolve(url: detail, sourceHost: "mikanani.me") == .currentWebView)
        #expect(MikanNewWindowDestination.resolve(url: torrent, sourceHost: "mikanani.me") == .currentWebView)
        #expect(MikanNewWindowDestination.resolve(url: magnet, sourceHost: "mikanani.me") == .currentWebView)
        #expect(MikanNewWindowDestination.resolve(url: magnet, sourceHost: "example.com") == .ignore)
        #expect(MikanNewWindowDestination.resolve(
            url: external, sourceHost: "mikanani.me", isUserActivated: true, isMainFrame: true
        ) == .externalBrowser)
        #expect(MikanNewWindowDestination.resolve(
            url: external, sourceHost: "mikanani.me", isUserActivated: false, isMainFrame: true
        ) == .ignore)
        #expect(MikanNewWindowDestination.resolve(
            url: external, sourceHost: "example.com", isUserActivated: true, isMainFrame: true
        ) == .ignore)
        #expect(MikanNewWindowDestination.resolve(url: file, sourceHost: "mikanani.me") == .ignore)
    }
}
