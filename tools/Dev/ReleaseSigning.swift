import Foundation
import Security

/// Prepares an isolated keychain for a CI release, and removes it again.
///
/// All secrets stay in memory or in a private directory under `RUNNER_TEMP`.
/// The state file holds only what cleanup needs to restore the keychain
/// search list: no password, certificate or key is written to it.
enum ReleaseSigning {
  static let command = Command(
    name: "release-signing", usage: "setup|cleanup",
    summary: "Create the temporary release keychain and notary profile in CI, or remove them.",
    run: run)

  static let stateName = "terminal-signing-state.json"
  static let requiredEnvironment = [
    "APPLE_APPLICATION_CERTIFICATE_BASE64",
    "APPLE_APPLICATION_CERTIFICATE_PASSWORD",
    "APPLE_INSTALLER_CERTIFICATE_BASE64",
    "APPLE_INSTALLER_CERTIFICATE_PASSWORD",
    "APPLE_NOTARY_KEY_BASE64",
    "APPLE_NOTARY_KEY_ID",
    "APPLE_NOTARY_ISSUER_ID",
    "APPLE_APPLICATION_SIGNING_IDENTITY",
    "APPLE_INSTALLER_SIGNING_IDENTITY",
    "APPLE_TEAM_ID",
  ]

  static func run(_ arguments: [String]) throws {
    let session = Session(environment: ProcessInfo.processInfo.environment, runner: .system,
                          emit: { print($0) }, randomHex: secureRandomHex)
    switch arguments.first {
    case "setup": try session.setup()
    case "cleanup": try session.cleanup()
    default: throw Failure.usage(command)
    }
  }

  /// How `security` and `notarytool` are run. Tests substitute a recorder.
  struct Runner {
    /// Runs a command and fails unless it succeeds.
    let run: ([String]) throws -> Void
    /// Runs a command and returns its standard output.
    let output: ([String]) throws -> String

    static let system = Runner(
      run: { _ = try checked($0) },
      output: { try checked($0).output })

    /// Arguments can contain passwords. Neither they nor the command's output
    /// go into a message that GitHub Actions could print.
    private static func checked(_ command: [String]) throws -> CommandResult {
      let result = try runCommand(command)
      guard result.succeeded else { throw Failure(command.prefix(2).joined(separator: " ") + " failed") }
      return result
    }
  }

  /// What cleanup needs to undo a setup.
  struct State {
    let workDirectory: String
    let keychain: String
    let searchList: [String]

    var json: String {
      JSONText.object([
        ("work_dir", .string(workDirectory)),
        ("keychain", .string(keychain)),
        ("search_list", .array(searchList.map(JSONText.string))),
      ]).compact
    }
  }

  /// The decoded inputs of a setup.
  struct Inputs {
    let applicationCertificate: Data
    let applicationPassword: String
    let installerCertificate: Data
    let installerPassword: String
    let notaryKey: Data
    let notaryKeyID: String
    let notaryIssuerID: String
  }

  struct Session {
    let environment: [String: String]
    let runner: Runner
    /// Receives each line of setup's standard output.
    let emit: (String) -> Void
    /// Returns the hex form of that many random bytes.
    let randomHex: (Int) throws -> String

