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
      let result = try runCommand(command, errors: .separate)
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
      JSONValue.object([
        ("work_dir", .string(workDirectory)),
        ("keychain", .string(keychain)),
        ("search_list", .strings(searchList)),
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
          // No state file here is this run's: a failed write removes its own.
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

      do { try FileManager.default.removeItem(atPath: state.workDirectory) } catch {
        // An earlier interrupted cleanup may already have removed it.
        if FileManager.default.fileExists(atPath: state.workDirectory) { failed = true }
      }

      // The state stays after a failure, so that cleanup can be run again.
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
      let path = lexicalPath(value)
      guard isDirectory(path) else { throw Failure("RUNNER_TEMP must name an existing directory") }
      return path
    }

    private func statePath() throws -> String { try runnerTemp() + "/" + stateName }

    private func currentSearchList() throws -> [String] {
      let output = try runner.output(["security", "list-keychains", "-d", "user"])
      guard let words = shellSplit(output) else { throw Failure("security returned an invalid keychain search list") }
      guard !words.isEmpty else { throw Failure("security keychain search list is empty") }
      return words.map(lexicalPath)
    }

    private func setSearchList(_ paths: [String]) throws {
      try runner.run(["security", "list-keychains", "-d", "user", "-s"] + paths)
    }

    /// The recorded state, or nil when no setup is outstanding. A state that
    /// does not describe a directory this tool made under `RUNNER_TEMP` is
    /// refused, so cleanup can never be pointed at another path. So is one
    /// without a search list: restoring it would leave the user with no keychains.
    private func readState() throws -> State? {
      let path = try statePath()
      guard FileManager.default.fileExists(atPath: path) else { return nil }
      let invalid = Failure("release signing state is invalid")
      guard let data = FileManager.default.contents(atPath: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let workDirectory = object["work_dir"] as? String,
            let keychain = object["keychain"] as? String,
            let searchList = object["search_list"] as? [String] else { throw invalid }
      guard lexicalPath(workDirectory).hasPrefix(try runnerTemp() + "/"),
            lastComponent(workDirectory).hasPrefix("terminal-signing-"),
            keychain == joined(workDirectory, "signing.keychain-db"), !searchList.isEmpty else { throw invalid }
      return State(workDirectory: workDirectory, keychain: keychain, searchList: searchList)
    }

    private func writeSecret(_ directory: String, _ name: String, _ contents: Data) throws -> String {
      let path = directory + "/" + name
      try writePrivateFile(path, contents)
      return path
    }

    /// The file never exists with the default, possibly group-readable, mode,
    /// and `O_EXCL` refuses a path this run did not make. Such a path is left
    /// as it was; only a file this call created is removed when writing it fails.
    func writePrivateFile(_ path: String, _ contents: Data) throws {
      let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      guard descriptor >= 0 else { throw Failure("cannot write \(lastComponent(path))") }
      var written = contents.withUnsafeBytes { buffer -> Bool in
        var offset = 0
        while offset < buffer.count {
          let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
          if count <= 0 { return false }
          offset += count
        }
        return true
      }
      written = close(descriptor) == 0 && written
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
  static func lexicalPath(_ path: String) -> String {
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
}
