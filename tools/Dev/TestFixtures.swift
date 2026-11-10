import Foundation

/// Fails the running test unless `condition` holds.
func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String,
            file: StaticString = #fileID, line: UInt = #line) throws {
  if try !condition() { throw Failure("\(message()) (\(file):\(line))") }
}

/// A bundle whose executable is a shell script, standing in for the app in tests.
func fakeBundle(in directory: String, script: String) throws -> String {
  let bundle = directory + "/Fixture.app"
  try writeScript(script, to: bundle + "/Contents/MacOS/Terminal")
  return bundle
}

/// Runs `body` with such a bundle and the temporary directory that holds it.
func withFakeBundle(_ script: String, _ body: (_ app: String, _ root: String) throws -> Void) throws {
  try withTemporaryDirectory("dev-fake-bundle-") { root in
    try body(try fakeBundle(in: root, script: script), root)
  }
}

/// Runs `body`, which must fail, and returns its failure.
@discardableResult
func expectFailure(_ what: String, _ body: () throws -> Void) throws -> Failure {
  do { try body() } catch let failure as Failure { return failure }
  throw Failure("\(what) was accepted")
}
