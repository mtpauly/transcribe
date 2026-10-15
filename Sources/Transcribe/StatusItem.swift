import AppKit

/// Menu-bar icon that mirrors the coordinator's state, with a menu of common actions.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let coordinator: Coordinator
  var configuration: Configuration
  private let configurationURL: URL
  private let logURL: URL
  private let reloadConfiguration: () -> Void

  init(
    coordinator: Coordinator,
    configuration: Configuration,
    configurationURL: URL,
    logURL: URL,
    reloadConfiguration: @escaping () -> Void
  ) {
    self.coordinator = coordinator
    self.configuration = configuration
    self.configurationURL = configurationURL
    self.logURL = logURL
    self.reloadConfiguration = reloadConfiguration
    super.init()
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    item.menu = menu
    show(coordinator.state)
  }

  func show(_ state: Coordinator.State) {
    let symbol =
      switch state {
      case .idle: "mic"
      case .starting, .recording: "mic.fill"
      case .transcribing: "waveform"
      }
    let label = Self.label(for: state)
    item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    item.button?.toolTip = "Transcribe: \(label)"
  }

  /// Rebuilt each time the menu opens so it reflects the current state and transcript.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let state = coordinator.state

    menu.addItem(info("Transcribe: \(Self.label(for: state))"))
    menu.addItem(.separator())

    let toggle = action(
      state == .recording ? "Stop Recording" : "Start Recording",
      #selector(toggleRecording), key: " ", modifiers: .option)
    toggle.isEnabled = state == .idle || state == .recording
    menu.addItem(toggle)
    let cancel = action("Cancel", #selector(cancel), key: "\u{1b}", modifiers: [])
    cancel.isEnabled = coordinator.isCancellable
    menu.addItem(cancel)
    menu.addItem(.separator())

    let transcript = coordinator.lastTranscript
    menu.addItem(info(transcript.map { "“\(Self.preview($0))”" } ?? "No transcript yet"))
    let paste = action("Paste Again", #selector(pasteAgain), key: "v", modifiers: [.option, .shift])
    paste.isEnabled = transcript != nil
    menu.addItem(paste)
    let copy = action("Copy", #selector(copyTranscript))
    copy.isEnabled = transcript != nil
    menu.addItem(copy)
    menu.addItem(.separator())

    menu.addItem(copyPath("Copy Log Path", logURL))
    menu.addItem(copyPath("Copy Config Path", configurationURL))
    if let directory = configuration.recordingsDirectory {
      menu.addItem(copyPath("Copy Recordings Folder Path", directory))
    }
    menu.addItem(.separator())

    menu.addItem(action("Reload Config", #selector(reloadConfig)))
    menu.addItem(.separator())

    menu.addItem(info("Model: \(configuration.model)"))
    menu.addItem(info("Microphone: \(MacPlatform.defaultInputDeviceName() ?? "Unknown")"))
    menu.addItem(.separator())

    menu.addItem(action("Quit Transcribe", #selector(quit), key: "q", modifiers: .command))
  }

  @objc private func toggleRecording() {
    Task { await coordinator.toggle() }
  }

  @objc private func cancel() {
    coordinator.cancel()
  }

  @objc private func pasteAgain() {
    coordinator.pasteLastTranscript()
  }

  @objc private func copyTranscript() {
    guard let transcript = coordinator.lastTranscript else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(transcript, forType: .string)
  }

  @objc private func copyPath(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
  }

  @objc private func reloadConfig() {
    reloadConfiguration()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  /// A "Copy … Path" item followed by the start of the path in gray.
  private func copyPath(_ title: String, _ url: URL) -> NSMenuItem {
    let item = action(title, #selector(copyPath(_:)))
    item.representedObject = url.path
    let font = NSFont.menuFont(ofSize: 0)
    let shown = Self.truncated((url.path as NSString).abbreviatingWithTildeInPath, limit: 32)
    let attributed = NSMutableAttributedString(
      string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    attributed.append(
      NSAttributedString(
        string: "  \(shown)",
        attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
    item.attributedTitle = attributed
    return item
  }

  private func info(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func action(
    _ title: String, _ selector: Selector, key: String = "",
    modifiers: NSEvent.ModifierFlags = .command
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = self
    return item
  }

  private static func label(for state: Coordinator.State) -> String {
    switch state {
    case .idle: "Idle"
    case .starting: "Starting"
    case .recording: "Recording"
    case .transcribing: "Transcribing"
    }
  }

  private static func preview(_ text: String) -> String {
    truncated(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text, limit: 50)
  }

  private static func truncated(_ text: String, limit: Int) -> String {
    text.count > limit ? text.prefix(limit) + "…" : text
  }
}
