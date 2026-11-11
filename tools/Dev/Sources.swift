import Foundation

/// Formatting and syntax checks over the repository's Swift sources.
enum Sources {
  static let command = Command(
    name: "sources", usage: "format|check",
    summary: "Format hand-written Swift in place, or check that every Swift file parses.",
    run: run)

  static let directories = ["Sources", "Tests", "tools"]

  static func run(_ arguments: [String]) throws {
    switch arguments {
    case ["format"]:
      // Generated tables keep the layout their generator gave them.
      let written = try swiftFiles().filter { try !isGenerated($0) }
      guard try runInherited(["/usr/bin/xcrun", "swift-format", "format", "--in-place"] + written) else {
        throw Failure("swift-format failed")
      }
    case ["check"]:
      for file in try swiftFiles() {
        guard try runInherited(["/usr/bin/xcrun", "swiftc", "-frontend", "-parse", file]) else {
          throw Failure("Swift syntax failed: \(file)")
        }
      }
    default:
      throw Failure.usage(command)
    }
  }

  /// Every Swift file under the source directories, relative to the repository, in order.
  static func swiftFiles(root: String = Repository.root) throws -> [String] {
    try directories.flatMap { directory -> [String] in
      guard let entries = FileManager.default.enumerator(atPath: root + "/" + directory) else {
        throw Failure("cannot list \(directory)")
      }
      return entries.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { directory + "/" + $0 }
    }.sorted()
  }

  static func isGenerated(_ file: String, root: String = Repository.root) throws -> Bool {
    guard let text = try? String(contentsOfFile: root + "/" + file, encoding: .utf8) else {
      throw Failure("cannot read \(file)")
    }
    return text.hasPrefix("// Generated")
  }
}
