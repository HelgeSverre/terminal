import Foundation

/// Tests the justfile's `_glyph-rendering-tests` recipe: when the GPU glyph
/// gate runs, and when a hosted runner's known driver fault may skip it.
///
/// The recipe itself is run by `just`, in a temporary directory, so its shell
/// logic and exit status are what is tested. The compiler, the probe and the
/// nested recipes are replaced by scripts; nothing touches Metal or a window.
enum GlyphPolicy {
  struct Scenario {
    let name: String
    /// What the stand-in upload probe prints and how it exits.
    let probeStatus: Int
    let knownDevice: Bool
    let completedUpload: Bool
    /// The value of `TERMINAL_CI_GPU_POLICY`.
    let policy: String
    let cpuStatus: Int
    /// What the recipe must do.
    let expectedStatus: Int
    let runsGPUGate: Bool
    let writesSkip: Bool
  }

  static let scenarios = [
    Scenario(name: "known-driver-fault", probeStatus: 139, knownDevice: true, completedUpload: false, policy: "paravirtual",
             cpuStatus: 0, expectedStatus: 0, runsGPUGate: false, writesSkip: true),
    Scenario(name: "unknown-fault", probeStatus: 139, knownDevice: false, completedUpload: false, policy: "paravirtual",
             cpuStatus: 0, expectedStatus: 139, runsGPUGate: false, writesSkip: false),
    Scenario(name: "different-error", probeStatus: 1, knownDevice: true, completedUpload: false, policy: "paravirtual",
             cpuStatus: 0, expectedStatus: 1, runsGPUGate: false, writesSkip: false),
    Scenario(name: "probe-success", probeStatus: 0, knownDevice: true, completedUpload: true, policy: "paravirtual",
             cpuStatus: 0, expectedStatus: 0, runsGPUGate: true, writesSkip: false),
    Scenario(name: "later-driver-fault", probeStatus: 139, knownDevice: true, completedUpload: true, policy: "paravirtual",
             cpuStatus: 0, expectedStatus: 139, runsGPUGate: false, writesSkip: false),
    Scenario(name: "local-default", probeStatus: 139, knownDevice: true, completedUpload: false, policy: "",
             cpuStatus: 0, expectedStatus: 0, runsGPUGate: true, writesSkip: false),
    Scenario(name: "cpu-failure", probeStatus: 139, knownDevice: true, completedUpload: false, policy: "paravirtual",
             cpuStatus: 7, expectedStatus: 7, runsGPUGate: false, writesSkip: false),
  ]

  static let tests = scenarios.map { scenario in
    SelfTest.Case(name: "glyph policy: \(scenario.name)") { try check(scenario) }
  }

  /// The recipe's lines, from its name to the end of its indented body.
  static func recipe() throws -> String {
    let lines = try String(contentsOfFile: Repository.path("justfile"), encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false)
    guard let start = lines.firstIndex(where: { $0.hasPrefix("_glyph-rendering-tests:") }) else { throw Failure("missing glyph gate") }
    let body = lines[(start + 1)...].prefix { $0.hasPrefix("    ") || $0.allSatisfy(\.isWhitespace) }
    return ([lines[start]] + body).joined(separator: "\n") + "\n"
  }

  private static func check(_ scenario: Scenario) throws {
    let just = try executablePath("just")
    try withTemporaryDirectory("dev-glyph-policy-") { directory in
      try FileManager.default.createDirectory(atPath: directory + "/bin", withIntermediateDirectories: true)
      try recipe().write(toFile: directory + "/justfile", atomically: true, encoding: .utf8)
      // Nested recipes only record that they were asked for; the CPU gate also exits as told.
      try writeExecutable(directory + "/bin/just", """
        #!/bin/bash
        printf '%s\\n' "$1" >> invoked
        if [[ "$1" == _glyph-raster-tests ]]; then exit "${CPU_STATUS:-0}"; fi

        """)
      // `xcrun swift` prints a source list; `xcrun swiftc` installs the stand-in probe as the build product.
      try writeExecutable(directory + "/bin/xcrun", """
        #!/bin/bash
        if [[ "$1" == swift ]]; then
          echo tests/MetalUploadProbe.swift
        else
          cp "$PROBE_SOURCE" target/native/metal-upload-probe
          chmod +x target/native/metal-upload-probe
        fi

        """)
      var markers = scenario.knownDevice ? """
        echo 'METAL_UPLOAD_DEVICE=name=Apple Paravirtual registry=1'
        echo 'METAL_UPLOAD_PROBE=after_shared_texture_replace'
        echo 'METAL_UPLOAD_PROBE=before_shared_heap_texture_replace'

        """ : "echo unknown\n"
      if scenario.completedUpload { markers += "echo 'METAL_UPLOAD_PROBE=after_shared_heap_texture_replace'\n" }
      try writeExecutable(directory + "/probe", "#!/bin/bash\n\(markers)exit \(scenario.probeStatus)\n")
      // A skip left by an earlier run must never survive a local pass or a failed run.
      let result = directory + "/reports/gpu-policy/glyph-residency.json"
      try FileManager.default.createDirectory(atPath: directory + "/reports/gpu-policy", withIntermediateDirectories: true)
      try #"{"status":"stale"}"#.write(toFile: result, atomically: true, encoding: .utf8)

      let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
      let finished = try runCaptured(
        [just, "--justfile", directory + "/justfile", "_glyph-rendering-tests"],
        adding: ["PATH": "\(directory)/bin:\(path)", "PROBE_SOURCE": directory + "/probe",
                 "TERMINAL_CI_GPU_POLICY": scenario.policy, "CPU_STATUS": String(scenario.cpuStatus)],
        directory: directory)
      let calls = ((try? String(contentsOfFile: directory + "/invoked", encoding: .utf8)) ?? "").split(separator: "\n")
      try expect(!finished.signalled && Int(finished.code) == scenario.expectedStatus,
                 "status \(finished.exitStatus), expected \(scenario.expectedStatus)\n\(finished.text)")
      try expect(calls.first == "_glyph-raster-tests", "missing CPU gate")
      try expect(calls.contains("_glyph-residency-tests") == scenario.runsGPUGate, "wrong GPU gate")
      try expect(FileManager.default.fileExists(atPath: result) == scenario.writesSkip, "wrong skip report")
      if scenario.writesSkip {
        try expect(try JSONValue(parsingFile: result)["status"]?.text == "skipped", "invalid skip report")
      }
    }
  }
}
