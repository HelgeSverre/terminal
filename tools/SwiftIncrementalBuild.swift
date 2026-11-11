import CryptoKit
import Foundation

// A deliberately small build seam for measuring Swift's actual per-source
// incremental compiler mode. It builds only the executable: bundle assembly,
// Metal and signing are intentionally outside this timing because they do not
// exercise the Swift dependency graph.

enum IncrementalBuildError: Error { case command([String], Int32), inputsChanged }
enum BuildConfiguration: String { case development, release }

func requestedConfiguration(_ arguments: [String]) -> BuildConfiguration {
  guard let index = arguments.firstIndex(of: "--configuration") else { return .development }
  guard arguments.indices.contains(index + 1), let configuration = BuildConfiguration(rawValue: arguments[index + 1]) else {
    fputs("Use --configuration development or --configuration release\n", stderr)
    exit(2)
  }
  return configuration
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let arguments = Array(CommandLine.arguments.dropFirst())
let configuration = requestedConfiguration(arguments)
let build = root.appendingPathComponent(
  configuration == .development ? "target/swift-incremental" : "target/swift-release",
  isDirectory: true)
let clean = arguments.contains("--clean")
struct SourceGraph: Decodable {
  let app: [String]
  let emulation: [String]?
  let tests: [String: [String]]?
}
let graph: SourceGraph
do {
  graph = try JSONDecoder().decode(
    SourceGraph.self, from: Data(contentsOf: root.appendingPathComponent("tools/swift-sources.json")))
} catch { fatalError("Invalid tools/swift-sources.json: \(error)") }
func graphSources(_ group: String) -> [String]? {
  if group == "app" { return graph.app }
  if group == "emulation" { return graph.emulation }
  return graph.tests?[group]
}
if let index = arguments.firstIndex(of: "--print"), arguments.indices.contains(index + 1) {
  guard let values = graphSources(arguments[index + 1]) else {
    fputs("Unknown source group: \(arguments[index + 1])\n", stderr); exit(2)
  }
  values.forEach { print($0) }
  exit(0)
}
if arguments.contains("--verify") {
  var groups: [(String, [String])] = [("app", graph.app)]
  if let emulation = graph.emulation { groups.append(("emulation", emulation)) }
  for (name, values) in graph.tests ?? [:] { groups.append(("tests.\(name)", values)) }
  var count = 0
  for (name, values) in groups {
    guard Set(values).count == values.count else {
      fputs("Duplicate source in \(name)\n", stderr); exit(2)
    }
    for value in values {
      let allowedRoots = ["Sources/Terminal", "Tests/Programs"]
      let source = root.appendingPathComponent(value).standardizedFileURL.resolvingSymlinksInPath()
      guard value.hasSuffix(".swift"), allowedRoots.contains(where: { directory in
        value.hasPrefix(directory + "/")
          && source.path.hasPrefix(root.appendingPathComponent(directory).resolvingSymlinksInPath().path + "/")
      }) else {
        fputs("Invalid \(name) source path: \(value)\n", stderr); exit(2)
      }
      let path = source.path
      guard FileManager.default.fileExists(atPath: path) else {
        fputs("Missing \(name) source: \(path)\n", stderr); exit(2)
      }
      count += 1
    }
  }
  func swiftFiles(in directory: String) -> Set<String> {
    let url = root.appendingPathComponent(directory, isDirectory: true)
    return Set((FileManager.default.enumerator(at: url,
      includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
      .filter { $0.pathExtension == "swift" }
      .map { String($0.path.dropFirst(root.path.count + 1)) })
  }
  let appFiles = swiftFiles(in: "Sources/Terminal")
  let testFiles = swiftFiles(in: "Tests/Programs")
  let declaredApp = Set(graph.app)
  let declaredTests = Set((graph.tests ?? [:]).values.flatMap { $0 }.filter { $0.hasPrefix("Tests/Programs/") })
  guard appFiles == declaredApp else {
    fputs("App source graph mismatch; unlisted: \(appFiles.subtracting(declaredApp).sorted()), stale: \(declaredApp.subtracting(appFiles).sorted())\n", stderr); exit(2)
  }
  guard testFiles == declaredTests else {
    fputs("Test source graph mismatch; unlisted: \(testFiles.subtracting(declaredTests).sorted()), stale: \(declaredTests.subtracting(testFiles).sorted())\n", stderr); exit(2)
  }
  guard Set(graph.emulation ?? []).isSubset(of: declaredApp) else {
    fputs("Emulation sources must belong to the app graph\n", stderr); exit(2)
  }
  // Bundle assembly stays in justfile, but verify every non-Swift input that
  // its recipe compiles or copies so a source-only cache cannot hide a broken
  // header, shader, launch helper, plist, shell integration or font tree.
  for relative in ["Sources/Terminal/Interop/Bridge.h", "Sources/Terminal/Interop/Spawn.c",
    "Sources/TerminalLauncher/Launcher.c", "Resources/Terminal/Terminal.metal",
    "Resources/Terminal/Info.plist", "Resources/Terminal/Terminal.sdef",
    "Resources/Terminal/Terminal.terminfo", "Resources/Terminal/ShellIntegration",
    "assets/AppIcon.png", "assets/fonts"] {
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) else {
      fputs("Missing bundle/build input: \(relative)\n", stderr); exit(2)
    }
  }
  print("Swift source graph verified: \(graph.app.count) app sources; \(graph.tests?.count ?? 0) test groups; \(count) declared paths; bundle inputs present")
  exit(0)
}
let sources = graph.app.map { root.appendingPathComponent($0).path }

func run(_ arguments: [String]) throws {
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  task.arguments = arguments
  task.standardOutput = FileHandle.standardOutput
  task.standardError = FileHandle.standardError
  try task.run()
  task.waitUntilExit()
  guard task.terminationStatus == 0 else { throw IncrementalBuildError.command(arguments, task.terminationStatus) }
}

func capture(_ arguments: [String]) throws -> String {
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  task.arguments = arguments
  let output = Pipe()
  task.standardOutput = output
  task.standardError = FileHandle.standardError
  try task.run()
  task.waitUntilExit()
  guard task.terminationStatus == 0 else { throw IncrementalBuildError.command(arguments, task.terminationStatus) }
  return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sourcesHash(_ sources: [String]) throws -> String {
  var digest = SHA256()
  for source in sources.sorted() {
    let relative = source.hasPrefix(root.path + "/") ? String(source.dropFirst(root.path.count + 1)) : source
    digest.update(data: Data("\(relative)\u{0}".utf8))
    digest.update(data: try Data(contentsOf: URL(fileURLWithPath: source)))
  }
  return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

// Content is authoritative. Modification time only detects edits hidden from
// Swift's timestamp-based incremental dependency state.
struct SourceState: Codable {
  let path: String
  let contentHash: String
  let modificationTime: TimeInterval
}
func fileHash(_ url: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var digest = SHA256()
  while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { digest.update(data: data) }
  return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
func sourceStates() throws -> [SourceState] {
  try sources.sorted().map { path in
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let date = attributes[.modificationDate] as? Date ?? .distantPast
    return SourceState(path: path, contentHash: try fileHash(URL(fileURLWithPath: path)),
      modificationTime: date.timeIntervalSinceReferenceDate)
  }
}
func sourceFingerprint(_ states: [SourceState]) -> String {
  sha256(Data(states.map { "\($0.path)\u{0}\($0.contentHash)\n" }.joined().utf8))
}
struct Toolchain: Codable {
  let swiftPath: String
  let swiftVersion: String
  let swiftSHA256: String
  let clangPath: String
  let clangVersion: String
  let clangSHA256: String
  let sdkPath: String
  let sdkVersion: String
  let sdkBuild: String
  static func current() throws -> Toolchain {
    let swift = try capture(["--find", "swiftc"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let clang = try capture(["--find", "clang"]).trimmingCharacters(in: .whitespacesAndNewlines)
    return try Toolchain(swiftPath: swift, swiftVersion: capture(["swiftc", "-version"]),
      swiftSHA256: fileHash(URL(fileURLWithPath: swift)),
      clangPath: clang, clangVersion: capture(["clang", "--version"]),
      clangSHA256: fileHash(URL(fileURLWithPath: clang)),
      sdkPath: capture(["--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines),
      sdkVersion: capture(["--sdk", "macosx", "--show-sdk-version"]),
      sdkBuild: capture(["--sdk", "macosx", "--show-sdk-build-version"]))
  }
  var fingerprint: String {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    return sha256(try! encoder.encode(self))
  }
}

struct ReleaseProvenance: Encodable {
  let configuration: String
  let sourceGraphSHA256: String
  let appSourcesSHA256: String
  let bridgeSHA256: String
  let spawnSourceSHA256: String
  let compiler: String
  let toolchain: Toolchain
  let cFlags: [String]
  let sdkPath: String
  let target: String
  let module: String
  let flags: [String]
  let executableSHA256: String
  let executableBytes: UInt64
  let compileMilliseconds: Double
}

func milliseconds<T>(_ body: () throws -> T) rethrows -> (T, Double) {
  let start = DispatchTime.now().uptimeNanoseconds
  let result = try body()
  return (result, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

func fnv1a(_ values: [Data]) -> String {
  var hash: UInt64 = 0xcbf29ce484222325
  for value in values {
    for byte in value { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
  }
  return String(format: "%016llx", hash)
}
func pathName(_ source: String) -> String {
  let relative = source.hasPrefix(root.path + "/") ? String(source.dropFirst(root.path.count + 1)) : source
  let safe = relative.map { $0.isLetter || $0.isNumber ? $0 : "_" }
  return "\(String(safe))-\(fnv1a([Data(source.utf8)]))"
}

if configuration == .release {
  do {
    let fm = FileManager.default
    if clean, fm.fileExists(atPath: build.path) { try fm.removeItem(at: build) }
    try fm.createDirectory(at: build, withIntermediateDirectories: true)
    let provenanceURL = build.appendingPathComponent("provenance.json")
    if fm.fileExists(atPath: provenanceURL.path) { try fm.removeItem(at: provenanceURL) }

    // Distribution artifacts trade edit/rebuild speed for the optimizer's
    // complete view of the same app graph used by development.
    let graphURL = root.appendingPathComponent("tools/swift-sources.json")
    let spawnSource = root.appendingPathComponent("Sources/Terminal/Interop/Spawn.c")
    let spawn = build.appendingPathComponent("Spawn.o").path
    let executable = build.appendingPathComponent("Terminal").path
    // A failed rebuild must not leave the conventional output naming old code.
    if fm.fileExists(atPath: executable) { try fm.removeItem(atPath: executable) }
    let bridge = root.appendingPathComponent("Sources/Terminal/Interop/Bridge.h").path
    let toolchain = try Toolchain.current()
    let cFlags = ["-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0", "-isysroot", toolchain.sdkPath]
    let releaseFlags = [
      // Release skips dynamic exclusivity checks: on the parser's hot path they
      // cost a quarter of throughput. Development and test builds keep them.
      "-swift-version", "5", "-O", "-whole-module-optimization", "-enforce-exclusivity=unchecked",
      "-target", "arm64-apple-macosx15.0",
      "-sdk", toolchain.sdkPath, "-module-name", "Terminal", "-import-objc-header", bridge,
      "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Metal", "-framework", "CoreText", "-framework", "ImageIO",
    ]
    let graphHash = sha256(try Data(contentsOf: graphURL))
    let appSourcesHash = try sourcesHash(sources)
    let bridgeHash = sha256(try Data(contentsOf: URL(fileURLWithPath: bridge)))
    let spawnSourceHash = sha256(try Data(contentsOf: spawnSource))
    let (_, compileTime) = try milliseconds {
      try run(["clang"] + cFlags + ["-c", spawnSource.path, "-o", spawn])
      try run(["swiftc"] + releaseFlags + sources + [spawn, "-o", executable])
    }
    guard graphHash == sha256(try Data(contentsOf: graphURL)),
      appSourcesHash == (try sourcesHash(sources)),
      bridgeHash == sha256(try Data(contentsOf: URL(fileURLWithPath: bridge))),
      spawnSourceHash == sha256(try Data(contentsOf: spawnSource))
    else { throw IncrementalBuildError.inputsChanged }
    let executableURL = URL(fileURLWithPath: executable)
    let attributes = try fm.attributesOfItem(atPath: executable)
    let provenance = ReleaseProvenance(
      configuration: "release-wmo",
      sourceGraphSHA256: graphHash,
      appSourcesSHA256: appSourcesHash,
      bridgeSHA256: bridgeHash,
      spawnSourceSHA256: spawnSourceHash,
      compiler: toolchain.swiftVersion,
      toolchain: toolchain, cFlags: cFlags,
      sdkPath: toolchain.sdkPath,
      target: "arm64-apple-macosx15.0",
      module: "Terminal",
      flags: releaseFlags,
      executableSHA256: sha256(try Data(contentsOf: executableURL)),
      executableBytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
      compileMilliseconds: compileTime)
    try JSONEncoder().encode(provenance).write(to: provenanceURL, options: .atomic)
    print(String(format: "Swift release WMO compile %.2f ms; executable %@", compileTime, executable))
    exit(0)
  } catch {
    // WMO may have left a partially linked output; provenance must never name it.
    for output in ["Terminal", "provenance.json"] {
      let file = build.appendingPathComponent(output)
      if FileManager.default.fileExists(atPath: file.path) {
        do { try FileManager.default.removeItem(at: file) }
        catch { fputs("Could not invalidate failed release output: \(error)\n", stderr) }
      }
    }
    fputs("Swift release build failed: \(error)\n", stderr)
    exit(1)
  }
}

do {
  let fm = FileManager.default
  let toolchain = try Toolchain.current()
  let graphURL = root.appendingPathComponent("tools/swift-sources.json")
  let bridgeURL = root.appendingPathComponent("Sources/Terminal/Interop/Bridge.h")
  let spawnSource = root.appendingPathComponent("Sources/Terminal/Interop/Spawn.c")
  let objectDirectory = build.appendingPathComponent("objects", isDirectory: true)
  let mapURL = build.appendingPathComponent("output-file-map.json")
  let spawn = build.appendingPathComponent("Spawn.o").path
  let executable = build.appendingPathComponent("Terminal").path
  let cFlags = ["-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0", "-isysroot", toolchain.sdkPath]
  let linkFlags = ["-target", "arm64-apple-macosx15.0", "-sdk", toolchain.sdkPath,
    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Metal",
    "-framework", "CoreText", "-framework", "ImageIO"]
  let compileFlags = ["-incremental", "-c", "-swift-version", "5", "-O",
    "-target", "arm64-apple-macosx15.0", "-sdk", toolchain.sdkPath,
    "-module-name", "Terminal", "-import-objc-header", bridgeURL.path,
    "-output-file-map", mapURL.path]
  let graphHash = try fileHash(graphURL)
  let bridgeHash = try fileHash(bridgeURL)
  let spawnHash = try fileHash(spawnSource)
  let configuration = sha256(Data(([toolchain.fingerprint, graphHash, bridgeHash]
    + cFlags + compileFlags + linkFlags).joined(separator: "\u{0}").utf8))
  let configurationURL = build.appendingPathComponent("configuration.fingerprint")
  let priorConfiguration = try? String(contentsOf: configurationURL, encoding: .utf8)
  if clean || priorConfiguration != configuration {
    if fm.fileExists(atPath: build.path) { try fm.removeItem(at: build) }
  }
  try fm.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
  var map: [String: [String: String]] = [
    "": ["swift-dependencies": build.appendingPathComponent("master.swiftdeps").path]
  ]
  for source in sources {
    let stem = pathName(source)
    map[source] = [
      "object": objectDirectory.appendingPathComponent("\(stem).o").path,
      "swift-dependencies": objectDirectory.appendingPathComponent("\(stem).swiftdeps").path,
      "dependencies": objectDirectory.appendingPathComponent("\(stem).d").path,
      "diagnostics": objectDirectory.appendingPathComponent("\(stem).dia").path,
    ]
  }
  try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]).write(to: mapURL, options: .atomic)
  let states = try sourceStates()
  let sourceStamp = sourceFingerprint(states)
  let stateURL = build.appendingPathComponent("source-state.json")
  let stampURL = build.appendingPathComponent("source.fingerprint")
  let priorStates = try? JSONDecoder().decode([SourceState].self, from: Data(contentsOf: stateURL))
  let hiddenMutation: Bool = priorStates.map { previous in
    let oldByPath = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) })
    return states.contains { state in
      guard let old = oldByPath[state.path] else { return false }
      return old.contentHash != state.contentHash && old.modificationTime == state.modificationTime
    }
  } ?? true
  if hiddenMutation {
    // A same-timestamp content edit must not let the compiler reuse stale .o
    // files. Invalidate dependency state as well, including Swift's priors.
    for stale in [objectDirectory, build.appendingPathComponent("master.priors"),
                  build.appendingPathComponent("master.swiftdeps")]
      where fm.fileExists(atPath: stale.path) { try fm.removeItem(at: stale) }
    try fm.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
  }
  let objects = sources.map { objectDirectory.appendingPathComponent("\(pathName($0)).o").path }
  let missingOutputs = sources.contains { source in
    ["object", "swift-dependencies"].contains { !fm.fileExists(atPath: map[source]![$0]!) }
  }
  let needsCompile = hiddenMutation || missingOutputs
    || (try? String(contentsOf: stampURL, encoding: .utf8)) != sourceStamp
  let spawnStampURL = build.appendingPathComponent("spawn.fingerprint")
  let needsSpawn = !fm.fileExists(atPath: spawn)
    || (try? String(contentsOf: spawnStampURL, encoding: .utf8)) != spawnHash
  let linkStampURL = build.appendingPathComponent("link.fingerprint")
  let previousObjectHash = fm.fileExists(atPath: spawn) ? try fileHash(URL(fileURLWithPath: spawn)) : ""
  let previousObjectLinkStamp = sha256(Data((configuration + "\u{0}" + previousObjectHash).utf8))
  let needsLink = needsCompile || needsSpawn || !fm.isExecutableFile(atPath: executable)
    || (try? String(contentsOf: linkStampURL, encoding: .utf8)) != previousObjectLinkStamp
  if needsLink, fm.fileExists(atPath: executable) {
    try fm.removeItem(atPath: executable)
  }
  let (_, compileTime) = try milliseconds {
    if needsSpawn { try run(["clang"] + cFlags + ["-c", spawnSource.path, "-o", spawn]) }
    if needsCompile { try run(["swiftc"] + compileFlags + sources) }
  }
  // The C object's contents also participate: external replacement must relink.
  let linkStamp = sha256(Data((configuration + "\u{0}" + (try fileHash(URL(fileURLWithPath: spawn)))).utf8))
  let (_, linkTime) = try milliseconds {
    if needsLink { try run(["swiftc"] + linkFlags + objects + [spawn, "-o", executable]) }
  }
  guard graphHash == (try fileHash(graphURL)), bridgeHash == (try fileHash(bridgeURL)),
        spawnHash == (try fileHash(spawnSource)), sourceStamp == sourceFingerprint(try sourceStates())
  else {
    // Never leave a successful-looking cached executable after a mixed build.
    if fm.fileExists(atPath: executable) { try fm.removeItem(atPath: executable) }
    throw IncrementalBuildError.inputsChanged
  }
  try configuration.write(to: configurationURL, atomically: true, encoding: .utf8)
  try sourceStamp.write(to: stampURL, atomically: true, encoding: .utf8)
  try JSONEncoder().encode(states).write(to: stateURL, options: .atomic)
  try spawnHash.write(to: spawnStampURL, atomically: true, encoding: .utf8)
  try linkStamp.write(to: linkStampURL, atomically: true, encoding: .utf8)
  if !needsCompile && !needsLink { print("Swift incremental no-op; cached executable \(executable)") }
  else { print(String(format: "Swift incremental compile %.2f ms; link %.2f ms; executable %@", compileTime, linkTime, executable)) }
} catch {
  // A failed compiler/linker can overwrite only some objects. None may be
  // reused with fingerprints from a prior success, even if sources revert.
  if FileManager.default.fileExists(atPath: build.path) {
    do { try FileManager.default.removeItem(at: build) }
    catch { fputs("Could not invalidate failed incremental cache: \(error)\n", stderr) }
  }
  fputs("Swift incremental build failed: \(error)\n", stderr)
  exit(1)
}
