import Foundation
import Testing
@testable import dev

/// Serialized: one test changes this process's environment.
@Suite(.serialized) struct CommandTests {
  @Test("run command: output, error, status, environment and directory are kept apart") func outputErrorStatusEnvironmentAndDirectory() throws {
    try withTemporaryDirectory("dev-run-command-") { directory in
      let script = "printf out; printf err >&2; printf \"$DEV_ADDED\" > added; test -n \"$PATH\" && exit 3"
      let result = try runCommand(["sh", "-c", script], adding: ["DEV_ADDED": "value"], directory: directory,
                                  errors: .separate)
      #expect(result.output == "out" && result.error == "err", "got: \(result.output) / \(result.error)")
      #expect(result.status == 3 && !result.succeeded, "got status \(result.status)")
      #expect(try String(contentsOfFile: directory + "/added", encoding: .utf8) == "value", "variable is added")
      #expect(try runCommand(["dev-no-such-command"]).status == 127, "a missing command fails")
      let killed = try runCommand(["sh", "-c", "kill -9 $$"])
      #expect(!killed.succeeded && killed.signalled && killed.status == 137 && killed.exitStatus.isEmpty,
              "a signalled command fails")
      let large = try runCommand(
        ["sh", "-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; head -c 300000 /dev/zero | tr '\\0' y"], errors: .separate)
      #expect(large.output.count == 300_000 && large.error.count == 300_000, "large streams do not stall")
    }
  }

  @Test("run command: errors are merged or filed, input is passed and a variable can be removed") func errorsAreMergedOrFiled() throws {
    try withTemporaryDirectory("dev-run-command-streams-") { directory in
      let merged = try runCommand(["/bin/sh", "-c", "echo out; echo err >&2"])
      #expect(merged.output == "out\nerr\n" && merged.error.isEmpty, "got: \(merged.output)")
      let filed = try runCommand(["/bin/sh", "-c", "echo out; echo err >&2"], errors: .file(directory + "/errors.log"))
      #expect(filed.output == "out\n", "got: \(filed.output)")
      #expect(try String(contentsOfFile: directory + "/errors.log", encoding: .utf8) == "err\n", "errors are filed")
      #expect(try runCommand(["/bin/cat"], input: "typed").output == "typed", "input reaches the command")
      #expect(try runCommand(["/bin/cat"]).output.isEmpty, "no input is an empty input")
      #expect(try runCommand(["/usr/bin/true"], input: String(repeating: "x", count: 200_000)).succeeded,
              "a command that reads nothing does not end the tool")
      setenv("DEV_REMOVED", "set", 1)
      defer { unsetenv("DEV_REMOVED") }
      let removed = try runCommand(["/bin/sh", "-c", "echo ${DEV_REMOVED-unset}"], adding: ["DEV_REMOVED": nil])
      #expect(removed.output == "unset\n", "got: \(removed.output)")
      #expect(try runInherited(["/usr/bin/true"]) && !runInherited(["false"]), "an inherited run reports success")
      let failure = try #require(throws: Failure.self) { try runInherited([directory + "/none"]) }
      #expect(failure.message.hasPrefix("cannot run \(directory)/none"), "a program that cannot be started is an error")
    }
  }
}
