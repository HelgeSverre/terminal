import Foundation

/// Runs the CSI corpus against the emulator at two commits and requires identical output.
///
/// Every input is read from Git at the named commits, never from the working
/// tree, so the comparison is between two frozen sources. Only the corpus is
/// shared, and it comes from this checkout.
enum CompareCSIDispatch {
  static let command = Command(
    name: "compare-csi-dispatch", usage: "BASE_REF CANDIDATE_REF NEW_OUTPUT_DIRECTORY",
    summary: "Compile the CSI corpus against two commits and compare every snapshot and reply digest.",
    run: run)

  static let help = """
    Usage: dev compare-csi-dispatch BASE_REF CANDIDATE_REF NEW_OUTPUTDIR
    Freeze canonical-layout source inputs from two Git commits, compile the same
    local CSI corpus with WMO, and compare 62,918 snapshot/reply digest records.
    Requires macOS/Xcode. Retains sources, binaries, logs, and traces in a new
    private output directory; never adds them to Git. Older native/ layouts fail.
    """

  private static let graph = "tools/swift-sources.json"
  private static let header = "Sources/Terminal/Interop/Bridge.h"
  private static let corpus = "Tests/TerminalTests/CSIDifferentialProbe.swift"
  private static let flags = ["-swift-version", "5", "-O", "-whole-module-optimization"]
  static let expectedLines = 62_918

  static func run(_ arguments: [String]) throws {
    if arguments == ["--help"] || arguments == ["-h"] { return print(help) }
    if arguments == ["--version"] { return print("compare_csi_dispatch 1") }
    guard arguments.count == 3, !arguments.contains(where: { $0.hasPrefix("-") }) else { throw Failure.usage(command) }
    Interruption.observe()

    var report: JSONValue = ["passed": false, "flags": .strings(flags), "runs": [:]]
    var output: String?
    var failure: Failure?
    do {
      try compare(arguments, report: &report, output: &output)
    } catch let caught as Failure {
      report["failure"] = .string(caught.message)
      failure = caught
    }
    // A report is written only into a directory this run created.
    if let output { try report.write(to: output + "/comparison.json") }
    if let failure { throw failure }
  }

