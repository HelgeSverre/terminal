import CryptoKit
import Foundation

// Builds only the AppKit host. Cargo owns terminal-core; its archive is a link
// input, so a Rust-only edit must never invalidate Swift's frontend cache.
enum BuildError: Error { case command([String], Int32), missing(String) }
struct SourceGraph: Decodable { let app: [String]; let tests: [String: [String]] }
struct SourceState: Codable {
  let path: String
  let contentHash: String
  let modificationTime: TimeInterval
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let arguments = Array(CommandLine.arguments.dropFirst())
let cache = root.appendingPathComponent("target/swift-host-incremental", isDirectory: true)
let graphURL = root.appendingPathComponent("tools/swift-sources.json")
let graph: SourceGraph

do {
  graph = try JSONDecoder().decode(SourceGraph.self, from: Data(contentsOf: graphURL))
} catch {
  fputs("Invalid tools/swift-sources.json: \(error)\n", stderr)
  exit(2)
}

func group(_ name: String) -> [String]? { name == "app" ? graph.app : graph.tests[name] }
if let index = arguments.firstIndex(of: "--print"), arguments.indices.contains(index + 1) {
  guard let values = group(arguments[index + 1]) else {
    fputs("Unknown source group: \(arguments[index + 1])\n", stderr)
    exit(2)
  }
  values.forEach { print("native/\($0)") }
  exit(0)
}

func run(_ arguments: [String], capture: Bool = false) throws -> String {
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  task.arguments = arguments
  let output = Pipe()
  if capture {
    task.standardOutput = output
    task.standardError = output
  } else {
    task.standardOutput = FileHandle.standardOutput
    task.standardError = FileHandle.standardError
  }
  try task.run()
  task.waitUntilExit()
  guard task.terminationStatus == 0 else { throw BuildError.command(arguments, task.terminationStatus) }
  return capture ? String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) : ""
}

func sha256(_ data: [Data]) -> String {
  var digest = SHA256()
  for value in data { digest.update(data: value) }
  return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

func fileHash(_ url: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var digest = SHA256()
  while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { digest.update(data: chunk) }
  return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

func fingerprint(files: [URL], extra: [String] = []) throws -> String {
  var parts = extra.map { Data("value\u{0}\($0)\n".utf8) }
  for file in files.sorted(by: { $0.path < $1.path }) {
    parts.append(Data("file\u{0}\(file.path)\u{0}".utf8))
    parts.append(Data(try fileHash(file).utf8))
    parts.append(Data([0x0A]))
  }
  return sha256(parts)
}

func sourceStates(files: [URL]) throws -> [SourceState] {
  let fm = FileManager.default
  return try files.sorted(by: { $0.path < $1.path }).map { file in
    let attributes = try fm.attributesOfItem(atPath: file.path)
    let date = attributes[.modificationDate] as? Date ?? .distantPast
    return SourceState(path: file.path, contentHash: try fileHash(file), modificationTime: date.timeIntervalSinceReferenceDate)
  }
}

func sourceFingerprint(_ states: [SourceState]) -> String {
  sha256(states.map { Data("\($0.path)\u{0}\($0.contentHash)\n".utf8) })
}

func preservedTimestampMutation(previous: [SourceState], current: [SourceState]) -> Bool {
  let oldByPath = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) })
  return current.contains { state in
    guard let old = oldByPath[state.path] else { return false }
    return old.contentHash != state.contentHash && old.modificationTime == state.modificationTime
  }
}

func isContained(_ file: String, under directory: URL) -> Bool {
  let url = directory.appendingPathComponent(file).standardizedFileURL
  return url.path.hasPrefix(directory.standardizedFileURL.path + "/")
}

func objectName(_ source: String) -> String {
  let safe = source.map { $0.isLetter || $0.isNumber ? $0 : "_" }
  return "\(String(safe))-\(sha256([Data(source.utf8)]).prefix(16))"
}

