import AppKit
import ApplicationServices
import PolishCore

struct FocusReadError: Error, LocalizedError, Equatable {
    let code: Int32

    var errorDescription: String? {
        L10n.format("辅助功能读取失败（AX %@），本次未能确认输入焦点。", String(describing: code))
    }
}

@MainActor
final class AXTextTarget: TextTarget {
    let id: String
    let label: String
    let website: WebsiteSource?
    let websiteIconHost: String?
    let supportsBackgroundWrite: Bool
    /// The AX role this element reported at capture time, and whether it lives in a web view.
    /// Both are read once here and never again: the inspector needs them to explain why a
    /// result had to wait, and asking the element again after its process moved on would
    /// answer about something else.
    let role: String
    var isWeb: Bool { webContext != nil }
    /// The range the last `capture()` read, in UTF-16 units. Nil until the first capture.
    private(set) var capturedRange: NSRange?
    private let application: NSRunningApplication
    private let appElement: AXUIElement
    private let element: AXUIElement
    private let window: AXUIElement
    private let webContext: WebContext?
    private let usesClipboard: Bool
    private let usesChromiumTextPositions: Bool

    private struct WebSelectionLayout {
        let text: ChromiumTextLayout
        let elements: [AXUIElement]
        let fullRange: CFTypeRef
    }

    private struct WebContext {
        let element: AXUIElement
        let url: URL
    }

