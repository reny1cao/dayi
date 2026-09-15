import Foundation
import Testing
import PolishStore

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    return url
}

/// Whole seconds survive the millisecond column exactly, which keeps record equality usable.
func fixedDate(_ offset: TimeInterval = 0) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset.rounded())
}

private func openScratch() async throws -> Database {
    let database = try Database(.memory)
    try await database.write { session in
        try session.execute("CREATE TABLE items (id TEXT PRIMARY KEY NOT NULL, value TEXT, number INTEGER) STRICT")
    }
    return database
}

@Test func everyStorageClassRoundTripsThroughItsColumn() async throws {
    let database = try Database(.memory)
    try await database.write { session in
        try session.execute("CREATE TABLE probe (t TEXT, i INTEGER, d REAL, b BLOB, n TEXT)")
        _ = try session.run("INSERT INTO probe VALUES (?, ?, ?, ?, ?)",
                            [.text("值"), .integer(-42), .double(0.5), .blob(Data([0, 255, 7])), .null])
    }
    let row = try await database.read { session in
        try session.query("SELECT *, length(b) AS blob_length, d + d AS doubled FROM probe") { row in
            (try row.text("t"), try row.integer("i"), try row.optionalText("n"),
             try row.isNull("n"), try row.integer("blob_length"))
        }
    }[0]
    #expect(row.0 == "值")
    #expect(row.1 == -42)
    #expect(row.2 == nil)
    #expect(row.3)
    #expect(row.4 == 3)
}

@Test func aSubSecondBusyTimeoutIsNotRoundedAwayToZero() async throws {
    let database = try Database(.memory, busyTimeout: .milliseconds(250))
    let timeout = try await database.read { session in
        try session.query("PRAGMA busy_timeout") { try $0.integer("timeout") }
    }[0]
    #expect(timeout == 250)
}

@Test func datesAndIdentifiersSurviveTheirEncodings() async throws {
    let database = try await openScratch()
    let id = UUID()
    let moment = fixedDate()
    try await database.write { session in
        _ = try session.run("INSERT INTO items (id, value, number) VALUES (?, ?, ?)",
                            [SQLValue(id), .text("x"), SQLValue(moment)])
    }
    let read = try await database.read { session in
        try session.query("SELECT id, number FROM items") { row in
            (try row.uuid("id"), try row.date("number"))
        }
    }[0]
    #expect(read.0 == id)
    #expect(read.1 == moment)
}

/// Dates are stored as whole milliseconds. A caller that needs finer resolution has to know
/// that, so the rounding is asserted rather than left to be discovered.
@Test func dateStorageRoundsToMilliseconds() async throws {
    let database = try await openScratch()
    let precise = Date(timeIntervalSince1970: 1_700_000_000.123_456)
    try await database.write { session in
        _ = try session.run("INSERT INTO items (id, number) VALUES (?, ?)", [SQLValue(UUID()), SQLValue(precise)])
    }
    let stored = try await database.read { session in
        try session.query("SELECT number FROM items") { try $0.date("number") }
    }[0]
    #expect(abs(stored.timeIntervalSince(precise)) < 0.001)
    #expect(stored != precise)
}

/// The project measures ranges in UTF-16 code units and refuses canonical equality as proof.
/// Storage has to hold that line: two canonically equivalent strings must not become one.
@Test func textIsStoredByCodeUnitAndNeverNormalised() async throws {
    let database = try await openScratch()
    let composed = "é🙂"
    let decomposed = "e\u{0301}🙂"
    #expect(composed == decomposed)
    #expect(!composed.utf16.elementsEqual(decomposed.utf16))
    try await database.write { session in
        _ = try session.run("INSERT INTO items (id, value) VALUES (?, ?)", [.text("a"), .text(composed)])
        _ = try session.run("INSERT INTO items (id, value) VALUES (?, ?)", [.text("b"), .text(decomposed)])
    }
    let values = try await database.read { session in
        try session.query("SELECT value FROM items ORDER BY id") { try $0.text("value") }
    }
    #expect(values[0].utf16.elementsEqual(composed.utf16))
    #expect(values[1].utf16.elementsEqual(decomposed.utf16))
    #expect(!values[0].utf16.elementsEqual(values[1].utf16))
}

@Test func aThrowInsideAWriteRollsBackEveryStatement() async throws {
    let database = try await openScratch()
    struct Abort: Error {}
    await #expect(throws: Abort.self) {
        try await database.write { session in
            _ = try session.run("INSERT INTO items (id) VALUES (?)", [.text("kept?")])
            throw Abort()
        }
    }
    let count = try await database.read { session in
        try session.query("SELECT COUNT(*) AS n FROM items") { try $0.integer("n") }
    }[0]
    #expect(count == 0)
}

@Test func aSavepointRollsBackOnlyItsOwnStatements() async throws {
    let database = try await openScratch()
    struct Abort: Error {}
    try await database.write { session in
        _ = try session.run("INSERT INTO items (id) VALUES (?)", [.text("outer")])
        try? session.savepoint {
            _ = try session.run("INSERT INTO items (id) VALUES (?)", [.text("inner")])
            throw Abort()
        }
        _ = try session.run("INSERT INTO items (id) VALUES (?)", [.text("after")])
    }
    let ids = try await database.read { session in
        try session.query("SELECT id FROM items ORDER BY id") { try $0.text("id") }
    }
    #expect(ids == ["after", "outer"])
}

@Test func aRolledBackTransactionLeavesTheConnectionUsable() async throws {
    let database = try await openScratch()
    struct Abort: Error {}
    _ = try? await database.write { session -> Int in throw Abort() }
    try await database.write { session in
        _ = try session.run("INSERT INTO items (id) VALUES (?)", [.text("later")])
    }
    let ids = try await database.read { session in
        try session.query("SELECT id FROM items") { try $0.text("id") }
    }
    #expect(ids == ["later"])
}

