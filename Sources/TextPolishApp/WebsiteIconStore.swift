import AppKit
import CryptoKit
import Observation
import SwiftUI

struct WebsiteBadge: View {
    let host: String
    var icons = WebsiteIconStore.shared

    var body: some View {
        Group {
            if let image = icons.images[host] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                (ProviderIcon.websiteImage(for: host) ?? Image(systemName: "globe"))
                    .resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: Metric.sidebarBadgeSize, height: Metric.sidebarBadgeSize)
        .accessibilityHidden(true)
        .task(id: host) { await icons.loadCached(host) }
    }
}

/// Only the captured polish trigger starts networking. View lifetime and scrolling only
/// read disk, while this app-owned store keeps downloads alive across focus changes.
@MainActor @Observable
final class WebsiteIconStore {
    static let shared = WebsiteIconStore()
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private let loader: WebsiteIconLoader
    @ObservationIgnored private var loaded: Set<String> = []
    @ObservationIgnored private var requests: [String: Task<Void, Never>] = [:]

    init(loader: WebsiteIconLoader = WebsiteIconLoader()) { self.loader = loader }

    func loadCached(_ host: String) async {
        guard loaded.insert(host).inserted else { return }
        if let data = await loader.cachedImage(host), let image = NSImage(data: data) {
            images[host] = image
        }
    }

    @discardableResult
    func fetchIfMissing(_ host: String) -> Task<Void, Never>? {
        guard images[host] == nil, ProviderIcon.websiteImage(for: host) == nil else { return nil }
        if let request = requests[host] { return request }
        let request = Task {
            if let data = await loader.resolve(host), let image = NSImage(data: data) {
                images[host] = image
            }
            requests[host] = nil
        }
        requests[host] = request
        return request
    }
}

actor WebsiteIconLoader {
    private struct Entry: Codable {
        let attemptedAt: Date
        let png: Data?
    }
    private let directory: URL
    private let download: @Sendable (String) async -> Data?
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.local.dayi/website-icons", isDirectory: true),
         now: @escaping @Sendable () -> Date = { Date() },
         download: @escaping @Sendable (String) async -> Data? = { await WebsiteIconDownload.fetch($0) }) {
        self.directory = directory
        self.now = now
        self.download = download
    }

    func cachedImage(_ host: String) -> Data? { entry(host)?.png }

    func resolve(_ host: String) async -> Data? {
        guard WebsiteIconDownload.isPublicHostName(host) else { return nil }
        if let entry = entry(host) {
            if let png = entry.png { return png }
            if now().timeIntervalSince(entry.attemptedAt) < 24 * 60 * 60 { return nil }
        }
        let data = await download(host)
        let entry = Entry(attemptedAt: now(), png: data.flatMap(WebsiteIconDownload.thumbnail))
        entries[host] = entry
        // A failed cache write must not discard a downloaded icon or affect polishing.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(entry) {
            let path = file(host)
            try? data.write(to: path, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        return entry.png
    }

    private func entry(_ host: String) -> Entry? {
        if let entry = entries[host] { return entry }
        let path = file(host)
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 128 * 1024,
              let data = try? Data(contentsOf: path),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.attemptedAt <= now(),
              entry.png == nil || entry.png.flatMap(WebsiteIconDownload.thumbnail) != nil else { return nil }
        entries[host] = entry
        return entry
    }

    private func file(_ host: String) -> URL {
        let key = SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
}
