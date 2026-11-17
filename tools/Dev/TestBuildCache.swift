import Foundation

/// A fresh checkout changes source mtimes even when its bytes match the build
/// cache. Restore only timestamps recorded for byte-identical, tracked files.
/// Changed/new inputs retain their timestamps and SwiftPM still checks its graph,
/// compiler options and dependencies normally.
enum TestBuildCache {
  static let command = Command(name: "test-cache", usage: "record|restore",
    summary: "Preserve content-verified source timestamps for incremental test builds.", run: run)

  struct Entry: Codable {
    let path: String
    let digest: String
    let seconds: Int
    let nanoseconds: Int
  }
  struct Manifest: Codable {
    let schema: Int
    let root: String
    let files: [Entry]
  }

  static func run(_ arguments: [String]) throws {
    guard arguments.count == 1, ["record", "restore"].contains(arguments[0]) else { throw Failure.usage(command) }
    let root = FileManager.default.currentDirectoryPath
    let result = try runCommand(["git", "ls-files", "-z", "--", "Package.swift", "Package.resolved",
      "Sources", "Tests", "tools", "Resources", "Benchmarks", "assets", "justfile"], directory: root)
    guard result.succeeded else { throw Failure("cannot enumerate test build inputs") }
    let paths = result.output.split(separator: "\0").map(String.init)
    let state = root + "/target/swiftpm/testing/source-state.json"
    if arguments[0] == "record" {
      try record(root: root, paths: paths, state: state)
    } else {
      print("Test cache: restored timestamps for \(try restore(root: root, paths: paths, state: state)) unchanged inputs")
    }
  }

  private static func regularFile(_ path: String, root: String) -> stat? {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
    let full = root + "/" + path
    guard URL(fileURLWithPath: full).resolvingSymlinksInPath().path.hasPrefix(root + "/") else { return nil }
    var info = stat()
    guard lstat(full, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    return info
  }

  static func record(root: String, paths: [String], state: String) throws {
    let files = try paths.compactMap { path -> Entry? in
      guard let info = regularFile(path, root: root) else { return nil }
      return Entry(path: path, digest: try sha256(ofFile: root + "/" + path),
        seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
    let data = try JSONEncoder().encode(Manifest(schema: 1, root: root, files: files))
    try data.write(to: URL(fileURLWithPath: state), options: .atomic)
  }

  @discardableResult
  static func restore(root: String, paths: [String], state: String) throws -> Int {
    guard let data = FileManager.default.contents(atPath: state),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
      manifest.schema == 1, manifest.root == root else { return 0 }
    let tracked = Set(paths)
    var restored = 0
    for entry in manifest.files {
      guard tracked.contains(entry.path), regularFile(entry.path, root: root) != nil,
        (0..<1_000_000_000).contains(entry.nanoseconds),
        try sha256(ofFile: root + "/" + entry.path) == entry.digest else { continue }
      var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                   timespec(tv_sec: entry.seconds, tv_nsec: entry.nanoseconds)]
      guard utimensat(AT_FDCWD, root + "/" + entry.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw Failure("cannot restore cached input timestamp: \(entry.path)")
      }
      restored += 1
    }
    return restored
  }
}
