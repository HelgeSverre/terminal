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
  values.forEach { print("native/\($0)") }
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
      let path = root.appendingPathComponent("native/\(value)").path
      guard FileManager.default.fileExists(atPath: path) else {
        fputs("Missing \(name) source: \(path)\n", stderr); exit(2)
      }
      count += 1
    }
  }
  // Bundle assembly stays in justfile, but verify every non-Swift input that
  // its recipe compiles or copies so a source-only cache cannot hide a broken
  // header, shader, launch helper, plist, shell integration or font tree.
  for relative in ["native/Bridge.h", "native/Spawn.c", "native/Launcher.c", "native/Terminal.metal", "native/Info.plist", "native/ShellIntegration", "assets/fonts"] {
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) else {
      fputs("Missing bundle/build input: \(relative)\n", stderr); exit(2)
    }
  }
  print("Swift source graph verified: \(graph.app.count) app sources; \(graph.tests?.count ?? 0) test groups; \(count) declared paths; bundle inputs present")
  exit(0)
}
let sources = graph.app.map { root.appendingPathComponent("native/\($0)").path }

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

struct ReleaseProvenance: Encodable {
  let configuration: String
  let sourceGraphSHA256: String
  let appSourcesSHA256: String
  let bridgeSHA256: String
  let spawnSourceSHA256: String
  let compiler: String
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
    let spawnSource = root.appendingPathComponent("native/Spawn.c")
    let spawn = build.appendingPathComponent("Spawn.o").path
    let executable = build.appendingPathComponent("Terminal").path
    let bridge = root.appendingPathComponent("native/Bridge.h").path
    let releaseFlags = [
      "-swift-version", "5", "-O", "-whole-module-optimization", "-target", "arm64-apple-macosx15.0",
      "-module-name", "TerminalIncremental", "-import-objc-header", bridge,
      "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Metal", "-framework", "CoreText", "-framework", "ImageIO",
    ]
    let graphHash = sha256(try Data(contentsOf: graphURL))
    let appSourcesHash = try sourcesHash(sources)
    let bridgeHash = sha256(try Data(contentsOf: URL(fileURLWithPath: bridge)))
    let spawnSourceHash = sha256(try Data(contentsOf: spawnSource))
    let (_, compileTime) = try milliseconds {
      try run(["clang", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0", "-c", spawnSource.path, "-o", spawn])
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
      compiler: try capture(["swiftc", "-version"]),
      sdkPath: try capture(["--sdk", "macosx", "--show-sdk-path"]),
      target: "arm64-apple-macosx15.0",
      module: "TerminalIncremental",
      flags: releaseFlags,
      executableSHA256: sha256(try Data(contentsOf: executableURL)),
      executableBytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
      compileMilliseconds: compileTime)
    try JSONEncoder().encode(provenance).write(to: provenanceURL, options: .atomic)
    print(String(format: "Swift release WMO compile %.2f ms; executable %@", compileTime, executable))
    exit(0)
  } catch {
    fputs("Swift release build failed: \(error)\n", stderr)
    exit(1)
  }
}

do {
  let fm = FileManager.default
  if clean, fm.fileExists(atPath: build.path) { try fm.removeItem(at: build) }
  try fm.createDirectory(at: build, withIntermediateDirectories: true)
  let graphURL = root.appendingPathComponent("tools/swift-sources.json")
  let configuration = fnv1a([
    try Data(contentsOf: graphURL),
    try Data(contentsOf: root.appendingPathComponent("native/Bridge.h")),
    Data("swift-5-O-arm64-apple-macosx15.0-AppKit-QuartzCore-Metal-CoreText-ImageIO".utf8),
  ])
  let configurationURL = build.appendingPathComponent("configuration.fingerprint")
  let priorConfiguration = try? String(contentsOf: configurationURL, encoding: .utf8)
  if priorConfiguration != configuration, fm.fileExists(atPath: build.path) {
    try fm.removeItem(at: build)
    try fm.createDirectory(at: build, withIntermediateDirectories: true)
  }
  try configuration.write(to: configurationURL, atomically: true, encoding: .utf8)
  let objectDirectory = build.appendingPathComponent("objects", isDirectory: true)
  try fm.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
  let spawn = build.appendingPathComponent("Spawn.o").path
  let mapURL = build.appendingPathComponent("output-file-map.json")
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
  try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]).write(to: mapURL)
  let common = [
    "swiftc", "-incremental", "-c", "-swift-version", "5", "-O", "-target", "arm64-apple-macosx15.0",
    "-module-name", "TerminalIncremental", "-import-objc-header", root.appendingPathComponent("native/Bridge.h").path,
    "-output-file-map", mapURL.path, "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Metal",
    "-framework", "CoreText", "-framework", "ImageIO",
  ]
  let stampURL = build.appendingPathComponent("source.stamp")
  let stamp = try sources.map { source in
    let attributes = try fm.attributesOfItem(atPath: source)
    return "\(source)\t\(attributes[.size] ?? 0)\t\(attributes[.modificationDate] as? Date ?? .distantPast)"
  }.joined(separator: "\n")
  let executable = build.appendingPathComponent("Terminal").path
  if !clean, priorConfiguration == configuration, (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp,
    fm.isExecutableFile(atPath: executable)
  {
    print("Swift incremental no-op; cached executable \(executable)")
    exit(0)
  }
  let (_, compileTime) = try milliseconds {
    if !fm.fileExists(atPath: spawn) || priorConfiguration != configuration {
      try run(["clang", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0", "-c", root.appendingPathComponent("native/Spawn.c").path, "-o", spawn])
    }
    try run(common + sources)
  }
  let objects = sources.map { source -> String in
    let stem = pathName(source)
    return objectDirectory.appendingPathComponent("\(stem).o").path
  }
  let (_, linkTime) = try milliseconds {
    try run(["swiftc", "-target", "arm64-apple-macosx15.0"] + objects + [spawn,
      "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Metal", "-framework", "CoreText",
      "-framework", "ImageIO", "-o", executable])
  }
  try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
  print(String(format: "Swift incremental compile %.2f ms; link %.2f ms; executable %@", compileTime, linkTime, executable))
} catch {
  fputs("Swift incremental build failed: \(error)\n", stderr)
  exit(1)
}
