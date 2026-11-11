import Foundation
import Darwin

@main struct DistributionTests {
  static func main() throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("terminal-stapler-test-\(UUID().uuidString)")
    try files.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("xcrun")
    let counter = directory.appendingPathComponent("attempts")
    // Exercise the actual command-launch and retry seam with a disposable tool.
    let fixture = #"""
    #!/bin/sh
    count=0
    if [ -f "$STAPLER_TEST_COUNTER" ]; then count=$(cat "$STAPLER_TEST_COUNTER"); fi
    count=$((count + 1))
    printf '%s' "$count" > "$STAPLER_TEST_COUNTER"
    if [ "$count" -le "$STAPLER_TEST_FAILURES" ]; then exit "$STAPLER_TEST_STATUS"; fi
    printf TICKET_ATTACHED
    """#
    try Data(fixture.utf8).write(to: executable)
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let originalPath = ProcessInfo.processInfo.environment["PATH"]
    setenv("PATH", "\(directory.path):/usr/bin:/bin", 1)
    setenv("STAPLER_TEST_COUNTER", counter.path, 1)
    defer {
      if let originalPath { setenv("PATH", originalPath, 1) } else { unsetenv("PATH") }
      for key in ["STAPLER_TEST_COUNTER", "STAPLER_TEST_FAILURES", "STAPLER_TEST_STATUS"] { unsetenv(key) }
    }
    let distribution = Distribution()
    let originalKeychain = ProcessInfo.processInfo.environment["APPLE_SIGNING_KEYCHAIN"]
    defer {
      if let originalKeychain { setenv("APPLE_SIGNING_KEYCHAIN", originalKeychain, 1) }
      else { unsetenv("APPLE_SIGNING_KEYCHAIN") }
    }
    unsetenv("APPLE_SIGNING_KEYCHAIN")
    precondition(distribution.notaryCommand(["history"], profile: "fixture")
      == ["xcrun", "notarytool", "history", "--keychain-profile", "fixture"])
    setenv("APPLE_SIGNING_KEYCHAIN", "/temporary signing/owned.keychain-db", 1)
    for arguments in [["history"], ["submit", "fixture.zip"], ["log", "submission"]] {
      precondition(distribution.notaryCommand(arguments, profile: "fixture")
        == ["xcrun", "notarytool"] + arguments + ["--keychain-profile", "fixture",
          "--keychain", "/temporary signing/owned.keychain-db"])
    }
    func scenario(status: Int, failures: Int, command: [String], attempts: Int, success: Bool) throws {
      try? files.removeItem(at: counter)
      setenv("STAPLER_TEST_STATUS", String(status), 1)
      setenv("STAPLER_TEST_FAILURES", String(failures), 1)
      do {
        let output = try distribution.run(command)
        precondition(success && String(decoding: output, as: UTF8.self) == "TICKET_ATTACHED")
      } catch Distribution.Failure.command(_, let actual) {
        precondition(!success && actual == status)
      }
      let actualAttempts = try String(contentsOf: counter, encoding: .utf8)
      precondition(actualAttempts == String(attempts))
    }
    let staple = ["xcrun", "stapler", "staple", "fixture.app"]
    try scenario(status: 68, failures: 2, command: staple, attempts: 3, success: true)
    try scenario(status: 68, failures: 10, command: staple, attempts: 4, success: false)
    for status in [65, 66, 73, 77] {
      try scenario(status: status, failures: 10, command: staple, attempts: 1, success: false)
    }
    let validate = ["xcrun", "stapler", "validate", "fixture.app"]
    try scenario(status: 68, failures: 1, command: validate, attempts: 2, success: true)
    try scenario(status: 66, failures: 10, command: validate, attempts: 1, success: false)
    try scenario(status: 68, failures: 10,
      command: ["xcrun", "notarytool", "history"], attempts: 1, success: false)
    print("PASS distribution: transient staple/validate retries, bounded exhaustion, permanent and unrelated failures fail fast")
  }
}
