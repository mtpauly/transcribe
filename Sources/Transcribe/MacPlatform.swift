import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation


@MainActor
final class MacPlatform: NSObject, TranscriptionPlatform {
  private var capture: AudioCapture?

  func startRecording() async throws -> String? {
    guard capture == nil else {
      throw PlatformError.recordingAlreadyActive
    }
    guard await microphoneAuthorized() else {
      throw PlatformError.microphoneDenied
    }

    let capture = AudioCapture()
    try capture.start()
    self.capture = capture
    return defaultInputDeviceName()
  }

  func stopRecording() throws -> Recording {
    guard let capture else {
      throw PlatformError.noActiveRecording
    }
    self.capture = nil
    let samples = capture.stop()
    return Recording(
      audio: WAV.encode(pcm16Mono: samples, sampleRate: AudioCapture.sampleRate),
      format: "wav"
    )
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

  /// AVAudioEngine records from the system default input, so report that device.
  private func defaultInputDeviceName() -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
      ) == noErr,
      deviceID != kAudioObjectUnknown
    else {
      return nil
    }

    address.mSelector = kAudioObjectPropertyName
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
      let name
    else {
      return nil
    }
    return name.takeRetainedValue() as String
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
  case noActiveRecording
  case couldNotWritePasteboard
  case couldNotCreatePasteEvents

  var errorDescription: String? {
    switch self {
    case .recordingAlreadyActive:
      return "A recording is already active"
    case .microphoneDenied:
      return "Microphone access is denied in System Settings"
    case .noActiveRecording:
      return "No recording is active"
    case .couldNotWritePasteboard:
      return "Could not write the transcription to the pasteboard"
    case .couldNotCreatePasteEvents:
      return "Could not create the Command-V keyboard events"
    }
  }
}
