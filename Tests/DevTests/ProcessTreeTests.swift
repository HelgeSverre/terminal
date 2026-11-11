import Foundation
import Testing
@testable import dev

/// Serialized: one test changes this process's environment.
@Suite(.serialized) struct ProcessTreeTests {
  @Test("process tree: a timeout reaps a resistant app and its child, and nothing else") func aTimeoutReapsAResistantApp() throws {
    try withTemporaryDirectory("dev-process-tree-") { directory in
      let childFile = directory + "/child.pid"
      let bystander = try ProcessTree(["/bin/sleep", "30"])
      defer { bystander.cleanup() }
      // Both the shell and its child ignore the polite request.
      let tree = try ProcessTree(["/bin/sh", "-c",
        "trap '' TERM; (trap '' TERM; exec sleep 30) & echo $! > \"$0\"; wait", childFile])
      defer { tree.cleanup() }
      #expect(tree.wait(seconds: 0.5) == nil, "still running")
      let child = Int(try String(contentsOfFile: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
      #expect(tree.observedOwned(Int(tree.pid)), "owns itself")
      #expect(tree.observedOwned(child), "owns its child")
      #expect(!tree.observedOwned(Int(bystander.pid)), "does not own a bystander")
      #expect(!tree.observedOwned(nil), "owns no missing PID")
      #expect(tree.cleanup().isEmpty, "cleanup leaves no survivors")
      #expect(tree.observedOwned(child), "ownership evidence survives the child's exit")
      #expect(kill(pid_t(child!), 0) != 0, "child is gone")
      #expect(kill(bystander.pid, 0) == 0, "bystander still runs")
    }
  }

  @Test("process tree: a failure status is kept and the process reaped") func aFailureStatusIsKeptAnd() throws {
    let tree = try ProcessTree(["/bin/sh", "-c", "exit 7"])
    defer { tree.cleanup() }
    #expect(tree.wait(seconds: 2)?.code == 7, "exit code 7")
    #expect(tree.cleanup().isEmpty, "nothing survives")
  }

  @Test("process tree: an exited app does not hide a lingering child") func anExitedAppDoesNotHide() throws {
    let tree = try ProcessTree(["/bin/sh", "-c", "sleep 30 & sleep 0.4; exit 0"])
    defer { tree.cleanup() }
    #expect(tree.wait(seconds: 2)?.succeeded == true, "app exits cleanly")
    #expect(!tree.livePIDs.isEmpty, "child still listed")
    #expect(tree.cleanup().isEmpty, "cleanup ends the child")
  }

  @Test("process tree: launched processes do not inherit colour controls") func launchedProcessesDoNotInheritColour() throws {
    try withTemporaryDirectory("dev-process-environment-") { directory in
      for (index, key) in ProcessTree.colourControls.enumerated() { setenv(key, "parent-\(index)", 1) }
      defer { ProcessTree.colourControls.forEach { unsetenv($0) } }
      let script = ProcessTree.colourControls.map { "echo \($0)=${\($0)-<unset>}" }.joined(separator: "; ")
      func lines(_ environment: [String: String?], _ name: String) throws -> [String] {
        let log = directory + "/" + name
        let tree = try ProcessTree(["/bin/sh", "-c", script], environment: environment, output: .log(log))
        defer { tree.cleanup() }
        #expect(tree.wait(seconds: 2)?.succeeded == true, "fixture runs")
        return try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
      }
      #expect(try lines([:], "default.log") == ProcessTree.colourControls.map { "\($0)=<unset>" },
                 "all four are unset by default")
      let explicit = try lines(["NO_COLOR": "1"], "explicit.log")
      #expect(explicit.first == "NO_COLOR=1", "an explicit value is passed on")
      #expect(Array(explicit.dropFirst()) == ProcessTree.colourControls.dropFirst().map { "\($0)=<unset>" },
                 "the others stay unset")
      #expect(ProcessInfo.processInfo.environment["NO_COLOR"] == "parent-0", "the parent is untouched")
    }
  }

  @Test("process tree: output is discarded, logged together or apart, and a log is never reused") func outputIsDiscardedLoggedTogetherOr() throws {
    try withTemporaryDirectory("dev-process-output-") { directory in
      func run(_ output: ProcessTree.Output) throws {
        let tree = try ProcessTree(["/bin/sh", "-c", "echo out; echo err >&2"], output: output)
        defer { tree.cleanup() }
        #expect(tree.wait(seconds: 2)?.succeeded == true, "fixture runs")
      }
      func text(_ name: String) throws -> String { try String(contentsOfFile: directory + "/" + name, encoding: .utf8) }
      try run(.discarded)
      try run(.log(directory + "/both.log"))
      #expect(try text("both.log") == "out\nerr\n", "one log holds both streams in order")
      try run(.logs(output: directory + "/out.log", errors: directory + "/err.log"))
      #expect(try text("out.log") == "out\n" && text("err.log") == "err\n", "two logs hold one stream each")
      try "earlier run\n".write(toFile: directory + "/kept.log", atomically: true, encoding: .utf8)
      let refusals: [ProcessTree.Output] = [
        .log(directory + "/kept.log"), .logs(output: directory + "/kept.log", errors: directory + "/new.log"),
        .logs(output: directory + "/new-output.log", errors: directory + "/kept.log"),
      ]
      for output in refusals {
        let failure = try expectFailure("an existing log") { try run(output) }
        #expect(failure.message.contains("kept.log exists"), "got: \(failure.message)")
      }
      #expect(try text("kept.log") == "earlier run\n", "the earlier log is untouched")
      try run(.log(directory + "/kept.log", replacing: true))
      #expect(try text("kept.log") == "out\nerr\n", "a log is replaced only on request")
    }
  }

}
