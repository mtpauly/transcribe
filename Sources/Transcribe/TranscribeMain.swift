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
      let client = OpenRouterClient(
        apiKey: configuration.openRouterAPIKey,
        model: configuration.model
      )
      let archive = configuration.recordingsDirectory.map {
        DirectoryRecordingArchive(directory: $0, log: logger.write)
      }
      if let archive {
        logger.write("saving recordings to \(archive.directory.path)")
      }
      let coordinator = Coordinator(
        platform: platform,
        transcriber: client,
        archive: archive,
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

      self.coordinator = coordinator
      hotkeyMonitor = monitor
      logger.write(
        "ready; press Option+Space to start or stop recording, Escape to cancel, Option+Shift+V to paste the last transcript (pid \(ProcessInfo.processInfo.processIdentifier))"
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

  private func showAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
