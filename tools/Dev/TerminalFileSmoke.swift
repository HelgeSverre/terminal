import AppKit
import Foundation
import UniformTypeIdentifiers

/// Exercises Launch Services through an isolated bundle identity. Never
/// registers, launches, or sends events to the user's installed terminal.
enum TerminalFileSmoke {
  static let command = Command(name: "terminal-file-smoke", usage: "[APP]",
    summary: "Verify terminal-handler discovery and cold/warm command-file opening.", run: run)
  private static let register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  static func run(_ arguments: [String]) throws {
    guard arguments.count <= 1 else { throw Failure.usage(command) }
    let source = absolutePath(arguments.first ?? "dist/Terminal.app", relativeTo: Repository.root)
    let root = URL(fileURLWithPath: Repository.path("target/native/file-open-\(UUID().uuidString)"))
    let bundle = root.appendingPathComponent("Terminal File Fixture.app")
    let identifier = "no.helgesverre.terminal.file-fixture." + UUID().uuidString.lowercased()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.copyItem(atPath: source, toPath: bundle.path)
    let plist = bundle.appendingPathComponent("Contents/Info.plist")
    try checked(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier \(identifier)", plist.path])
    try checked(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", bundle.path])
    try checked([register, "-f", bundle.path])
    defer { _ = try? runCommand([register, "-u", bundle.path]) }
    var application: NSRunningApplication?
    defer {
      if let application = application ?? NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first,
        !application.isTerminated {
        application.terminate()
        if !wait(seconds: 5, { application.isTerminated }) {
          application.forceTerminate()
          _ = wait(seconds: 2, { application.isTerminated })
        }
      }
    }

    let types = ["com.apple.terminal.shell-script", "public.unix-executable"]
    for name in types {
      guard let type = UTType(name), wait(seconds: 5, {
        NSWorkspace.shared.urlsForApplications(toOpen: type).contains {
          $0.standardizedFileURL == bundle.standardizedFileURL
        }
      }) else { throw Failure("fixture was not discovered as a handler for \(name)") }
    }
    var receipts: [[String: Any]] = []
    for mode in ["cold", "warm"] {
      let receipt = root.appendingPathComponent("\(mode).txt")
      let script = root.appendingPathComponent("\(mode) it's a $(touch INJECTED) 猫.command")
      let text = "#!/bin/sh\n/bin/rm -f -- \"$0\"\nprintf '%s\\n' \"$PPID\" \"$PWD\" \"$(tty)\" > \(quote(receipt.path))\n"
      try Data(text.utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let previousPID = application?.processIdentifier
      try checked(["/usr/bin/open", "-g", "-a", bundle.path, script.path, "--args", "--background"])
      guard wait(seconds: 10, {
        if application == nil {
          application = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
        }
        return (try? String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").count) == 3
      }), let application else { throw Failure("\(mode) open did not execute its command file") }
      let lines = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").map(String.init)
      guard lines.count == 3, lines[0] == String(application.processIdentifier),
        lines[1] == root.path, lines[2].hasPrefix("/dev/ttys"),
        !FileManager.default.fileExists(atPath: script.path),
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("INJECTED").path),
        previousPID == nil || previousPID == application.processIdentifier
      else { throw Failure("\(mode) open returned an invalid receipt: \(lines)") }
      receipts.append(["mode": mode, "app_pid": application.processIdentifier,
        "working_directory": lines[1], "tty": lines[2]])
      print("PASS \(mode): command file executed on a PTY with its literal path")
    }
    try writeJSON(["passed": true, "source_bundle": source, "content_types": types,
      "receipts": receipts], to: Repository.path("reports/terminal-file-smoke.json"))
  }

  private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
  private static func checked(_ command: [String]) throws {
    let result = try runCommand(command)
    guard result.succeeded else { throw Failure("\(command[0]): \(result.output)") }
  }
  private static func wait(seconds: Double, _ predicate: () -> Bool) -> Bool {
    let deadline = Clock.now + UInt64(seconds * 1_000_000_000)
    while !predicate(), Clock.now < deadline { usleep(10_000) }
    return predicate()
  }
}
