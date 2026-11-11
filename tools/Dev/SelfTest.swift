import Foundation

/// One of the tool's own tests, as the command files still declare them.
/// They are moving to Swift Testing suites in `Tests/DevTests`; this type goes
/// when the last one has moved.
enum SelfTest {
  struct Case {
    let name: String
    let run: () throws -> Void
  }
}

