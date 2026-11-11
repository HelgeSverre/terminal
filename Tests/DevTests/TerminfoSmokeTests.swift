import Foundation
import Testing
@testable import dev

@Suite struct TerminfoSmokeTests {
  /// Runs a command that must succeed, as the smoke command's own helper does.
  private func succeed(_ command: [String]) throws {
    let result = try runCommand(command)
    guard result.succeeded else { throw Failure("\(command.joined(separator: " ")) failed:\n\(result.output)") }
  }

  /// Runs `body` with the repository's terminfo source, a database compiled
  /// from it in place of the bundle's, and a parser stand-in that prints the
  /// screens a correct parser would.
  private func withFakeProbe(alternate: Bool,
                             _ body: (String, String, String, String) throws -> Void) throws {
    try withTemporaryDirectory("dev-terminfo-smoke-") { directory in
      let source = Repository.path("Resources/Terminal/Terminal.terminfo")
      try succeed(["/usr/bin/tic", "-x", "-o", directory + "/bundle", source])
      let blank: [String: Any] = ["text": " "]
      let marked: [String: Any] = ["text": "A", "style": ["foreground": ["Indexed": 201]]]
      try writeJSON(["alternate": alternate, "rows": [["cells": [Any]()], ["cells": [blank, blank, marked]]]],
                    to: directory + "/8.json")
      try writeJSON(["rows": [["cells": TerminfoSmoke.lineDrawingOutput.map { ["text": String($0)] }]]], to: directory + "/40.json")
      try writeScript("cat > /dev/null; cat \"\(directory)/$1.json\"", to: directory + "/probe")
      try body(source, directory + "/bundle", directory + "/probe", directory)
    }
  }

  @Test("terminfo smoke: the source entry passes with a stand-in parser") func theSourceEntryPasses() throws {
    try withFakeProbe(alternate: false) { source, database, probe, directory in
      try TerminfoSmoke.run(source: source, bundleDatabase: database, probe: probe, directory: directory)
    }
  }

  @Test("terminfo smoke: a screen left on the alternate buffer fails") func aScreenLeftOnTheAlternateBufferFails() throws {
    try withFakeProbe(alternate: true) { source, database, probe, directory in
      let failure = try #require(throws: Failure.self) {
        try TerminfoSmoke.run(source: source, bundleDatabase: database, probe: probe, directory: directory)
      }
      #expect(failure.message == "tput rmcup did not restore the main screen", "got: \(failure.message)")
    }
  }

  @Test("terminfo smoke: an unsupported capability is found only as a whole name") func anUnsupportedCapabilityIsFoundOnlyAsAWholeName() throws {
    let listing = "helge-terminal|test,\n\t" + TerminfoSmoke.required.joined(separator: ",\n\t") + ",\n\t"
    try TerminfoSmoke.checkListing(listing + "blinking,\n\tXTerm=1,")
    for line in ["blink=\\E[5m,", "xenl,", "XT"] {
      let failure = try #require(throws: Failure.self) { try TerminfoSmoke.checkListing(listing + line) }
      #expect(failure.message.hasPrefix("unsupported inherited capability"), "got: \(failure.message)")
    }
    let failure = try #require(throws: Failure.self) { try TerminfoSmoke.checkListing("helge-terminal|test,\n\tam,") }
    #expect(failure.message == "missing bce in compiled entry", "got: \(failure.message)")
  }
}
