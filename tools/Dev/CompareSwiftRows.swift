import Foundation

/// Compares row storage between two revisions of the emulator.
///
/// The same probe is compiled against the emulator sources archived from each
/// revision. The baseline's allocation charges calibrate both runs, and the
/// two traces must then be identical. Sources, binaries, logs and traces stay
/// in the report directory.
enum CompareSwiftRows {
  static let command = Command(
    name: "compare-swift-rows", usage: "BASE_REVISION CANDIDATE_REVISION NEW_REPORT_DIRECTORY",
    summary: "Compile the row storage probe against two revisions and require identical traces.",
    run: run)

  static func run(_ arguments: [String]) throws {
    guard arguments.count == 3 else { throw Failure.usage(command) }
    let output = try OutputDirectory(creating: arguments[2])
    let probe = output.file("probe.swift")
    // The report keeps the probe and the runner it was produced with.
    try copy(Repository.path("tools/RowStorageCompatibilityProbe.swift"), to: probe)
    try copy(#filePath, to: output.file("runner.swift"))
    var result: JSONValue = [
      "passed": false, "fixture_sha256": .string(try sha256(ofFile: probe)),
      "runner_sha256": .string(try sha256(ofFile: output.file("runner.swift"))), "revisions": [:],
    ]
    var failure: Failure?
    do {
      try compare(baseline: arguments[0], candidate: arguments[1], probe: probe, output: output, result: &result)
    } catch let caught as Failure {
      result["failure"] = .string(caught.message)
      failure = caught
    }
    try result.write(to: output.file("comparison.json"))
    if let failure { throw failure }
    guard result["passed"]?.truth == true else {
      throw Failure("row traces differ; see \(output.file("comparison.json"))")
    }
  }

  private static func compare(baseline: String, candidate: String, probe: String, output: OutputDirectory,
                              result: inout JSONValue) throws {
    result["compiler"] = .string(try text(["xcrun", "swiftc", "--version"], log: output.file("compiler-version.log")))
    result["macos_build"] = .string(try text(["/usr/bin/sw_vers", "-buildVersion"], log: output.file("macos-version.log")))
    for (label, revision) in [("baseline", baseline), ("candidate", candidate)] {
      let entry = try build(label, revision: revision, probe: probe, output: output)
      result["revisions"]?[label] = entry
    }
    let calibration = try JSONValue(parsing: try capture([output.file("baseline/probe")], log: output.file("calibration.log")))
    let charges = output.file("baseline-charges.json")
    try calibration.required("charges", in: "calibration output").write(to: charges)
    var traces: [String: JSONValue] = [:]
    for label in ["baseline", "candidate"] {
      let raw = try capture([output.file("\(label)/probe"), charges], log: output.file("\(label)-probe.log"))
      try raw.write(to: URL(fileURLWithPath: output.file("\(label).json")))
      traces[label] = try JSONValue(parsing: raw)
    }
    let difference = firstDifference(traces["baseline"]!, traces["candidate"]!)
    result["difference"] = difference ?? .null
    guard let records = traces["baseline"]!["records"]?.elements else { throw Failure("baseline trace has no records") }
    result["records"] = .int(records.count)
    result["passed"] = .bool(difference == nil)
    let summary: JSONValue = ["passed": result["passed"]!, "records": result["records"]!, "difference": result["difference"]!]
    print(summary.pretty)
  }

  /// Archives the emulator sources of `revision`, compiles the probe against
  /// them, and returns what the report records about the build.
  private static func build(_ label: String, revision: String, probe: String, output: OutputDirectory) throws -> JSONValue {
    func log(_ name: String) -> String { output.file("\(label)-\(name).log") }
    let commit = try text(["git", "rev-parse", "--verify", "--end-of-options", "\(revision)^{commit}"], log: log("revision"))
    let directory = output.file(label)
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let archive = directory + "/sources.tar"
    // Frozen checkpoints can precede the source-layout migration.
    let treeRoots = try text(["git", "ls-tree", "--name-only", commit], log: log("tree"))
      .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let sourceRoots = ["Sources", "Tests", "native"].filter(treeRoots.contains)
    try capture(["git", "archive", commit] + sourceRoots + ["tools/swift-sources.json"], log: log("archive"))
      .write(to: URL(fileURLWithPath: archive))
    try capture(["/usr/bin/tar", "-xf", archive, "-C", directory], log: log("extract"))
    try FileManager.default.removeItem(atPath: archive)

    let inputs = try probeInputs(graph: JSONValue(parsingFile: directory + "/tools/swift-sources.json"), directory: directory)
    let executable = directory + "/probe"
    let command = ["xcrun", "swiftc", "-swift-version", "5", "-O", "-whole-module-optimization",
                   "-target", "arm64-apple-macosx15.0", "-module-name", "RowStorageProbe",
                   "-import-objc-header", inputs.bridge] + inputs.sources
      + [probe, "-framework", "Foundation", "-framework", "CoreGraphics", "-framework", "ImageIO", "-o", executable]
    try capture(command, log: log("build"))
    let hashes = try (inputs.sources + [inputs.bridge]).map { path in
      (key: String(path.dropFirst(directory.count + 1)), value: JSONValue.string(try sha256(ofFile: path)))
    }
    return ["commit": .string(commit), "build_command": .strings(command), "inputs": .object(hashes),
            "executable_sha256": .string(try sha256(ofFile: executable))]
  }

  /// The bridging header and emulator sources named by an archived source
  /// manifest. Archived checkpoints predate the emulator naming cleanup and
  /// the move to `Sources/`, so the group name and the layout are read from
  /// the manifest itself; callers still supply only revisions.
  static func probeInputs(graph: JSONValue, directory: String) throws -> (bridge: String, sources: [String]) {
    let groups = try graph.required("tests", in: "source manifest")
    let group = groups["emulator"] != nil ? "emulator" : "swift_core"
    guard let first = try graph.required("app", in: "source manifest").elements?.first?.text else {
      throw Failure("source manifest has no app sources")
    }
    let canonical = first.hasPrefix("Sources/")
    guard let listed = try groups.required(group, in: "source manifest tests").elements else {
      throw Failure("source manifest group \(group) is not a list")
    }
    let sources = listed.compactMap(\.text)
      .filter { !["EmulatorTests.swift", "SwiftCoreTests.swift"].contains(($0 as NSString).lastPathComponent) }
      .map { directory + "/" + (canonical ? $0 : "native/\($0)") }
    return (directory + "/" + (canonical ? "Sources/Terminal/Interop/Bridge.h" : "native/Bridge.h"), sources)
  }

  /// Where two values first differ, as the path and both sides, or nil when they are the same.
  static func firstDifference(_ left: JSONValue, _ right: JSONValue, path: String = "$") -> JSONValue? {
    if let leftMembers = left.members, let rightMembers = right.members {
      let leftKeys = leftMembers.map(\.key).sorted(), rightKeys = rightMembers.map(\.key).sorted()
      guard leftKeys == rightKeys else { return [.string(path), .strings(leftKeys), .strings(rightKeys)] }
      for member in leftMembers {
        if let difference = firstDifference(member.value, right[member.key]!, path: "\(path).\(member.key)") { return difference }
      }
      return nil
    }
    if let leftElements = left.elements, let rightElements = right.elements {
      guard leftElements.count == rightElements.count else {
        return [.string("\(path).length"), .int(leftElements.count), .int(rightElements.count)]
      }
      for (index, pair) in zip(leftElements, rightElements).enumerated() {
        if let difference = firstDifference(pair.0, pair.1, path: "\(path)[\(index)]") { return difference }
      }
      return nil
    }
    return left.matches(right) ? nil : [.string(path), left, right]
  }

  /// Runs a command, keeps its standard error in `log`, and returns its standard output.
  @discardableResult
  private static func capture(_ command: [String], log: String) throws -> Data {
    let finished = try runCommand(command, errors: .file(log))
    guard finished.succeeded else { throw Failure("Command failed (\(finished.exitStatus)): \(command[0]); see \(log)") }
    return finished.data
  }

  private static func text(_ command: [String], log: String) throws -> String {
    String(decoding: try capture(command, log: log), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func copy(_ source: String, to destination: String) throws {
    do { try FileManager.default.copyItem(atPath: source, toPath: destination) }
    catch { throw Failure("cannot copy \(source): \(error.localizedDescription)") }
  }

  static let tests = [
    SelfTest.Case(name: "compare swift rows: the first difference is found by path") {
      func difference(_ left: String, _ right: String) throws -> String? {
        firstDifference(try JSONValue(parsing: left), try JSONValue(parsing: right))?.compact
      }
      try expect(try difference(#"{"a":[1,{"b":2.0}]}"#, #"{"a":[1,{"b":2}]}"#) == nil, "equal numbers are no difference")
      try expect(try difference(#"{"a":[1,{"b":2}]}"#, #"{"a":[1,{"b":3}]}"#) == #"["$.a[1].b",2,3]"#, "a nested value")
      try expect(try difference(#"{"a":[1]}"#, #"{"a":[1,2]}"#) == #"["$.a.length",1,2]"#, "an array length")
      try expect(try difference(#"{"b":1,"a":1}"#, #"{"a":1,"c":1}"#) == #"["$",["a","b"],["a","c"]]"#, "member names")
      try expect(try difference(#"{"a":{}}"#, #"{"a":[]}"#) == #"["$.a",{},[]]"#, "a change of kind")
    },
    SelfTest.Case(name: "compare swift rows: sources follow the archived manifest's layout") {
      let current = try JSONValue(parsing: #"{"app":["Sources/Terminal/App.swift"],"tests":{"emulator":["Sources/Terminal/Grid.swift","Tests/TerminalTests/EmulatorTests.swift"]}}"#)
      let modern = try probeInputs(graph: current, directory: "/r")
      try expect(modern.bridge == "/r/Sources/Terminal/Interop/Bridge.h", "bridge: \(modern.bridge)")
      try expect(modern.sources == ["/r/Sources/Terminal/Grid.swift"], "sources: \(modern.sources)")
      let archived = try JSONValue(parsing: #"{"app":["App.swift"],"tests":{"swift_core":["Grid.swift","SwiftCoreTests.swift"]}}"#)
      let old = try probeInputs(graph: archived, directory: "/r")
      try expect(old.bridge == "/r/native/Bridge.h", "bridge: \(old.bridge)")
      try expect(old.sources == ["/r/native/Grid.swift"], "sources: \(old.sources)")
    },
  ]
}
