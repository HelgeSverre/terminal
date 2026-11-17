import Foundation
import TerminalInterop

// Runs esctest2 (Thomas Dickey's terminal conformance suite) against the
// emulator: esctest runs on a PTY whose other end is the emulator, which
// answers its queries, DECRQCRA included, as the app would.
//
//   esctest ESCTEST-DIR KNOWN-GOOD REPORT [--update] [esctest options…]
//
// It compares the tests that passed with the known-good list: a listed test
// that no longer passes is a regression and fails the run; a test that
// newly passes is reported, and `--update` rewrites the list.
@main enum EscTestHarness {
  static func main() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 3 else {
      print("usage: esctest ESCTEST-DIR KNOWN-GOOD REPORT [--update] [esctest options…]"); exit(2)
    }
    func absolute(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    let directory = absolute(arguments.removeFirst()), knownGoodPath = absolute(arguments.removeFirst())
    let reportPath = absolute(arguments.removeFirst())
    let update = arguments.first == "--update"
    if update { arguments.removeFirst() }
    let log = URL(fileURLWithPath: reportPath).deletingPathExtension().appendingPathExtension("log").path

    let columns: UInt16 = 80, rows: UInt16 = 24
    var master: Int32 = -1, slave: Int32 = -1
    var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 800, ws_ypixel: 480)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else { print("openpty failed"); exit(1) }
    guard let core = helge_terminal_create(UInt32(columns), UInt32(rows)) else { print("no emulator"); exit(1) }
    defer { helge_terminal_destroy(core) }
    _ = helge_terminal_resize_pixels(core, UInt32(columns), UInt32(rows), 10, 20)
    // esctest's reset() forces black text on white before every case and its
    // OSC 110/111 tests expect a reset to return to those resource defaults.
    // Configure this test host accordingly; application resets still return
    // to the application's actual configured scheme.
    swiftTerminalSetColorScheme(core, colors: TerminalColorScheme(foreground: 0x000000, background: 0xffffff))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", directory + "/esctest/esctest.py", "--expected-terminal=xterm",
                         "--xterm-checksum=334", "--xterm-reverse-wrap=383",
                         "--logfile=" + log, "--v=2", "--timeout=0.5"] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory + "/esctest")
    let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    process.environment = environment
    try process.run()
    close(slave)
    // Never block on either direction: esctest and the emulator each wait
    // for the other, so a blocking write would deadlock them.
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

    final class Writer { var pending = Data() }
    let writer = Writer()
    let collect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
      guard let context, let bytes, count > 0 else { return }
      Unmanaged<Writer>.fromOpaque(context).takeUnretainedValue().pending.append(bytes, count: count)
    }
    var buffer = [UInt8](repeating: 0, count: 65_536)
    var now: UInt64 = 1
    let started = Date()
    while true {
      var descriptor = pollfd(fd: master, events: Int16(POLLIN) | (writer.pending.isEmpty ? 0 : Int16(POLLOUT)), revents: 0)
      let ready = poll(&descriptor, 1, 200)
      if ready > 0 && descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
        let count = read(master, &buffer, buffer.count)
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { break }   // The PTY is closed.
        var offset = 0
        while offset < max(0, count) || helge_terminal_has_work(core) {
          // A turn that only finished a repeat consumes nothing and is
          // progress; the rest of this read still has to be fed.
          let repeating = helge_terminal_has_work(core)
          let used = buffer.withUnsafeBufferPointer { helge_terminal_feed(core, $0.baseAddress! + offset, max(0, count) - offset, now) }
          offset += used
          helge_terminal_replies(core, Unmanaged.passUnretained(writer).toOpaque(), collect)
          if used == 0 && !repeating { break }
        }
        now += 1
      } else if !process.isRunning { break }
      if !writer.pending.isEmpty {
        let written = writer.pending.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
        if written > 0 { writer.pending.removeFirst(written) }
        else if written < 0 && errno != EAGAIN && errno != EINTR { writer.pending.removeAll() }
      }
      if Date().timeIntervalSince(started) > 1800 { process.terminate(); print("esctest took over 30 minutes"); exit(1) }
    }
    process.waitUntilExit()
    close(master)

    // The log: "Run test: NAME", then "Passed.", "Fails as expected: …",
    // "Skipped …" or "*** TEST NAME FAILED:".
    let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    var results: [String: String] = [:]
    var current: String?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("Run test: ") { current = String(line.dropFirst("Run test: ".count)); continue }
      guard let name = current else { continue }
      if line == "Passed." { results[name] = "pass"; current = nil }
      else if line.hasPrefix("Fails as expected") { results[name] = "known-bug"; current = nil }
      else if line.hasPrefix("Skipped") { results[name] = "skipped"; current = nil }
      else if line.hasPrefix("*** TEST") { results[name] = "fail"; current = nil }
    }
    guard !results.isEmpty else {
      // Whatever esctest printed went to the emulated screen.
      let screen = swiftTerminalSnapshot(core, scroll: nil, now: now + 1000).snapshot?.rows
        .map { $0.cells.map(\.text).joined() }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? []
      print("esctest ran no tests; see \(log). The screen shows:\n" + screen.joined(separator: "\n")); exit(1)
    }
    let passed = Set(results.filter { $0.value == "pass" }.keys)
    let knownGood = Set(((try? String(contentsOfFile: knownGoodPath, encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") })
    let regressions = knownGood.subtracting(passed).sorted(), newlyPassing = passed.subtracting(knownGood).sorted()
    let counts = Dictionary(grouping: results.values, by: { $0 }).mapValues(\.count)
    let report: [String: Any] = [
      "passed": counts["pass"] ?? 0, "failed": counts["fail"] ?? 0, "skipped": counts["skipped"] ?? 0,
      "known_bugs": counts["known-bug"] ?? 0, "total": results.count,
      "regressions": regressions, "newly_passing": newlyPassing,
      "failing": results.filter { $0.value == "fail" }.keys.sorted(),
    ]
    let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: reportPath))
    print("esctest: \(counts["pass"] ?? 0) passed, \(counts["fail"] ?? 0) failed, \(counts["skipped"] ?? 0) skipped, "
      + "\(counts["known-bug"] ?? 0) known bugs, of \(results.count); report in \(reportPath)")
    if update {
      let header = "# esctest2 cases the emulator passes. `just esctest` fails when one of\n# them stops passing; `just esctest-update` rewrites this list.\n"
      try (header + passed.sorted().joined(separator: "\n") + "\n").write(toFile: knownGoodPath, atomically: true, encoding: .utf8)
      print("known-good list: \(passed.count) cases")
    } else {
      if !newlyPassing.isEmpty { print("newly passing (run just esctest-update): " + newlyPassing.joined(separator: " ")) }
      if !regressions.isEmpty { print("REGRESSIONS: " + regressions.joined(separator: " ")); exit(1) }
    }
  }
}
