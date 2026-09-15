import Foundation
import PolishCore
import PolishStore
import Testing

@Test func failureMetadataSurvivesMigrationAndFileReopen() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let location = Database.Location.file(root.appendingPathComponent("failure.sqlite3"))
    let old = try Database(location)
    try await Migrator.migrate(old, using: PolishSchema.migrations.filter { $0.version <= 2 })
    let oldID = UUID()
    _ = try await old.write { session in
        try session.run("INSERT INTO records (id,target_label,outcome,message,created_at,updated_at) VALUES (?,?,'failed',?,0,0)",
                        [SQLValue(oldID), .text("Notes"), .text("旧版本原始错误")])
    }
    let migrated = try await PolishStorage.open(location)
    let oldRecord = try #require(try await migrated.records.record(oldID))
    #expect(oldRecord.message == "旧版本原始错误")
    #expect(oldRecord.failure == nil)
    let record = PolishRecord(targetLabel: "Notes", outcome: .failed, message: "发生时的文字",
                              failure: .polish(.httpStatus(429)))
    try await migrated.records.save(record)
    let reopened = try await PolishStorage.open(location)
    var restored = try #require(try await reopened.records.record(record.id))
    #expect(restored.failure == .polish(.httpStatus(429)))
    #expect(restored.message == "发生时的文字")
    #expect(restored.failure?.message == PolishError.httpStatus(429).localizedDescription)
    restored.failure = nil
    restored.message = nil
    restored.outcome = .applied
    try await reopened.records.save(restored)
    #expect(try await reopened.records.record(record.id)?.failure == nil)
}

@Test func failureEncodingStoresCodesAndArgumentsRatherThanTranslatedText() throws {
    let data = try JSONEncoder().encode(RecordedFailure.polish(.httpStatus(429)))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("httpStatus"))
    #expect(text.contains("429"))
    #expect(!text.contains("请求"))
    #expect(try JSONDecoder().decode(RecordedFailure.self, from: data) == .polish(.httpStatus(429)))
}
