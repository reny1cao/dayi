import AppKit
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import TextPolishApp

private final class IconURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var data = Data() }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    static func reset(_ values: [String: Reply]) { lock.withLock { replies = values; requests = [] } }
    static var seen: [URLRequest] { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.requests.append(request)
            return Self.replies[request.url!.absoluteString] ?? Reply(status: 404)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct WebsiteIconTests {
    static func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IconURLProtocol.self]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }

    @Test func faviconFirstDoesNotLoadHomepageOrSendCredentials() async throws {
        IconURLProtocol.reset(["https://site.example/favicon.ico": .init(data: try Self.png())])
        let session = session()
        defer { session.invalidateAndCancel() }
        let data = await WebsiteIconDownload.fetch("site.example", session: session, resolve: { _ in true })
        #expect(data != nil)
        #expect(IconURLProtocol.seen.count == 1)
        let request = try #require(IconURLProtocol.seen.first)
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == 5)
        for header in ["Cookie", "Authorization", "Referer"] { #expect(request.value(forHTTPHeaderField: header) == nil) }
        let png = try #require(data)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 64)
    }

    @Test func homepageHandlesRelativePathsEntitiesAndPublicCDN() async throws {
        IconURLProtocol.reset([
            "https://site.example/": .init(headers: ["Content-Type": "text/html"], data: Data("""
                <html><head><base href="https://cdn.example/assets/">
                <link REL='shortcut ICON' href='brand.png?a=1&amp;b=2'></head>
                <body><link rel=icon href="https://unrelated.example/ignored.png"></body></html>
                """.utf8)),
            "https://cdn.example/assets/brand.png?a=1&b=2": .init(data: try Self.png())
        ])
        let session = session()
        defer { session.invalidateAndCancel() }
        #expect(await WebsiteIconDownload.fetch("site.example", session: session, resolve: { _ in true }) != nil)
        #expect(IconURLProtocol.seen.map { $0.url!.absoluteString } == [
            "https://site.example/favicon.ico", "https://site.example/", "https://cdn.example/assets/brand.png?a=1&b=2"
        ])
    }

    @Test func redirectsAndDNSAreValidatedBeforeEachRequest() async {
        IconURLProtocol.reset([
            "https://site.example/favicon.ico": .init(status: 302, headers: ["Location": "https://private.example/icon"]),
            "https://site.example/": .init(status: 302, headers: ["Location": "http://public.example/"])
        ])
        let session = session()
        defer { session.invalidateAndCancel() }
        #expect(await WebsiteIconDownload.fetch("site.example", session: session,
                                                resolve: { $0 != "private.example" }) == nil)
        #expect(IconURLProtocol.seen.count == 2)
        #expect(IconURLProtocol.seen.allSatisfy { $0.url!.host == "site.example" })
    }

    @Test func largeHomepageUsesBoundedPrefixContainingItsIconDeclaration() async throws {
        let html = "<head><link rel=icon href='/brand.png'></head><body>" + String(repeating: "x", count: 300 * 1024)
        IconURLProtocol.reset([
            "https://site.example/": .init(headers: ["Content-Type": "text/html", "Content-Length": String(html.utf8.count)],
                                          data: Data(html.utf8)),
            "https://site.example/brand.png": .init(data: try Self.png())
        ])
        let session = session()
        defer { session.invalidateAndCancel() }
        #expect(await WebsiteIconDownload.fetch("site.example", session: session, resolve: { _ in true }) != nil)
        #expect(IconURLProtocol.seen.count == 3)
    }

    @Test func invalidImagesOversizedResponsesAndRedirectLoopsStop() async {
        IconURLProtocol.reset([
            "https://site.example/favicon.ico": .init(headers: ["Content-Length": "2000000"], data: Data("not an image".utf8)),
            "https://site.example/": .init(status: 302, headers: ["Location": "/"])
        ])
        let session = session()
        defer { session.invalidateAndCancel() }
        #expect(await WebsiteIconDownload.fetch("site.example", session: session, resolve: { _ in true }) == nil)
        #expect(IconURLProtocol.seen.count == 5)
        #expect(WebsiteIconDownload.thumbnail(Data("<svg><script>bad()</script></svg>".utf8)) == nil)
    }

    @Test func hostAndURLBoundaries() throws {
        for host in ["localhost", "a.local", "a.internal", "a.home.arpa", "127.0.0.1", "192.168.1.1", "::1", "8.8.8.8", "a..com", "a.com/path"] {
            #expect(!WebsiteIconDownload.isPublicHostName(host))
        }
        for address in ["127.1.2.3", "10.1.2.3", "172.16.1.2", "192.168.1.2", "169.254.1.1", "100.64.1.1", "0.0.0.0", "224.0.0.1", "::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1", "2001:db8::1"] {
            #expect(!WebsiteIconDownload.isPublicAddress(address))
        }
        #expect(WebsiteIconDownload.isPublicAddress("1.1.1.1"))
        #expect(WebsiteIconDownload.isPublicAddress("2606:4700:4700::1111"))
        for value in ["http://site.example/icon", "file:///icon", "https://u:p@site.example/icon", "https://site.example:8443/icon", "https://127.0.0.1/icon"] {
            #expect(!WebsiteIconDownload.validURL(try #require(URL(string: value))))
        }
    }

    @Test func nativeHTMLParserHandlesXHTMLWithoutLoadingExternalEntities() throws {
        let base = URL(string: "https://site.example/")!
        let html = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head>
            <link rel="icon" href="/brand.png?a=1&amp;b=2" /></head><body /></html>
            """
        #expect(try WebsiteIconDownload.iconURLs(html: html, base: base).map(\.absoluteString)
                == ["https://site.example/brand.png?a=1&b=2"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("https://canary.example/should-never-be-read.png".utf8).write(to: file)
        let entity = """
            <?xml version="1.0"?><!DOCTYPE html [<!ENTITY external SYSTEM "\(file.absoluteString)">]>
            <html><head><link rel="icon" href="&external;" /></head></html>
            """
        let urls = (try? WebsiteIconDownload.iconURLs(html: entity, base: base)) ?? []
        #expect(!urls.contains { $0.host == "canary.example" })
    }

    actor Downloads {
        var hosts: [String] = []
        let data: Data?
        init(_ data: Data?) { self.data = data }
        func get(_ host: String) async -> Data? {
            hosts.append(host)
            await Task.yield()
            return data
        }
    }

    @Test @MainActor func triggerDeduplicatesCachesAcrossRestartAndViewsNeverDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Downloads(try Self.png())
        let loader = WebsiteIconLoader(directory: directory, download: { await calls.get($0) })
        let store = WebsiteIconStore(loader: loader)
        await store.loadCached("site.example")
        #expect(await calls.hosts.isEmpty)
        let first = try #require(store.fetchIfMissing("site.example"))
        let second = try #require(store.fetchIfMissing("site.example"))
        await first.value
        await second.value
        #expect(await calls.hosts == ["site.example"])
        #expect(store.images["site.example"] != nil)
        #expect(store.images["other.example"] == nil)
        #expect(store.fetchIfMissing("chatgpt.com") == nil)
        let reopened = WebsiteIconStore(loader: WebsiteIconLoader(directory: directory, download: { _ in
            Issue.record("A cached icon must not download after restart"); return nil
        }))
        await reopened.loadCached("site.example")
        #expect(reopened.images["site.example"] != nil)
        #expect(reopened.fetchIfMissing("site.example") == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func failedFetchCooldownSurvivesRestartAndExpiresOnNextTrigger() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Downloads(nil)
        let time = Date()
        let first = WebsiteIconLoader(directory: directory, now: { time }, download: { await calls.get($0) })
        #expect(await first.resolve("site.example") == nil)
        let reopened = WebsiteIconLoader(directory: directory, now: { time.addingTimeInterval(60) }, download: { await calls.get($0) })
        #expect(await reopened.resolve("site.example") == nil)
        #expect(await calls.hosts.count == 1)
        let tomorrow = WebsiteIconLoader(directory: directory, now: { time.addingTimeInterval(86401) }, download: { await calls.get($0) })
        #expect(await tomorrow.resolve("site.example") == nil)
        #expect(await calls.hosts.count == 2)
    }

    @Test @MainActor func badgeRefreshesInPlaceAfterDownload() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try Self.png()
        let store = WebsiteIconStore(loader: WebsiteIconLoader(directory: directory, download: { _ in data }))
        let host = NSHostingView(rootView: WebsiteBadge(host: "site.example", icons: store).frame(width: 40, height: 40))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func pixels() throws -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        try await Task.sleep(for: .milliseconds(80))
        let before = try pixels()
        let request = try #require(store.fetchIfMissing("site.example"))
        await request.value
        try await Task.sleep(for: .milliseconds(80))
        #expect(try pixels() != before)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DAYI_ICON_TEST_HOST"] != nil))
    func livePublicWebsiteIcon() async throws {
        guard let host = ProcessInfo.processInfo.environment["DAYI_ICON_TEST_HOST"] else { return }
        let data = try #require(await WebsiteIconDownload.fetch(host))
        #expect(WebsiteIconDownload.thumbnail(data) != nil)
        if let output = ProcessInfo.processInfo.environment["DAYI_ICON_TEST_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
    }
}