    /// `waking` is called once, with the host's name, if the host has to be woken before it
    /// can say what is focused; that wait is the only slow path and the caller shows it.
    static func captureFocused(in application: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
                               waking: @MainActor (String) -> Void) async throws -> AXTextTarget {
        guard AXIsProcessTrusted() else { throw AppError.accessibilityRequired }
        guard let app = application else { throw TargetError.noFocusedInput }
        // The hot key reaches this app's own window too. That press has no target to read.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw TargetError.hostForeground }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1)
        // Chromium hosts report no focused element at all unless the caret sits in a live input.
        guard let element = try await focusedElement(of: app, appElement, waking: waking) else {
            throw TargetError.noFocusedInput
        }
        guard let role = try attribute(element, kAXRoleAttribute) as? String else { throw TargetError.unsupportedInput }
        let subrole = try? attribute(element, kAXSubroleAttribute) as? String
        guard [kAXTextAreaRole, kAXTextFieldRole].contains(role), subrole != kAXSecureTextFieldSubrole else {
            throw TargetError.unsupportedInput
        }
        let window = try elementAttribute(element, kAXWindowAttribute)
        let webContext = try webContext(of: element, window: window)
        // Web editors use their normal paste event so the editor's own state updates.
        // AXSelectedText setters in Chromium/WebKit cannot establish that capability.
        let usesClipboard = webContext != nil
        let writableAttribute = usesClipboard ? kAXValueAttribute : kAXSelectedTextAttribute
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, writableAttribute as CFString, &settable) == .success,
              settable.boolValue else { throw TargetError.readOnlyInput }
        return AXTextTarget(application: app, appElement: appElement, element: element, window: window,
                            webContext: webContext, usesClipboard: usesClipboard,
                            supportsBackgroundWrite: !usesClipboard && role == kAXTextAreaRole, role: role)
    }

    private init(application: NSRunningApplication, appElement: AXUIElement, element: AXUIElement, window: AXUIElement,
                 webContext: WebContext?, usesClipboard: Bool, supportsBackgroundWrite: Bool, role: String) {
        self.application = application
        self.appElement = appElement
        self.element = element
        self.window = window
        self.webContext = webContext
        self.usesClipboard = usesClipboard
        self.supportsBackgroundWrite = supportsBackgroundWrite
        self.role = role
        self.usesChromiumTextPositions = usesClipboard && Self.isChromiumHost(application, appElement)
        self.label = application.localizedName ?? L10n.tr("输入区")
        let source = BrowserSource.capture(bundleID: application.bundleIdentifier, element: element, window: window)
        self.website = source?.website
        self.websiteIconHost = source?.iconHost
        self.id = "\(application.processIdentifier):\(application.launchDate?.timeIntervalSince1970 ?? 0):\(CFHash(element)):\(webContext?.url.absoluteString ?? "")"
    }

    var isFocused: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let focused = try? Self.elementAttribute(appElement, kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused, element)
    }

    /// A collapsed selection means the whole input is the subject: the text is selected here so
    /// the write path finds the same range the snapshot was taken from.
    ///
    /// Chromium editors expose their placeholder as the value while empty and refuse to select
    /// it, so an input counts as empty when nothing can be selected, not when the value reads as
    /// empty. Chromium rich editors need text-node coordinates for selections, while the
    /// snapshot keeps the rendered paragraph breaks supplied by AXValue.
    func capture() throws -> TextSnapshot {
        let document = try readDocument()
        if let layout = try webSelectionLayout(document: document) {
            if try selectedRange().length == 0 {
                let fullRange = NSRange(location: 0, length: document.utf16.count)
                try setSelection(fullRange, using: layout)
                let clock = ContinuousClock()
                let deadline = clock.now + .milliseconds(500)
                while (try? selectedDocumentRange(using: layout)) != fullRange {
                    guard isFocused else { throw TargetError.foregroundRequired }
                    guard clock.now < deadline else { throw TargetError.unmappableSelection }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            guard try readDocument().utf16.elementsEqual(document.utf16) else { throw TargetError.conflict }
            let range = try selectedDocumentRange(using: layout)
            let snapshot = try TextSnapshot(document: document, range: range)
            capturedRange = range
            return snapshot
        }
        var range = try selectedRange()
        let widened = range.length == 0
        if widened {
            let length = (document as NSString).length
            guard !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TargetError.emptyDocument }
            _ = try? setSelection(NSRange(location: 0, length: length))
            range = try awaitWidenedSelection()
            if range.length == 0 {
                try selectAllByKeyboard()
                range = try awaitWidenedSelection()
            }
            guard range.length > 0 else { throw TargetError.emptyDocument }
        }
        let snapshot = try TextSnapshot(document: document, range: range)
        guard let selected = try Self.attribute(element, kAXSelectedTextAttribute) as? String,
              selected.utf16.elementsEqual(snapshot.selectedText.utf16) else {
            throw widened ? TargetError.unmappableSelection : TargetError.invalidSelection
        }
        capturedRange = range
        return snapshot
    }

    /// ⌘A delivered to the host process, where the focused editor interprets it. It is only
    /// sent while this element holds the focus, so it cannot select anything else.
    private func selectAllByKeyboard() throws {
        guard isFocused else { throw TargetError.foregroundRequired }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { throw TargetError.invalidSelection }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(application.processIdentifier)
        up.postToPid(application.processIdentifier)
    }

    func readDocument() throws -> String {
        guard !application.isTerminated else { throw TargetError.targetQuit }
        guard let currentWindow = try? Self.elementAttribute(element, kAXWindowAttribute), CFEqual(currentWindow, window),
              let value = try Self.attribute(element, kAXValueAttribute) as? String else { throw TargetError.unavailable }
        let currentContext = try Self.webContext(of: element, window: window)
        switch (webContext, currentContext) {
        case (nil, nil): break
        case let (original?, current?) where CFEqual(original.element, current.element) && original.url == current.url: break
        default: throw TargetError.unavailable
        }
        return value
    }

    func replace(range: NSRange, with text: String, expectedDocument: String) async throws {
        // Native text areas can replace through AX without activation or keyboard events.
        // Web editors and shared native text-field editors retain the foreground requirement.
        guard supportsBackgroundWrite || isFocused else { throw TargetError.foregroundRequired }
        guard try readDocument().utf16.elementsEqual(expectedDocument.utf16) else { throw TargetError.conflict }
        _ = try TextSnapshot(document: expectedDocument, range: range)
        let layout = try webSelectionLayout(document: expectedDocument)
        try setSelection(range, using: layout)
        guard supportsBackgroundWrite || isFocused else { throw TargetError.foregroundRequired }
        guard try readDocument().utf16.elementsEqual(expectedDocument.utf16) else { throw TargetError.conflict }
        if usesClipboard {
            try await paste(range: range, text: text, expectedDocument: expectedDocument, layout: layout)
            return
        }
        guard try selectedRange() == range else { throw TargetError.notApplied }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard status == .success else { throw TargetError.uncertain }
        // Caller verifies actual content. Success here is not proof of a successful edit.
    }

    private func paste(range: NSRange, text: String, expectedDocument: String, layout: WebSelectionLayout?) async throws {
        // Selection updates and keyboard paste are asynchronous across Electron processes.
        // Poll only for acknowledgement; post exactly one paste and never retry a write.
        let clock = ContinuousClock()
        let selectionDeadline = clock.now + .seconds(1)
        while (try? selectedDocumentRange(using: layout)) != range {
            guard isFocused else { throw TargetError.foregroundRequired }
            guard try readDocument().utf16.elementsEqual(expectedDocument.utf16) else { throw TargetError.conflict }
            guard clock.now < selectionDeadline else { throw TargetError.notApplied }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard isFocused, try readDocument().utf16.elementsEqual(expectedDocument.utf16) else { throw TargetError.conflict }
        let lease = try ClipboardLease(text: text)
        defer { lease.restore() }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw TargetError.notApplied }
        guard lease.isCurrent else { throw TargetError.notApplied }
        guard isFocused else { throw TargetError.foregroundRequired }
        guard try selectedDocumentRange(using: layout) == range,
              try readDocument().utf16.elementsEqual(expectedDocument.utf16) else { throw TargetError.conflict }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(application.processIdentifier)
        up.postToPid(application.processIdentifier)
        let expected = (expectedDocument as NSString).replacingCharacters(in: range, with: text)
        let deadline = clock.now + .seconds(2)
        while true {
            let current = try readDocument()
            if current.utf16.elementsEqual(expected.utf16) { return }
            guard current.utf16.elementsEqual(expectedDocument.utf16), lease.isCurrent, clock.now < deadline else { throw TargetError.uncertain }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Electron and Codex apply a selection on the renderer side and answer the next read from
    /// the old state for a few frames. A short bounded wait is the difference between reading
    /// the selection that was just set and reading the one it replaced.
    private func awaitWidenedSelection() throws -> NSRange {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(500)
        while true {
            let range = try selectedRange()
            if range.length > 0 || clock.now >= deadline { return range }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func selectedRange() throws -> NSRange {
        let value = try Self.attribute(element, kAXSelectedTextRangeAttribute)
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw TargetError.invalidSelection }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { throw TargetError.invalidSelection }
        return NSRange(location: range.location, length: range.length)
    }

    private func webSelectionLayout(document: String) throws -> WebSelectionLayout? {
        guard usesChromiumTextPositions else { return nil }
        let fullRange = try Self.parameter(element, "AXTextMarkerRangeForUIElement", element)
        guard CFGetTypeID(fullRange) == AXTextMarkerRangeGetTypeID(),
              let text = try Self.parameter(element, "AXStringForTextMarkerRange", fullRange) as? String else {
            throw TargetError.unmappableSelection
        }
        // Empty editors can expose their placeholder as AXValue. Keep the existing
        // empty-input check. Plain text fields already use document coordinates.
        if text.isEmpty || text.utf16.elementsEqual(document.utf16) { return nil }
        var elements: [AXUIElement] = []
        var texts: [String] = []
        var visited: [AXUIElement] = []
        @MainActor func collect(_ node: AXUIElement) throws {
            for previous in visited where CFEqual(previous, node) { throw TargetError.unmappableSelection }
            visited.append(node)
            let role = try Self.attribute(node, kAXRoleAttribute) as? String
            if role == kAXStaticTextRole {
                guard let value = try Self.attribute(node, kAXValueAttribute) as? String else {
                    throw TargetError.unmappableSelection
                }
                if !value.isEmpty { elements.append(node); texts.append(value) }
                return
            }
            // No embedded controls or attachments may disappear from the mapping.
            guard CFEqual(node, element) || [kAXGroupRole, "AXLink", "AXParagraph"].contains(role) else {
                throw TargetError.unmappableSelection
            }
            guard let children = try Self.attribute(node, kAXChildrenAttribute) as? [AXUIElement] else {
                throw TargetError.unmappableSelection
            }
            for child in children { try collect(child) }
        }
        try collect(element)
        return WebSelectionLayout(text: try ChromiumTextLayout(document: document, textNodes: texts,
                                                              accessibilityText: text),
                                  elements: elements, fullRange: fullRange)
    }

    private func selectedDocumentRange(using layout: WebSelectionLayout?) throws -> NSRange {
        guard let layout, let webContext else { return try selectedRange() }
        let selection = try Self.attribute(element, "AXSelectedTextMarkerRange")
        guard CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() else { throw TargetError.invalidSelection }
        @MainActor func position(_ marker: CFTypeRef) throws -> Int {
            let owner = try Self.parameter(webContext.element, "AXUIElementForTextMarker", marker)
            guard CFGetTypeID(owner) == AXUIElementGetTypeID(),
                  let offset = try Self.parameter(webContext.element, "AXIndexForTextMarker", marker) as? NSNumber else {
                throw TargetError.invalidSelection
            }
            if CFEqual(owner, element) {
                return try layout.text.documentOffset(forAccessibilityOffset: offset.intValue)
            }
            for (index, node) in layout.elements.enumerated() where CFEqual(node, owner) {
                return try layout.text.documentOffset(inRun: index, localOffset: offset.intValue)
            }
            throw TargetError.invalidSelection
        }
        let start = try position(AXTextMarkerRangeCopyStartMarker(selection as! AXTextMarkerRange))
        let end = try position(AXTextMarkerRangeCopyEndMarker(selection as! AXTextMarkerRange))
        let range = NSRange(location: min(start, end), length: abs(end - start))
        let axRange = try layout.text.accessibilityRange(for: range)
        guard try selectedRange() == axRange,
              let selected = try Self.attribute(element, kAXSelectedTextAttribute) as? String,
              selected.utf16.elementsEqual((layout.text.accessibilityText as NSString).substring(with: axRange).utf16) else {
            throw TargetError.invalidSelection
        }
        return range
    }

    private static func webContext(of element: AXUIElement, window: AXUIElement) throws -> WebContext? {
        var parent = element
        // The AX tree is supplied by another process. Detect malformed parent cycles.
        var ancestors: [AXUIElement] = []
        while !CFEqual(parent, window) {
            guard !ancestors.contains(where: { CFEqual($0, parent) }) else { throw TargetError.unavailable }
            ancestors.append(parent)
            if try attribute(parent, kAXRoleAttribute) as? String == "AXWebArea" {
                guard let url = try attribute(parent, kAXURLAttribute) as? URL else { throw TargetError.unavailable }
                return WebContext(element: parent, url: url)
            }
            parent = try elementAttribute(parent, kAXParentAttribute)
        }
        return nil
    }

    func returnToContext(range: NSRange) throws {
        let document = try readDocument()
        _ = try TextSnapshot(document: document, range: range)
        application.activate()
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success,
              AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            throw TargetError.unavailable
        }
        try setSelection(range, using: webSelectionLayout(document: document))
    }

    private func setSelection(_ range: NSRange, using layout: WebSelectionLayout?) throws {
        guard let layout else { return try setSelection(range) }
        guard isFocused else { throw TargetError.foregroundRequired }
        if range == NSRange(location: 0, length: layout.text.document.utf16.count) {
            guard AXUIElementSetAttributeValue(element, "AXSelectedTextMarkerRange" as CFString,
                                               layout.fullRange) == .success else { throw TargetError.notApplied }
        } else {
            try setSelection(layout.text.accessibilityRange(for: range))
        }
    }

    private static func parameter(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) throws -> CFTypeRef {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success,
              let result else { throw TargetError.unavailable }
        return result
    }

    private func setSelection(_ range: NSRange) throws {
        var value = CFRange(location: range.location, length: range.length)
        guard let boxed = AXValueCreate(.cfRange, &value),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, boxed) == .success else {
            throw TargetError.notApplied
        }
    }

    /// A Chromium host (Codex, Claude, Chrome, every Electron app) keeps its web accessibility
    /// tree off until an assistive client announces itself, and turns it off again about five
    /// minutes after a page is hidden. While it is off, every focus query answers
    /// `kAXErrorNoValue`, the same answer a genuinely unfocused application gives.
    ///
    /// The announcement is `AXEnhancedUserInterface` on the application element, the attribute
    /// VoiceOver sets; Electron additionally accepts its own `AXManualAccessibility`. Codex's
    /// framework is Chromium without Electron and knows only the first. Every host debounces the
    /// request behind a quiet two-second window before switching the tree on, and the renderer
    /// then serialises the page, so the first answer arrives well after two seconds (2.1 s
    /// measured on Codex 26.903). The accessibility server reports the set itself as
    /// `notImplemented` on hosts that act on it, so return codes are not evidence and are ignored.
    ///
    /// Only a host that ships Chromium is asked and waited on. Anywhere else `noValue` means what
    /// it says and is reported at once, and any other error is never waited on. The host keeps
    /// its tree on afterwards, as it does after VoiceOver has been used, so the next press in the
    /// same host answers immediately.
    private static let wakeLimit: Duration = .seconds(5)

    private static func focusedElement(of app: NSRunningApplication, _ appElement: AXUIElement,
                                       waking: @MainActor (String) -> Void) async throws -> AXUIElement? {
        var status = AXError.success
        if let element = try copyFocusedElement(of: appElement, status: &status) { return element }
        guard status == .noValue, isChromiumHost(app, appElement) else { return nil }
        waking(app.localizedName ?? L10n.tr("目标应用"))
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let clock = ContinuousClock()
        let deadline = clock.now + wakeLimit
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if let element = try copyFocusedElement(of: appElement, status: &status) { return element }
        }
        return nil
    }

    private static func isChromiumHost(_ app: NSRunningApplication, _ appElement: AXUIElement) -> Bool {
        if let bundle = app.bundleURL, isChromiumBundle(bundle) { return true }
        // Electron publishes its opt-in attribute on the application element itself.
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(appElement, &names) == .success,
              let names = names as? [String] else { return false }
        return names.contains("AXManualAccessibility")
    }

    /// Chromium ships its ICU data and resource packs inside a framework, whatever the framework
    /// is called: `Electron Framework`, `Google Chrome Framework`, Codex's `Codex Framework`.
    /// Flutter ships the ICU file too and nothing else here, so both markers are required.
    static func isChromiumBundle(_ bundleURL: URL) -> Bool {
        let manager = FileManager.default
        let frameworks = bundleURL.appending(path: "Contents/Frameworks")
        guard let names = try? manager.contentsOfDirectory(atPath: frameworks.path) else { return false }
        return names.contains { name in
            guard name.hasSuffix(".framework") else { return false }
            let resources = frameworks.appending(path: "\(name)/Resources")
            guard manager.fileExists(atPath: resources.appending(path: "icudtl.dat").path),
                  let files = try? manager.contentsOfDirectory(atPath: resources.path) else { return false }
            return files.contains { $0.hasSuffix(".pak") }
        }
    }

    private static func copyFocusedElement(of appElement: AXUIElement, status: inout AXError) throws -> AXUIElement? {
        var value: CFTypeRef?
        status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
        return try checkedFocusedElement(value, status: status)
    }

    static func checkedFocusedElement(_ value: CFTypeRef?, status: AXError) throws -> AXUIElement? {
        if status == .noValue { return nil }
        guard status == .success else { throw FocusReadError(code: status.rawValue) }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw TargetError.unavailable }
        return (value as! AXUIElement)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success, let result else {
            throw TargetError.unavailable
        }
        return result
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) throws -> AXUIElement {
        let value = try attribute(element, name)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw TargetError.unavailable }
        return value as! AXUIElement
    }
}
