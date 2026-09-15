import Darwin
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

/// No browser cookies, credentials, script execution or third-party icon lookup service.
/// Redirects are handled explicitly so every destination passes the same URL/DNS checks.
enum WebsiteIconDownload {
    enum Failure: Error { case invalidURL, blockedAddress, response, oversized }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }

    static func fetch(_ host: String) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await fetch(host, session: session)
    }

    // Session and resolver injection allow the real request/redirect/parser pipeline to be
    // tested with synthetic responses, without contacting fixture domains or local services.
    static func fetch(_ host: String, session: URLSession,
                      resolve: @Sendable (String) async -> Bool = { await publicDNS($0) }) async -> Data? {
        guard isPublicHostName(host), let root = URL(string: "https://\(host)/") else { return nil }
        if let response = try? await read(root.appendingPathComponent("favicon.ico"), session: session,
                                          resolve: resolve, limit: 1024 * 1024),
           let png = thumbnail(response.data) { return png }
        guard let page = try? await read(root, session: session, resolve: resolve, limit: 256 * 1024,
                                        allowTruncation: true),
              page.mime == "text/html" || page.mime == "application/xhtml+xml",
              let html = String(data: page.data, encoding: .utf8),
              let urls = try? iconURLs(html: html, base: page.url) else { return nil }
        for url in urls.prefix(3) {
            if let response = try? await read(url, session: session, resolve: resolve, limit: 1024 * 1024),
               let png = thumbnail(response.data) { return png }
        }
        return nil
    }

    static func iconURLs(html: String, base: URL) throws -> [URL] {
        let document = try XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        guard let head = try document.nodes(forXPath: "//*[local-name()='head']").first else { return [] }
        var baseURL = base
        if let element = try head.nodes(forXPath: ".//*[local-name()='base'][@href]").first as? XMLElement,
           let href = element.attribute(forName: "href")?.stringValue,
           let candidate = URL(string: href, relativeTo: base)?.absoluteURL,
           validURL(candidate) { baseURL = candidate }
        var urls: [URL] = []
        for node in try head.nodes(forXPath: ".//*[local-name()='link'][@href][@rel]") {
            guard let link = node as? XMLElement,
                  let relation = link.attribute(forName: "rel")?.stringValue,
                  let href = link.attribute(forName: "href")?.stringValue else { continue }
            let rel = relation.lowercased().split(whereSeparator: { $0.isWhitespace })
            guard rel.contains("icon") || rel.contains("apple-touch-icon"),
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  validURL(url), !urls.contains(url) else { continue }
            urls.append(url)
        }
        return urls
    }

    static func validURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
            && url.host(percentEncoded: false).map(isPublicHostName) == true
    }

    static func isPublicHostName(_ host: String) -> Bool {
        let host = host.lowercased()
        guard IPv4Address(host) == nil, IPv6Address(host) == nil,
              host.count <= 253, host.contains("."), !host.hasSuffix("."),
              !["localhost", "local", "internal", "invalid", "test", "home.arpa"].contains(where: {
                  host == $0 || host.hasSuffix("." + $0)
              }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    private static func read(_ initial: URL, session: URLSession,
                             resolve: @Sendable (String) async -> Bool, limit: Int,
                             allowTruncation: Bool = false) async throws
        -> (data: Data, url: URL, mime: String?) {
        var url = initial
        for hop in 0...3 {
            guard validURL(url), let host = url.host(percentEncoded: false) else { throw Failure.invalidURL }
            guard await resolve(host) else { throw Failure.blockedAddress }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.httpShouldHandleCookies = false
            request.setValue("Dayi/0.2.4", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw Failure.response }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard hop < 3, let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw Failure.response }
                url = next
                continue
            }
            guard (200..<300).contains(response.statusCode) else { throw Failure.response }
            guard allowTruncation || response.expectedContentLength <= limit else { throw Failure.oversized }
            var data = Data()
            for try await byte in bytes {
                if data.count == limit {
                    if allowTruncation { break }
                    throw Failure.oversized
                }
                data.append(byte)
            }
            return (data, url, response.mimeType?.lowercased())
        }
        throw Failure.response
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func publicDNS(_ host: String) async -> Bool {
        // getaddrinfo is blocking; never run it on the main actor or the polish task.
        await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return false }
            defer { freeaddrinfo(first) }
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let item = current {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer,
                                  socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                      isPublicAddress(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                             as: UTF8.self)) else { return false }
                current = item.pointee.ai_next
            }
            return true
        }.value
    }

    static func isPublicAddress(_ address: String) -> Bool {
        if let ip = IPv4Address(address) {
            let b = Array(ip.rawValue)
            return b[0] != 0 && b[0] != 10 && b[0] != 127 && b[0] < 224
                && !(b[0] == 100 && (64...127).contains(b[1]))
                && !(b[0] == 169 && b[1] == 254)
                && !(b[0] == 172 && (16...31).contains(b[1]))
                && !(b[0] == 192 && (b[1] == 168 || (b[1] == 0 && (b[2] == 0 || b[2] == 2))))
                && !(b[0] == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100)))
                && !(b[0] == 203 && b[1] == 0 && b[2] == 113)
        }
        if let ip = IPv6Address(address) {
            let b = Array(ip.rawValue)
            return b[0] & 0xe0 == 0x20 && !(b[0] == 0x20 && b[1] == 0x02)
                && !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8)
        }
        return false
    }
}
