import AppKit
import ApplicationServices
import PolishCore

/// Browser identity is separate from Chromium engine detection: desktop apps can embed
/// Chromium and even declare HTTP handlers without being general-purpose browsers.
enum BrowserSource {
    static func isBrowser(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
                "com.microsoft.edgemac", "com.brave.Browser"].contains(bundleID)
    }

    /// Walk only the captured input's ancestors. The outermost web area identifies the
    /// page containing an iframe; never read the address bar or another tab's web area.
    @MainActor static func capture(bundleID: String?, element: AXUIElement,
                                   window: AXUIElement) -> (website: WebsiteSource, iconHost: String?)? {
        guard isBrowser(bundleID: bundleID) else { return nil }
        var current = element
        var ancestors: [AXUIElement] = []
        var page: (website: WebsiteSource, iconHost: String?)?
        while !CFEqual(current, window) {
            guard !ancestors.contains(where: { CFEqual($0, current) }) else { return nil }
            ancestors.append(current)
            guard let role = attribute(current, kAXRoleAttribute) as? String else { return nil }
            if role == "AXWebArea" {
                // A missing outer URL must not attribute the whole page to an inner frame.
                page = (attribute(current, kAXURLAttribute) as? URL).flatMap { url in
                    WebsiteSource(url: url).map {
                        ($0, url.scheme?.lowercased() == "https" && (url.port == nil || url.port == 443)
                            ? $0.host : nil)
                    }
                }
            }
            guard let parent = attribute(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return page
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
