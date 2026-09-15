import Foundation
import GRDB

/// A synchronous view of the connection, handed to the body of one transaction. It cannot
/// outlive the actor-free transaction call that created it, which is what makes "every
/// statement runs inside its transaction" structural rather than a convention.
public typealias Session = GRDB.Database

/// One row of a result set. The typed accessors below are the reason this is not used raw:
/// a column that is missing or unreadable has to fail with its own name, so a schema change
/// surfaces as a named decoding failure rather than a silently shifted value.
public typealias Row = GRDB.Row

/// The five storage classes SQLite has. Entities convert to and from these explicitly.
///
/// This vocabulary is kept rather than handing GRDB native Swift values because it pins the
/// on-disk encodings the project depends on: whole-millisecond integers for dates and
/// lowercase-free UUID strings. GRDB's own `Date` conversion would write ISO-8601 text.
public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    public init(_ value: UUID?) { self = value.map { .text($0.uuidString) } ?? .null }
    /// Whole milliseconds keep ordering exact and survive a round trip, which a float does not.
    public init(_ value: Date?) { self = value.map { .integer(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? .null }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: .null
        case .integer(let number): number.databaseValue
        case .double(let number): number.databaseValue
        case .text(let string): string.databaseValue
        case .blob(let data): data.databaseValue
        }
    }
}

extension Row {
    private func stored(_ name: String) throws -> DatabaseValue {
        guard hasColumn(name) else { throw PersistenceError.decoding(name) }
        return self[name]
    }

    public func isNull(_ name: String) throws -> Bool { try stored(name).isNull }

    public func text(_ name: String) throws -> String {
        guard let value = try optionalText(name) else { throw PersistenceError.decoding(name) }
        return value
    }

    /// SQLite stores TEXT as UTF-8 and never normalises it, so UTF-16 offsets held elsewhere
    /// in the project stay valid across a round trip.
    public func optionalText(_ name: String) throws -> String? {
        String.fromDatabaseValue(try stored(name))
    }

    public func integer(_ name: String) throws -> Int64 {
        guard let value = try optionalInteger(name) else { throw PersistenceError.decoding(name) }
        return value
    }

    public func optionalInteger(_ name: String) throws -> Int64? {
        Int64.fromDatabaseValue(try stored(name))
    }

    public func bool(_ name: String) throws -> Bool { try integer(name) != 0 }

    public func date(_ name: String) throws -> Date {
        Date(timeIntervalSince1970: Double(try integer(name)) / 1000)
    }

    public func optionalDate(_ name: String) throws -> Date? {
        try optionalInteger(name).map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    public func uuid(_ name: String) throws -> UUID {
        guard let value = UUID(uuidString: try text(name)) else { throw PersistenceError.decoding(name) }
        return value
    }

    public func optionalUUID(_ name: String) throws -> UUID? {
        guard let raw = try optionalText(name) else { return nil }
        guard let value = UUID(uuidString: raw) else { throw PersistenceError.decoding(name) }
        return value
    }
}

extension Session {
    /// Runs one or more statements with no bindings and no results. Used for schema work.
    public func execute(_ sql: String) throws { try execute(sql: sql) }

    /// Runs one statement and returns the number of rows it changed.
    @discardableResult
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        try execute(sql: sql, arguments: StatementArguments(bindings.map(\.databaseValue)))
        return changesCount
    }

    public func query<T>(_ sql: String, _ bindings: [SQLValue] = [], row transform: (Row) throws -> T) throws -> [T] {
        try Row.fetchAll(self, sql: sql, arguments: StatementArguments(bindings.map(\.databaseValue)))
            .map(transform)
    }

    /// A nested unit of work. A throw rolls back only the statements inside it, which lets a
    /// batch reject one bad element without discarding the whole transaction.
    public func savepoint<T>(_ body: () throws -> T) throws -> T {
        var produced: T?
        try inSavepoint {
            produced = try body()
            return .commit
        }
        // inSavepoint returns normally only after the body completed, so this is always set.
        return produced!
    }
}

