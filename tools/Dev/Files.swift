import CryptoKit
import Foundation

/// Paths inside the repository this tool was built from.
enum Repository {
  static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
  static func path(_ relative: String) -> String { root + "/" + relative }
}

/// The running tool, for commands that launch it again as a fixture.
enum Tool {
  static let executable: String = {
    let running = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
      .standardizedFileURL.path
    // Under `swift test` the running program is the test runner and this code
    // sits in the test bundle; the tool is the product built beside it.
    var image = Dl_info()
    guard dladdr(#dsohandle, &image) != 0, let name = image.dli_fname else { return running }
    let path = String(cString: name)
    guard let bundle = path.range(of: ".xctest/") else { return running }
    return URL(fileURLWithPath: String(path[..<bundle.lowerBound]))
      .deletingLastPathComponent().appendingPathComponent("dev").path
  }()

  /// Writes an executable that runs one of this tool's subcommands. The app
  /// starts `SHELL` as a single path with `-l`, so a subcommand needs a file
  /// of its own. `exec` keeps the PID, so signals reach the subcommand.
  static func writeLauncher(at path: String, subcommand: [String]) throws {
    let words = ([executable] + subcommand).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    try writeScript("exec " + words.joined(separator: " ") + " \"$@\"", to: path, mode: 0o700)
  }
}

/// `path` as an absolute path, with `~` expanded and `.` and `..` removed.
/// A relative path is read against `base`, or the current directory without
/// one. Symbolic links are not resolved.
func absolutePath(_ path: String, relativeTo base: String? = nil) -> String {
  let expanded = (path as NSString).expandingTildeInPath
  guard let base else { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
  return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: base, isDirectory: true))
    .standardizedFileURL.path
}

/// The path with every symbolic link resolved, as reports record a bundle.
/// Fails when nothing exists there.
func realPath(_ path: String) throws -> String {
  guard let resolved = realpath(path, nil) else {
    throw Failure("cannot resolve \(path): \(String(cString: strerror(errno)))")
  }
  defer { free(resolved) }
  return String(cString: resolved)
}

func isDirectory(_ path: String) -> Bool {
  var directory: ObjCBool = false
  return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
}

/// Where a program named without a directory is found on PATH. Reports record
/// commands as they are written, such as `xcrun swiftc`, and launch the file this finds.
func executablePath(_ name: String) throws -> String {
  if name.contains("/") { return name }
  let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
  for directory in directories where FileManager.default.isExecutableFile(atPath: "\(directory)/\(name)") {
    return "\(directory)/\(name)"
  }
  throw Failure("\(name) is not on PATH")
}

/// The SHA-256 of some bytes, as lowercase hex.
func sha256(of data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The SHA-256 of a file, as lowercase hex.
func sha256(ofFile path: String) throws -> String {
  guard let data = FileManager.default.contents(atPath: path) else { throw Failure("cannot read \(path)") }
  return sha256(of: data)
}

func fileBytes(_ path: String) throws -> Int {
  guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber else {
    throw Failure("cannot read \(path)")
  }
  return size.intValue
}

/// The combined size of the regular files in a bundle. Symbolic links are
/// neither followed nor counted. Without `includingHidden`, names starting
/// with a dot and everything below them are left out.
func bundleBytes(_ bundle: String, includingHidden: Bool) -> Int {
  guard let walker = FileManager.default.enumerator(atPath: bundle) else { return 0 }
  var total = 0
  for case let relative as String in walker {
    if !includingHidden, relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: bundle + "/" + relative),
          attributes[.type] as? FileAttributeType == .typeRegular else { continue }
    total += (attributes[.size] as? NSNumber)?.intValue ?? 0
  }
  return total
}

/// A directory that exists for the length of `body` and is removed afterwards.
func withTemporaryDirectory<Result>(_ prefix: String, _ body: (String) throws -> Result) throws -> Result {
  let path = NSTemporaryDirectory() + prefix + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: path) }
  return try body(path)
}

/// Writes an executable script: the interpreter line, `body` and a final
/// newline. Its directory is created when missing.
func writeScript(_ body: String, to path: String, interpreter: String = "/bin/sh", mode: Int = 0o755) throws {
  do {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try ("#!" + interpreter + "\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
  } catch { throw Failure("cannot write \(path): \(error.localizedDescription)") }
}

/// Takes the next pane number from a counter file shared by every fixture of
/// one run. The file is locked, because panes start at the same time.
func claimPaneNumber(counter path: String, below limit: Int? = nil) throws -> Int {
  let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
  guard descriptor >= 0 else { throw Failure(SystemFailure("open \(path)").message) }
  defer { close(descriptor) }
  guard flock(descriptor, LOCK_EX) == 0 else { throw Failure(SystemFailure("flock \(path)").message) }
  var buffer = [UInt8](repeating: 0, count: 32)
  let count = max(read(descriptor, &buffer, buffer.count), 0)
  let text = String(decoding: buffer[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  let pane = Int(text) ?? 0
  if let limit, !(0..<limit).contains(pane) { throw Failure("too many workload panes") }
  let next = Array(String(pane + 1).utf8)
  guard ftruncate(descriptor, 0) == 0, pwrite(descriptor, next, next.count, 0) == next.count else {
    throw Failure(SystemFailure("write \(path)").message)
  }
  return pane
}
