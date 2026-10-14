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

  @Test("retries 429s using Retry-After, then succeeds")
  func retriesRateLimit() async throws {
    let responses = Responses([
      (429, ["Retry-After": "2"], "{}"),
      (429, [:], #"{"error":{"code":429,"metadata":{"retry_after_seconds":3}}}"#),
      (200, [:], #"{"text":" hello "}"#),
    ])
    let sleeps = Sleeps()
    let client = OpenRouterClient(
      apiKey: "k", model: "m",
      send: { _ in try await responses.next() },
      sleep: { await sleeps.record($0) }
    )

    let text = try await client.transcribe(Recording(audio: Data(), format: "wav"))

    #expect(text == "hello")
    #expect(await sleeps.durations == [.seconds(2), .seconds(3)])
  }

  @Test("gives up after the max number of 429 retries")
  func exhaustsRetries() async throws {
    let responses = Responses(
      Array(repeating: (429, [:], "{}"), count: OpenRouterClient.maxRateLimitRetries + 1)
    )
    let sleeps = Sleeps()
    let client = OpenRouterClient(
      apiKey: "k", model: "m",
      send: { _ in try await responses.next() },
      sleep: { await sleeps.record($0) }
    )

    await #expect(throws: OpenRouterError.self) {
      try await client.transcribe(Recording(audio: Data(), format: "wav"))
    }
    #expect(
      await sleeps.durations
        == Array(
          repeating: OpenRouterClient.defaultRetryDelay,
          count: OpenRouterClient.maxRateLimitRetries))
    #expect(await responses.remaining == 0)
  }

  @Test("does not retry other errors")
  func noRetryOnOtherErrors() async throws {
    let responses = Responses([(500, [:], "boom"), (200, [:], #"{"text":"x"}"#)])
    let sleeps = Sleeps()
    let client = OpenRouterClient(
      apiKey: "k", model: "m",
      send: { _ in try await responses.next() },
      sleep: { await sleeps.record($0) }
    )

    await #expect(throws: OpenRouterError.self) {
      try await client.transcribe(Recording(audio: Data(), format: "wav"))
    }
    #expect(await sleeps.durations.isEmpty)
    #expect(await responses.remaining == 1)
  }

  @Test("caps long Retry-After values")
  func capsRetryDelay() throws {
    let url = try #require(URL(string: "https://example.com"))
    let response = try #require(
      HTTPURLResponse(
        url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "600"]))
    #expect(
      OpenRouterClient.retryDelay(response: response, body: Data())
        == OpenRouterClient.maxRetryDelay)
  }
}

private actor Responses {
  private var queue: [(Int, [String: String], String)]

  init(_ queue: [(Int, [String: String], String)]) {
    self.queue = queue
  }

  var remaining: Int { queue.count }

  func next() throws -> (Data, URLResponse) {
    let (status, headers, body) = queue.removeFirst()
    let url = URL(string: "https://openrouter.ai")!
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    return (Data(body.utf8), response)
  }
}

private actor Sleeps {
  private(set) var durations: [Duration] = []

  func record(_ duration: Duration) {
    durations.append(duration)
  }
}
