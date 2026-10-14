import Foundation
import Testing

@testable import Transcribe

@Suite("OpenRouter client")
struct OpenRouterClientTests {
  @Test("builds the expected transcription request")
  func request() throws {
    let audio = Data("fake-wave-data".utf8)
    let client = OpenRouterClient(apiKey: "test-key", model: "test-model")

    let request = try client.makeRequest(audio: audio, format: "wav")

    #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "test-model")
    let inputAudio = try #require(json["input_audio"] as? [String: Any])
    #expect(inputAudio["format"] as? String == "wav")
    #expect(inputAudio["data"] as? String == audio.base64EncodedString())
  }
}
