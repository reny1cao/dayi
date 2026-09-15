import Foundation
import Testing
import PolishStore

private func elapsed(_ body: () async throws -> Void) async rethrows -> Double {
    let clock = ContinuousClock()
    let start = clock.now
    try await body()
    return Double((clock.now - start).components.attoseconds) / 1e18
        + Double((clock.now - start).components.seconds)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["POLISH_BENCH"] != nil))
func benchmark() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("bench.sqlite3")
    let storage = try await PolishStorage.open(.file(url))
    let skill = Skill(name: "增强", systemPrompt: "s", userPromptTemplate: "{input}", sourceVersion: "v")
    try await storage.skills.save(skill)

    let draft = String(repeating: "把这段提示词改写得更清楚一些。", count: 40)   // ~600 汉字
    let result = String(repeating: "改写后的提示词，包含更明确的约束与验收条件。", count: 40)
    func make(_ index: Int) -> PolishRecord {
        PolishRecord(skillID: index % 3 == 0 ? skill.id : nil, targetLabel: "Chrome",
                     originalText: draft, resultText: result,
                     outcome: index % 4 == 0 ? .applied : .waiting,
                     createdAt: Date().addingTimeInterval(-Double(index) * 60),
                     updatedAt: Date())
    }

    // One save per state change is the real write pattern: each is its own transaction.
    let singles = try await elapsed {
        for index in 0..<1_000 { try await storage.records.save(make(index)) }
    }
    print("BENCH single-row upserts: 1000 in \(String(format: "%.2f", singles))s → \(Int(1000 / singles))/s")

    // Bulk load to reach a scale the app will not see for years.
    for batch in 0..<10 {
        let records = (0..<10_000).map { make(batch * 10_000 + 1_000 + $0) }
        try await storage.database.write { session in
            for record in records {
                _ = try session.run("""
                    INSERT INTO records (id, skill_id, target_label, original_text, result_text,
                                         outcome, message, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)
                    """, [SQLValue(record.id), SQLValue(record.skillID), .text(record.targetLabel),
                          SQLValue(record.originalText), SQLValue(record.resultText),
                          .text(record.outcome.rawValue), SQLValue(record.createdAt), SQLValue(record.updatedAt)])
            }
        }
    }
    let total = try await storage.database.read { session in
        try session.query("SELECT COUNT(*) AS n FROM records") { try $0.integer("n") }
    }[0]
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0) / 1_048_576
    print("BENCH rows=\(total) file=\(size)MB")

    let recent = try await elapsed { _ = try await storage.records.recent(limit: 200) }
    print("BENCH recent(200) at \(total) rows: \(String(format: "%.1f", recent * 1000))ms")

    let usage = try await elapsed { _ = try await storage.records.usage(since: Date(timeIntervalSince1970: 0)) }
    print("BENCH usage(all) at \(total) rows: \(String(format: "%.1f", usage * 1000))ms")

    let purge = try await elapsed {
        _ = try await storage.records.purge(RetentionPolicy(maxAge: 30 * 86_400, maxCount: 500, textMaxAge: 7 * 86_400), now: Date())
    }
    print("BENCH purge to 500 from \(total) rows: \(String(format: "%.1f", purge * 1000))ms")

    let afterRecent = try await elapsed { _ = try await storage.records.recent(limit: 200) }
    print("BENCH recent(200) after purge: \(String(format: "%.1f", afterRecent * 1000))ms")
}
