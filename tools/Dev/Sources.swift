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
      try check(files: swiftFiles(), root: Repository.root)
    default:
      throw Failure.usage(command)
    }
  }

  /// Keep file scopes separate (several tools have a main.swift), but amortize
  /// compiler startup across at most three workers. Report errors in file order.
  static func check(files: [String], root: String) throws {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 3
    final class Failures: @unchecked Sendable {
      private let lock = NSLock()
      private var values: [String: String] = [:]
      func record(_ file: String, _ message: String) { lock.lock(); values[file] = message; lock.unlock() }
      var snapshot: [String: String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    let collected = Failures()
    for file in files {
      queue.addOperation {
        do {
          let result = try runCommand(["/usr/bin/xcrun", "swiftc", "-frontend", "-parse", file], directory: root)
          if !result.succeeded {
            collected.record(file, result.output)
          }
        } catch {
          collected.record(file, String(describing: error))
        }
      }
    }
    queue.waitUntilAllOperationsAreFinished()
    let failures = collected.snapshot
    if !failures.isEmpty {
      throw Failure(files.compactMap { file in failures[file].map { "Swift syntax failed: \(file)\n\($0)" } }
        .joined(separator: "\n"))
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
