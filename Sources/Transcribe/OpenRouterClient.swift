import Foundation

protocol Transcriber: Sendable {
  func transcribe(_ recording: Recording) async throws -> String
}

struct OpenRouterClient: Transcriber {
  private static let endpoint = URL(
    string: "https://openrouter.ai/api/v1/audio/transcriptions"
  )!

  private let apiKey: String
  private let model: String

  init(apiKey: String, model: String) {
    self.apiKey = apiKey
    self.model = model
  }

  func transcribe(_ recording: Recording) async throws -> String {
    let request = try makeRequest(audio: recording.audio, format: recording.format)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw OpenRouterError.nonHTTPResponse
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
