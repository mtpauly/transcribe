import Foundation

struct Configuration: Sendable, Equatable {
  static let defaultModel = "microsoft/mai-transcribe-2"

  let openRouterAPIKey: String
  let model: String

  static func defaultURL(fileManager: FileManager = .default) throws -> URL {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    )
    return
      applicationSupport
      .appendingPathComponent("Transcribe", isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
  }

  static func load(from url: URL) throws -> Configuration {
    var fileConfiguration = FileConfiguration()

    if FileManager.default.fileExists(atPath: url.path) {
      do {
        let data = try Data(contentsOf: url)
        fileConfiguration = try JSONDecoder().decode(FileConfiguration.self, from: data)
      } catch {
        throw ConfigurationError.couldNotRead(url, underlying: error)
      }
    }

    guard let apiKey = nonempty(fileConfiguration.openRouterAPIKey) else {
      throw ConfigurationError.missingAPIKey(url)
    }

    return Configuration(
      openRouterAPIKey: apiKey,
      model: nonempty(fileConfiguration.model) ?? defaultModel
    )
  }
}

enum ConfigurationError: LocalizedError {
  case couldNotRead(URL, underlying: any Error)
  case missingAPIKey(URL)

  var errorDescription: String? {
    switch self {
    case .couldNotRead(let url, let error):
      return "Could not read \(url.path): \(error.localizedDescription)"
    case .missingAPIKey(let url):
      return "OpenRouter API key is missing; add it to \(url.path)"
    }
  }
}

private struct FileConfiguration: Decodable {
  var openRouterAPIKey: String?
  var model: String?

  enum CodingKeys: String, CodingKey {
    case openRouterAPIKey = "openrouter_api_key"
    case model
  }
}

private func nonempty(_ value: String?) -> String? {
  guard
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
    !value.isEmpty
  else {
    return nil
  }
  return value
}
