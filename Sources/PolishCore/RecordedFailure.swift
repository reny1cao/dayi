import Foundation

/// These case names and associated values are a persisted contract. Keep the original
/// message alongside them for older records and errors supplied by external systems.
public enum RecordedFailure: Codable, Equatable, Sendable {
    case polish(PolishError)
    case target(TargetError)
    case focusRead(Int32)
    case accessibilityRequired
    case hotKey(Int32)
    case interrupted(wasWriting: Bool)
    case requestIncomplete
    case applicationFailed

    public init?(_ error: Error) {
        if let error = error as? PolishError { self = .polish(error) }
        else if let error = error as? TargetError { self = .target(error) }
        else { return nil }
    }

    public var message: String {
        switch self {
        case .polish(let error): error.localizedDescription
        case .target(let error): error.localizedDescription
        case .focusRead(let code): L10n.format("辅助功能读取失败（AX %@），本次未能确认输入焦点。", String(code))
        case .accessibilityRequired: L10n.tr("达意还没有辅助功能权限")
        case .hotKey(let code): L10n.format("系统报告的原因：注册失败（%@）。", String(code))
        case .interrupted(let wasWriting):
            wasWriting ? L10n.tr("应用退出时正在写回，无法确认结果。") : L10n.tr("应用退出时任务未完成。")
        case .requestIncomplete: L10n.tr("润色请求未完成。")
        case .applicationFailed: L10n.tr("无法应用结果。")
        }
    }
}
