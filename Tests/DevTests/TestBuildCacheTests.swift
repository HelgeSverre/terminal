import Foundation
import Testing
@testable import dev

@Suite struct TestBuildCacheTests {
  @Test func onlyIdenticalTrackedFilesRegainTheirExactTimestamp() throws {
    try withTemporaryDirectory("test-build-cache-") { root in
      let paths = ["Same.swift", "Changed.swift", "Removed.swift"]
      for path in paths { try Data("original".utf8).write(to: URL(fileURLWithPath: root + "/" + path)) }
      var original = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789),
                      timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789)]
      for path in paths { #expect(utimensat(AT_FDCWD, root + "/" + path, &original, 0) == 0) }
      let state = root + "/state.json"
      try TestBuildCache.record(root: root, paths: paths, state: state)
      for path in paths { try Data((path == "Changed.swift" ? "modified" : "original").utf8)
        .write(to: URL(fileURLWithPath: root + "/" + path)) }
      try FileManager.default.removeItem(atPath: root + "/Removed.swift")
      try Data("new".utf8).write(to: URL(fileURLWithPath: root + "/New.swift"))
      let current = ["Same.swift", "Changed.swift", "New.swift"]
      #expect(try TestBuildCache.restore(root: root, paths: current, state: state) == 1)
      var info = stat()
      #expect(stat(root + "/Same.swift", &info) == 0)
      #expect(info.st_mtimespec.tv_sec == 1_700_000_000 && info.st_mtimespec.tv_nsec == 123_456_789)
      #expect(stat(root + "/Changed.swift", &info) == 0)
      #expect(info.st_mtimespec.tv_sec != 1_700_000_000)
      #expect(try String(contentsOfFile: root + "/Changed.swift", encoding: .utf8) == "modified")
      #expect(try TestBuildCache.restore(root: root, paths: [], state: state) == 0)
      #expect(try TestBuildCache.restore(root: root + "/different", paths: current, state: state) == 0)
    }
  }

  @Test func symlinksAndMalformedReceiptsAreNotRestored() throws {
    try withTemporaryDirectory("test-build-cache-invalid-") { root in
      try Data("content".utf8).write(to: URL(fileURLWithPath: root + "/Real.swift"))
      try FileManager.default.createSymbolicLink(atPath: root + "/Link.swift", withDestinationPath: "Real.swift")
      let state = root + "/state.json"
      try TestBuildCache.record(root: root, paths: ["Link.swift", "../outside"], state: state)
      #expect(try TestBuildCache.restore(root: root, paths: ["Link.swift"], state: state) == 0)
      try Data("invalid".utf8).write(to: URL(fileURLWithPath: state))
      #expect(try TestBuildCache.restore(root: root, paths: ["Real.swift"], state: state) == 0)
    }
  }
}
