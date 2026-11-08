import Foundation

// A deliberately small build seam for measuring Swift's actual per-source
// incremental compiler mode. It builds only the executable: bundle assembly,
// Metal and signing are intentionally outside this timing because they do not
// exercise the Swift dependency graph.

enum IncrementalBuildError: Error { case command([String], Int32) }

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let build = root.appendingPathComponent("target/swift-incremental", isDirectory: true)
let clean = CommandLine.arguments.dropFirst().contains("--clean")
struct SourceGraph: Decodable { let app: [String] }
let graph: SourceGraph
do {
  graph = try JSONDecoder().decode(
    SourceGraph.self, from: Data(contentsOf: root.appendingPathComponent("tools/swift-sources.json")))
} catch { fatalError("Invalid tools/swift-sources.json: \(error)") }
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

func milliseconds<T>(_ body: () throws -> T) rethrows -> (T, Double) {
  let start = DispatchTime.now().uptimeNanoseconds
  let result = try body()
  return (result, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

do {
  let fm = FileManager.default
  if clean, fm.fileExists(atPath: build.path) { try fm.removeItem(at: build) }
  try fm.createDirectory(at: build, withIntermediateDirectories: true)
  let objectDirectory = build.appendingPathComponent("objects", isDirectory: true)
  try fm.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
  let spawn = build.appendingPathComponent("Spawn.o").path
  let mapURL = build.appendingPathComponent("output-file-map.json")
  var map: [String: [String: String]] = [
    "": ["swift-dependencies": build.appendingPathComponent("master.swiftdeps").path]
  ]
  for source in sources {
    let stem = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
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
  let (_, compileTime) = try milliseconds {
    try run(["clang", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0", "-c", root.appendingPathComponent("native/Spawn.c").path, "-o", spawn])
    try run(common + sources)
  }
  let objects = sources.map { source -> String in
    let stem = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
    return objectDirectory.appendingPathComponent("\(stem).o").path
  }
  let executable = build.appendingPathComponent("Terminal").path
  let (_, linkTime) = try milliseconds {
    try run(["swiftc", "-target", "arm64-apple-macosx15.0"] + objects + [spawn,
      "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Metal", "-framework", "CoreText",
      "-framework", "ImageIO", "-o", executable])
  }
  print(String(format: "Swift incremental compile %.2f ms; link %.2f ms; executable %@", compileTime, linkTime, executable))
} catch {
  fputs("Swift incremental build failed: \(error)\n", stderr)
  exit(1)
}