@Test func aDuplicateKeyIsReportedAsAConstraintFailure() async throws {
    let database = try await openScratch()
    try await database.write { session in
        _ = try session.run("INSERT INTO items (id) VALUES (?)", [.text("one")])
    }
    await #expect(throws: PersistenceError.self) {
        try await database.write { session in
            _ = try session.run("INSERT INTO items (id) VALUES (?)", [.text("one")])
        }
    }
    do {
        try await database.write { session in
            _ = try session.run("INSERT INTO items (id) VALUES (?)", [.text("one")])
        }
    } catch let error as PersistenceError {
        guard case .constraint = error else { Issue.record("expected a constraint failure, got \(error)"); return }
    }
}

@Test func askingForAnAbsentColumnFailsWithItsName() async throws {
    let database = try await openScratch()
    try await database.write { session in
        _ = try session.run("INSERT INTO items (id) VALUES (?)", [.text("one")])
    }
    await #expect(throws: PersistenceError.decoding("missing")) {
        try await database.read { session in
            try session.query("SELECT id FROM items") { try $0.text("missing") }
        }
    }
}

@Test func malformedSQLFailsBeforeAnythingIsWritten() async throws {
    let database = try await openScratch()
    await #expect(throws: PersistenceError.self) {
        try await database.write { session in
            _ = try session.run("INSERT INTO items (nope) VALUES (?)", [.text("x")])
        }
    }
    let count = try await database.read { session in
        try session.query("SELECT COUNT(*) AS n FROM items") { try $0.integer("n") }
    }[0]
    #expect(count == 0)
}

@Test func theFileAndItsDirectoryAreReadableOnlyByTheirOwner() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("store").appendingPathComponent("dayi.sqlite3")
    let database = try Database(.file(url))
    try await database.write { session in try session.execute("CREATE TABLE t (a TEXT)") }
    let directory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
    #expect(directory[.posixPermissions] as? Int == 0o700)
    // The -wal sibling holds transactions that have not been checkpointed yet, so it carries
    // the same mode as the database itself.
    for suffix in ["", "-wal", "-shm"] {
        let sibling = url.path + suffix
        guard FileManager.default.fileExists(atPath: sibling) else {
            Issue.record("expected \(sibling) to exist")
            continue
        }
        #expect(try FileManager.default.attributesOfItem(atPath: sibling)[.posixPermissions] as? Int == 0o600)
    }
}

@Test func aSymlinkedDatabasePathIsRefused() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real.sqlite3")
    FileManager.default.createFile(atPath: real.path, contents: nil)
    let link = root.appendingPathComponent("link.sqlite3")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(throws: PersistenceError.self) { _ = try Database(.file(link)) }
}

@Test func aDirectoryThatCannotBeCreatedIsReportedAsCannotOpen() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.chmod(root, 0o700); try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    let url = root.appendingPathComponent("blocked").appendingPathComponent("dayi.sqlite3")
    #expect(throws: PersistenceError.self) { _ = try Database(.file(url)) }
}

@Test func aFileThatIsNotADatabaseIsReportedAsCorrupt() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("garbage.sqlite3")
    try Data("this is not a database".utf8).write(to: url)
    // Opening runs the connection pragmas, so a file that is not a database fails here
    // rather than at the first query a caller happens to make.
    #expect(throws: PersistenceError.self) { _ = try Database(.file(url)) }
    do {
        _ = try Database(.file(url))
    } catch let error as PersistenceError {
        guard case .corrupt = error else { Issue.record("expected corruption, got \(error)"); return }
    }
}

@Test func concurrentWritersThroughOneConnectionAllLand() async throws {
    let database = try await openScratch()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<40 {
            group.addTask {
                try? await database.write { session in
                    _ = try session.run("INSERT INTO items (id, number) VALUES (?, ?)",
                                        [.text("\(index)"), .integer(Int64(index))])
                }
            }
        }
    }
    let sum = try await database.read { session in
        try session.query("SELECT COUNT(*) AS n, SUM(number) AS total FROM items") {
            (try $0.integer("n"), try $0.integer("total"))
        }
    }[0]
    #expect(sum.0 == 40)
    #expect(sum.1 == 780)
}

@Test func aSecondConnectionSeesWhatTheFirstCommitted() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("shared.sqlite3")
    let writer = try Database(.file(url))
    try await writer.write { session in
        try session.execute("CREATE TABLE t (a TEXT) STRICT")
        _ = try session.run("INSERT INTO t VALUES (?)", [.text("committed")])
    }
    let reader = try Database(.file(url))
    let values = try await reader.read { session in
        try session.query("SELECT a FROM t") { try $0.text("a") }
    }
    #expect(values == ["committed"])
}

@Test func theApplicationLocationSitsUnderApplicationSupport() throws {
    guard case .file(let url) = try Database.applicationSupportLocation() else {
        Issue.record("expected a file location")
        return
    }
    #expect(url.lastPathComponent == "dayi.sqlite3")
    #expect(url.deletingLastPathComponent().lastPathComponent == "dev.local.dayi")
    #expect(url.path.contains("Application Support"))

    // Naming a location must not create anything; opening is what creates the file. The
    // default path may already hold this machine's real database, so the check uses an
    // identifier nothing can have written to.
    let unused = try Database.applicationSupportLocation(bundleIdentifier: "dev.local.dayi.test-\(UUID().uuidString)")
    guard case .file(let untouched) = unused else {
        Issue.record("expected a file location")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: untouched.deletingLastPathComponent().path))
}

private extension FileManager {
    func chmod(_ url: URL, _ mode: Int) throws {
        try setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