    func setup() throws {
      let inputs = try validatedInputs()
      let temporary = try runnerTemp()
      if FileManager.default.fileExists(atPath: try statePath()) { try cleanup() }
      let originalSearchList = try currentSearchList()

      let workDirectory = temporary + "/terminal-signing-" + (try randomHex(16))
      let keychain = workDirectory + "/signing.keychain-db"
      let profile = "terminal-notary-" + (try randomHex(16))
      var stateWritten = false

      do {
        // A pre-existing path is never reused, even though a random collision
        // is exceptionally unlikely. The explicit chmod fixes the inherited mode.
        guard mkdir(workDirectory, 0o700) == 0, chmod(workDirectory, 0o700) == 0 else {
          throw Failure("cannot create the signing directory")
        }
        let state = State(workDirectory: workDirectory, keychain: keychain, searchList: originalSearchList)
        try writePrivateFile(try statePath(), Data(state.json.utf8))
        stateWritten = true

        // Hex avoids shell and metacharacter surprises while keeping 256 bits of entropy.
        let keychainPassword = try randomHex(32)
        try runner.run(["security", "create-keychain", "-p", keychainPassword, keychain])
        try runner.run(["security", "set-keychain-settings", "-lut", "21600", keychain])
        try runner.run(["security", "unlock-keychain", "-p", keychainPassword, keychain])
        try setSearchList([keychain] + state.searchList)

        let applicationCertificate = try writeSecret(workDirectory, "application.p12", inputs.applicationCertificate)
        let installerCertificate = try writeSecret(workDirectory, "installer.p12", inputs.installerCertificate)
        let notaryKey = try writeSecret(workDirectory, "notary-key.p8", inputs.notaryKey)

        try importCertificate(applicationCertificate, inputs.applicationPassword, keychain)
        try delete(applicationCertificate)
        try importCertificate(installerCertificate, inputs.installerPassword, keychain)
        try delete(installerCertificate)
        try runner.run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
                        "-k", keychainPassword, keychain])
        try runner.run(["xcrun", "notarytool", "store-credentials", profile,
                        "--key", notaryKey,
                        "--key-id", inputs.notaryKeyID,
                        "--issuer", inputs.notaryIssuerID,
                        "--keychain", keychain])
        try delete(notaryKey)