  private static func compare(_ arguments: [String], report: inout JSONValue, output: inout String?) throws {
    let commits = try arguments.prefix(2).map { reference in
      String(decoding: try git("rev-parse", "--verify", "--end-of-options", "\(reference)^{commit}"), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var frozen: [String: (graph: Data, sources: [String])] = [:]
    for commit in commits {
      let text = try git("show", "\(commit):\(graph)")
      guard let sources = canonicalSources(try JSONValue(parsing: text)["emulation"]) else {
        throw Failure("\(commit): requires canonical Sources/Terminal emulation graph; old layouts unsupported")
      }
      try git("cat-file", "-e", "\(commit):\(header)")
      frozen[commit] = (text, sources)
    }
    let corpusSource = Repository.path(corpus)
    guard FileManager.default.fileExists(atPath: corpusSource) else { throw Failure("Missing shared corpus: \(corpusSource)") }

    let destination = try createPrivateDirectory(arguments[2])
    output = destination
    let corpusCopy = destination + "/CSIDifferentialProbe.swift"
    try FileManager.default.copyItem(atPath: corpusSource, toPath: corpusCopy)
    report["corpus_sha256"] = .string(try sha256(ofFile: corpusCopy))
    report["runner_sha256"] = .string(try sha256(ofFile: #filePath))
    report["process_helper_sha256"] = .string(try sha256(ofFile: Repository.path("tools/Dev/ProcessTree.swift")))
    try run(["xcrun", "swiftc", "--version"], log: destination + "/compiler.txt", seconds: 30)
    report["compiler"] = .string(try String(contentsOfFile: destination + "/compiler.txt", encoding: .utf8))

    for (name, commit) in zip(["baseline", "candidate"], commits) {
      let entry = try measure(name, commit: commit, inputs: frozen[commit]!, corpus: corpusCopy, output: destination)
      report["runs"]?[name] = entry.record
      if let failure = entry.failure { throw failure }
    }
    let traces = ["baseline", "candidate"].map { destination + "/\($0)/trace.txt" }
    let hashes = Set((report["runs"]?.members ?? []).compactMap { $0.value["output_sha256"]?.text })
    guard hashes.count == 1, FileManager.default.contentsEqual(atPath: traces[0], andPath: traces[1]) else {
      throw Failure("CSI output differs; inspect retained traces")
    }
    report["passed"] = true
    FileHandle.standardError.write(Data("PASS CSI differential: \(expectedLines) records; \(destination)/comparison.json\n".utf8))
  }

  /// Writes one commit's inputs, compiles the corpus against them and runs
  /// it. The record is returned even when a step fails, so that the report
  /// keeps the hashes and the command that led to the failure.
  private static func measure(_ name: String, commit: String, inputs: (graph: Data, sources: [String]), corpus: String,
                              output: String) throws -> (record: JSONValue, failure: Failure?) {
    let directory = output + "/" + name
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    var hashes: [(key: String, value: JSONValue)] = []
    for path in [graph, header] + inputs.sources {
      let target = directory + "/" + path
      try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                              withIntermediateDirectories: true)
      try (path == graph ? inputs.graph : try git("show", "\(commit):\(path)")).write(to: URL(fileURLWithPath: target))
      hashes.append((path, .string(try sha256(ofFile: target))))
    }
    let executable = directory + "/csi-probe"
    let command = ["xcrun", "swiftc"] + flags + ["-module-cache-path", directory + "/module-cache",
      "-import-objc-header", directory + "/" + header] + inputs.sources.map { directory + "/" + $0 }
      + [corpus, "-framework", "Foundation", "-framework", "CoreGraphics", "-framework", "ImageIO", "-o", executable]
    var record: JSONValue = ["commit": .string(commit), "source_sha256": .object(hashes), "command": .strings(command)]
    do {
      FileHandle.standardError.write(Data("Compiling \(name) \(commit)\n".utf8))
      try run(command, log: directory + "/compile.log", seconds: 300)
      record["executable_sha256"] = .string(try sha256(ofFile: executable))
      let trace = directory + "/trace.txt"
      FileHandle.standardError.write(Data("Running \(name) CSI corpus\n".utf8))
      try run([executable], log: trace, seconds: 600)
      let lines = try recordCount(inTrace: trace)
      record["line_count"] = .int(lines)
      record["output_sha256"] = .string(try sha256(ofFile: trace))
      guard lines == expectedLines else { throw Failure("Expected \(expectedLines) records, got \(lines): \(trace)") }
    } catch let failure as Failure {
      return (record, failure)
    }
    return (record, nil)
  }

  /// The emulation source list, when it is a non-empty list of distinct
  /// Swift files under `Sources/Terminal/` with no empty or dot path parts.
  /// Paths become file names under the output directory, so nothing else is accepted.
  static func canonicalSources(_ value: JSONValue?) -> [String]? {
    guard let elements = value?.elements, !elements.isEmpty else { return nil }
    let sources = elements.compactMap(\.text)
    guard sources.count == elements.count, Set(sources).count == sources.count else { return nil }
    let canonical = sources.allSatisfy { path in
      path.hasPrefix("Sources/Terminal/") && path.hasSuffix(".swift")
        && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
    return canonical ? sources : nil
  }

  /// The number of records in a trace. Every line must be a record.
  static func recordCount(inTrace path: String) throws -> Int {
    guard let data = FileManager.default.contents(atPath: path) else { throw Failure("cannot read \(path)") }
    let text = String(decoding: data, as: UTF8.self)
    if text.isEmpty { return 0 }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    // A complete last record leaves nothing after its newline.
    guard lines.removeLast().isEmpty else { throw Failure("Unexpected trace record in \(path)") }
    let record = "^[0-9]+:-?[0-9]+:SHA256 digest: [0-9a-f]{64}$"
    for line in lines where line.range(of: record, options: .regularExpression) == nil || line.contains("\r") {
      throw Failure("Unexpected trace record in \(path)")
    }
    return lines.count
  }

  /// Creates the output directory, which must not exist, for this user only.
  private static func createPrivateDirectory(_ path: String) throws -> String {
    let destination = URL(fileURLWithPath: path).standardizedFileURL.path
    var information = stat()
    guard lstat(destination, &information) != 0 else { throw Failure("Output already exists: \(destination)") }
    // mkdir fails on an existing directory, so nothing is reused or cleaned.
    guard mkdir(destination, 0o700) == 0, chmod(destination, 0o700) == 0 else {
      throw Failure("cannot create \(destination): \(String(cString: strerror(errno)))")
    }
    return destination
  }

  /// Runs a step with a time limit. It must succeed and leave no process behind.
  static func run(_ command: [String], log: String, seconds: Double) throws {
    let process = try ProcessTree([try executablePath(command[0])] + command.dropFirst(), output: .log(log))
    var failure: Failure?
    do {
      guard let exit = try process.waitInterruptibly(seconds: seconds) else {
        throw Failure("Timed out after \(seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds))s; inspect \(log)")
      }
      guard exit.succeeded else {
        throw Failure("Process failed (\(exit.signalled ? "signal" : "exit") \(exit.code)); inspect \(log)")
      }
      let children = process.livePIDs
      guard children.isEmpty else { throw Failure("Process left children: \(children)") }
    } catch let caught as Failure {
      failure = caught
    }
    let remaining = process.cleanup()
    guard remaining.isEmpty else { throw Failure("Processes survived cleanup: \(remaining)") }
    if let failure { throw failure }
  }

  @discardableResult
  private static func git(_ arguments: String...) throws -> Data {
    let finished = try runCaptured(["git", "-C", Repository.root] + arguments)
    guard finished.succeeded else {
      throw Failure("git \(arguments[0]) failed: \(finished.text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return finished.output
  }

  static let tests = [
    SelfTest.Case(name: "compare csi dispatch: only a canonical emulation graph is accepted") {
      func accepted(_ json: String) throws -> Bool { canonicalSources(try JSONValue(parsing: json)) != nil }
      try expect(try accepted(#"["Sources/Terminal/Emulation/Parser.swift"]"#), "a canonical path")
      try expect(try !accepted("[]"), "an empty list")
      try expect(try !accepted(#"["native/Parser.swift"]"#), "an old layout")
      try expect(try !accepted(#"["Sources/Terminal/../../etc/x.swift"]"#), "a path that climbs out")
      try expect(try !accepted(#"["Sources/Terminal//x.swift"]"#), "an empty path part")
      try expect(try !accepted(#"["Sources/Terminal/a.swift","Sources/Terminal/a.swift"]"#), "a repeated path")
      try expect(try !accepted(#"["Sources/Terminal/a.swift",7]"#), "a path that is not text")
      try expect(try !accepted(#"["Sources/Terminal/a.c"]"#), "a file that is not Swift")
      try expect(canonicalSources(nil) == nil, "a missing group")
    },
    SelfTest.Case(name: "compare csi dispatch: every trace line must be a record") {
      try withTemporaryDirectory("dev-csi-trace-") { directory in
        let digest = String(repeating: "a", count: 64)
        func count(_ text: String) throws -> Int {
          try text.write(toFile: directory + "/trace.txt", atomically: true, encoding: .utf8)
          return try recordCount(inTrace: directory + "/trace.txt")
        }
        try expect(try count("0:-1:SHA256 digest: \(digest)\n12:3:SHA256 digest: \(digest)\n") == 2, "two records")
        try expect(try count("") == 0, "an empty trace")
        for broken in ["0:1:SHA256 digest: \(digest)", "0:1:SHA256 digest: \(digest)\n\n", "0:1:SHA256 digest: abc\n",
                       "note\n0:1:SHA256 digest: \(digest)\n"] {
          try expect((try? count(broken)) == nil, "accepted: \(broken.debugDescription)")
        }
      }
    },
    SelfTest.Case(name: "compare csi dispatch: a step must succeed in time and leave nothing behind") {
      try withTemporaryDirectory("dev-csi-step-") { directory in
        func message(_ script: String, _ name: String, seconds: Double = 5) -> String? {
          do { try run(["/bin/sh", "-c", script], log: directory + "/" + name, seconds: seconds) }
          catch let failure as Failure { return failure.message }
          catch { return "\(error)" }
          return nil
        }
        try expect(message("echo hello", "pass.log") == nil, "a clean step passes")
        try expect(try String(contentsOfFile: directory + "/pass.log", encoding: .utf8) == "hello\n", "its output is logged")
        try expect(message("exit 3", "fail.log")?.contains("Process failed (exit 3)") == true, "a failing step")
        try expect(message("sleep 30", "slow.log", seconds: 0.3)?.contains("Timed out after 0.3s") == true, "a slow step")
        try expect(message("sleep 30 & sleep 0.4", "child.log")?.contains("Process left children") == true, "a lingering child")
      }
    },
  ]
}
