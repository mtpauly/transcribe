import Foundation

protocol Transcriber: Sendable {
  func transcribe(_ recording: Recording) async throws -> String
}

struct OpenRouterClient: Transcriber {
  typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  typealias Sleep = @Sendable (Duration) async throws -> Void

  private static let endpoint = URL(
    string: "https://openrouter.ai/api/v1/audio/transcriptions"
  )!
  static let maxRateLimitRetries = 2
  static let defaultRetryDelay: Duration = .seconds(1)
  // Cap server-requested waits so a large Retry-After doesn't stall the paste.
  static let maxRetryDelay: Duration = .seconds(5)

  private let apiKey: String
  private let model: String
  private let send: Send
  private let sleep: Sleep
  private let log: @Sendable (String) -> Void

  init(
    apiKey: String,
    model: String,
    send: @escaping Send = { try await URLSession.shared.data(for: $0) },
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.apiKey = apiKey
    self.model = model
    self.send = send
    self.sleep = sleep
    self.log = log
  }

  func transcribe(_ recording: Recording) async throws -> String {
    let request = try makeRequest(audio: recording.audio, format: recording.format)
    log("transcription request sent (model \(model))")
    var (data, response) = try await sendHTTP(request)
    var retries = 0
    while response.statusCode == 429 && retries < Self.maxRateLimitRetries {
      retries += 1
      let delay = Self.retryDelay(response: response, body: data)
      log("rate limited (HTTP 429); retry \(retries)/\(Self.maxRateLimitRetries) in \(delay)")
      try await sleep(delay)
      (data, response) = try await sendHTTP(request)
    }
    guard (200..<300).contains(response.statusCode) else {
      let detail = String(decoding: data.prefix(8 * 1024), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw OpenRouterError.requestFailed(status: response.statusCode, detail: detail)
    }

    let decoded: TranscriptionResponse
    do {
      decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    } catch {
      throw OpenRouterError.invalidResponse(error)
    }

    let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw OpenRouterError.emptyTranscription
    }
    return text
  }

  private func sendHTTP(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await send(request)
    guard let response = response as? HTTPURLResponse else {
      throw OpenRouterError.nonHTTPResponse
    }
    return (data, response)
  }

  /// Uses the Retry-After header, then OpenRouter's `error.metadata.retry_after_seconds`
  /// (which carries the upstream provider's value), then a short default.
  static func retryDelay(response: HTTPURLResponse, body: Data) -> Duration {
    let headerSeconds = response.value(forHTTPHeaderField: "Retry-After")
      .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    let bodySeconds = (try? JSONDecoder().decode(RateLimitResponse.self, from: body))?
      .error.metadata?.retryAfterSeconds
    guard let seconds = headerSeconds ?? bodySeconds, seconds >= 0 else {
      return defaultRetryDelay
    }
    return min(.milliseconds(Int(seconds * 1000)), maxRetryDelay)
  }

  func makeRequest(audio: Data, format: String) throws -> URLRequest {
    let payload = TranscriptionRequest(
      model: model,
      inputAudio: InputAudio(
        data: audio.base64EncodedString(),
        format: format
      )
    )

    var request = URLRequest(url: Self.endpoint, timeoutInterval: 90)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)
    return request
  }
}

enum OpenRouterError: LocalizedError {
  case nonHTTPResponse
  case requestFailed(status: Int, detail: String)
  case invalidResponse(any Error)
  case emptyTranscription

  var errorDescription: String? {
    switch self {
    case .nonHTTPResponse:
      return "OpenRouter returned a non-HTTP response"
    case .requestFailed(let status, let detail):
      let suffix = detail.isEmpty ? "" : ": \(detail)"
      return "Transcription request failed (HTTP \(status))\(suffix)"
    case .invalidResponse(let error):
      return "Could not decode transcription response: \(error.localizedDescription)"
    case .emptyTranscription:
      return "Transcription response contained no text"
    }
  }
}

private struct TranscriptionRequest: Encodable {
  let model: String
  let inputAudio: InputAudio

  enum CodingKeys: String, CodingKey {
    case model
    case inputAudio = "input_audio"
  }
}

private struct InputAudio: Encodable {
  let data: String
  let format: String
}

private struct TranscriptionResponse: Decodable {
  let text: String
}

private struct RateLimitResponse: Decodable {
  struct ErrorBody: Decodable {
    let metadata: Metadata?
  }

  struct Metadata: Decodable {
    let retryAfterSeconds: Double?

    enum CodingKeys: String, CodingKey {
      case retryAfterSeconds = "retry_after_seconds"
    }
  }

  let error: ErrorBody
}
