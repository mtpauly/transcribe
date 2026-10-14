import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class MacPlatform: NSObject, TranscriptionPlatform {
  private var recorder: AVAudioRecorder?

  func startRecording(at url: URL) async throws {
    guard recorder == nil else {
      throw PlatformError.recordingAlreadyActive
    }
    guard await microphoneAuthorized() else {
      throw PlatformError.microphoneDenied
    }

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsFloatKey: false,
    ]
    let recorder = try AVAudioRecorder(url: url, settings: settings)
    guard recorder.prepareToRecord(), recorder.record() else {
      throw PlatformError.couldNotStartRecording
    }
    self.recorder = recorder
  }

  func stopRecording() throws {
    guard let recorder else {
      throw PlatformError.noActiveRecording
    }
    recorder.stop()
    self.recorder = nil
  }

  func paste(_ text: String) throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      throw PlatformError.couldNotWritePasteboard
    }
    try postPasteShortcut()
  }

  func recordingStarted() {
    playSound(named: "Tink")
  }

  func recordingStopped() {
    playSound(named: "Pop")
  }

  func busy() {
    playSound(named: "Funk")
  }

  func failed() {
    playSound(named: "Basso")
  }

  private func microphoneAuthorized() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .denied, .restricted:
      return false
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .audio)
    @unknown default:
      return false
    }
  }

  private func postPasteShortcut() throws {
    guard
      let commandDown = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true),
      let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
      let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false),
      let commandUp = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false)
    else {
      throw PlatformError.couldNotCreatePasteEvents
    }

    commandDown.flags = .maskCommand
    vDown.flags = .maskCommand
    vUp.flags = .maskCommand
    commandDown.post(tap: .cghidEventTap)
    vDown.post(tap: .cghidEventTap)
    vUp.post(tap: .cghidEventTap)
    commandUp.post(tap: .cghidEventTap)
  }

  private func playSound(named name: String) {
    if NSSound(named: NSSound.Name(name))?.play() != true {
      NSSound.beep()
    }
  }
}

enum AccessibilityPermission {
  static func isTrusted(prompt: Bool) -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }
}

private enum PlatformError: LocalizedError {
  case recordingAlreadyActive
  case microphoneDenied
  case couldNotStartRecording
  case noActiveRecording
  case couldNotWritePasteboard
  case couldNotCreatePasteEvents

  var errorDescription: String? {
    switch self {
    case .recordingAlreadyActive:
      return "A recording is already active"
    case .microphoneDenied:
      return "Microphone access is denied in System Settings"
    case .couldNotStartRecording:
      return "AVAudioRecorder could not start recording"
    case .noActiveRecording:
      return "No recording is active"
    case .couldNotWritePasteboard:
      return "Could not write the transcription to the pasteboard"
    case .couldNotCreatePasteEvents:
      return "Could not create the Command-V keyboard events"
    }
  }
}
