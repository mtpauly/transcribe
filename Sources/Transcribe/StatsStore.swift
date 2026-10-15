import Foundation
import SQLite3

/// One finished recording: transcribed, cancelled, or failed. The transcript text
/// itself is never stored.
struct TranscriptionStats: Sendable, Equatable {
  enum Outcome: String, Sendable {
    case success
    case cancelled
    case error
  }

  let startedAt: Date
  let audioMilliseconds: Int
  let audioBytes: Int?
  /// Time from the end of recording until the transcript came back; nil when there was none.
  let latencyMilliseconds: Int?
  let wordCount: Int?
  let characterCount: Int?
  let model: String
  let outcome: Outcome

  static func wordCount(of text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }
}

struct StatsSummary: Sendable, Equatable {
  var transcriptions = 0
  var words = 0
  var audioMilliseconds = 0
}

protocol StatsRecorder: Sendable {
  /// Starts saving the entry; failures are logged rather than reported to the caller.
  func record(_ entry: TranscriptionStats)
}

/// Stores one row per transcription in a local SQLite database.
final class SQLiteStatsStore: StatsRecorder, @unchecked Sendable {
  static let schemaVersion: Int32 = 1

  let url: URL
  private let queue = DispatchQueue(label: "com.mattpauly.transcribe.stats")
  private let log: @Sendable (String) -> Void
  // Only touched on `queue` after init.
  private let db: OpaquePointer

  static func defaultURL(configurationURL: URL) -> URL {
    configurationURL.deletingLastPathComponent().appendingPathComponent("stats.db")
  }

  init(url: URL, log: @escaping @Sendable (String) -> Void = { _ in }) throws {
    self.url = url
    self.log = log
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(
        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    var handle: OpaquePointer?
    let status = sqlite3_open_v2(
      url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    guard status == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
      sqlite3_close(handle)
      throw StatsStoreError.sqlite("open \(url.path): \(message)")
    }
    db = handle
    sqlite3_busy_timeout(db, 1000)
    do {
      try migrate()
    } catch {
      sqlite3_close(db)
      throw error
    }
  }

  deinit {
    sqlite3_close(db)
  }

  func record(_ entry: TranscriptionStats) {
    queue.async { [self] in
      do {
        try insert(entry)
      } catch {
        log("error: record stats: \(error.localizedDescription)")
      }
    }
  }

  /// Totals for successful transcriptions started at or after `since` (all time when nil).
  func summary(since: Date? = nil) throws -> StatsSummary {
    try queue.sync {
      let statement = try prepare(
        """
        SELECT COUNT(*), COALESCE(SUM(word_count), 0), COALESCE(SUM(audio_ms), 0)
        FROM transcriptions
        WHERE outcome = 'success' AND started_at >= ?
        """)
      defer { sqlite3_finalize(statement) }
      bind(since.map(Self.timestamp) ?? "", at: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw error("summarize")
      }
      return StatsSummary(
        transcriptions: Int(sqlite3_column_int64(statement, 0)),
        words: Int(sqlite3_column_int64(statement, 1)),
        audioMilliseconds: Int(sqlite3_column_int64(statement, 2))
      )
    }
  }

  /// Waits for pending writes; for tests.
  func flush() {
    queue.sync {}
  }

  private func migrate() throws {
    let statement = try prepare("PRAGMA user_version")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw error("read schema version")
    }
    if sqlite3_column_int(statement, 0) >= Self.schemaVersion {
      return
    }
    try execute(
      """
      BEGIN;
      CREATE TABLE transcriptions (
        id INTEGER PRIMARY KEY,
        started_at TEXT NOT NULL,
        audio_ms INTEGER NOT NULL,
        audio_bytes INTEGER,
        latency_ms INTEGER,
        word_count INTEGER,
        char_count INTEGER,
        model TEXT NOT NULL,
        outcome TEXT NOT NULL
      );
      CREATE INDEX transcriptions_started_at ON transcriptions (started_at);
      PRAGMA user_version = \(Self.schemaVersion);
      COMMIT;
      """)
  }

  private func insert(_ entry: TranscriptionStats) throws {
    let statement = try prepare(
      """
      INSERT INTO transcriptions
        (started_at, audio_ms, audio_bytes, latency_ms, word_count, char_count, model, outcome)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """)
    defer { sqlite3_finalize(statement) }
    bind(Self.timestamp(entry.startedAt), at: 1, in: statement)
    bind(entry.audioMilliseconds, at: 2, in: statement)
    bind(entry.audioBytes, at: 3, in: statement)
    bind(entry.latencyMilliseconds, at: 4, in: statement)
    bind(entry.wordCount, at: 5, in: statement)
    bind(entry.characterCount, at: 6, in: statement)
    bind(entry.model, at: 7, in: statement)
    bind(entry.outcome.rawValue, at: 8, in: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw error("insert")
    }
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      let failure = error("execute")
      sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
      throw failure
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw error("prepare")
    }
    return statement
  }

  private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
  }

  private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer) {
    if let value {
      sqlite3_bind_int64(statement, index, Int64(value))
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func error(_ operation: String) -> StatsStoreError {
    .sqlite("\(operation): \(String(cString: sqlite3_errmsg(db)))")
  }

  /// UTC ISO 8601 with milliseconds, e.g. `2026-10-14T09:31:02.123Z`; sorts chronologically
  /// as text and is understood by SQLite's date functions.
  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

// SQLITE_TRANSIENT isn't imported into Swift: tells SQLite to copy bound strings.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum StatsStoreError: LocalizedError {
  case sqlite(String)

  var errorDescription: String? {
    switch self {
    case .sqlite(let message):
      return "SQLite \(message)"
    }
  }
}
