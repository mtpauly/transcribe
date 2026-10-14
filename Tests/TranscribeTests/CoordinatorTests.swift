import Foundation
import Testing

@testable import Transcribe

@Suite("Coordinator")
@MainActor
struct CoordinatorTests {
  @Test("records, transcribes, and pastes")
  func happyPath() async {
    let platform = FakePlatform()
    let transcriber = StubTranscriber(text: "hello world")
    let coordinator = Coordinator(platform: platform, transcriber: transcriber)

    await coordinator.toggle()
    #expect(coordinator.state == .recording)
    #expect(platform.startedURLs.count == 1)
    #expect(platform.startedCueCount == 1)

    await coordinator.toggle()
    #expect(coordinator.state == .idle)
    #expect(platform.stopCount == 1)
    #expect(platform.stoppedCueCount == 1)
    #expect(platform.pastedTexts == ["hello world"])
  }

  @Test("returns to idle after transcription failure")
  func transcriptionFailure() async {
    let platform = FakePlatform()
    let transcriber = StubTranscriber(error: StubError.failed)
    let coordinator = Coordinator(platform: platform, transcriber: transcriber)

    await coordinator.toggle()
    await coordinator.toggle()

    #expect(coordinator.state == .idle)
    #expect(platform.failedCount == 1)

    await coordinator.toggle()
    #expect(coordinator.state == .recording)
    coordinator.shutdown()
  }
}

@MainActor
private final class FakePlatform: TranscriptionPlatform {
  var startedURLs: [URL] = []
  var stopCount = 0
  var pastedTexts: [String] = []
  var startedCueCount = 0
  var stoppedCueCount = 0
  var busyCount = 0
  var failedCount = 0

  func startRecording(at url: URL) async throws {
    startedURLs.append(url)
  }

  func stopRecording() throws {
    stopCount += 1
  }

  func paste(_ text: String) throws {
    pastedTexts.append(text)
  }

  func recordingStarted() { startedCueCount += 1 }
  func recordingStopped() { stoppedCueCount += 1 }
  func busy() { busyCount += 1 }
  func failed() { failedCount += 1 }
}

private struct StubTranscriber: Transcriber {
  let text: String?
  let error: StubError?

  init(text: String) {
    self.text = text
    error = nil
  }

  init(error: StubError) {
    text = nil
    self.error = error
  }

  func transcribe(fileAt url: URL) async throws -> String {
    if let error {
      throw error
    }
    return text ?? ""
  }
}

private enum StubError: Error {
  case failed
}
