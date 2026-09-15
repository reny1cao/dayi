import Foundation
import Network

/// A history label, not a navigation target. Paths, queries, credentials and fragments
/// never cross this boundary; the original AX URL remains private to the live target.
public struct WebsiteSource: Hashable, Sendable {
    public let host: String

    public init?(url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host(percentEncoded: false) else { return nil }
        self.init(host: host)
    }

    /// Also validates the persisted column. A URL or a host with a path is not a host.
    public init?(host: String) {
        var normalized = host.lowercased()
        if normalized.hasSuffix(".") { normalized.removeLast() }
        guard !normalized.isEmpty,
              normalized.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0)
                  || [45, 46, 58, 95].contains($0) }) else { return nil }
        if normalized.contains(":"), IPv6Address(normalized) == nil { return nil }
        let authority = normalized.contains(":") ? "[\(normalized)]" : normalized
        guard let url = URL(string: "https://\(authority)"),
              url.host(percentEncoded: false) == normalized else { return nil }
        self.host = normalized
    }
}