if arguments.contains("--verify") {
  let fm = FileManager.default
  let groups = [("app", graph.app)] + graph.tests.keys.sorted().compactMap { name in graph.tests[name].map { ("tests.\(name)", $0) } }
  for (name, files) in groups {
    guard Set(files).count == files.count else {
      fputs("Duplicate source in \(name)\n", stderr)
      exit(2)
    }
    for file in files where !isContained(file, under: root.appendingPathComponent("native")) || !file.hasSuffix(".swift") {
      fputs("Invalid \(name) source path: \(file)\n", stderr)
      exit(2)
    }
    for file in files where !fm.fileExists(atPath: root.appendingPathComponent("native/\(file)").path) {
      fputs("Missing \(name) source: \(file)\n", stderr)
      exit(2)
    }
  }
  let native = root.appendingPathComponent("native", isDirectory: true)
  let nativeSources = Set(
    (fm.enumerator(at: native, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
      .filter { $0.pathExtension == "swift" && !$0.path.contains("/tests/") }
      .map { $0.path.replacingOccurrences(of: native.path + "/", with: "") }
  )
  let listedAppSources = Set(graph.app)
  if nativeSources != listedAppSources {
    let omitted = nativeSources.subtracting(listedAppSources).sorted()
    let stale = listedAppSources.subtracting(nativeSources).sorted()
    fputs("App source graph mismatch; unlisted: \(omitted), non-app entries: \(stale)\n", stderr)
    exit(2)
  }
  let nativeTests = Set(
    (fm.enumerator(at: native.appendingPathComponent("tests"), includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
      .filter { $0.pathExtension == "swift" }
      .map { $0.path.replacingOccurrences(of: native.path + "/", with: "") }
  )
  let listedTests = Set(graph.tests.values.flatMap { $0.filter { $0.hasPrefix("tests/") } })
  if nativeTests != listedTests {
    fputs("Test source graph mismatch; unlisted: \(nativeTests.subtracting(listedTests).sorted()), stale: \(listedTests.subtracting(nativeTests).sorted())\n", stderr)
    exit(2)
  }
  for file in ["native/Bridge.h", "native/Spawn.c", "native/Launcher.c", "native/Terminal.metal", "native/Info.plist", "native/Terminal.sdef", "native/Terminal.terminfo", "native/ShellIntegration", "assets/fonts"] where !fm.fileExists(atPath: root.appendingPathComponent(file).path) {
    fputs("Missing build input: \(file)\n", stderr)
    exit(2)
  }
  print("Swift host source graph verified: \(graph.app.count) app sources; \(graph.tests.count) test groups")
  exit(0)
}

do {
  let fm = FileManager.default
  if arguments.contains("--clean") {
    if fm.fileExists(atPath: cache.path) { try fm.removeItem(at: cache) }
    print("Swift host cache removed")
    exit(0)
  }
  try fm.createDirectory(at: cache, withIntermediateDirectories: true)

  let bridge = root.appendingPathComponent("native/Bridge.h")
  let sources = graph.app.map { root.appendingPathComponent("native/\($0)") }
  let compiler = try run(["swiftc", "-version"], capture: true)
  let compilerPath = try run(["--find", "swiftc"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
  let compilerIdentity = try fileHash(URL(fileURLWithPath: compilerPath))
  let sdkPath = try run(["--sdk", "macosx", "--show-sdk-path"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
  let sdkVersion = try run(["--sdk", "macosx", "--show-sdk-version"], capture: true)
  let sdkBuild = try run(["--sdk", "macosx", "--show-sdk-build-version"], capture: true)
  let compileFlags = [
    "-incremental", "-c", "-swift-version", "5", "-O", "-target", "arm64-apple-macosx15.0",
    "-module-name", "TerminalHostIncremental", "-import-objc-header", bridge.path,
  ]
  let linkFlags = ["-target", "arm64-apple-macosx15.0", "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Metal", "-framework", "CoreText"]
  let configuration = try fingerprint(
    files: [graphURL, bridge],
    extra: ["compiler-path=\(compilerPath)", "compiler-build=\(compiler)", "compiler-sha256=\(compilerIdentity)", "sdk-path=\(sdkPath)", "sdk-version=\(sdkVersion)", "sdk-build=\(sdkBuild)", "compile=\(compileFlags.joined(separator: "\u{1F}"))", "link=\(linkFlags.joined(separator: "\u{1F}"))"]
  )
  let configurationURL = cache.appendingPathComponent("configuration.fingerprint")
  let priorConfiguration = try? String(contentsOf: configurationURL, encoding: .utf8)
  if priorConfiguration != configuration {
    if fm.fileExists(atPath: cache.path) { try fm.removeItem(at: cache) }
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try configuration.write(to: configurationURL, atomically: true, encoding: .utf8)
  }

  let objects = cache.appendingPathComponent("objects", isDirectory: true)
  try fm.createDirectory(at: objects, withIntermediateDirectories: true)
  var outputMap: [String: [String: String]] = ["": ["swift-dependencies": cache.appendingPathComponent("master.swiftdeps").path]]
  for source in sources {
    let name = objectName(source.path)
    outputMap[source.path] = [
      "object": objects.appendingPathComponent("\(name).o").path,
      "swift-dependencies": objects.appendingPathComponent("\(name).swiftdeps").path,
      "dependencies": objects.appendingPathComponent("\(name).d").path,
    ]
  }
  let outputMapURL = cache.appendingPathComponent("output-file-map.json")
  try JSONSerialization.data(withJSONObject: outputMap, options: [.sortedKeys]).write(to: outputMapURL)

  let currentSourceStates = try sourceStates(files: sources)
  let sourceStamp = sourceFingerprint(currentSourceStates)
  let sourceStampURL = cache.appendingPathComponent("source.fingerprint")
  let sourceStateURL = cache.appendingPathComponent("source-state.json")
  let archive = root.appendingPathComponent("target/release/libterminal_core.a")
  let spawn = root.appendingPathComponent("target/native/Spawn.o")
  guard fm.fileExists(atPath: archive.path), fm.fileExists(atPath: spawn.path) else {
    throw BuildError.missing("Run Cargo and compile Spawn.o before Swift host link")
  }
  let linkStamp = try fingerprint(files: [archive, spawn], extra: ["link=\(linkFlags.joined(separator: "\u{1F}"))"])
  let linkStampURL = cache.appendingPathComponent("link.fingerprint")
  let executable = cache.appendingPathComponent("Terminal")
  let expectedOutputs = sources.flatMap { source -> [URL] in
    let name = objectName(source.path)
    return [objects.appendingPathComponent("\(name).o"), objects.appendingPathComponent("\(name).swiftdeps")]
  }
  let priorSourceStamp = try? String(contentsOf: sourceStampURL, encoding: .utf8)
  let priorSourceStates = try? JSONDecoder().decode([SourceState].self, from: Data(contentsOf: sourceStateURL))
  let missingSourceStates = priorSourceStates == nil
  let preservedMutation = priorSourceStates.map {
    preservedTimestampMutation(previous: $0, current: currentSourceStates)
  } ?? false
  if missingSourceStates || preservedMutation {
    // Swift 6.2's incremental dependency state is timestamp based. Remove it
    // if source timestamps conceal changes or the comparison state was lost.
    // An invalidation failure must fail the build rather than reuse stale code.
    for stale in [objects, cache.appendingPathComponent("master.priors")]
      where fm.fileExists(atPath: stale.path) {
      try fm.removeItem(at: stale)
    }
    try fm.createDirectory(at: objects, withIntermediateDirectories: true)
  }
  let missingOutputs = expectedOutputs.contains { !fm.fileExists(atPath: $0.path) }
  let needsCompile = priorConfiguration != configuration || priorSourceStamp != sourceStamp || missingOutputs
  let needsLink = needsCompile || (try? String(contentsOf: linkStampURL, encoding: .utf8)) != linkStamp || !fm.isExecutableFile(atPath: executable.path)

  if needsCompile {
    _ = try run(["swiftc"] + compileFlags + ["-output-file-map", outputMapURL.path] + sources.map(\.path))
    try sourceStamp.write(to: sourceStampURL, atomically: true, encoding: .utf8)
    try JSONEncoder().encode(currentSourceStates).write(to: sourceStateURL)
  }
  if needsLink {
    let outputObjects = sources.map { objects.appendingPathComponent("\(objectName($0.path)).o").path }
    _ = try run(["swiftc"] + linkFlags + outputObjects + [spawn.path, archive.path, "-o", executable.path])
    try linkStamp.write(to: linkStampURL, atomically: true, encoding: .utf8)
  }
  print(needsCompile ? "Swift host incremental compile + link" : needsLink ? "Swift host relink (Rust/C input changed)" : "Swift host no-op")
} catch {
  fputs("Swift host build failed: \(error)\n", stderr)
  exit(1)
}
