import Foundation

public struct TextSnapshot: Equatable, Sendable {
    public let document: String
    public let range: NSRange

    public init(document: String, range: NSRange) throws {
        let length = (document as NSString).length
        guard range.location >= 0, range.location <= length,
              range.length > 0, range.length <= length - range.location,
              (document as NSString).rangeOfComposedCharacterSequences(for: range) == range else {
            throw TargetError.invalidSelection
        }
        self.document = document
        self.range = range
    }

    public var selectedText: String { (document as NSString).substring(with: range) }

    public func replacing(with text: String) -> String {
        (document as NSString).replacingCharacters(in: range, with: text)
    }
}

public enum TargetError: Error, Codable, Equatable, Sendable, LocalizedError {
    case invalidSelection, unsupportedInput, readOnlyInput, noFocusedInput, hostForeground, targetQuit
    case unavailable, conflict, foregroundRequired, busy, notApplied, uncertain, noResult, cannotUndo, emptyDocument, unmappableSelection

    public var errorDescription: String? {
        switch self {
        case .invalidSelection: L10n.tr("无法确定要润色的文本，请先在输入区选中它。")
        case .emptyDocument: L10n.tr("输入区里还没有文字，无法润色。")
        case .unmappableSelection: L10n.tr("这个输入区的多段内容无法按原位定位，请只选中其中一段再润色。")
        case .unsupportedInput: L10n.tr("当前焦点不是可润色的文本输入区。")
        case .readOnlyInput: L10n.tr("这个输入区不允许写入，无法润色。")
        case .noFocusedInput: L10n.tr("没有找到输入焦点。请先点进要润色的输入框，再按 ⌃⌥P。")
        case .hostForeground: L10n.tr("Dayi 窗口在最前面。请切回目标应用并把光标放进输入框，再按 ⌃⌥P。")
        case .targetQuit: L10n.tr("原应用已退出。")
        case .unavailable: L10n.tr("原输入区已不可用（窗口或页面已改变）。")
        case .conflict: L10n.tr("原文本已变化，未覆盖新内容。")
        case .foregroundRequired: L10n.tr("结果已保留，请回到原输入区后应用。")
        case .busy: L10n.tr("这个输入区已有运行中的润色任务。")
        case .notApplied: L10n.tr("未能写入原输入区。")
        case .uncertain: L10n.tr("无法确认写入结果；已停止自动操作。")
        case .noResult: L10n.tr("没有可应用的结果。")
        case .cannotUndo: L10n.tr("无法安全撤回这次替换。")
        }
    }
}

/// Real applications are external consistency boundaries. Each implementation must
/// validate the retained document identity and expected UTF-16 units immediately before writing.
/// Canonical String equality cannot protect ranges measured in UTF-16 offsets.
@MainActor
public protocol TextTarget: AnyObject {
    var id: String { get }
    var label: String { get }
    var supportsBackgroundWrite: Bool { get }
    var isFocused: Bool { get }
    func capture() throws -> TextSnapshot
    func readDocument() throws -> String
    /// A throw of `uncertain` means a write might have happened. Never retry it blindly.
    func replace(range: NSRange, with text: String, expectedDocument: String) async throws
    func returnToContext(range: NSRange) throws
}

public struct AppliedEdit: Sendable {
    public let original: TextSnapshot
    public let replacement: String
    public let range: NSRange

    public init(original: TextSnapshot, replacement: String) {
        self.original = original
        self.replacement = replacement
        self.range = NSRange(location: original.range.location, length: (replacement as NSString).length)
    }

    /// A stable prefix and exact inserted segment prove the retained range. Edits in
    /// the suffix are preserved; prefix changes require editor-specific position mapping.
    public func validatedRange(in current: String) throws -> NSRange {
        let expected = original.replacing(with: replacement)
        let prefixLength = NSMaxRange(range)
        guard (current as NSString).length >= prefixLength,
              (current as NSString).rangeOfComposedCharacterSequences(for: range) == range,
              (current as NSString).substring(to: prefixLength).utf16.elementsEqual(
                  (expected as NSString).substring(to: prefixLength).utf16) else {
            throw TargetError.cannotUndo
        }
        return range
    }

    public func undoDocument(from current: String) throws -> String {
        let range = try validatedRange(in: current)
        return (current as NSString).replacingCharacters(in: range, with: original.selectedText)
    }
}