        // These are the only lines setup writes to standard output, so a
        // caller can append them to GITHUB_ENV without a secret landing there.
        emit("APPLE_NOTARY_PROFILE=\(profile)")
        emit("APPLE_SIGNING_KEYCHAIN=\(keychain)")
      } catch {
        if stateWritten {
          // The setup error is the one reported. State stays for a later
          // explicit cleanup if restoring the search list failed.
          try? cleanup()
        } else {
          if let state = try? statePath() { try? FileManager.default.removeItem(atPath: state) }
          try? FileManager.default.removeItem(atPath: workDirectory)
        }
        throw error
      }
    }

    func cleanup() throws {
      guard let state = try readState() else { return }
      var failed = false

      do { try setSearchList(state.searchList) } catch { failed = true }

      do { try runner.run(["security", "delete-keychain", state.keychain]) } catch {
        // An earlier interrupted cleanup may already have deleted it. The
        // missing file is then a successful, idempotent outcome.
        if FileManager.default.fileExists(atPath: state.keychain) { failed = true }
      }

      try? FileManager.default.removeItem(atPath: state.workDirectory)

      guard !failed else { throw Failure("release signing cleanup failed") }
      try? FileManager.default.removeItem(atPath: try statePath())
    }

    private func validatedInputs() throws -> Inputs {
      let missing = requiredEnvironment.filter { (environment[$0] ?? "").isEmpty }
      guard missing.isEmpty else {
        throw Failure("missing required environment variables: " + missing.joined(separator: ", "))
      }
      return Inputs(
        applicationCertificate: try decodeBase64("APPLE_APPLICATION_CERTIFICATE_BASE64"),
        applicationPassword: environment["APPLE_APPLICATION_CERTIFICATE_PASSWORD"] ?? "",
        installerCertificate: try decodeBase64("APPLE_INSTALLER_CERTIFICATE_BASE64"),
        installerPassword: environment["APPLE_INSTALLER_CERTIFICATE_PASSWORD"] ?? "",
        notaryKey: try decodeBase64("APPLE_NOTARY_KEY_BASE64"),
        notaryKeyID: environment["APPLE_NOTARY_KEY_ID"] ?? "",
        notaryIssuerID: environment["APPLE_NOTARY_ISSUER_ID"] ?? "")
    }

    /// Strict base64: no line breaks, full padding and canonical final bits,
    /// which re-encoding the result checks.
    private func decodeBase64(_ name: String) throws -> Data {
      let text = environment[name] ?? ""
      guard let decoded = Data(base64Encoded: text), !decoded.isEmpty, decoded.base64EncodedString() == text else {
        throw Failure("\(name) must contain non-empty strict base64")
      }
      return decoded
    }

    private func runnerTemp() throws -> String {
      guard let value = environment["RUNNER_TEMP"], !value.isEmpty else { throw Failure("RUNNER_TEMP must be set") }
      let path = absolutePath(value)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw Failure("RUNNER_TEMP must name an existing directory")
      }
      return path
    }

    private func statePath() throws -> String { try runnerTemp() + "/" + stateName }

    private func currentSearchList() throws -> [String] {
      let output = try runner.output(["security", "list-keychains", "-d", "user"])
      guard let words = shellSplit(output) else { throw Failure("security returned an invalid keychain search list") }
      guard !words.isEmpty else { throw Failure("security keychain search list is empty") }
      return words.map(absolutePath)
    }

    private func setSearchList(_ paths: [String]) throws {
      try runner.run(["security", "list-keychains", "-d", "user", "-s"] + paths)
    }

    /// The recorded state, or nil when no setup is outstanding. A state that
    /// does not describe a directory this tool made under `RUNNER_TEMP` is
    /// refused, so cleanup can never be pointed at another path.
    private func readState() throws -> State? {
      let path = try statePath()
      guard FileManager.default.fileExists(atPath: path) else { return nil }
      let invalid = Failure("release signing state is invalid")
      guard let data = FileManager.default.contents(atPath: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let workDirectory = object["work_dir"] as? String,
            let keychain = object["keychain"] as? String,
            let searchList = object["search_list"] as? [String] else { throw invalid }
      guard absolutePath(workDirectory).hasPrefix(try runnerTemp() + "/"),
            lastComponent(workDirectory).hasPrefix("terminal-signing-"),
            keychain == joined(workDirectory, "signing.keychain-db") else { throw invalid }
      return State(workDirectory: workDirectory, keychain: keychain, searchList: searchList)
    }

    private func writeSecret(_ directory: String, _ name: String, _ contents: Data) throws -> String {
      let path = directory + "/" + name
      try writePrivateFile(path, contents)
      return path
    }

    /// The file never exists with the default, possibly group-readable, mode,
    /// and `O_EXCL` refuses a path this run did not make.
    private func writePrivateFile(_ path: String, _ contents: Data) throws {
      let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      var written = descriptor >= 0
      if written {
        written = contents.withUnsafeBytes { buffer -> Bool in
          var offset = 0
          while offset < buffer.count {
            let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            if count <= 0 { return false }
            offset += count
          }
          return true
        }
        written = close(descriptor) == 0 && written
      }
      guard written else {
        try? FileManager.default.removeItem(atPath: path)
        throw Failure("cannot write \(lastComponent(path))")
      }
    }

    private func delete(_ path: String) throws {
      guard unlink(path) == 0 else { throw Failure("cannot delete \(lastComponent(path))") }
    }

    private func importCertificate(_ path: String, _ password: String, _ keychain: String) throws {
      try runner.run(["security", "import", path, "-k", keychain, "-P", password,
                      "-T", "/usr/bin/codesign", "-T", "/usr/bin/pkgbuild", "-T", "/usr/bin/productsign"])
    }
  }

  /// Hex of `count` bytes from the system's secure generator.
  static func secureRandomHex(_ count: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
      throw Failure("cannot generate random bytes")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// An absolute path with `~`, `.` and `..` resolved by name only. Symbolic
  /// links are left alone, so a path compares equal to the one a setup stored.
  static func absolutePath(_ path: String) -> String {
    var path = path
    if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
    if !path.hasPrefix("/") { path = FileManager.default.currentDirectoryPath + "/" + path }
    var parts: [Substring] = []
    for part in path.split(separator: "/") where part != "." {
      if part == ".." { _ = parts.popLast() } else { parts.append(part) }
    }
    return "/" + parts.joined(separator: "/")
  }

  /// The final name in a path, ignoring trailing slashes.
  static func lastComponent(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? "/"
  }

  /// `name` under `directory`, with exactly one slash between them.
  static func joined(_ directory: String, _ name: String) -> String {
    var directory = Substring(directory)
    while directory.hasSuffix("/") { directory.removeLast() }
    return directory + "/" + name
  }

  /// Splits text into words as a POSIX shell would, which is how `security`
  /// quotes the paths it lists. Returns nil for an unmatched quote.
  static func shellSplit(_ text: String) -> [String]? {
    let scalars = Array(text.unicodeScalars)
    let spaces: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]
    var words: [String] = []
    var word = String.UnicodeScalarView()
    var inWord = false
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      index += 1
      if spaces.contains(scalar) {
        if inWord { words.append(String(word)) }
        word = String.UnicodeScalarView()
        inWord = false
        continue
      }
      inWord = true
      switch scalar {
      case "'":
        guard let end = scalars[index...].firstIndex(of: "'") else { return nil }
        word.append(contentsOf: scalars[index..<end])
        index = end + 1
      case "\"":
        var closed = false
        while index < scalars.count, !closed {
          let inner = scalars[index]
          index += 1
          if inner == "\"" {
            closed = true
          } else if inner == "\\" {
            guard index < scalars.count else { return nil }
            // Inside double quotes a backslash escapes only these characters.
            if !["$", "`", "\"", "\\", "\n"].contains(scalars[index]) { word.append(inner) }
            word.append(scalars[index])
            index += 1
          } else {
            word.append(inner)
          }
        }
        guard closed else { return nil }
      case "\\":
        if index < scalars.count, scalars[index] != "\n" {
          word.append(scalars[index])
          index += 1
        } else {
          word.append(scalar)
        }
      default:
        word.append(scalar)
      }
    }
    if inWord { words.append(String(word)) }
    return words
  }

  // Tests. No command is ever run: the recorder stands in for `security` and
  // `notarytool`, and every path is inside a temporary directory.

  /// Records each command and fails or observes the ones a test selects.
  final class FakeRunner {
    var commands: [[String]] = []
    var failOn: (([String]) -> Bool)?
    var onRun: (([String]) throws -> Void)?
    let searchList = ["/tmp/login.keychain-db"]

    var runner: Runner {
      Runner(
        run: { command in
          self.commands.append(command)
          try self.onRun?(command)
          try self.failIfNeeded(command)
        },
        output: { command in
          self.commands.append(command)
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
    var statePath: String { temp + "/" + stateName }

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
    lazy var session: Session = {
      var index = 0
      return Session(environment: environment, runner: runner.runner, emit: { self.lines.append($0) },
                     randomHex: { _ in
                       index += 1
                       return fixedHex(index)
                     })
    }()

    func state() throws -> [String: Any] { try readJSONObject(statePath) }
    var signingDirectories: [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: temp)) ?? []).filter { $0.hasPrefix("terminal-signing-") }
    }
  }

  private static func fixedHex(_ index: Int) -> String {
    let digits = String(index, radix: 16)
    return String(repeating: "0", count: 64 - digits.count) + digits
  }

  private static func withFixture(_ body: (Fixture) throws -> Void) throws {
    try withTemporaryDirectory("dev-release-signing-") { try body(Fixture(temp: absolutePath($0))) }
  }

  private static func mode(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }

  static let tests = [
    SelfTest.Case(name: "release signing: missing variables are rejected before any command or file is created") {
      try withFixture { fixture in
        fixture.environment["APPLE_TEAM_ID"] = nil
        let message = try failureMessage("a missing variable") { try fixture.session.setup() }
        try expect(message.contains("APPLE_TEAM_ID"), "got: \(message)")
        try expect(fixture.runner.commands.isEmpty, "no command ran")
        try expect(!FileManager.default.fileExists(atPath: fixture.statePath), "no state file")
      }
    },
    SelfTest.Case(name: "release signing: invalid base64 is rejected before any command") {
      try withFixture { fixture in
        fixture.environment["APPLE_NOTARY_KEY_BASE64"] = "not base64!"
        let message = try failureMessage("invalid base64") { try fixture.session.setup() }
        try expect(message.contains("APPLE_NOTARY_KEY_BASE64"), "got: \(message)")
        try expect(fixture.runner.commands.isEmpty, "no command ran")
      }
    },
    SelfTest.Case(name: "release signing: setup uses the expected argv, writes private files and emits only env assignments") {
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
          observed[lastComponent(path)] = "\(contents) \(String(try mode(path), radix: 8))"
        }

        try fixture.session.setup()

        let state = try fixture.state()
        let keychain = state["keychain"] as? String ?? ""
        let workDirectory = state["work_dir"] as? String ?? ""
        let commands = fixture.runner.commands
        try expect(try mode(fixture.statePath) == 0o600, "state file is private")
        try expect(try mode(workDirectory) == 0o700, "work directory is private")
        try expect(observed["application.p12"] == "application-certificate-data 600", "application certificate")
        try expect(observed["installer.p12"] == "installer-certificate-data 600", "installer certificate")
        try expect(observed["notary-key.p8"] == "notary-key-data 600", "notary key")
        try expect(fixture.lines == ["APPLE_NOTARY_PROFILE=terminal-notary-\(fixedHex(2))",
                                     "APPLE_SIGNING_KEYCHAIN=\(keychain)"], "got: \(fixture.lines)")
        let output = fixture.lines.joined(separator: "\n")
        try expect(!["password", "certificate-data", "notary-key-data"].contains { output.contains($0) },
                   "no secret is emitted")
        try expect(String(decoding: FileManager.default.contents(atPath: fixture.statePath) ?? Data(), as: UTF8.self)
                     == "{\"work_dir\":\"\(workDirectory)\",\"keychain\":\"\(keychain)\","
                     + "\"search_list\":[\"/tmp/login.keychain-db\"]}", "state file text")

        try expect(commands.contains(["security", "create-keychain", "-p", fixedHex(3), keychain]), "create-keychain")
        try expect(commands.contains(["security", "set-keychain-settings", "-lut", "21600", keychain]), "settings")
        try expect(commands.contains(["security", "unlock-keychain", "-p", fixedHex(3), keychain]), "unlock")
        try expect(commands.contains(["security", "list-keychains", "-d", "user", "-s", keychain,
                                      "/tmp/login.keychain-db"]), "search list gains the keychain")
        let imports = commands.filter { $0.starts(with: ["security", "import"]) }
        try expect(imports.count == 2, "two imports")
        for command in imports {
          let tools = command.indices.filter { command[$0] == "-T" }.map { command[$0 + 1] }
          try expect(tools == ["/usr/bin/codesign", "/usr/bin/pkgbuild", "/usr/bin/productsign"], "got: \(tools)")
        }
        try expect(commands.contains(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                                      "-s", "-k", fixedHex(3), keychain]), "partition list")
        let notary = commands.first { $0.starts(with: ["xcrun", "notarytool", "store-credentials"]) }
        try expect(notary == ["xcrun", "notarytool", "store-credentials", "terminal-notary-\(fixedHex(2))",
                              "--key", workDirectory + "/notary-key.p8", "--key-id", "ABCDEFGHIJ",
                              "--issuer", "issuer-id", "--keychain", keychain], "got: \(notary ?? [])")
        for name in ["notary-key.p8", "application.p12", "installer.p12"] {
          try expect(!FileManager.default.fileExists(atPath: workDirectory + "/" + name), "\(name) is deleted")
        }
      }
    },
    SelfTest.Case(name: "release signing: a setup failure restores the search list and removes state") {
      try withFixture { fixture in
        fixture.runner.failOn = { $0.starts(with: ["security", "import"]) }
        _ = try failureMessage("a failed import") { try fixture.session.setup() }

        try expect(!FileManager.default.fileExists(atPath: fixture.statePath), "state is removed")
        try expect(fixture.signingDirectories.isEmpty, "work directory is removed")
        try expect(fixture.runner.commands.contains { $0.starts(with: ["security", "delete-keychain"]) },
                   "keychain is deleted")
        try expect(fixture.runner.restores.last == ["security", "list-keychains", "-d", "user", "-s",
                                                    "/tmp/login.keychain-db"], "search list is restored")
        try expect(fixture.lines.isEmpty, "nothing is emitted")
      }
    },
    SelfTest.Case(name: "release signing: cleanup retains state for a retry when it cannot restore the search list") {
      try withFixture { fixture in
        try fixture.session.setup()
        fixture.runner.failOn = {
          $0.starts(with: ["security", "list-keychains", "-d", "user", "-s"]) && $0.last == "/tmp/login.keychain-db"
        }
        _ = try failureMessage("a failed restore") { try fixture.session.cleanup() }
        try expect(FileManager.default.fileExists(atPath: fixture.statePath), "state is kept")

        fixture.runner.failOn = nil
        try fixture.session.cleanup()
        try expect(!FileManager.default.fileExists(atPath: fixture.statePath), "state is removed")
      }
    },
    SelfTest.Case(name: "release signing: cleanup is idempotent and restores the original search list") {
      try withFixture { fixture in
        try fixture.session.setup()
        let state = try fixture.state()
        let keychain = state["keychain"] as? String ?? ""
        try Data().write(to: URL(fileURLWithPath: keychain))

        try fixture.session.cleanup()
        try fixture.session.cleanup()

        try expect(!FileManager.default.fileExists(atPath: fixture.statePath), "state is removed")
        try expect(!FileManager.default.fileExists(atPath: state["work_dir"] as? String ?? ""), "work directory is removed")
        try expect(fixture.runner.commands.contains(["security", "delete-keychain", keychain]), "keychain is deleted")
        try expect(fixture.runner.restores.last == ["security", "list-keychains", "-d", "user", "-s",
                                                    "/tmp/login.keychain-db"], "search list is restored")
      }
    },
    SelfTest.Case(name: "release signing: cleanup refuses a state file that points outside RUNNER_TEMP") {
      try withFixture { fixture in
        let outside = "{\"work_dir\":\"/tmp/terminal-signing-x\",\"keychain\":\"/tmp/terminal-signing-x/signing.keychain-db\",\"search_list\":[]}"
        let escaping = "{\"work_dir\":\"\(fixture.temp)/terminal-signing-x/../..\",\"keychain\":\"\(fixture.temp)/terminal-signing-x/../../signing.keychain-db\",\"search_list\":[]}"
        let renamed = "{\"work_dir\":\"\(fixture.temp)/other\",\"keychain\":\"\(fixture.temp)/other/signing.keychain-db\",\"search_list\":[]}"
        for text in [outside, escaping, renamed, "not json"] {
          try text.write(toFile: fixture.statePath, atomically: true, encoding: .utf8)
          let message = try failureMessage("a foreign state file") { try fixture.session.cleanup() }
          try expect(message == "release signing state is invalid", "got: \(message)")
        }
        try expect(fixture.runner.commands.isEmpty, "no command ran")
      }
    },
    SelfTest.Case(name: "release signing: the keychain list is split like shell words") {
      try expect(shellSplit("    \"/Users/a b/login.keychain-db\"\n    \"/Library/Keychains/System.keychain\"\n")
                   ?? [] == ["/Users/a b/login.keychain-db", "/Library/Keychains/System.keychain"], "quoted lines")
      try expect(shellSplit("a\\ b 'c d'\"e\\\"f\" ''") ?? [] == ["a b", "c de\"f", ""], "escapes and joins")
      try expect(shellSplit("  \n") ?? ["x"] == [], "blank output has no words")
      try expect(shellSplit("\"unterminated") == nil, "an unmatched quote is refused")
      try expect(absolutePath("/a/./b/../c/") == "/a/c", "paths are resolved by name")
    },
  ]
}
