import Foundation

/// Finalized audio held in memory, e.g. a WAV file's bytes with format "wav".
struct Recording: Sendable, Equatable {
  let audio: Data
  let format: String
}

@MainActor
protocol TranscriptionPlatform: AnyObject {
  /// Starts recording and returns the name of the input device in use, if known.
  func startRecording() async throws -> String?
  func stopRecording() throws -> Recording
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
  private let archive: (any RecordingArchive)?
  private let log: @Sendable (String) -> Void

  init(
    platform: any TranscriptionPlatform,
    transcriber: any Transcriber,
    archive: (any RecordingArchive)? = nil,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.platform = platform
    self.transcriber = transcriber
    self.archive = archive
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
        _ = try platform.stopRecording()
      } catch {
        log("error stopping recording during shutdown: \(error.localizedDescription)")
      }
    }
    state = .idle
  }

  private func startRecording() async {
    state = .starting
    do {
      let device = try await platform.startRecording()
      state = .recording
      log("recording started on \(device ?? "unknown input device")")
      platform.recordingStarted()
    } catch {
      state = .idle
      reportFailure("start recording", error: error)
    }
  }

  private func stopAndTranscribe() async {
    let recording: Recording
    do {
      recording = try platform.stopRecording()
    } catch {
      state = .idle
      reportFailure("stop recording", error: error)
      return
    }

    state = .transcribing
    log("recording stopped (\(recording.audio.count / 1024) KB); transcription started")
    platform.recordingStopped()
    archive?.save(recording)

    do {
      let text = try await transcriber.transcribe(recording)
      guard state == .transcribing else {
        return
      }
      log("transcribed text: \(text)")
      try platform.paste(text)
      log("transcription pasted")
      state = .idle
    } catch {
      state = .idle
      reportFailure("transcribe recording", error: error)
    }
  }

  private func reportFailure(_ operation: String, error: any Error) {
    log("error: \(operation): \(error.localizedDescription)")
    platform.failed()
  }
}
