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

  @Test("cancelling a recording discards it without transcribing")
  func cancelRecording() async {
    let platform = FakePlatform()
    let transcriber = StubTranscriber(text: "unused")
    let archive = FakeArchive()
    let coordinator = Coordinator(
      platform: platform,
      transcriber: transcriber,
      archive: archive
    )

    await coordinator.toggle()
    #expect(coordinator.isCancellable)
    coordinator.cancel()

    #expect(coordinator.state == .idle)
    #expect(!coordinator.isCancellable)
    #expect(platform.stopCount == 1)
    #expect(platform.cancelledCueCount == 1)
    #expect(transcriber.received.recordings.isEmpty)
    #expect(archive.saved.recordings.isEmpty)
  }

  @Test("cancelling a pending transcription skips the paste")
  func cancelTranscription() async {
    let platform = FakePlatform()
    let coordinator = Coordinator(platform: platform, transcriber: HangingTranscriber())

    await coordinator.toggle()
    let stopping = Task { await coordinator.toggle() }
    while coordinator.state != .transcribing {
      await Task.yield()
    }
    #expect(coordinator.isCancellable)
    coordinator.cancel()
    await stopping.value

    #expect(coordinator.state == .idle)
    #expect(platform.cancelledCueCount == 1)
    #expect(platform.failedCount == 0)
    #expect(platform.pastedTexts.isEmpty)

    await coordinator.toggle()
    #expect(coordinator.state == .recording)
    coordinator.shutdown()
  }

  @Test("uses updated dependencies for the next recording")
  func updateDependencies() async {
    let platform = FakePlatform()
    let oldTranscriber = StubTranscriber(text: "old")
    let oldArchive = FakeArchive()
    let coordinator = Coordinator(
      platform: platform,
      transcriber: oldTranscriber,
      archive: oldArchive
    )
    let newTranscriber = StubTranscriber(text: "new")
    let newArchive = FakeArchive()

    coordinator.update(transcriber: newTranscriber, archive: newArchive)
    await coordinator.toggle()
    await coordinator.toggle()

    #expect(oldTranscriber.received.recordings.isEmpty)
    #expect(oldArchive.saved.recordings.isEmpty)
    #expect(newTranscriber.received.recordings == [FakePlatform.recording])
    #expect(newArchive.saved.recordings == [FakePlatform.recording])
    #expect(platform.pastedTexts == ["new"])
  }

  @Test("pastes the last transcript again")
  func pasteLastTranscript() async {
    let platform = FakePlatform()
    let coordinator = Coordinator(
      platform: platform,
      transcriber: StubTranscriber(text: "hello world")
    )

    await coordinator.toggle()
    await coordinator.toggle()
    coordinator.pasteLastTranscript()

    #expect(platform.pastedTexts == ["hello world", "hello world"])
    #expect(platform.failedCount == 0)
  }

  @Test("pasting the last transcript before any fails")
  func pasteLastTranscriptWithoutOne() {
    let platform = FakePlatform()
    let coordinator = Coordinator(platform: platform, transcriber: StubTranscriber(text: ""))

    coordinator.pasteLastTranscript()

    #expect(platform.pastedTexts.isEmpty)
    #expect(platform.failedCount == 1)
  }

  @Test("cancel does nothing while idle")
  func cancelWhileIdle() {
    let platform = FakePlatform()
    let coordinator = Coordinator(platform: platform, transcriber: StubTranscriber(text: ""))

    #expect(!coordinator.isCancellable)
    coordinator.cancel()

    #expect(coordinator.state == .idle)
    #expect(platform.stopCount == 0)
    #expect(platform.cancelledCueCount == 0)
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
  var cancelledCueCount = 0
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
  func recordingCancelled() { cancelledCueCount += 1 }
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

/// Never finishes on its own; only returns by throwing when cancelled.
private struct HangingTranscriber: Transcriber {
  func transcribe(_ recording: Recording) async throws -> String {
    try await Task.sleep(for: .seconds(3600))
    return ""
  }
}

private enum StubError: Error {
  case failed
}
