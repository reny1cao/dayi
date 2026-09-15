import Foundation
import PolishCore
import Testing
@testable import TextPolishApp

struct ChromiumTextLayoutTests {
    @Test func paragraphsKeepTheirLineBreaksAndUseNodeOffsets() throws {
        let document = "第一段🙂\n第二段 e\u{301}\n第三段"
        let nodes = ["第一段🙂", "第二段 e\u{301}", "第三段"]
        let layout = try ChromiumTextLayout(document: document, textNodes: nodes, accessibilityText: nodes.joined())
        let firstLength = nodes[0].utf16.count
        #expect(try layout.documentOffset(inRun: 1, localOffset: 0) == firstLength + 1)
        #expect(try layout.accessibilityRange(for: NSRange(location: 0, length: document.utf16.count)) ==
                NSRange(location: 0, length: nodes.joined().utf16.count))
        // A real marker identifies which side of a paragraph break it belongs to.
        #expect(try layout.documentOffset(inRun: 0, localOffset: firstLength) == firstLength)
        #expect(throws: TargetError.invalidSelection) {
            try layout.documentOffset(forAccessibilityOffset: firstLength)
        }
        let start = try layout.documentOffset(inRun: 0, localOffset: 1)
        let end = try layout.documentOffset(inRun: 1, localOffset: 3)
        let snapshot = try TextSnapshot(document: document, range: NSRange(location: start, length: end - start))
        #expect(snapshot.selectedText == "一段🙂\n第二段")
        #expect(try layout.accessibilityRange(for: snapshot.range) == NSRange(location: 1, length: firstLength + 2))
        // Replace and undo use document coordinates, preserving the unselected suffix.
        let replacement = "替换\n结果"
        let edit = AppliedEdit(original: snapshot, replacement: replacement)
        let after = snapshot.replacing(with: replacement) + " 后续编辑"
        #expect(try edit.undoDocument(from: after) == document + " 后续编辑")
    }

    @Test func repeatedParagraphsAreLocatedByNodeIdentityNotTextSearch() throws {
        let layout = try ChromiumTextLayout(document: "same\nsame\nsame", textNodes: ["same", "same", "same"],
                                            accessibilityText: "samesamesame")
        #expect(try layout.documentOffset(inRun: 1, localOffset: 0) == 5)
        #expect(try layout.documentOffset(inRun: 2, localOffset: 4) == 14)
        #expect(try layout.accessibilityRange(for: NSRange(location: 5, length: 4)) == NSRange(location: 4, length: 4))
    }

    @Test func inlineRunsAndEmptyParagraphsKeepTheirCoordinates() throws {
        let layout = try ChromiumTextLayout(document: "ab\n\ncd", textNodes: ["a", "b", "c", "d"],
                                            accessibilityText: "abcd")
        #expect(try layout.documentOffset(forAccessibilityOffset: 1) == 1)
        #expect(try layout.documentOffset(inRun: 2, localOffset: 0) == 4)
        #expect(throws: TargetError.invalidSelection) {
            try layout.accessibilityRange(for: NSRange(location: 3, length: 2))
        }
    }

    @Test func rejectsDifferentUnicodeOmittedContentAndAmbiguousLineBreaks() throws {
        for (document, nodes, flat) in [
            ("é\nx", ["e\u{301}", "x"], "e\u{301}x"),
            ("a x\nb", ["a", "b"], "ab"),
            ("a\nb", ["a", "b"], "a?b"),
            ("a\n\nb", ["a", "\n", "b"], "a\nb"),
        ] {
            #expect(throws: TargetError.unmappableSelection) {
                try ChromiumTextLayout(document: document, textNodes: nodes, accessibilityText: flat)
            }
        }
    }

    @Test func refusesInvalidOffsetsAndSplitGraphemes() throws {
        let layout = try ChromiumTextLayout(document: "🙂\ne\u{301}", textNodes: ["🙂", "e\u{301}"],
                                            accessibilityText: "🙂e\u{301}")
        #expect(throws: TargetError.invalidSelection) { try layout.documentOffset(inRun: 2, localOffset: 0) }
        #expect(throws: TargetError.invalidSelection) { try layout.documentOffset(inRun: 0, localOffset: -1) }
        #expect(throws: TargetError.invalidSelection) { try layout.documentOffset(inRun: 0, localOffset: 3) }
        #expect(throws: TargetError.invalidSelection) {
            try layout.accessibilityRange(for: NSRange(location: 1, length: 1))
        }
    }
}
