import Foundation

@MainActor
protocol TranscriptionPlatform: AnyObject {
  func startRecording(at url: URL) async throws
  func stopRecording() throws
  func paste(_ text: String) throws
  func recordingStarted()
  func recordingStopped()
  func busy()
  func failed()
}

@MainActor
final class Coordinator {
  enum State: Sendable, Equatable {
    case idle
    case starting
    case recording
    case transcribing
  }

  private(set) var state: State = .idle

  private let platform: any TranscriptionPlatform
  private let transcriber: any Transcriber
  private let log: @Sendable (String) -> Void
  private var recordingURL: URL?

  init(
    platform: any TranscriptionPlatform,
    transcriber: any Transcriber,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.platform = platform
    self.transcriber = transcriber
    self.log = log
  }

  func toggle() async {
    switch state {
    case .idle:
      await startRecording()
    case .recording:
      await stopAndTranscribe()
    case .starting, .transcribing:
      log("hotkey ignored while busy")
      platform.busy()
    }
  }

  func shutdown() {
    if state == .recording {
      do {
        try platform.stopRecording()
      } catch {
        log("error stopping recording during shutdown: \(error.localizedDescription)")
      }
    }
    removeRecording()
    reset()
  }

  private func startRecording() async {
    state = .starting
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("transcribe-\(UUID().uuidString)")
      .appendingPathExtension("wav")

    do {
      try await platform.startRecording(at: url)
      recordingURL = url
      state = .recording
      log("recording started: \(url.path)")
      platform.recordingStarted()
    } catch {
      try? FileManager.default.removeItem(at: url)
      reset()
      reportFailure("start recording", error: error)
    }
  }

  private func stopAndTranscribe() async {
    guard let url = recordingURL else {
      reset()
      reportFailure("stop recording", error: CoordinatorError.missingRecording)
      return
    }

    do {
      try platform.stopRecording()
    } catch {
      removeRecording()
      reset()
      reportFailure("stop recording", error: error)
      return
    }

    state = .transcribing
    log("recording stopped; transcription started")
    platform.recordingStopped()

    do {
      let text = try await transcriber.transcribe(fileAt: url)
      guard state == .transcribing else {
        removeRecording()
        return
      }
      try platform.paste(text)
      log("transcription pasted")
      removeRecording()
      reset()
    } catch {
      removeRecording()
      reset()
      reportFailure("transcribe recording", error: error)
    }
  }

  private func reportFailure(_ operation: String, error: any Error) {
    log("error: \(operation): \(error.localizedDescription)")
    platform.failed()
  }

  private func removeRecording() {
    guard let recordingURL else {
      return
    }
    try? FileManager.default.removeItem(at: recordingURL)
    self.recordingURL = nil
  }

  private func reset() {
    state = .idle
    recordingURL = nil
  }
}

private enum CoordinatorError: LocalizedError {
  case missingRecording

  var errorDescription: String? {
    "The current recording path is missing"
  }
}
