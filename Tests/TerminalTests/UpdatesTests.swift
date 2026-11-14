import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession

@Suite struct UpdatesTests {
  /// Only a released copy started the ordinary way looks for updates.
  @Test func onlyAReleasedCopyStartedPlainlyUpdates() {
    func updates(_ arguments: [String], key: Bool = true, released: Bool = true) -> Bool {
      Updates.updates(arguments: arguments, hasFeedKey: key, signedForRelease: released)
    }
    #expect(updates(["Terminal"]))
    #expect(!updates(["Terminal"], key: false), "a build without the feed key")
    #expect(!updates(["Terminal"], released: false), "a local, ad hoc signed build")
    #expect(!updates(["Terminal", "--execute", "/bin/cat"]), "a command run for a measurement")
    #expect(!updates(["Terminal", "--self-test", "report.json"]), "a smoke run")
  }
}