/// One database. GRDB owns the connections, statements, transactions and their result codes;
/// what stays here is the part specific to this project: where the file lives, that it must
/// not be a symlink, who may read it, and how failures are named.
public final class Database: Sendable {
    public enum Location: Sendable, Equatable {
        /// A private database that disappears with the process. Used by tests and by the
        /// "keep nothing on disk" mode.
        case memory
        case file(URL)
    }

    public let location: Location
    private let writer: any DatabaseWriter

    public init(_ location: Location, busyTimeout: Duration = .seconds(5)) throws {
        self.location = location
        writer = try Self.makeWriter(location, busyTimeout: busyTimeout)
    }

    /// A write transaction. GRDB 7 takes the write lock up front, so a busy database fails
    /// here instead of at COMMIT with the caller's work already done.
    public func write<T: Sendable>(_ body: @Sendable (Session) throws -> T) async throws -> T {
        do { return try await writer.write(body) } catch { throw PersistenceError.from(error) }
    }

    /// A read transaction. The snapshot keeps several queries consistent with each other.
    public func read<T: Sendable>(_ body: @Sendable (Session) throws -> T) async throws -> T {
        do { return try await writer.read(body) } catch { throw PersistenceError.from(error) }
    }

    public func userVersion() async throws -> Int32 {
        try await read { session in
            try session.query("PRAGMA user_version") { row in Int32(try row.integer("user_version")) }.first ?? 0
        }
    }

    private static func makeWriter(_ location: Location, busyTimeout: Duration) throws -> any DatabaseWriter {
        var configuration = Configuration()
        let components = busyTimeout.components
        configuration.busyMode = .timeout(Double(components.seconds) + Double(components.attoseconds) / 1e18)
        configuration.prepareDatabase { database in
            // NORMAL under WAL: an application crash loses no committed transaction, a power
            // cut may lose the last few. For polish history that is the right trade; the
            // drafts themselves still live in the target application.
            try database.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        do {
            switch location {
            case .memory:
                return try DatabaseQueue(configuration: configuration)
            case .file(let url):
                try rejectSymlink(at: url)
                try prepareDirectory(for: url)
                restrict(url)
                // A pool keeps WAL readers running while a writer holds the lock, so a
                // background purge cannot block the window that lists records.
                let pool = try DatabasePool(path: url.path, configuration: configuration)
                // The siblings hold recent transactions, so they carry the same mode. They are
                // restricted again after opening because a database that already existed at a
                // wider mode created them before this process could say otherwise.
                for suffix in ["", "-wal", "-shm"] {
                    restrict(URL(fileURLWithPath: url.path + suffix))
                }
                return pool
            }
        } catch {
            throw PersistenceError.from(error)
        }
    }

    /// SQLite copies the database file's mode onto the -wal and -shm siblings when it creates
    /// them, so an empty file has to exist at 0600 before the pool opens it. A file system with
    /// no POSIX modes makes this a no-op, which is why the 0700 directory is the guarantee that
    /// counts. A zero-length file is a valid empty database.
    private static func restrict(_ url: URL) {
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: permissions)
            return
        }
        try? FileManager.default.setAttributes(permissions, ofItemAtPath: url.path)
    }

    /// A symlinked database file could redirect writes outside the intended storage path.
    /// `attributesOfItem` does not follow the link, so it sees the link itself.
    private static func rejectSymlink(at url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PersistenceError.cannotOpen(url.path)
        }
    }

    /// The directory holds the database plus its WAL siblings; 0700 keeps them private.
    private static func prepareDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw PersistenceError.cannotOpen(directory.path) }
    }

    /// Where the app keeps its database. Application Support, not a temporary directory:
    /// this data is meant to survive a restart.
    public static func applicationSupportLocation(
        bundleIdentifier: String = "dev.local.dayi", fileName: String = "dayi.sqlite3"
    ) throws -> Location {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PersistenceError.cannotOpen("Application Support")
        }
        return .file(base.appendingPathComponent(bundleIdentifier, isDirectory: true).appendingPathComponent(fileName))
    }
}
