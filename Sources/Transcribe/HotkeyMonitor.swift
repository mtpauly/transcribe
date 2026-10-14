import ApplicationServices
import CoreGraphics
import Foundation

final class HotkeyMonitor: @unchecked Sendable {
  private static let spaceKeyCode: CGKeyCode = 49

  private let onToggle: @Sendable () -> Void
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var suppressingSpace = false

  init(onToggle: @escaping @Sendable () -> Void) {
    self.onToggle = onToggle
  }

  func install() throws {
    guard eventTap == nil else {
      return
    }

    let mask =
      CGEventMask(1 << CGEventType.keyDown.rawValue)
      | CGEventMask(1 << CGEventType.keyUp.rawValue)
    let reference = Unmanaged.passUnretained(self).toOpaque()

    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: hotkeyEventCallback,
        userInfo: reference
      )
    else {
      throw HotkeyError.eventTapDenied
    }

    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
      CFMachPortInvalidate(eventTap)
      throw HotkeyError.couldNotCreateRunLoopSource
    }

    self.eventTap = eventTap
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      suppressingSpace = false
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    guard keyCode == Self.spaceKeyCode else {
      return Unmanaged.passUnretained(event)
    }

    if type == .keyDown, event.flags.contains(.maskAlternate) {
      let firstPress = !suppressingSpace
      suppressingSpace = true
      if firstPress {
        onToggle()
      }
      return nil
    }

    if type == .keyUp, suppressingSpace {
      suppressingSpace = false
      return nil
    }

    return Unmanaged.passUnretained(event)
  }

  deinit {
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    if let eventTap {
      CFMachPortInvalidate(eventTap)
    }
  }
}

private func hotkeyEventCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else {
    return Unmanaged.passUnretained(event)
  }
  let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
  return monitor.handle(type: type, event: event)
}

private enum HotkeyError: LocalizedError {
  case eventTapDenied
  case couldNotCreateRunLoopSource

  var errorDescription: String? {
    switch self {
    case .eventTapDenied:
      return "macOS refused the keyboard event tap; verify Accessibility permission"
    case .couldNotCreateRunLoopSource:
      return "Could not create the keyboard event run-loop source"
    }
  }
}
