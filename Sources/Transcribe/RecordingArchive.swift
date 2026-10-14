import Foundation

protocol RecordingArchive: Sendable {
  /// Starts saving the recording; failures are logged rather than reported to the caller.
  func save(_ recording: Recording)
}

struct DirectoryRecordingArchive: RecordingArchive {
  let directory: URL
  private let log: @Sendable (String) -> Void

  init(directory: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
    self.directory = directory
    self.log = log
  }

  func save(_ recording: Recording) {
    Task.detached(priority: .utility) { [self] in
      do {
        let url = try write(recording)
        log("recording saved: \(url.path)")
      } catch {
        log("error: save recording: \(error.localizedDescription)")
      }
    }
  }

  func write(_ recording: Recording, at date: Date = Date()) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let url = directory
      .appendingPathComponent(Self.filename(for: date))
      .appendingPathExtension(recording.format)
    guard
      FileManager.default.createFile(
        atPath: url.path,
        contents: recording.audio,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw RecordingArchiveError.couldNotWrite(url)
    }
    return url
  }

  /// A sortable, Finder-safe name such as `2026-10-14T09-31-02Z-a1b2c3`.
  static func filename(for date: Date) -> String {
    let timestamp = ISO8601DateFormatter().string(from: date)
      .replacingOccurrences(of: ":", with: "-")
    let suffix = UUID().uuidString.prefix(6).lowercased()
    return "\(timestamp)-\(suffix)"
  }
}

private enum RecordingArchiveError: LocalizedError {
  case couldNotWrite(URL)

  var errorDescription: String? {
    switch self {
    case .couldNotWrite(let url):
      return "Could not write \(url.path)"
    }
  }
}
