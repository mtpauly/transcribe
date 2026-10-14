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
    #expect(platform.startCount == 1)
    #expect(platform.startedCueCount == 1)

    await coordinator.toggle()
    #expect(coordinator.state == .idle)
    #expect(platform.stopCount == 1)
    #expect(platform.stoppedCueCount == 1)
    #expect(transcriber.received.recordings == [FakePlatform.recording])
    #expect(platform.pastedTexts == ["hello world"])
  }

  @Test("archives the recording even when transcription fails")
  func archivesRecording() async {
    let platform = FakePlatform()
    let archive = FakeArchive()
    let coordinator = Coordinator(
      platform: platform,
      transcriber: StubTranscriber(error: StubError.failed),
      archive: archive
    )

    await coordinator.toggle()
    #expect(archive.saved.recordings.isEmpty)

    await coordinator.toggle()
    #expect(archive.saved.recordings == [FakePlatform.recording])
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
  static let recording = Recording(audio: Data("audio".utf8), format: "wav")

  var startCount = 0
  var stopCount = 0
  var pastedTexts: [String] = []
  var startedCueCount = 0
  var stoppedCueCount = 0
  var busyCount = 0
  var failedCount = 0

  func startRecording() async throws -> String? {
    startCount += 1
    return nil
  }

  func stopRecording() throws -> Recording {
    stopCount += 1
    return Self.recording
  }

  func paste(_ text: String) throws {
    pastedTexts.append(text)
  }

  func recordingStarted() { startedCueCount += 1 }
  func recordingStopped() { stoppedCueCount += 1 }
  func busy() { busyCount += 1 }
  func failed() { failedCount += 1 }
}

private final class RecordingLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [Recording] = []

  var recordings: [Recording] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }

  func append(_ recording: Recording) {
    lock.lock()
    defer { lock.unlock() }
    items.append(recording)
  }
}

private struct FakeArchive: RecordingArchive {
  let saved = RecordingLog()

  func save(_ recording: Recording) {
    saved.append(recording)
  }
}

private struct StubTranscriber: Transcriber {
  let text: String?
  let error: StubError?
  let received = RecordingLog()

  init(text: String) {
    self.text = text
    error = nil
  }

  init(error: StubError) {
    text = nil
    self.error = error
  }

  func transcribe(_ recording: Recording) async throws -> String {
    received.append(recording)
    if let error {
      throw error
    }
    return text ?? ""
  }
}

private enum StubError: Error {
  case failed
}
