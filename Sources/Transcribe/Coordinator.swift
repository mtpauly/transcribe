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
  func recordingCancelled()
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

  private(set) var state: State = .idle {
    didSet {
      if state != oldValue { onStateChange?(state) }
    }
  }
  var onStateChange: ((State) -> Void)?
  private var transcription: Task<String, any Error>?
  private(set) var lastTranscript: String?

  /// Whether Escape should cancel: while recording or waiting on a transcription.
  var isCancellable: Bool {
    state == .recording || state == .transcribing
  }

  private let platform: any TranscriptionPlatform
  private var transcriber: any Transcriber
  private var archive: (any RecordingArchive)?
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

  /// Swaps in new dependencies, e.g. after a config reload. A transcription already
  /// in flight finishes with the ones it started with.
  func update(transcriber: any Transcriber, archive: (any RecordingArchive)?) {
    self.transcriber = transcriber
    self.archive = archive
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

  func cancel() {
    switch state {
    case .recording:
      do {
        _ = try platform.stopRecording()
      } catch {
        log("error stopping recording during cancel: \(error.localizedDescription)")
      }
      log("recording cancelled")
    case .transcribing:
      transcription?.cancel()
      transcription = nil
      log("transcription cancelled")
    case .idle, .starting:
      return
    }
    state = .idle
    platform.recordingCancelled()
  }

  func pasteLastTranscript() {
    guard let lastTranscript else {
      log("no transcript to paste yet")
      platform.failed()
      return
    }
    do {
      try platform.paste(lastTranscript)
      log("last transcript pasted")
    } catch {
      reportFailure("paste last transcript", error: error)
    }
  }

  func shutdown() {
    transcription?.cancel()
    transcription = nil
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

    let transcriber = transcriber
    let task = Task { try await transcriber.transcribe(recording) }
    transcription = task
    do {
      let text = try await task.value
      // Cancelled or superseded while waiting; drop the result.
      guard transcription == task else {
        return
      }
      transcription = nil
      lastTranscript = text
      log("transcribed text: \(text)")
      try platform.paste(text)
      log("transcription pasted")
      state = .idle
    } catch {
      guard transcription == task else {
        return
      }
      transcription = nil
      state = .idle
      reportFailure("transcribe recording", error: error)
    }
  }

  private func reportFailure(_ operation: String, error: any Error) {
    log("error: \(operation): \(error.localizedDescription)")
    platform.failed()
  }
}
