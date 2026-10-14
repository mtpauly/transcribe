import Foundation
import Testing

@testable import Transcribe

@Suite("Configuration")
struct ConfigurationTests {
  @Test("missing model uses the default")
  func defaults() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("config.json")
    try Data(#"{"openrouter_api_key":" test-key "}"#.utf8).write(to: url)

    let configuration = try Configuration.load(from: url)

    #expect(configuration.openRouterAPIKey == "test-key")
    #expect(configuration.model == Configuration.defaultModel)
    #expect(configuration.recordingsDirectory == nil)
  }

  @Test("save_recordings defaults to a recordings folder beside the config")
  func defaultRecordingsDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("config.json")
    try Data(#"{"openrouter_api_key":"key","save_recordings":true}"#.utf8).write(to: url)

    let configuration = try Configuration.load(from: url)

    #expect(
      configuration.recordingsDirectory?.standardizedFileURL.path
        == directory.appendingPathComponent("recordings").standardizedFileURL.path
    )
  }

  @Test("recordings_directory overrides the default and expands ~")
  func customRecordingsDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("config.json")
    try Data(
      #"{"openrouter_api_key":"key","save_recordings":true,"recordings_directory":"~/clips"}"#
        .utf8
    ).write(to: url)

    let configuration = try Configuration.load(from: url)

    #expect(
      configuration.recordingsDirectory?.path
        == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("clips").path
    )
  }

  @Test("loads API key and model from the file")
  func file() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("config.json")
    try Data(
      """
      {
        "openrouter_api_key": "file-key",
        "model": "test-model"
      }
      """.utf8
    ).write(to: url)

    let configuration = try Configuration.load(from: url)

    #expect(configuration.openRouterAPIKey == "file-key")
    #expect(configuration.model == "test-model")
  }

  @Test("API key is required")
  func missingKey() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("missing.json")

    #expect(throws: ConfigurationError.self) {
      try Configuration.load(from: url)
    }
  }
}
