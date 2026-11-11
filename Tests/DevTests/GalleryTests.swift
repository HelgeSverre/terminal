import Foundation
import Testing
@testable import dev

@Suite struct GalleryTests {
  @Test("gallery: an executable resolves from the explicit path, the search path, then the fallback") func anExecutableResolvesFromTheExplicit() throws {
    try withTemporaryDirectory("dev-gallery-resolve-") { directory in
      for name in ["first", "second", "fallback"] {
        try FileManager.default.createDirectory(atPath: directory + "/" + name, withIntermediateDirectories: true)
      }
      let second = directory + "/second/files", fallback = directory + "/fallback/files"
      try writeScript("true", to: second)
      try writeScript("true", to: fallback)
      // A directory and a file without the execute bit are passed over.
      try FileManager.default.createDirectory(atPath: directory + "/first/files", withIntermediateDirectories: true)
      let search = "\(directory)/first:\(directory)/second"
      func resolve(_ explicit: String?, _ fallback: String, _ search: String) throws -> String {
        try Gallery.resolveExecutable("files", explicit: explicit, fallback: fallback, searchPath: search)
      }
      #expect(try resolve(nil, fallback, search) == second, "the search path comes before the fallback")
      #expect(try resolve(nil, fallback, "\(directory)/first") == fallback, "the fallback is used last")
      #expect(try resolve(fallback, second, search) == fallback, "an explicit path wins")
      let refusals: [(String?, String, String)] = [(directory + "/first/files", fallback, "not an executable"),
                                                   (nil, directory + "/none", "pass --files PATH")]
      for (explicit, missing, message) in refusals {
        let failure = try #require(throws: Failure.self) {
          _ = try resolve(explicit, missing, "\(directory)/first")
        }
        #expect(failure.message.contains(message), "got: \(failure.message)")
      }
    }
  }

  @Test("gallery: panes take consecutive numbers from the shared counter") func panesTakeConsecutiveNumbersFromThe() throws {
    try withTemporaryDirectory("dev-gallery-counter-") { directory in
      let counter = directory + "/pane-counter"
      #expect(try (0..<3).map { _ in try claimPaneNumber(counter: counter) } == [0, 1, 2], "three panes count from zero")
      #expect(try String(contentsOfFile: counter, encoding: .utf8) == "3", "the counter holds the next number")
      try "8".write(toFile: counter, atomically: true, encoding: .utf8)
      let failure = try #require(throws: Failure.self) {
        _ = try claimPaneNumber(counter: counter, below: 8)
      }
      #expect(failure.message == "too many workload panes", "got: \(failure.message)")
    }
  }

  @Test("gallery: the workspace has one staged file with an unstaged change") func theWorkspaceHasOneStagedFile() throws {
    try withTemporaryDirectory("dev-gallery-workspace-") { directory in
      try Gallery.writeWorkspace(directory + "/workspace")
      let diff = try runCommand(["/usr/bin/git", "-C", directory + "/workspace", "diff", "--", "src/main.swift"])
      #expect(diff.succeeded && diff.output.contains("+print(\"Ready for focused work\")"), "the diff shows the added line")
      let status = try runCommand(["/usr/bin/git", "-C", directory + "/workspace", "status", "--porcelain"])
      #expect(status.output.contains("AM src/main.swift"), "the source is staged and changed: \(status.output)")
    }
  }

}
