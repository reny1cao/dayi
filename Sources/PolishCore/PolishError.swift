import Foundation

public enum PolishError: Error, Codable, Equatable, Sendable, LocalizedError {
    case emptyInput
    case invalidConfiguration(String)
    case invalidResponse
    case httpStatus(Int)
    case emptyResult
    case incompleteResult

    public var errorDescription: String? {
        switch self {
        case .emptyInput: L10n.tr("输入不能为空。")
        case .invalidConfiguration(let field): L10n.format("配置无效：%@。", L10n.tr(field))
        case .invalidResponse: L10n.tr("模型返回了无法识别的响应。")
        case .httpStatus(let status): L10n.format("模型请求失败（HTTP %@）。", String(describing: status))
        case .emptyResult: L10n.tr("模型没有返回可用文本。")
        case .incompleteResult: L10n.tr("模型输出未正常完成；未采用不完整结果。")
        }
    }
}
