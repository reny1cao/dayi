import Foundation
import PolishCore

/// Chromium's text positions count text-node UTF-16 units, whereas AXValue also
/// contains rendered paragraph separators. Keep both coordinates; never remove
/// line breaks from the document sent to the model or checked before a write.
struct ChromiumTextLayout {
    struct Run {
        let documentRange: NSRange
        let accessibilityRange: NSRange
    }

    let document: String
    let accessibilityText: String
    let runs: [Run]

    init(document: String, textNodes: [String], accessibilityText: String) throws {
        let value = Array(document.utf16)
        guard textNodes.joined().utf16.elementsEqual(accessibilityText.utf16) else {
            throw TargetError.unmappableSelection
        }
        var documentOffset = 0
        var accessibilityOffset = 0
        var runs: [Run] = []
        for text in textNodes {
            let units = Array(text.utf16)
            guard !units.isEmpty else { throw TargetError.unmappableSelection }
            // The only extra characters allowed between actual text nodes are
            // rendered LF separators. Multiple possible alignments are refused.
            var candidates: [Int] = []
            var start = documentOffset
            while start <= value.count {
                if units.count <= value.count - start,
                   value[start..<(start + units.count)].elementsEqual(units) {
                    candidates.append(start)
                }
                guard start < value.count, value[start] == 10 else { break }
                start += 1
            }
            guard candidates.count == 1, let start = candidates.first else {
                throw TargetError.unmappableSelection
            }
            runs.append(Run(documentRange: NSRange(location: start, length: units.count),
                            accessibilityRange: NSRange(location: accessibilityOffset, length: units.count)))
            documentOffset = start + units.count
            accessibilityOffset += units.count
        }
        guard value[documentOffset...].allSatisfy({ $0 == 10 }) else {
            throw TargetError.unmappableSelection
        }
        self.document = document
        self.accessibilityText = accessibilityText
        self.runs = runs
    }

    func documentOffset(inRun index: Int, localOffset: Int) throws -> Int {
        guard runs.indices.contains(index), localOffset >= 0,
              localOffset <= runs[index].documentRange.length else { throw TargetError.invalidSelection }
        return runs[index].documentRange.location + localOffset
    }

    /// Used only for a marker anchored on the editor itself. At a paragraph
    /// boundary a flat offset can mean either side of the LF; it is not evidence
    /// of one particular document position.
    func documentOffset(forAccessibilityOffset offset: Int) throws -> Int {
        if offset == 0 { return 0 }
        if offset == accessibilityText.utf16.count { return document.utf16.count }
        let positions = Set(runs.compactMap { run -> Int? in
            guard offset >= run.accessibilityRange.location,
                  offset <= NSMaxRange(run.accessibilityRange) else { return nil }
            return run.documentRange.location + offset - run.accessibilityRange.location
        })
        guard positions.count == 1, let position = positions.first else { throw TargetError.invalidSelection }
        return position
    }

    func accessibilityRange(for range: NSRange) throws -> NSRange {
        _ = try TextSnapshot(document: document, range: range)
        func offset(_ position: Int) throws -> Int {
            if position == 0 { return 0 }
            if position == document.utf16.count { return accessibilityText.utf16.count }
            for run in runs where position >= run.documentRange.location && position <= NSMaxRange(run.documentRange) {
                return run.accessibilityRange.location + position - run.documentRange.location
            }
            throw TargetError.invalidSelection
        }
        let start = try offset(range.location)
        let end = try offset(NSMaxRange(range))
        guard end > start else { throw TargetError.invalidSelection }
        return NSRange(location: start, length: end - start)
    }
}
