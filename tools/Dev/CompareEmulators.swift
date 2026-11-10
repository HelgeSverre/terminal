import Foundation

/// Measures the frozen Swift and Rust emulator harnesses against each other.
///
/// Both executables are `tools/EmulatorComparison.c` linked to one core, built
/// beforehand from frozen source trees. This command builds nothing and opens
/// no window: it checks each executable against its provenance, runs the
/// harnesses in alternating turns, and then requires that both replayed the
/// same bytes and ended in the same terminal state. The method is in
/// `docs/emulator-comparison-method.md`.
enum CompareEmulators {
  static let command = Command(
    name: "compare-emulators",
    usage: "--swift-bin PATH --rust-bin PATH --swift-root PATH --rust-root PATH --swift-provenance PATH "
      + "--rust-provenance PATH --output PATH [--bytes N] [--warmup N] [--pairs N] [--samples-per-turn N] "
      + "[--timeout-seconds N]",
    summary: "Run the frozen Swift and Rust emulator harnesses in alternating turns and gate on equal results.",
    run: run)

  static let workloads = ["ascii", "mixed"]
  static let implementations = ["swift", "rust"]
  /// The fields that identify what a harness fed its core and what the core replied.
  static let streamFields = [(kind: "payload", fields: ["payload_bytes", "payload_fnv1a64"]),
                             (kind: "reply", fields: ["reply_bytes", "reply_fnv1a64"])]
  /// Publication counters, and the empty history projection of the old ABI.
  static let volatileRootFields = ["revision", "geometry_epoch", "document_epoch", "history_epoch", "screen_epoch",
                                   "viewport_clamp_revision", "history"]
  static let swiftOnlyGeometryFields = ["primary_margins", "alternate_margins", "vertical_margins"]

  struct Options {
    var paths: [String: String] = [:]
    var bytes = 32 * 1024 * 1024
    var warmup = 1
    var pairs = 3
    var samplesPerTurn = 5
    var timeoutSeconds = 120.0
    var output: String { paths["output"]! }

    static let required = ["swift-bin", "rust-bin", "swift-root", "rust-root", "swift-provenance", "rust-provenance", "output"]

    init() {}

    /// Reads `--name VALUE` and `--name=VALUE` pairs.
    init(_ arguments: [String]) throws {
      var rest = arguments[...]
      while let argument = rest.popFirst() {
        guard argument.hasPrefix("--") else { throw Failure.usage(CompareEmulators.command) }
        let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        guard let value = parts.count == 2 ? String(parts[1]) : rest.popFirst() else { throw Failure.usage(CompareEmulators.command) }
        func whole() throws -> Int {
          guard let number = Int(value) else { throw Failure("--\(name) needs a whole number, not \(value)") }
          return number
        }
        switch name {
        case _ where Self.required.contains(name): paths[name] = value
        case "bytes": bytes = try whole()
        case "warmup": warmup = try whole()
        case "pairs": pairs = try whole()
        case "samples-per-turn": samplesPerTurn = try whole()
        case "timeout-seconds":
          guard let seconds = Double(value) else { throw Failure("--timeout-seconds needs a number, not \(value)") }
          timeoutSeconds = seconds
        default: throw Failure.usage(CompareEmulators.command)
        }
      }
      let missing = Self.required.filter { paths[$0] == nil }
      guard missing.isEmpty else {
        var failure = Failure(Failure.usage(CompareEmulators.command).message + "\nmissing: " + missing.map { "--" + $0 }.joined(separator: ", "))
        failure.isUsage = true
        throw failure
      }
    }
  }

  static func run(_ arguments: [String]) throws {
    if arguments == ["--self-test"] {
      for test in tests { try test.run() }
      return print("compare_emulators self-test: PASS")
    }
    let options = try Options(arguments)
    Interruption.observe()
    try compare(options)
  }

