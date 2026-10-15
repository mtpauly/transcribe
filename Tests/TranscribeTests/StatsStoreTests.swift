import Foundation
import SQLite3
import Testing

@testable import Transcribe

@Suite("Stats store")
struct StatsStoreTests {
  private static func entry(
    at startedAt: Date, words: Int?, outcome: TranscriptionStats.Outcome = .success
  ) -> TranscriptionStats {
    TranscriptionStats(
      startedAt: startedAt,
      audioMilliseconds: 30_000,
      audioBytes: 1024,
      latencyMilliseconds: words == nil ? nil : 800,
      wordCount: words,
      characterCount: words.map { $0 * 5 },
      model: "test-model",
      outcome: outcome
    )
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("stats.db")
  }

  @Test("summarizes successful transcriptions, optionally since a date")
  func summary() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SQLiteStatsStore(url: url)
    let yesterday = Date(timeIntervalSince1970: 1_760_400_000)
    let today = yesterday.addingTimeInterval(86_400)

    store.record(Self.entry(at: yesterday, words: 10))
    store.record(Self.entry(at: today, words: 5))
    store.record(Self.entry(at: today, words: nil, outcome: .cancelled))
    store.record(Self.entry(at: today, words: nil, outcome: .error))
    store.flush()

    #expect(
      try store.summary() == StatsSummary(transcriptions: 2, words: 15, audioMilliseconds: 60_000))
    #expect(
      try store.summary(since: today)
        == StatsSummary(transcriptions: 1, words: 5, audioMilliseconds: 30_000))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }

  @Test("keeps rows across reopening and stores every column")
  func persistence() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    do {
      let store = try SQLiteStatsStore(url: url)
      store.record(Self.entry(at: Date(timeIntervalSince1970: 1_760_434_262.5), words: 3))
      store.flush()
    }

    let reopened = try SQLiteStatsStore(url: url)
    #expect(try reopened.summary().transcriptions == 1)

    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    sqlite3_prepare_v2(
      db,
      "SELECT started_at, audio_ms, audio_bytes, latency_ms, word_count, char_count, model, outcome FROM transcriptions",
      -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(String(cString: sqlite3_column_text(statement, 0)) == "2025-10-14T09:31:02.500Z")
    #expect(sqlite3_column_type(statement, 1) == SQLITE_INTEGER)
    #expect(sqlite3_column_int(statement, 1) == 30_000)
    #expect(sqlite3_column_int(statement, 2) == 1024)
    #expect(sqlite3_column_int(statement, 3) == 800)
    #expect(sqlite3_column_int(statement, 4) == 3)
    #expect(sqlite3_column_int(statement, 5) == 15)
    #expect(String(cString: sqlite3_column_text(statement, 6)) == "test-model")
    #expect(String(cString: sqlite3_column_text(statement, 7)) == "success")
  }

  @Test("counts words separated by any whitespace")
  func wordCount() {
    #expect(TranscriptionStats.wordCount(of: "") == 0)
    #expect(TranscriptionStats.wordCount(of: "  hello,  world\nagain\t ") == 3)
  }
}
