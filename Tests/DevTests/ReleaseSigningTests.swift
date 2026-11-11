import Foundation
import Testing
@testable import dev

@Suite struct ReleaseSigningTests {
  @Test("release signing: missing variables are rejected before any command or file is created") func missingVariablesAreRejectedBeforeAny() throws {
    try withFixture { fixture in
      fixture.environment["APPLE_TEAM_ID"] = nil
      let message = try #require(throws: Failure.self) { try fixture.session.setup() }.message
      #expect(message.contains("APPLE_TEAM_ID"), "got: \(message)")
      #expect(fixture.runner.commands.isEmpty, "no command ran")
      #expect(!FileManager.default.fileExists(atPath: fixture.statePath), "no state file")
    }
  }

  @Test("release signing: invalid base64 is rejected before any command") func invalidBase64IsRejectedBeforeAny() throws {
    try withFixture { fixture in
      fixture.environment["APPLE_NOTARY_KEY_BASE64"] = "not base64!"
      let message = try #require(throws: Failure.self) { try fixture.session.setup() }.message
      #expect(message.contains("APPLE_NOTARY_KEY_BASE64"), "got: \(message)")
      #expect(fixture.runner.commands.isEmpty, "no command ran")
    }
  }

  @Test("release signing: setup uses the expected argv, writes private files and emits only env assignments") func setupUsesTheExpectedArgvWrites() throws {
    try withFixture { fixture in
      var observed: [String: String] = [:]
      fixture.runner.onRun = { command in
        var path: String?
        if command.starts(with: ["security", "import"]) { path = command[2] }
        if command.starts(with: ["xcrun", "notarytool", "store-credentials"]) {
          path = command[command.firstIndex(of: "--key")! + 1]
        }
        guard let path else { return }
        let contents = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        observed[ReleaseSigning.lastComponent(path)] = "\(contents) \(String(try mode(path), radix: 8))"
      }

      try fixture.session.setup()

      let state = try fixture.state()
      let keychain = state["keychain"] as? String ?? ""
      let workDirectory = state["work_dir"] as? String ?? ""
      let commands = fixture.runner.commands
      #expect(try mode(fixture.statePath) == 0o600, "state file is private")
      #expect(try mode(workDirectory) == 0o700, "work directory is private")
      #expect(observed["application.p12"] == "application-certificate-data 600", "application certificate")
      #expect(observed["installer.p12"] == "installer-certificate-data 600", "installer certificate")
      #expect(observed["notary-key.p8"] == "notary-key-data 600", "notary key")
      #expect(fixture.lines == ["APPLE_NOTARY_PROFILE=terminal-notary-\(fixedHex(2))",
                                   "APPLE_SIGNING_KEYCHAIN=\(keychain)"], "got: \(fixture.lines)")
      let output = fixture.lines.joined(separator: "\n")
      #expect(!["password", "certificate-data", "notary-key-data"].contains { output.contains($0) },
                 "no secret is emitted")
      #expect(String(decoding: FileManager.default.contents(atPath: fixture.statePath) ?? Data(), as: UTF8.self)
                   == "{\"work_dir\":\"\(workDirectory)\",\"keychain\":\"\(keychain)\","
                   + "\"search_list\":[\"/tmp/login.keychain-db\"]}", "state file text")

      #expect(commands.contains(["security", "create-keychain", "-p", fixedHex(3), keychain]), "create-keychain")
      #expect(commands.contains(["security", "set-keychain-settings", "-lut", "21600", keychain]), "settings")
      #expect(commands.contains(["security", "unlock-keychain", "-p", fixedHex(3), keychain]), "unlock")
      #expect(commands.contains(["security", "list-keychains", "-d", "user", "-s", keychain,
                                    "/tmp/login.keychain-db"]), "search list gains the keychain")
      let imports = commands.filter { $0.starts(with: ["security", "import"]) }
      #expect(imports.count == 2, "two imports")
      for command in imports {
        let tools = command.indices.filter { command[$0] == "-T" }.map { command[$0 + 1] }
        #expect(tools == ["/usr/bin/codesign", "/usr/bin/pkgbuild", "/usr/bin/productsign"], "got: \(tools)")
      }
      #expect(commands.contains(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                                    "-s", "-k", fixedHex(3), keychain]), "partition list")
      let notary = commands.first { $0.starts(with: ["xcrun", "notarytool", "store-credentials"]) }
      #expect(notary == ["xcrun", "notarytool", "store-credentials", "terminal-notary-\(fixedHex(2))",
                            "--key", workDirectory + "/notary-key.p8", "--key-id", "ABCDEFGHIJ",
                            "--issuer", "issuer-id", "--keychain", keychain], "got: \(notary ?? [])")
      for name in ["notary-key.p8", "application.p12", "installer.p12"] {
        #expect(!FileManager.default.fileExists(atPath: workDirectory + "/" + name), "\(name) is deleted")
      }
    }
  }

  @Test("release signing: a setup failure restores the search list and removes state") func aSetupFailureRestoresTheSearch() throws {
    try withFixture { fixture in
      fixture.runner.failOn = { $0.starts(with: ["security", "import"]) }
      #expect(throws: Failure.self) { try fixture.session.setup() }

      #expect(!FileManager.default.fileExists(atPath: fixture.statePath), "state is removed")
      #expect(fixture.signingDirectories.isEmpty, "work directory is removed")
      #expect(fixture.runner.commands.contains { $0.starts(with: ["security", "delete-keychain"]) },
                 "keychain is deleted")
      #expect(fixture.runner.restores.last == ["security", "list-keychains", "-d", "user", "-s",
                                                  "/tmp/login.keychain-db"], "search list is restored")
      #expect(fixture.lines.isEmpty, "nothing is emitted")
    }
  }

  @Test("release signing: cleanup retains state for a retry when it cannot restore the search list") func cleanupRetainsStateForARetry() throws {
    try withFixture { fixture in
      try fixture.session.setup()
      fixture.runner.failOn = {
        $0.starts(with: ["security", "list-keychains", "-d", "user", "-s"]) && $0.last == "/tmp/login.keychain-db"
      }
      #expect(throws: Failure.self) { try fixture.session.cleanup() }
      #expect(FileManager.default.fileExists(atPath: fixture.statePath), "state is kept")

      fixture.runner.failOn = nil
      try fixture.session.cleanup()
      #expect(!FileManager.default.fileExists(atPath: fixture.statePath), "state is removed")
    }
  }

  @Test("release signing: cleanup is idempotent and restores the original search list") func cleanupIsIdempotentAndRestoresThe() throws {
    try withFixture { fixture in
      try fixture.session.setup()
      let state = try fixture.state()
      let keychain = state["keychain"] as? String ?? ""
      try Data().write(to: URL(fileURLWithPath: keychain))

      try fixture.session.cleanup()
      try fixture.session.cleanup()

      #expect(!FileManager.default.fileExists(atPath: fixture.statePath), "state is removed")
      #expect(!FileManager.default.fileExists(atPath: state["work_dir"] as? String ?? ""), "work directory is removed")
      #expect(fixture.runner.commands.contains(["security", "delete-keychain", keychain]), "keychain is deleted")
      #expect(fixture.runner.restores.last == ["security", "list-keychains", "-d", "user", "-s",
                                                  "/tmp/login.keychain-db"], "search list is restored")
    }
  }

  @Test("release signing: an empty keychain search list is refused at setup and at cleanup") func anEmptyKeychainSearchListIs() throws {
    try withFixture { fixture in
      fixture.runner.searchList = []
      let message = try #require(throws: Failure.self) { try fixture.session.setup() }.message
      #expect(message == "security keychain search list is empty", "got: \(message)")
      #expect(!FileManager.default.fileExists(atPath: fixture.statePath), "no state is written")
      #expect(fixture.runner.restores.isEmpty, "the search list is not set")

      let directory = fixture.temp + "/terminal-signing-x"
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
      try "{\"work_dir\":\"\(directory)\",\"keychain\":\"\(directory)/signing.keychain-db\",\"search_list\":[]}"
        .write(toFile: fixture.statePath, atomically: true, encoding: .utf8)
      fixture.runner.commands = []
      let refused = try #require(throws: Failure.self) { try fixture.session.cleanup() }.message
      #expect(refused == "release signing state is invalid", "got: \(refused)")
      #expect(fixture.runner.commands.isEmpty, "no command ran: \(fixture.runner.commands)")
      #expect(FileManager.default.fileExists(atPath: directory), "the work directory is left alone")
    }
  }

  @Test("release signing: cleanup fails and retains state when the work directory cannot be removed") func cleanupFailsAndRetainsStateWhen() throws {
    try withFixture { fixture in
      try fixture.session.setup()
      let workDirectory = try fixture.state()["work_dir"] as? String ?? ""
      try Data().write(to: URL(fileURLWithPath: workDirectory + "/held"))
      // Nothing can be unlinked from a directory that cannot be written.
      try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: workDirectory)
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workDirectory) }
      let message = try #require(throws: Failure.self) { try fixture.session.cleanup() }.message
      #expect(message == "release signing cleanup failed", "got: \(message)")
      #expect(FileManager.default.fileExists(atPath: fixture.statePath), "state is kept")
      #expect(FileManager.default.fileExists(atPath: workDirectory), "the work directory is still there")

      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workDirectory)
      try fixture.session.cleanup()
      #expect(!FileManager.default.fileExists(atPath: workDirectory), "the work directory is removed")
      #expect(!FileManager.default.fileExists(atPath: fixture.statePath), "state is removed")
    }
  }

  @Test("release signing: a private file that already exists is refused and left alone") func aPrivateFileThatAlreadyExists() throws {
    try withFixture { fixture in
      let path = fixture.temp + "/existing"
      try "earlier".write(toFile: path, atomically: true, encoding: .utf8)
      let message = try #require(throws: Failure.self) {
        try fixture.session.writePrivateFile(path, Data("new".utf8))
      }.message
      #expect(message == "cannot write existing", "got: \(message)")
      #expect(FileManager.default.contents(atPath: path) == Data("earlier".utf8), "the file is untouched")

      // A state file that appears after setup looked for one belongs to another run.
      fixture.runner.onRun = { command in
        guard command == ["security", "list-keychains", "-d", "user"] else { return }
        try "another run".write(toFile: fixture.statePath, atomically: true, encoding: .utf8)
      }
      #expect(throws: Failure.self) { try fixture.session.setup() }
      #expect(FileManager.default.contents(atPath: fixture.statePath) == Data("another run".utf8),
                 "the other run's state is untouched")
      #expect(fixture.signingDirectories.isEmpty, "the work directory is removed")
      #expect(fixture.lines.isEmpty, "nothing is emitted")
    }
  }

  @Test("release signing: cleanup refuses a state file that points outside RUNNER_TEMP") func cleanupRefusesAStateFileThat() throws {
    try withFixture { fixture in
      let list = "[\"/tmp/login.keychain-db\"]"
      let outside = "{\"work_dir\":\"/tmp/terminal-signing-x\",\"keychain\":\"/tmp/terminal-signing-x/signing.keychain-db\",\"search_list\":\(list)}"
      let escaping = "{\"work_dir\":\"\(fixture.temp)/terminal-signing-x/../..\",\"keychain\":\"\(fixture.temp)/terminal-signing-x/../../signing.keychain-db\",\"search_list\":\(list)}"
      let renamed = "{\"work_dir\":\"\(fixture.temp)/other\",\"keychain\":\"\(fixture.temp)/other/signing.keychain-db\",\"search_list\":\(list)}"
      for text in [outside, escaping, renamed, "not json"] {
        try text.write(toFile: fixture.statePath, atomically: true, encoding: .utf8)
        let message = try #require(throws: Failure.self) { try fixture.session.cleanup() }.message
        #expect(message == "release signing state is invalid", "got: \(message)")
      }
      #expect(fixture.runner.commands.isEmpty, "no command ran")
    }
  }

  @Test("release signing: the keychain list is split like shell words") func theKeychainListIsSplitLike() throws {
    #expect(ReleaseSigning.shellSplit("    \"/Users/a b/login.keychain-db\"\n    \"/Library/Keychains/System.keychain\"\n")
                 ?? [] == ["/Users/a b/login.keychain-db", "/Library/Keychains/System.keychain"], "quoted lines")
    #expect(ReleaseSigning.shellSplit("a\\ b 'c d'\"e\\\"f\" ''") ?? [] == ["a b", "c de\"f", ""], "escapes and joins")
    #expect(ReleaseSigning.shellSplit("  \n") ?? ["x"] == [], "blank output has no words")
    #expect(ReleaseSigning.shellSplit("\"unterminated") == nil, "an unmatched quote is refused")
    #expect(ReleaseSigning.lexicalPath("/a/./b/../c/") == "/a/c", "paths are resolved by name")
  }

  @Test("release signing: a failed command is named and nothing else") func aFailedCommandIsNamedAnd() throws {
    let message = try #require(throws: Failure.self) {
      try ReleaseSigning.Runner.system.run(["sh", "-c", "echo printed-detail; echo more >&2; exit 1", "argument-detail"])
    }.message
    #expect(message == "sh -c failed", "got: \(message)")
  }

}

