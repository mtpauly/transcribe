import Foundation

final class AppLogger: @unchecked Sendable {
  private let lock = NSLock()
  private let fileHandle: FileHandle

  init() throws {
    let logDirectory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs", isDirectory: true)
    let logURL = logDirectory.appendingPathComponent("Transcribe.log")

    if !FileManager.default.fileExists(atPath: logURL.path) {
      guard
        FileManager.default.createFile(
          atPath: logURL.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      else {
        throw LoggerError.couldNotCreate(logURL)
      }
    }
    fileHandle = try FileHandle(forWritingTo: logURL)
    try fileHandle.seekToEnd()
  }

  func write(_ message: String) {
    lock.lock()
    defer { lock.unlock() }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "transcribe: \(timestamp) \(message)\n"
    guard let data = line.data(using: .utf8) else {
      return
    }
    try? fileHandle.write(contentsOf: data)
    try? FileHandle.standardError.write(contentsOf: data)
  }

  deinit {
    try? fileHandle.close()
  }
}

private enum LoggerError: LocalizedError {
  case couldNotCreate(URL)

  var errorDescription: String? {
    switch self {
    case .couldNotCreate(let url):
      return "Could not create log file at \(url.path)"
    }
  }
}
