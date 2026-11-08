import Foundation

// Differential replay intentionally treats Rust as an *external* oracle. It
// never changes the Swift app build graph or links Rust into the experiment.
// A fixture supplies physical byte chunks; Swift consumes those chunks exactly,
// while Rust consumes their concatenation. The final snapshot is canonicalized
// (sorted JSON) before a recursive first-difference report is emitted.

struct Fixture: Decodable {
  let name: String
  let columns: Int
  let rows: Int
  let chunks_base64: [String]
}
struct FixtureFile: Decodable { let fixtures: [Fixture] }

enum Failure: Error, LocalizedError {
  case message(String)
  var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

func process(_ executable: String, _ args: [String], stdin: Data? = nil, cwd: String) throws -> (Data, Data) {
  let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = args
  task.currentDirectoryURL = URL(fileURLWithPath: cwd)
  let out = Pipe(), err = Pipe(); task.standardOutput = out; task.standardError = err
  let input = Pipe(); if let stdin { task.standardInput = input }
  try task.run()
  if let stdin { input.fileHandleForWriting.write(stdin); try? input.fileHandleForWriting.close() }
  task.waitUntilExit()
  let stdout = out.fileHandleForReading.readDataToEndOfFile()
  let stderr = err.fileHandleForReading.readDataToEndOfFile()
  guard task.terminationStatus == 0 else {
    throw Failure.message("\(executable) failed (\(task.terminationStatus)): \(String(decoding: stderr, as: UTF8.self))")
  }
  return (stdout, stderr)
}

func canonical(_ data: Data) throws -> Any {
  stripVolatile(try JSONSerialization.jsonObject(with: data))
}
/// Epochs/revisions describe internal publication accounting rather than the
/// terminal-visible state. Compare their behavior in dedicated transition
/// tests; omit them from transcript equivalence so the next semantic delta is
/// actionable.
func stripVolatile(_ value: Any) -> Any {
  if var object = value as? [String: Any] {
    ["revision", "geometry_epoch", "document_epoch", "history_epoch", "screen_epoch", "viewport_clamp_revision", "history"].forEach { object.removeValue(forKey: $0) }
    for (key, child) in object { object[key] = stripVolatile(child) }
    return object
  }
  if let array = value as? [Any] { return array.map(stripVolatile) }
  return value
}
func json(_ value: Any) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}
func firstDifference(_ a: Any, _ b: Any, path: String = "$") -> String? {
  if let aa = a as? [String: Any], let bb = b as? [String: Any] {
    let keys = Set(aa.keys).union(bb.keys)
    for key in keys.sorted() {
      guard let left = aa[key], let right = bb[key] else { return "\(path).\(key): key presence differs" }
      if let difference = firstDifference(left, right, path: "\(path).\(key)") { return difference }
    }
    return nil
  }
  if let aa = a as? [Any], let bb = b as? [Any] {
    guard aa.count == bb.count else { return "\(path): array count \(aa.count) != \(bb.count)" }
    for index in aa.indices { if let difference = firstDifference(aa[index], bb[index], path: "\(path)[\(index)]") { return difference } }
    return nil
  }
  return String(describing: a) == String(describing: b) ? nil : "\(path): \(String(describing: a)) != \(String(describing: b))"
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).path
let args = Array(CommandLine.arguments.dropFirst())
func argument(_ name: String, fallback: String) -> String { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? fallback }
let fixturesPath = argument("--fixtures", fallback: "native/tests/differential-fixtures.json")
let rustRoot = argument("--rust-root", fallback: ProcessInfo.processInfo.environment["TERMINAL_RUST_ORACLE_ROOT"] ?? "")
let outputPath = argument("--output", fallback: "reports/swift-port/differential.json")
guard !rustRoot.isEmpty else { throw Failure.message("pass --rust-root <frozen Rust worktree> or set TERMINAL_RUST_ORACLE_ROOT") }
let fixtures = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: URL(fileURLWithPath: fixturesPath)))
let runner = """
import Foundation
@_silgen_name("terminal_create") func terminal_create(_ c: UInt32, _ r: UInt32) -> OpaquePointer?
@_silgen_name("terminal_destroy") func terminal_destroy(_ value: OpaquePointer?)
@_silgen_name("terminal_feed") func terminal_feed(_ value: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ now: UInt64) -> Int
@_silgen_name("terminal_has_work") func terminal_has_work(_ value: OpaquePointer?) -> Bool
@_silgen_name("terminal_finish") func terminal_finish(_ value: OpaquePointer?)
@_silgen_name("terminal_snapshot") func terminal_snapshot(_ value: OpaquePointer?, _ scroll: Int, _ now: UInt64) -> UnsafeMutablePointer<CChar>?
@_silgen_name("terminal_string_free") func terminal_string_free(_ value: UnsafeMutablePointer<CChar>?)
typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void
@_silgen_name("terminal_replies") func terminal_replies(_ value: OpaquePointer?, _ context: UnsafeMutableRawPointer?, _ callback: Callback?)
final class Capture { var bytes = Data() }
let source = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let core = terminal_create((source["columns"] as! NSNumber).uint32Value, (source["rows"] as! NSNumber).uint32Value)!
defer { terminal_destroy(core) }
let capture = Capture()
let callback: Callback = { context, bytes, count in if let context, let bytes { Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().bytes.append(bytes, count: count) } }
for encoded in source["chunks_base64"] as! [String] {
  let data = Data(base64Encoded: encoded)!
  var offset = 0
  while offset < data.count || terminal_has_work(core) {
    let used = data.withUnsafeBytes { terminal_feed(core, $0.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), data.count - offset, 0) }
    terminal_replies(core, Unmanaged.passUnretained(capture).toOpaque(), callback)
    offset += used
    if used == 0 && !terminal_has_work(core) && offset < data.count { fatalError("core made no progress") }
  }
}
terminal_finish(core); terminal_replies(core, Unmanaged.passUnretained(capture).toOpaque(), callback)
let raw = terminal_snapshot(core, 0, 0)!; defer { terminal_string_free(raw) }
let value = try JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))
let output: [String: Any] = ["snapshot": value, "replies_base64": capture.bytes.base64EncodedString()]
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]); FileHandle.standardOutput.write(data)
"""
let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("terminal-swift-differential-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
// With multiple Swift sources, only a file named main.swift may contain
// top-level executable statements.
let runnerPath = temporary.appendingPathComponent("main.swift"); try runner.data(using: .utf8)!.write(to: runnerPath)
let runnerExecutable = temporary.appendingPathComponent("runner")
let sources = ["native/TerminalDocument.swift", "native/DocumentReflow.swift", "native/SwiftUnicode18Tables.swift", "native/SwiftUnicode.swift", "native/SwiftInputEncoder.swift", "native/SwiftGraphics.swift", "native/SwiftReflow.swift", "native/SwiftSearchViewport.swift", "native/SwiftMargins.swift", "native/SwiftTerminalCore.swift", runnerPath.path]
let compile = try process("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-O", "-import-objc-header", "native/Bridge.h"] + sources + ["-framework", "Foundation", "-framework", "CoreGraphics", "-framework", "ImageIO", "-o", runnerExecutable.path], cwd: root)
if !compile.1.isEmpty { fputs(String(decoding: compile.1, as: UTF8.self), stderr) }
var cases: [[String: Any]] = []
for fixture in fixtures.fixtures {
  let fixtureData = try JSONSerialization.data(withJSONObject: ["columns": fixture.columns, "rows": fixture.rows, "chunks_base64": fixture.chunks_base64])
  let fixturePath = temporary.appendingPathComponent("\(fixture.name).json"); try fixtureData.write(to: fixturePath)
  let swift = try process(runnerExecutable.path, [fixturePath.path], cwd: root)
  let swiftValue = try canonical(swift.0) as! [String: Any]
  let bytes = Data(fixture.chunks_base64.compactMap { Data(base64Encoded: $0) }.joined())
  let rust = try process("/usr/bin/env", ["cargo", "run", "--quiet", "--release", "--locked", "-p", "terminal-tools", "--bin", "terminal-tools", "--", "\(fixture.columns)", "\(fixture.rows)"], stdin: bytes, cwd: rustRoot)
  let rustSnapshot = try canonical(rust.0)
  let swiftSnapshot = swiftValue["snapshot"]!
  let difference = firstDifference(rustSnapshot, swiftSnapshot)
  cases.append(["name": fixture.name, "equal": difference == nil, "first_difference": difference as Any, "swift": swiftValue, "rust": ["snapshot": rustSnapshot, "stderr": String(decoding: rust.1, as: UTF8.self)]])
}
let result: [String: Any] = ["rust_root": rustRoot, "fixtures": cases, "passed": cases.allSatisfy { $0["equal"] as? Bool == true }]
let resultData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try FileManager.default.createDirectory(at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(), withIntermediateDirectories: true)
try resultData.write(to: URL(fileURLWithPath: outputPath))
for item in cases {
  let name = item["name"] ?? "fixture"
  let equal = item["equal"] ?? false
  let difference = item["first_difference"] ?? "no difference"
  print("\(name): equal=\(equal); \(difference)")
}
print("Wrote \(outputPath)")
