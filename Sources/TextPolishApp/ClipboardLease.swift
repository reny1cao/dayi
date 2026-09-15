import AppKit
import PolishCore

/// One outstanding paste at a time. Restore only while our clipboard revision
/// still owns the pasteboard; a later user copy must win.
@MainActor
final class ClipboardLease {
    private static var inUse = false
    private let pasteboard: NSPasteboard
    private let saved: [NSPasteboardItem]
    private let revision: Int
    private var finished = false

    init(text: String, pasteboard: NSPasteboard = .general) throws {
        guard !Self.inUse else { throw TargetError.notApplied }
        let initialRevision = pasteboard.changeCount
        var saved: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else {
                    throw TargetError.notApplied
                }
            }
            saved.append(copy)
        }
        guard pasteboard.changeCount == initialRevision else { throw TargetError.notApplied }
        Self.inUse = true
        self.pasteboard = pasteboard
        self.saved = saved
        pasteboard.clearContents()
        let written = pasteboard.setString(text, forType: .string)
        revision = pasteboard.changeCount
        if !written {
            restore()
            throw TargetError.notApplied
        }
    }

    var isCurrent: Bool { !finished && pasteboard.changeCount == revision }

    func restore() {
        guard !finished else { return }
        if isCurrent {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        finished = true
        Self.inUse = false
    }
}