  static func compare(_ options: Options) throws {
    guard options.bytes > 0, options.warmup > 0, options.pairs > 0, options.samplesPerTurn > 0, options.timeoutSeconds > 0 else {
      throw Failure("bytes, warmup, pairs, samples-per-turn and timeout must be positive")
    }
    let output = options.output
    guard !FileManager.default.fileExists(atPath: output) else { throw Failure("refusing to overwrite existing output \(output)") }
    for name in ["swift-bin", "rust-bin", "swift-provenance", "rust-provenance"] {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: options.paths[name]!, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw Failure("missing \(name): \(options.paths[name]!)")
      }
    }
    for (title, name) in [("Swift", "swift-bin"), ("Rust", "rust-bin")] {
      guard FileManager.default.isExecutableFile(atPath: options.paths[name]!) else {
        throw Failure("\(title) harness is not executable")
      }
    }
    try FileManager.default.createDirectory(atPath: output + "/snapshots", withIntermediateDirectories: true)
    var frozen: [(key: String, value: JSONValue)] = []
    for implementation in implementations {
      frozen.append((implementation, try loadProvenance(
        options.paths["\(implementation)-provenance"]!, implementation: implementation,
        executable: options.paths["\(implementation)-bin"]!, root: options.paths["\(implementation)-root"]!)))
    }