// Tests. No command is ever run: the recorder stands in for `security` and
// `notarytool`, and every path is inside a temporary directory.

/// Records each command and fails or observes the ones a test selects.
final class FakeRunner {
  var commands: [[String]] = []
  var failOn: (([String]) -> Bool)?
  var onRun: (([String]) throws -> Void)?
  var searchList = ["/tmp/login.keychain-db"]

  var runner: ReleaseSigning.Runner {
    ReleaseSigning.Runner(
      run: { command in
        self.commands.append(command)
        try self.onRun?(command)
        try self.failIfNeeded(command)
      },
      output: { command in
        self.commands.append(command)
        try self.onRun?(command)
        try self.failIfNeeded(command)
        guard command.dropFirst().first == "list-keychains" else { return "" }
        return self.searchList.map { "\"\($0)\"" }.joined(separator: "\n") + "\n"
      })
  }

  private func failIfNeeded(_ command: [String]) throws {
    if failOn?(command) == true { throw Failure("fake command failure") }
  }

  var restores: [[String]] { commands.filter { $0.starts(with: ["security", "list-keychains", "-d", "user", "-s"]) } }
}

/// A setup in a temporary `RUNNER_TEMP` with counting "random" values.
private final class Fixture {
  let temp: String
  let runner = FakeRunner()
  var environment: [String: String]
  var lines: [String] = []
  var statePath: String { temp + "/" + ReleaseSigning.stateName }

