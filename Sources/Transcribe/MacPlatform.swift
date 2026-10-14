import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation


@MainActor
final class MacPlatform: NSObject, TranscriptionPlatform {
  private var capture: AudioCapture?
  /// The user's clipboard, held while a paste's restore is pending, and which paste owns it.
  private var pendingRestoreItems: [NSPasteboardItem]?
  private var restoreGeneration = 0

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
    // A paste whose restore is still pending left our transcript on the pasteboard; keep the
    // user's original items from then rather than snapshotting the transcript.
    let savedItems = pendingRestoreItems ?? snapshot(of: pasteboard)
    pendingRestoreItems = savedItems
    restoreGeneration += 1
    let generation = restoreGeneration

    // Mark the text as transient so clipboard managers skip it.
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setData(Data(), forType: Self.transientType)
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else {
      throw PlatformError.couldNotWritePasteboard
    }
    let changeCount = pasteboard.changeCount

    try postPasteShortcut()

    // The target app reads the pasteboard when it handles Command-V, so restore the user's
    // clipboard only after it has had time to do so, and only if nothing else wrote to it since.
    Task { @MainActor in
      try? await Task.sleep(for: Self.restoreDelay)
      // A later paste took over the restore.
      guard generation == self.restoreGeneration else {
        return
      }
      self.pendingRestoreItems = nil
      guard pasteboard.changeCount == changeCount else {
        return
      }
      pasteboard.clearContents()
      if !savedItems.isEmpty {
        pasteboard.writeObjects(savedItems)
      }
    }
  }

  func recordingStarted() {
    playSound(named: "Tink")
  }

  func recordingStopped() {
    playSound(named: "Pop")
  }

  func recordingCancelled() {
    playSound(named: "Bottle")
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

  private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
  private static let restoreDelay: Duration = .milliseconds(500)

  /// Copies every item's data so it survives `clearContents()`.
  private func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
    (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) {
          copy.setData(data, forType: type)
        }
      }
      return copy
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
