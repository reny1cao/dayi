import AppKit
import Sparkle

/// Sparkle reads one static file, the appcast on the project site, and nothing else leaves
/// the Mac: system profiling is off and the feed URL and public key sit in Info.plist where
/// anyone can verify them. The updater exists only inside a packaged bundle; a `swift test`
/// process has no feed and never constructs it.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    /// True when this process is the packaged app with a feed declared.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Starts the scheduled check. Sparkle asks the user once whether it may check automatically.
    func start() {
        do { try controller.updater.start() } catch {
            NSLog("Dayi updater did not start: \(error.localizedDescription)")
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
