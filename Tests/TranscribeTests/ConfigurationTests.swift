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