    var result: JSONValue = [
      "protocol": 1,
      "orchestrator_sha256": .string(try sha256(ofFile: #filePath)),
      "started_at_utc": .string(timestamp()),
      "contract": [
        "geometry": [160, 50], "history_rows": 0, "workloads": .strings(workloads),
        "requested_bytes": .int(options.bytes), "warmup_per_implementation": .int(options.warmup),
        "alternating_pairs": .int(options.pairs), "samples_per_turn": .int(options.samplesPerTurn),
        "timeout_seconds_per_harness": .number(options.timeoutSeconds),
        "timed_operations": "feed, reply drain, pending-work drain, finish, reply drain, invariant validation, snapshot serialization/copy/free",
        "not_measured": "GUI, renderer, PTY, process creation, corpus construction and result file I/O",
      ],
      "hardware": hardware(),
      "background_at_start": backgroundActivity(),
      "implementations": .object(frozen),
      "warmups": [], "samples": [],
      "snapshot_gate": ["passed": true, "mismatches": []],
      "replay_gate": nil,
    ]
    // An interrupted or failed run keeps a report that says it is incomplete.
    var failure: Failure?
    do {
      try measure(options, result: &result)
      result["status"] = "complete"
    } catch let caught as Failure {
      result["status"] = "incomplete"
      result["failure"] = ["class": Interruption.requested ? "Interrupt" : "ComparisonError", "message": .string(caught.message)]
      failure = caught
    }
    result["finished_at_utc"] = .string(timestamp())
    try result.write(to: output + "/result.json")
    if let failure { throw failure }

    try summary(result).write(toFile: output + "/summary.md", atomically: true, encoding: .utf8)
    guard result["snapshot_gate"]?["passed"]?.truth == true, result["replay_gate"]?["passed"]?.truth == true else {
      throw Failure("comparison gates failed; see \(output)/result.json")
    }
  }

  /// Runs the warmups and the alternating turns of every workload, then applies both gates.
  private static func measure(_ options: Options, result: inout JSONValue) throws {
    let output = options.output
    func harness(_ implementation: String, _ workload: String, _ prefix: String) throws -> JSONValue {
      guard let executable = result["implementations"]?[implementation]?["executable"]?.text else {
        throw Failure("no executable recorded for \(implementation)")
      }
      return try runHarness(executable: executable, workload: workload, bytes: options.bytes,
                            snapshot: "\(output)/snapshots/\(prefix).json", log: "\(output)/\(prefix).log",
                            timeout: options.timeoutSeconds)
    }
    for workload in workloads {
      for implementation in implementations {
        for index in 1...options.warmup {
          result.append(try harness(implementation, workload, "warmup-\(workload)-\(implementation)-\(index)"), to: "warmups")
        }
      }
      for pair in 1...options.pairs {
        // The order alternates so that neither implementation always runs on a warmer machine.
        for implementation in pair % 2 == 1 ? implementations : implementations.reversed() {
          for sample in 1...options.samplesPerTurn {
            var record = try harness(implementation, workload, "\(workload)-pair\(pair)-\(implementation)-\(sample)")
            record["implementation"] = .string(implementation)
            record["pair"] = .int(pair)
            record["sample"] = .int(sample)
            result.append(record, to: "samples")
          }
        }
      }
    }
    let samples = result["samples"]?.elements ?? []
    result["replay_gate"] = validateReplayGate(samples, expected: options.pairs * options.samplesPerTurn)
    for mismatch in try snapshotMismatches(samples) {
      result["snapshot_gate"]?["passed"] = false
      result["snapshot_gate"]?.append(mismatch, to: "mismatches")
    }
  }

  /// Compares the final snapshots of the Swift and Rust samples of each workload, in order.
  static func snapshotMismatches(_ samples: [JSONValue]) throws -> [JSONValue] {
    var mismatches: [JSONValue] = []
    for workload in workloads {
      func paths(_ implementation: String) -> [String] {
        samples.filter { $0["workload"]?.text == workload && $0["implementation"]?.text == implementation }
          .compactMap { $0["snapshot_path"]?.text }
      }
      for (index, pair) in zip(paths("swift"), paths("rust")).enumerated() {
        let swift = try normalizeSnapshot(try contents(pair.0)), rust = try normalizeSnapshot(try contents(pair.1))
        let swiftCanonical = swift.canonical.sorted.compact, rustCanonical = rust.canonical.sorted.compact
        if swiftCanonical == rustCanonical { continue }
        mismatches.append([
          "workload": .string(workload), "sample_index": .int(index + 1),
          "swift_snapshot_sha256": .string(sha256(of: Data(swift.raw.compact.utf8))),
          "rust_snapshot_sha256": .string(sha256(of: Data(rust.raw.compact.utf8))),
          "swift_canonical_sha256": .string(sha256(of: Data(swiftCanonical.utf8))),
          "rust_canonical_sha256": .string(sha256(of: Data(rustCanonical.utf8))),
        ])
      }
    }
    return mismatches
  }

  /// Runs one harness to completion, sampling its memory, and returns its
  /// record with the measurements this runner adds. The harness gets its own
  /// process group, so a timeout or an interruption ends everything it started.
  static func runHarness(executable: String, workload: String, bytes: Int, snapshot: String, log: String,
                         timeout: Double, onSpawn: ((pid_t) -> Void)? = nil) throws -> JSONValue {
    let started = Clock.now
    let deadline = started + UInt64(timeout * 1_000_000_000)
    let pid = try spawnGroup([executable, "--workload", workload, "--bytes", String(bytes), "--snapshot", snapshot],
                             output: log, errors: log + ".stderr")
    onSpawn?(pid)
    var samples: [Int] = []
    var status: Int32 = 0
    while true {
      if let value = residentKilobytes(pid) { samples.append(value) }
      if waitpid(pid, &status, WNOHANG) == pid { break }
      if Clock.now >= deadline {
        terminateGroup(pid)
        throw Failure("harness timed out after \(JSONValue.decimal(timeout)) seconds: \(executable)")
      }
      if Interruption.requested {
        terminateGroup(pid)
        throw Failure("interrupted")
      }
      usleep(25_000)
    }
    let wall = Clock.now - started
    let errors = (try? String(contentsOfFile: log + ".stderr", encoding: .utf8)) ?? ""
    // The low seven bits of a wait status are the signal; none means an exit, with its code above them.
    guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else {
      throw Failure("\(executable) exited \(status & 0x7f == 0 ? String((status >> 8) & 0xff) : ""): \(errors)")
    }
    var record: JSONValue
    do { record = try JSONValue(parsing: try contents(log)) } catch let failure as Failure {
      throw Failure("\(executable) did not emit one JSON result: \(failure.message); stderr: \(errors)")
    }
    guard record.members != nil, record["protocol"]?.quantity == 1 else {
      throw Failure("\(executable) emitted an unsupported harness protocol")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: snapshot, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw Failure("\(executable) did not create \(snapshot)")
    }
    record["wall_ns"] = .int(Int(wall))
    record["rss_samples_kb"] = .array(samples.map(JSONValue.int))
    record["rss_last_kb"] = .optional(samples.last)
    record["rss_peak_kb"] = .optional(samples.max())
    record["rss_scope"] = "direct child; includes the allocated replay corpus and runtime allocations"
    record["snapshot_sha256"] = .string(try sha256(ofFile: snapshot))
    record["snapshot_path"] = .string(snapshot)
    return record
  }

  /// Starts a command as the leader of a new process group, with its output in two new files.
  private static func spawnGroup(_ command: [String], output: String, errors: String) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    posix_spawn_file_actions_addopen(&actions, 2, errors, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    posix_spawnattr_setpgroup(&attributes, 0)
    // The tool ignores interruption signals so that it can end in order, and
    // an ignored signal stays ignored in a spawned program unless it is reset.
    var defaults = sigset_t()
    sigfillset(&defaults)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))
    var arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }
    var pid: pid_t = 0
    let code = posix_spawn(&pid, command[0], &actions, &attributes, &arguments, environ)
    guard code == 0 else { throw Failure("cannot launch \(command[0]): \(String(cString: strerror(code)))") }
    return pid
  }

  /// Ends a harness and whatever it started, and reaps it: a polite request, then a kill after two seconds.
  private static func terminateGroup(_ pid: pid_t) {
    guard kill(-pid, SIGTERM) == 0 else { return }
    var status: Int32 = 0
    let deadline = Clock.now + 2_000_000_000
    while Clock.now < deadline {
      if waitpid(pid, &status, WNOHANG) != 0 { return }
      usleep(20_000)
    }
    guard kill(-pid, SIGKILL) == 0 else { return }
    _ = waitpid(pid, &status, 0)
  }

  private static func residentKilobytes(_ pid: pid_t) -> Int? {
    (try? runCaptured(["/bin/ps", "-o", "rss=", "-p", String(pid)])).flatMap {
      Int($0.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  /// Reads a provenance file and checks it against the executable and the
  /// source tree it names. Returns it with the facts measured here added.
  static func loadProvenance(_ path: String, implementation: String, executable: String, root: String) throws -> JSONValue {
    var provenance = try JSONValue(parsingFile: path)
    let required = ["implementation", "source_root", "source_commit", "source_tree_clean", "executable_sha256", "compiler",
                    "build_wall_seconds", "build_command"]
    let missing = required.filter { provenance[$0] == nil }
    guard missing.isEmpty else { throw Failure("\(path) lacks \(missing.joined(separator: ", "))") }
    guard provenance["implementation"]?.text == implementation else {
      throw Failure("\(path) describes \(provenance["implementation"]!.display), not \(implementation)")
    }
    let digest = try sha256(ofFile: executable)
    guard provenance["executable_sha256"]?.text == digest else {
      throw Failure("frozen binary hash mismatch for \(executable)")
    }
    guard let sourceRoot = provenance["source_root"]?.text, try realPath(sourceRoot) == (try realPath(root)) else {
      throw Failure("provenance source root does not match \(root)")
    }
    try requireFrozenSource(root, provenance: provenance)
    provenance["executable"] = .string(try realPath(executable))
    let size = try FileManager.default.attributesOfItem(atPath: executable)[.size] as? Int
    provenance["executable_bytes"] = .optional(size)
    provenance["provenance_path"] = .string(try realPath(path))
    return provenance
  }

  /// The source tree must still be the clean checkout of the commit the build recorded.
  private static func requireFrozenSource(_ root: String, provenance: JSONValue) throws {
    let root = try realPath(root)
    let actual = try commandOutput(["git", "-C", root, "rev-parse", "HEAD"])
    guard actual == provenance["source_commit"]?.text else {
      throw Failure("source commit changed for \(root): \(actual), expected \(provenance["source_commit"]!.display)")
    }
    guard try commandOutput(["git", "-C", root, "status", "--porcelain"]).isEmpty else {
      throw Failure("source worktree is not frozen/clean: \(root)")
    }
    guard provenance["source_tree_clean"]?.truth == true else { throw Failure("provenance did not attest a clean source tree") }
  }

  /// A snapshot as written, and the same with the fields removed that may differ between equal terminals.
  static func normalizeSnapshot(_ raw: Data) throws -> (raw: JSONValue, canonical: JSONValue) {
    let value: JSONValue
    do { value = try JSONValue(parsing: raw) } catch let failure as Failure { throw Failure("snapshot JSON invalid: \(failure.message)") }
    guard value.members != nil else { throw Failure("snapshot root is not an object") }
    guard value["input_ready"]?.truth != nil else { throw Failure("snapshot does not publish boolean input_ready") }
    var canonical = value
    for key in volatileRootFields { canonical[key] = nil }
    // Row identifiers and revisions name allocations and publications inside
    // one implementation; they are not terminal-visible cells. The raw
    // snapshots stay saved.
    if let rows = canonical["rows"]?.elements {
      canonical["rows"] = .array(rows.map { row in
        var row = row
        row["id"] = nil
        row["revision"] = nil
        return row
      })
    }
    // The Rust ABI's snapshot predates the three Swift-only margin fields. The
    // published corpus never changes margins; a margin fixture must compare
    // them once Rust exposes counterparts.
    for key in swiftOnlyGeometryFields { canonical[key] = nil }
    return (value, canonical)
  }

  /// Requires the expected number of samples from each implementation, and
  /// one payload stream and one reply stream shared by all of them. Without
  /// this the throughput of two different replays would be compared.
  static func validateReplayGate(_ samples: [JSONValue], expected: Int) -> JSONValue {
    var counts: [(key: String, value: JSONValue)] = [], streams: [(key: String, value: JSONValue)] = []
    var failures: [JSONValue] = []
    for workload in workloads {
      var workloadCounts: [(key: String, value: JSONValue)] = [], workloadStreams: [(key: String, value: JSONValue)] = []
      var observed: [String: [JSONValue]] = [:]
      for implementation in implementations {
        let own = samples.filter { $0["workload"]?.text == workload && $0["implementation"]?.text == implementation }
        workloadCounts.append((implementation, .int(own.count)))
        if own.count != expected {
          failures.append(["workload": .string(workload), "kind": "sample_count", "implementation": .string(implementation),
                           "expected": .int(expected), "observed": .int(own.count)])
        }
        var kinds: [(key: String, value: JSONValue)] = []
        for (kind, fields) in streamFields {
          let invalid = own.compactMap { sample -> JSONValue? in
            let unusable = fields.filter { !validStreamValue($0, sample[$0]) }
            if unusable.isEmpty { return nil }
            return ["pair": sample["pair"] ?? .null, "sample": sample["sample"] ?? .null, "fields": .strings(unusable)]
          }
          let values = streamValues(own, fields)
          kinds.append((kind, .array(values)))
          observed[kind, default: []] += values
          if invalid.isEmpty { continue }
          failures.append(["workload": .string(workload), "kind": .string("invalid_\(kind)_stream"),
                           "implementation": .string(implementation), "samples": .array(invalid)])
        }
        workloadStreams.append((implementation, .object(kinds)))
      }
      for (kind, _) in streamFields {
        let values = distinct(observed[kind] ?? [])
        if values.count == 1 { continue }
        failures.append(["workload": .string(workload), "kind": .string("\(kind)_stream_mismatch"), "observed_values": .array(values)])
      }
      counts.append((workload, .object(workloadCounts)))
      streams.append((workload, .object(workloadStreams)))
    }
    return ["passed": .bool(failures.isEmpty), "expected_samples_per_implementation_per_workload": .int(expected),
            "observed_sample_counts": .object(counts), "observed_stream_values": .object(streams), "failures": .array(failures)]
  }

  /// A byte count is a non-negative whole number; a digest is sixteen lowercase hex digits.
  private static func validStreamValue(_ field: String, _ value: JSONValue?) -> Bool {
    if field.hasSuffix("_bytes") {
      if case .integer(let digits)? = value { return !digits.hasPrefix("-") }
      return false
    }
    return value?.text?.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil
  }

  /// The distinct usable values of `fields` among `samples`.
  private static func streamValues(_ samples: [JSONValue], _ fields: [String]) -> [JSONValue] {
    distinct(samples.compactMap { sample in
      guard fields.allSatisfy({ validStreamValue($0, sample[$0]) }) else { return nil }
      return .object(fields.map { ($0, sample[$0]!) })
    })
  }

  private static func distinct(_ values: [JSONValue]) -> [JSONValue] {
    var seen = Set<String>()
    return values.filter { seen.insert($0.compact).inserted }
  }

  private static func hardware() -> JSONValue {
    ["os_product_version": commandOptional(["/usr/bin/sw_vers", "-productVersion"]),
     "kernel": commandOptional(["/usr/bin/uname", "-a"]),
     "model": commandOptional(["/usr/sbin/sysctl", "-n", "hw.model"]),
     "cpu": commandOptional(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]),
     "logical_cpus": commandOptional(["/usr/sbin/sysctl", "-n", "hw.logicalcpu"]),
     "power": commandOptional(["/usr/bin/pmset", "-g", "batt"])]
  }

  /// The load and the eight busiest processes, so a reader can judge how quiet the machine was.
  private static func backgroundActivity() -> JSONValue {
    let listing = commandOptional(["/bin/ps", "-axo", "pcpu=,comm="]).text ?? ""
    let processes = listing.split(separator: "\n").compactMap { line -> (name: String, cpu: Double)? in
      let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
      guard fields.count == 2, fields[0].range(of: "^[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil,
            let cpu = Double(fields[0]) else { return nil }
      return ((fields[1].trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent, cpu)
    }
    let busiest = processes.enumerated().sorted { ($0.element.cpu, $1.offset) > ($1.element.cpu, $0.offset) }.prefix(8)
    return ["observed_at_utc": .string(timestamp()),
            "load_average": commandOptional(["/usr/sbin/sysctl", "-n", "vm.loadavg"]),
            "top_processes": .array(busiest.map { ["name": .string($0.element.name), "cpu_percent": .number($0.element.cpu)] })]
  }

  /// The two tables of `summary.md`: the builds, and median throughput per workload.
  static func summary(_ result: JSONValue) throws -> String {
    let samples = result["samples"]?.elements ?? []
    let rows = try workloads.map { workload -> String in
      let medians = try implementations.map { implementation -> String in
        let rates = try samples.filter { $0["workload"]?.text == workload && $0["implementation"]?.text == implementation }
          .map(throughput)
        guard let median = median(rates) else { throw Failure("no \(implementation) samples for \(workload)") }
        return String(format: "%.2f", median)
      }
      return "| \(workload) | \(medians[0]) | \(medians[1]) |"
    }
    let builds = implementations.map { implementation -> String in
      let item = result["implementations"]?[implementation]
      func field(_ key: String) -> String { item?[key]?.display ?? "" }
      return "| \(implementation) | \(field("build_wall_seconds")) | \(field("executable_bytes")) | \(field("executable_sha256")) |"
    }
    func verdict(_ gate: String) -> String { result[gate]?["passed"]?.truth == true ? "PASS" : "FAIL" }
    return """
      # Frozen Swift vs Rust emulator comparison

      These are scoped results for the current frozen implementations, not a generic terminal-core or full-product comparison.
      Replay payload/reply gate: **\(verdict("replay_gate"))**. Canonical final-snapshot gate: **\(verdict("snapshot_gate"))**.

      | Implementation | Recorded headless-recipe build wall seconds (not matched app compile) | Executable bytes | SHA-256 |
      | --- | ---: | ---: | --- |
      \(builds.joined(separator: "\n"))

      | Workload | Swift median MiB/s | Rust median MiB/s |
      | --- | ---: | ---: |
      \(rows.joined(separator: "\n"))

      See `result.json` for every runtime/RSS sample and `snapshots/` for every raw final ABI JSON snapshot.

      """
  }

  /// Payload mebibytes per second of timed work.
  private static func throughput(_ record: JSONValue) throws -> Double {
    guard let bytes = record["payload_bytes"]?.quantity, let elapsed = record["elapsed_ns"]?.quantity else {
      throw Failure("a sample lacks payload_bytes or elapsed_ns")
    }
    return bytes / (1024 * 1024) / (elapsed / 1_000_000_000)
  }

  /// The middle value, or the mean of the middle two.
  static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let ordered = values.sorted(), middle = ordered.count / 2
    return ordered.count % 2 == 1 ? ordered[middle] : (ordered[middle - 1] + ordered[middle]) / 2
  }

  private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

  private static func contents(_ path: String) throws -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { throw Failure("cannot read \(path)") }
    return data
  }

  /// The trimmed output of a command that must succeed.
  private static func commandOutput(_ command: [String]) throws -> String {
    let finished = try runCaptured(command)
    guard finished.succeeded else { throw Failure("\(command.joined(separator: " ")) failed: \(finished.text)") }
    return finished.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The trimmed output of a command, whatever its status; null when it cannot be run.
  private static func commandOptional(_ command: [String]) -> JSONValue {
    .optional((try? runCaptured(command))?.text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static let tests = [
    SelfTest.Case(name: "compare emulators: input_ready stays in the canonical snapshot and volatile fields leave it") {
      func canonical(_ json: String) throws -> String { try normalizeSnapshot(Data(json.utf8)).canonical.sorted.compact }
      try expect(try canonical(#"{"input_ready":true,"rows":[]}"#) != canonical(#"{"input_ready":false,"rows":[]}"#),
                 "input_ready was projected away")
      let swift = #"{"rows":[{"id":4,"revision":9,"cells":"a"}],"input_ready":true,"revision":3,"history":[],"vertical_margins":[0,49]}"#
      let rust = #"{"input_ready":true,"revision":8,"rows":[{"cells":"a","id":1,"revision":2}]}"#
      let projected = try canonical(swift)
      try expect(try projected == canonical(rust), "volatile fields were compared")
      try expect(projected == #"{"input_ready":true,"rows":[{"cells":"a"}]}"#, "got \(projected)")
      try expect((try? normalizeSnapshot(Data(#"{"rows":[]}"#.utf8))) == nil, "a snapshot without input_ready was accepted")
      try expect((try? normalizeSnapshot(Data("[]".utf8))) == nil, "a snapshot that is not an object was accepted")
    },
    SelfTest.Case(name: "compare emulators: the replay gate accepts equal streams and records a mismatch") {
      // Both workloads are present so that the gate is never given partial input.
      var samples: [JSONValue] = []
      for workload in workloads {
        for implementation in implementations {
          for sample in 1...2 {
            samples.append(["workload": .string(workload), "implementation": .string(implementation), "pair": 1,
                            "sample": .int(sample), "payload_bytes": 99, "payload_fnv1a64": "0123456789abcdef",
                            "reply_bytes": 7, "reply_fnv1a64": "fedcba9876543210"])
          }
        }
      }
      func kinds(_ gate: JSONValue) -> [String] { (gate["failures"]?.elements ?? []).compactMap { $0["kind"]?.text } }
      let matching = validateReplayGate(samples, expected: 2)
      try expect(matching["passed"]?.truth == true, "matching replay streams were rejected: \(kinds(matching))")
      try expect(matching["observed_sample_counts"]?["mixed"]?["rust"]?.whole == 2, "sample counts are recorded")

      var payload = samples
      payload[2]["payload_fnv1a64"] = "1111111111111111"
      try expect(payload[2]["workload"]?.text == "ascii" && payload[2]["implementation"]?.text == "rust", "fixture order")
      let payloadGate = validateReplayGate(payload, expected: 2)
      try expect(payloadGate["passed"]?.truth == false, "mismatched payload stream was accepted")
      try expect(kinds(payloadGate) == ["payload_stream_mismatch"], "payload mismatch was not auditable: \(kinds(payloadGate))")

      var reply = samples
      reply[6]["reply_bytes"] = 8
      let replyGate = validateReplayGate(reply, expected: 2)
      try expect(replyGate["passed"]?.truth == false, "mismatched reply stream was accepted")
      try expect(kinds(replyGate) == ["reply_stream_mismatch"], "reply mismatch was not auditable: \(kinds(replyGate))")

      var invalid = samples
      invalid[0]["reply_fnv1a64"] = "FEDCBA9876543210"
      try expect(kinds(validateReplayGate(invalid, expected: 3)) ==
                   ["sample_count", "invalid_reply_stream", "sample_count", "sample_count", "sample_count"],
                 "an unusable digest and short counts are named")
    },
    SelfTest.Case(name: "compare emulators: the watchdog ends and reaps a hanging harness") {
      try withTemporaryDirectory("dev-emulator-watchdog-") { directory in
        try writeExecutable(directory + "/hang", "#!/bin/sh\nsleep 30\n")
        var child: pid_t?
        do {
          _ = try runHarness(executable: directory + "/hang", workload: "ascii", bytes: 1, snapshot: directory + "/snapshot.json",
                             log: directory + "/hang.log", timeout: 0.1, onSpawn: { child = $0 })
          throw Failure("watchdog did not fire")
        } catch let failure as Failure {
          try expect(failure.message.contains("timed out after 0.1 seconds"), "got: \(failure.message)")
        }
        guard let child else { throw Failure("watchdog child was never spawned") }
        try expect(kill(child, 0) != 0 && errno == ESRCH, "timed-out child still exists")
      }
    },
    SelfTest.Case(name: "compare emulators: a run against frozen fakes writes a complete report and passes both gates") {
      try withFrozenFakes(rustCell: "a") { options in
        try compare(options)
        let result = try JSONValue(parsingFile: options.output + "/result.json")
        try expect(result["status"]?.text == "complete", "status: \(result["status"]?.display ?? "none")")
        try expect(result["warmups"]?.elements?.count == 4 && result["samples"]?.elements?.count == 8, "run counts")
        try expect(result["samples"]?.elements?.map { $0["implementation"]!.display + $0["pair"]!.display }.prefix(4)
                     == ["swift1", "rust1", "rust2", "swift2"], "turns alternate")
        try expect(result["replay_gate"]?["passed"]?.truth == true && result["snapshot_gate"]?["passed"]?.truth == true, "gates")
        let swift = result["implementations"]?["swift"]
        try expect(swift?["executable_bytes"]?.whole != nil && swift?["build_wall_seconds"]?.compact == "1.5", "provenance is kept")
        let summary = try String(contentsOfFile: options.output + "/summary.md", encoding: .utf8)
        try expect(summary.contains("| ascii | 1024.00 | 1024.00 |") && summary.contains("| swift | 1.5 | "), "summary:\n\(summary)")
        try expect(FileManager.default.fileExists(atPath: options.output + "/snapshots/mixed-pair2-rust-1.json"), "snapshots are kept")
      }
    },
    SelfTest.Case(name: "compare emulators: a differing final snapshot fails the run and is recorded") {
      try withFrozenFakes(rustCell: "b", pairs: 1) { options in
        do {
          try compare(options)
          throw Failure("a snapshot mismatch was accepted")
        } catch let failure as Failure {
          try expect(failure.message.contains("comparison gates failed"), "got: \(failure.message)")
        }
        let result = try JSONValue(parsingFile: options.output + "/result.json")
        try expect(result["status"]?.text == "complete" && result["snapshot_gate"]?["passed"]?.truth == false, "gate result")
        try expect(result["snapshot_gate"]?["mismatches"]?.elements?.count == 2, "each workload's pair is listed")
        let summary = try String(contentsOfFile: options.output + "/summary.md", encoding: .utf8)
        try expect(summary.contains("Canonical final-snapshot gate: **FAIL**"), "the summary states the failure")
      }
    },
    SelfTest.Case(name: "compare emulators: provenance must match the executable and a clean source tree") {
      try withFrozenFakes(rustCell: "a") { options in
        var attempts = 0
        func message(_ change: (inout Options) throws -> Void) -> String {
          var changed = options
          attempts += 1
          changed.paths["output"] = options.output + "-\(attempts)"
          do { try change(&changed); try compare(changed) } catch let failure as Failure { return failure.message } catch {}
          return ""
        }
        try expect(message { $0.paths["swift-provenance"] = $0.paths["rust-provenance"] }.contains("describes rust, not swift"),
                   "the wrong implementation")
        try expect(message { $0.paths["swift-bin"] = "/bin/cat" }.contains("frozen binary hash mismatch"), "another binary")
        try expect(message { try "x".write(toFile: $0.paths["rust-root"]! + "/new", atomically: true, encoding: .utf8) }
                     .contains("not frozen/clean"), "a changed source tree")
        try expect(!FileManager.default.fileExists(atPath: options.output + "-1/result.json"), "no report without valid provenance")
        try expect(message { $0.pairs = 0 }.contains("must be positive"), "a count of zero")
      }
    },
  ]

  /// Runs `body` with two fake harnesses, each with a committed source tree
  /// and a provenance file. The Rust fake's snapshot holds `rustCell` where the Swift one holds "a".
  private static func withFrozenFakes(rustCell: String, pairs: Int = 2, _ body: (Options) throws -> Void) throws {
    try withTemporaryDirectory("dev-emulator-fakes-") { directory in
      var options = Options()
      options.pairs = pairs
      options.samplesPerTurn = 1
      options.timeoutSeconds = 10
      options.paths["output"] = directory + "/report"
      for (implementation, cell) in [("swift", "a"), ("rust", rustCell)] {
        let root = directory + "/" + implementation + "-source", harness = directory + "/" + implementation + "-harness"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try implementation.write(toFile: root + "/core", atomically: true, encoding: .utf8)
        let git = ["git", "-C", root, "-c", "user.name=dev", "-c", "user.email=dev@example.invalid", "-c", "commit.gpgsign=false"]
        for step in [["init", "--quiet"], ["add", "core"], ["commit", "--quiet", "--message", "frozen"]] {
          _ = try commandOutput(git + step)
        }
        // Arguments arrive as --workload W --bytes N --snapshot PATH.
        try writeExecutable(harness, """
          #!/bin/sh
          printf '{"input_ready":true,"revision":%s,"rows":[{"id":%s,"cells":"\(cell)"}]}' "$$" "$$" > "$6"
          printf '{"protocol":1,"workload":"%s","payload_bytes":1048576,"payload_fnv1a64":"0123456789abcdef",' "$2"
          printf '"reply_bytes":7,"reply_fnv1a64":"fedcba9876543210","elapsed_ns":976563}\\n'

          """)
        let provenance: JSONValue = [
          "implementation": .string(implementation), "source_root": .string(root),
          "source_commit": .string(try commandOutput(["git", "-C", root, "rev-parse", "HEAD"])), "source_tree_clean": true,
          "executable": "relative/harness", "executable_sha256": .string(try sha256(ofFile: harness)),
          "compiler": "none", "build_wall_seconds": 1.5, "build_command": "none",
        ]
        try provenance.write(to: directory + "/" + implementation + "-provenance.json")
        options.paths[implementation + "-bin"] = harness
        options.paths[implementation + "-root"] = root
        options.paths[implementation + "-provenance"] = directory + "/" + implementation + "-provenance.json"
      }
      try body(options)
    }
  }
}
