import CryptoKit
import Foundation

/// Paths inside the repository this tool was built from.
enum Repository {
  static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
  static func path(_ relative: String) -> String { root + "/" + relative }
}

/// The SHA-256 of a file, as lowercase hex.
func sha256(ofFile path: String) throws -> String {
  guard let data = FileManager.default.contents(atPath: path) else { throw Failure("cannot read \(path)") }
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Reads a JSON object from a file.
func readJSONObject(_ path: String) throws -> [String: Any] {
  guard let data = FileManager.default.contents(atPath: path) else { throw Failure("cannot read \(path)") }
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw Failure("\(path) is not a JSON object")
  }
  return object
}

/// Writes a JSON value, pretty-printed with sorted keys and a final newline.
func writeJSON(_ object: Any, to path: String) throws {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: path), options: .atomic)
}

/// Runs a command to completion and returns its output and whether it succeeded.
func capture(_ command: [String], environment: [String: String]? = nil) throws -> (output: String, succeeded: Bool) {
  let process = Process()
  let pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: command[0])
  process.arguments = Array(command.dropFirst())
  process.standardOutput = pipe
  process.standardError = pipe
  if let environment { process.environment = environment }
  do { try process.run() } catch { throw Failure("cannot run \(command[0]): \(error.localizedDescription)") }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (String(decoding: data, as: UTF8.self), process.terminationStatus == 0)
}

/// A directory that exists for the length of `body` and is removed afterwards.
func withTemporaryDirectory<Result>(_ prefix: String, _ body: (String) throws -> Result) throws -> Result {
  let path = NSTemporaryDirectory() + prefix + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: path) }
  return try body(path)
}
