import PolishCore
import Foundation
import GRDB

/// Storage is an external consistency boundary: the file lives outside the process and
/// outlives it. Every database failure is translated here once, so callers match on a domain
/// case instead of on a result code whose meaning depends on the call that produced it.
public enum PersistenceError: Error, Equatable, Sendable, LocalizedError {
    /// The database file could not be opened: a missing directory, a symlink, or no permission.
    /// Carries whichever of the path or the underlying reason the failure knew about.
    case cannotOpen(String)
    /// A uniqueness, foreign key, or NOT NULL rule rejected the write. The data is unchanged.
    case constraint(String)
    /// Another connection held the write lock past the busy timeout. Retrying is the caller's choice.
    case busy
    /// The file is not a usable database, or its pages failed an integrity check.
    case corrupt(String)
    /// The underlying file system refused a read or write.
    case io(String)
    /// The file carries a newer schema than this build understands; an older build must not write to it.
    case schemaTooNew(found: Int32, supported: Int32)
    /// A migration failed. The transaction around it was rolled back, so the schema is unchanged.
    case migrationFailed(version: Int32, reason: String)
    /// A stored row could not be turned back into its entity, naming the column at fault.
    case decoding(String)
    /// Anything the database reports that has no distinct recovery path.
    case sqlite(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let detail): L10n.format("无法打开数据库文件：%@", String(describing: detail))
        case .constraint(let message): L10n.format("写入违反数据约束：%@", String(describing: message))
        case .busy: L10n.tr("数据库正被其他连接写入，本次操作未执行。")
        case .corrupt(let message): L10n.format("数据库文件已损坏：%@", String(describing: message))
        case .io(let message): L10n.format("数据库读写失败：%@", String(describing: message))
        case .schemaTooNew(let found, let supported):
            L10n.format("数据库结构版本为 %@，高于本版本支持的 %@；请升级应用后再打开。", String(describing: found), String(describing: supported))
        case .migrationFailed(let version, let reason): L10n.format("结构迁移到版本 %@ 失败：%@", String(describing: version), String(describing: reason))
        case .decoding(let column): L10n.format("读取到无法解析的字段：%@。", String(describing: column))
        case .sqlite(let code, let message): L10n.format("数据库错误 %@：%@", String(describing: code), String(describing: message))
        }
    }

    /// Translates a database failure and passes everything else through untouched. A closure
    /// running inside a transaction may throw for its own reasons, and those errors belong to
    /// the caller, not to this layer.
    static func from(_ error: any Error) -> any Error {
        guard let error = error as? DatabaseError else { return error }
        // Only the primary code decides the recovery path; the extended text goes to the user.
        let message = error.message ?? error.description
        switch error.resultCode.primaryResultCode {
        case .SQLITE_CONSTRAINT: return constraint(message)
        case .SQLITE_BUSY, .SQLITE_LOCKED: return busy
        case .SQLITE_CORRUPT, .SQLITE_NOTADB: return corrupt(message)
        case .SQLITE_IOERR, .SQLITE_FULL, .SQLITE_READONLY, .SQLITE_PERM, .SQLITE_AUTH: return io(message)
        case .SQLITE_CANTOPEN: return cannotOpen(message)
        default: return sqlite(code: error.resultCode.rawValue, message: message)
        }
    }
}
