import AppKit
import Foundation

@main
enum TranscribeMain {
  @MainActor
  static func main() {
    do {
      let logger = try AppLogger()
      let application = NSApplication.shared
      application.setActivationPolicy(.accessory)
      let delegate = ApplicationDelegate(logger: logger)
      application.delegate = delegate

      withExtendedLifetime((logger, delegate)) {
        application.run()
      }
    } catch {
      let message = "transcribe: fatal error: \(error.localizedDescription)\n"
      FileHandle.standardError.write(Data(message.utf8))
    }
  }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  private let logger: AppLogger
  private var coordinator: Coordinator?
  private var hotkeyMonitor: HotkeyMonitor?
  private var statusItem: StatusItem?
  private var platform: MacPlatform?
  private var configurationURL: URL?

  init(logger: AppLogger) {
    self.logger = logger
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let configurationURL = try Configuration.defaultURL()
      let configuration: Configuration
      do {
        configuration = try Configuration.load(from: configurationURL)
      } catch {
        showAlert(
          title: "Transcribe configuration error",
          message:
            "\(error.localizedDescription)\n\nCopy config.example.json to:\n\(configurationURL.path)"
        )
        throw error
      }

      guard AccessibilityPermission.isTrusted(prompt: true) else {
        logger.write(
          "Accessibility permission is required; grant it in System Settings and relaunch")
        showAlert(
          title: "Accessibility permission required",
          message:
            "Enable Transcribe under System Settings → Privacy & Security → Accessibility, then launch it again."
        )
        NSApp.terminate(nil)
        return
      }

      let platform = MacPlatform()
      let (client, archive) = makeDependencies(for: configuration)
      let stats = openStats(configurationURL: configurationURL)
      let coordinator = Coordinator(
        platform: platform,
        transcriber: client,
        archive: archive,
        stats: stats,
        log: logger.write
      )
      let monitor = HotkeyMonitor(
        onToggle: {
          Task { @MainActor in
            await coordinator.toggle()
          }
        },
        onCancel: {
          Task { @MainActor in
            coordinator.cancel()
          }
        },
        onPasteLast: {
          Task { @MainActor in
            coordinator.pasteLastTranscript()
          }
        },
        canCancel: {
          // The event tap runs on the main run loop.
          MainActor.assumeIsolated { coordinator.isCancellable }
        }
      )
      try monitor.install()

      let statusItem = StatusItem(
        coordinator: coordinator,
        configuration: configuration,
        configurationURL: configurationURL,
        logURL: logger.logURL,
        stats: stats,
        reloadConfiguration: { [weak self] in self?.reloadConfiguration() }
      )
      coordinator.onStateChange = { statusItem.show($0) }

      self.coordinator = coordinator
      hotkeyMonitor = monitor
      self.statusItem = statusItem
      self.platform = platform
      self.configurationURL = configurationURL
      logger.write(
        "ready; model \(configuration.model); press Option+Space to start or stop recording, Escape to cancel, Option+Shift+V to paste the last transcript (pid \(ProcessInfo.processInfo.processIdentifier))"
      )
    } catch {
      logger.write("fatal error: \(error.localizedDescription)")
      NSApp.terminate(nil)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    coordinator?.shutdown()
    logger.write("stopped")
  }

  /// Rereads config.json and swaps in a new client and archive. On failure the
  /// current configuration stays in effect.
  private func reloadConfiguration() {
    guard let configurationURL, let coordinator, let statusItem else { return }
    let configuration: Configuration
    do {
      configuration = try Configuration.load(from: configurationURL)
    } catch {
      logger.write("error: reload config: \(error.localizedDescription)")
      platform?.failed()
      return
    }
    let (client, archive) = makeDependencies(for: configuration)
    coordinator.update(transcriber: client, archive: archive)
    statusItem.configuration = configuration
    logger.write("config reloaded; model \(configuration.model)")
  }

  /// Stats are optional: if the database can't be opened, transcription still works.
  private func openStats(configurationURL: URL) -> SQLiteStatsStore? {
    let url = SQLiteStatsStore.defaultURL(configurationURL: configurationURL)
    do {
      return try SQLiteStatsStore(url: url, log: logger.write)
    } catch {
      logger.write("error: open stats database: \(error.localizedDescription)")
      return nil
    }
  }

  private func makeDependencies(
    for configuration: Configuration
  ) -> (OpenRouterClient, DirectoryRecordingArchive?) {
    let client = OpenRouterClient(
      apiKey: configuration.openRouterAPIKey,
      model: configuration.model,
      log: logger.write
    )
    let archive = configuration.recordingsDirectory.map {
      DirectoryRecordingArchive(directory: $0, log: logger.write)
    }
    if let archive {
      logger.write("saving recordings to \(archive.directory.path)")
    }
    return (client, archive)
  }

  private func showAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
