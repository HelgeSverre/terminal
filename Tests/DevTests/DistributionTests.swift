import Darwin
import Foundation
import Testing
@testable import dev

@Suite(.serialized) struct DistributionTests {
  @Test("distribution: notaryCommand appends keychain only when configured") func notaryCommandKeychain() {
    let distribution = Distribution(sleep: { _ in })
    let originalKeychain = ProcessInfo.processInfo.environment["APPLE_SIGNING_KEYCHAIN"]
    defer {
      if let originalKeychain { setenv("APPLE_SIGNING_KEYCHAIN", originalKeychain, 1) }
      else { unsetenv("APPLE_SIGNING_KEYCHAIN") }
    }
    unsetenv("APPLE_SIGNING_KEYCHAIN")
    #expect(
      distribution.notaryCommand(["history"], profile: "fixture")
        == ["xcrun", "notarytool", "history", "--keychain-profile", "fixture"])
    setenv("APPLE_SIGNING_KEYCHAIN", "/temporary signing/owned.keychain-db", 1)
    for arguments in [["history"], ["submit", "fixture.zip"], ["log", "submission"]] {
      #expect(
        distribution.notaryCommand(arguments, profile: "fixture")
          == ["xcrun", "notarytool"] + arguments + ["--keychain-profile", "fixture",
            "--keychain", "/temporary signing/owned.keychain-db"])
    }
  }

  @Test("distribution: transient staple/validate retries, bounded exhaustion, permanent and unrelated failures fail fast")
  func staplerRetryPolicy() throws {
    try withTemporaryDirectory("terminal-stapler-test-") { root in
      let files = FileManager.default
      let directory = URL(fileURLWithPath: root)
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
      var delays: [TimeInterval] = []
      let distribution = Distribution(sleep: { delays.append($0) })
      func scenario(status: Int, failures: Int, command: [String], attempts: Int, success: Bool) throws {
        delays.removeAll()
        try? files.removeItem(at: counter)
        setenv("STAPLER_TEST_STATUS", String(status), 1)
        setenv("STAPLER_TEST_FAILURES", String(failures), 1)
        if success {
          let output = try distribution.run(command)
          #expect(String(decoding: output, as: UTF8.self) == "TICKET_ATTACHED")
        } else {
          let error = try #require(throws: Distribution.Failure.self) {
            _ = try distribution.run(command)
          }
          if case .command(_, let actual) = error {
            #expect(actual == Int32(status))
          } else {
            Issue.record("expected command failure, got \(error)")
          }
        }
        let actualAttempts = try String(contentsOf: counter, encoding: .utf8)
        #expect(actualAttempts == String(attempts))
        #expect(delays == (0..<(attempts - 1)).map { Double(1 << $0) })
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
    }
  }
}
