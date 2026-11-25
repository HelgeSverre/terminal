import AppKit
import Network
import Sparkle

/// Only the feed is served, on an ephemeral loopback port.
final class Preview: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
  var listener: NWListener?
  var controller: SPUStandardUpdaterController?
  var feedURL: String = ""

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let data = try Data(contentsOf: Bundle.main.url(forResource: "appcast", withExtension: "xml")!)
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      let listener = try NWListener(using: parameters)
      self.listener = listener
      listener.newConnectionHandler = { connection in
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
          let header = "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
          connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
        }
      }
      listener.stateUpdateHandler = { [self] state in
        MainActor.assumeIsolated {
          if case .ready = state, let port = listener.port {
            feedURL = "http://127.0.0.1:\(port.rawValue)/appcast.xml"
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            self.controller = controller
            do {
              try controller.updater.start()
              controller.updater.automaticallyChecksForUpdates = false
              controller.checkForUpdates(nil)
              NSApp.activate(ignoringOtherApps: true)
            } catch { fail(error) }
          } else if case .failed(let error) = state { fail(error) }
        }
      }
      listener.start(queue: .main)
    } catch { fail(error) }
  }

  func feedURLString(for updater: SPUUpdater) -> String? { feedURL }

  // Sparkle calls this before acting on the choice. No download or install is allowed.
  func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
               forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
    exit(0)
  }

  func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
    exit(0)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func fail(_ error: Error) {
    let alert = NSAlert(error: error)
    alert.runModal()
    NSApp.terminate(nil)
  }
}

let app = NSApplication.shared
let preview = Preview()
app.setActivationPolicy(.regular)
app.delegate = preview
app.run()
