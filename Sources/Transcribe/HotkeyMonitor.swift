import ApplicationServices
import CoreGraphics
import Foundation

final class HotkeyMonitor: @unchecked Sendable {
  private static let spaceKeyCode: CGKeyCode = 49
  private static let escapeKeyCode: CGKeyCode = 53
  private static let vKeyCode: CGKeyCode = 9
  private static let modifierMask: CGEventFlags = [
    .maskCommand, .maskAlternate, .maskControl, .maskShift,
  ]

  private let onToggle: @Sendable () -> Void
  private let onCancel: @Sendable () -> Void
  private let onPasteLast: @Sendable () -> Void
  private let canCancel: @Sendable () -> Bool
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  /// Keys whose press was consumed, so their repeats and key-up are consumed too.
  private var suppressedKeys: Set<CGKeyCode> = []

  /// `canCancel` is called on the event tap's thread (the main run loop) and must be fast.
  init(
    onToggle: @escaping @Sendable () -> Void,
    onCancel: @escaping @Sendable () -> Void,
    onPasteLast: @escaping @Sendable () -> Void,
    canCancel: @escaping @Sendable () -> Bool
  ) {
    self.onToggle = onToggle
    self.onCancel = onCancel
    self.onPasteLast = onPasteLast
    self.canCancel = canCancel
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
      suppressedKeys.removeAll()
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = event.flags.intersection(Self.modifierMask)

    if type == .keyUp {
      return suppressedKeys.remove(keyCode) == nil ? Unmanaged.passUnretained(event) : nil
    }
    guard type == .keyDown else {
      return Unmanaged.passUnretained(event)
    }

    switch keyCode {
    case Self.spaceKeyCode where modifiers == .maskAlternate:
      if suppressedKeys.insert(keyCode).inserted {
        onToggle()
      }
      return nil
    case Self.vKeyCode where modifiers == [.maskAlternate, .maskShift]:
      if suppressedKeys.insert(keyCode).inserted {
        onPasteLast()
      }
      return nil
    case Self.escapeKeyCode where modifiers.isEmpty:
      if suppressedKeys.contains(keyCode) {
        return nil
      }
      guard canCancel() else {
        return Unmanaged.passUnretained(event)
      }
      suppressedKeys.insert(keyCode)
      onCancel()
      return nil
    default:
      return Unmanaged.passUnretained(event)
    }
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