  init(temp: String) {
    self.temp = temp
    func encoded(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    environment = [
      "RUNNER_TEMP": temp,
      "APPLE_APPLICATION_CERTIFICATE_BASE64": encoded("application-certificate-data"),
      "APPLE_APPLICATION_CERTIFICATE_PASSWORD": "application-password",
      "APPLE_INSTALLER_CERTIFICATE_BASE64": encoded("installer-certificate-data"),
      "APPLE_INSTALLER_CERTIFICATE_PASSWORD": "installer-password",
      "APPLE_NOTARY_KEY_BASE64": encoded("notary-key-data"),
      "APPLE_NOTARY_KEY_ID": "ABCDEFGHIJ",
      "APPLE_NOTARY_ISSUER_ID": "issuer-id",
      "APPLE_APPLICATION_SIGNING_IDENTITY": "Developer ID Application: Example",
      "APPLE_INSTALLER_SIGNING_IDENTITY": "Developer ID Installer: Example",
      "APPLE_TEAM_ID": "TEAMID1234",
    ]
  }

  /// One session keeps one counter, as one run of the tool would.
  lazy var session: ReleaseSigning.Session = {
    var index = 0
    return ReleaseSigning.Session(environment: environment, runner: runner.runner, emit: { self.lines.append($0) },
                   randomHex: { _ in
                     index += 1
                     return fixedHex(index)
                   })
  }()

  func state() throws -> [String: Any] { try readJSONObject(statePath) }
  var signingDirectories: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: temp)) ?? [])
      .filter { $0.hasPrefix("terminal-signing-") && $0 != ReleaseSigning.stateName }
  }
}

private func fixedHex(_ index: Int) -> String {
  let digits = String(index, radix: 16)
  return String(repeating: "0", count: 64 - digits.count) + digits
}

private func withFixture(_ body: (Fixture) throws -> Void) throws {
  try withTemporaryDirectory("dev-release-signing-") { try body(Fixture(temp: ReleaseSigning.lexicalPath($0))) }
}

private func mode(_ path: String) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
