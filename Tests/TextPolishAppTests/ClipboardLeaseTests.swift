import AppKit
import PolishCore
import Testing
@testable import TextPolishApp

@Suite(.serialized) @MainActor
struct ClipboardLeaseTests {
    private func board() -> NSPasteboard {
        NSPasteboard(name: .init("TextPolish.Tests.\(UUID().uuidString)"))
    }

    @Test func restoresAllItemsAndTypes() throws {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("original 🙂", forType: .string)
        let customType = NSPasteboard.PasteboardType("dev.local.textpolish.test")
        first.setData(Data([0, 1, 2, 255]), forType: customType)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        pasteboard.writeObjects([first, second])
        let lease = try ClipboardLease(text: "replacement", pasteboard: pasteboard)
        #expect(pasteboard.string(forType: .string) == "replacement")
        lease.restore()
        let restored = try #require(pasteboard.pasteboardItems)
        #expect(restored.count == 2)
        #expect(restored[0].string(forType: .string) == "original 🙂")
        #expect(restored[0].data(forType: customType) == Data([0, 1, 2, 255]))
        #expect(restored[1].string(forType: .string) == "second")
    }

    @Test func laterCopyWinsEvenWhenItMatchesTemporaryText() throws {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old clipboard", forType: .string)
        let lease = try ClipboardLease(text: "replacement", pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("replacement", forType: .string)
        #expect(!lease.isCurrent)
        let revision = pasteboard.changeCount
        lease.restore()
        #expect(pasteboard.changeCount == revision)
        #expect(pasteboard.string(forType: .string) == "replacement")
    }

    @Test func serializesOutstandingPastesAndRestoresEmptyClipboard() throws {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        let lease = try ClipboardLease(text: "first", pasteboard: pasteboard)
        #expect(throws: TargetError.notApplied) { try ClipboardLease(text: "second", pasteboard: pasteboard) }
        #expect(pasteboard.string(forType: .string) == "first")
        lease.restore()
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
        let revision = pasteboard.changeCount
        lease.restore()
        #expect(pasteboard.changeCount == revision)
        let next = try ClipboardLease(text: "next", pasteboard: pasteboard)
        next.restore()
    }
}
