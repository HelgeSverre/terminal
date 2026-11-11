import Foundation

/// A check a command runs on itself before it launches anything.
///
/// The TUI stress and rendering-proof commands compile helpers and drive
/// pseudo-terminals; before a real run they prove those pieces work here with
/// lists of these cases (`--prepare`, `--self-test`). They are part of what the
/// commands do. The tool's tests are the Swift Testing suites in
/// `Tests/DevTests`.
enum SelfTest {
  struct Case {
    let name: String
    let run: () throws -> Void
  }
}

