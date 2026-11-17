import Foundation
import Darwin

struct ResumeRecord: Codable, Equatable {
  var rule: String
  var session: String?
  var exact: Bool
  var warned: Bool
}

/// Only the bundled rule table can supply executable/argument templates.
/// Neither persisted state nor a hook may supply a command or launch flags.
struct ResumeRules: Decodable {
  struct Rule: Decodable {
    struct Match: Decodable { var argv0: String }
    struct SessionLookup: Decodable {
      var jsonFile: String
      var key: String
      enum CodingKeys: String, CodingKey { case jsonFile = "json_file", key }
    }
    var id: String
    var label: String
    var match: Match
    var session: SessionLookup?
    var sessionPattern: String
    var resume: [String]
    var guess: [String]
    var warnArgv: [String]
    enum CodingKeys: String, CodingKey {
      case id, label, match, session, resume, guess
      case sessionPattern = "session_pattern", warnArgv = "warn_argv"
    }
    func accepts(_ value: String) -> Bool {
      guard !value.isEmpty, value.utf8.count <= 256,
        let expression = try? NSRegularExpression(pattern: sessionPattern) else { return false }
      let range = NSRange(value.startIndex..., in: value)
      return expression.firstMatch(in: value, range: range)?.range == range
    }
    func arguments(for record: ResumeRecord) -> [String]? {
      guard record.rule == id else { return nil }
      if let value = record.session {
        guard accepts(value) else { return nil }
        return resume.map { $0 == "{session}" ? value : $0 }
      }
      return guess
    }
  }
  var version: Int
  var rules: [Rule]
  static let empty = ResumeRules(version: 1, rules: [])

  static func load(_ url: URL?) -> ResumeRules {
    guard let url, let data = try? boundedFile(url, limit: 65_536),
      let table = try? JSONDecoder().decode(ResumeRules.self, from: data), table.version == 1,
      Set(table.rules.map(\.id)).count == table.rules.count,
      table.rules.allSatisfy({ rule in
        !rule.id.isEmpty && rule.id.utf8.count <= 64
          && rule.id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
          && !rule.match.argv0.isEmpty && rule.match.argv0 == URL(fileURLWithPath: rule.match.argv0).lastPathComponent
          && rule.label.utf8.count <= 256 && !rule.label.unicodeScalars.contains(where: { $0.value < 32 })
          && (try? NSRegularExpression(pattern: rule.sessionPattern)) != nil
          && rule.resume.contains("{session}") && !rule.guess.contains("{session}")
          && [rule.resume, rule.guess].allSatisfy { arguments in
            !arguments.isEmpty && arguments.count <= 256
              && arguments.allSatisfy { argument in
                !argument.isEmpty && argument.utf8.count <= 8192
                  && !argument.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
                  && (argument == "{session}" || (!argument.contains("{") && !argument.contains("}")))
              } && arguments[0] != "{session}"
          }
      }) else { return .empty }
    return table
  }
  func rule(_ id: String) -> Rule? { rules.first { $0.id == id } }
  func matching(command: String) -> Rule? {
    guard let first = command.split(whereSeparator: \.isWhitespace).first else { return nil }
    let name = URL(fileURLWithPath: String(first)).lastPathComponent
    return rules.first { $0.match.argv0 == name }
  }
  static func shellCommand(_ arguments: [String]) -> String {
    arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
  }
  static func boundedFile(_ url: URL, limit: Int) throws -> Data {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw POSIXError(.ENOENT) }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size >= 0, info.st_size <= limit else { throw POSIXError(.EFBIG) }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while result.count <= limit {
      let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - result.count))
      if count == 0 { return result }
      if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
      result.append(contentsOf: buffer.prefix(count))
    }
    throw POSIXError(.EFBIG)
  }
}

final class ResumeSampler: @unchecked Sendable {
  struct Pane { var id: PaneID; var pid: Int32; var hook: URL }
  private let queue = DispatchQueue(label: "terminal.recovery.foreground", qos: .utility)
  private var liveProcess: Process?
  let rules: ResumeRules
  let home: URL
  private let commandForTesting: ((Int32) -> String?)?
  init(rules: ResumeRules, home: URL, commandForTesting: ((Int32) -> String?)? = nil) {
    self.rules = rules; self.home = home; self.commandForTesting = commandForTesting
  }

  func sample(_ panes: [Pane], completion: @escaping @MainActor ([PaneID: ResumeRecord]) -> Void) {
    queue.async { [self] in
      var records: [PaneID: ResumeRecord] = [:]
      for pane in panes {
        guard let command = commandForTesting.map({ $0(pane.pid) }) ?? foregroundCommand(pane.pid),
          let rule = rules.matching(command: command) else { continue }
        var session: String?
        if let data = try? ResumeRules.boundedFile(pane.hook, limit: 65_536),
          let hook = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          hook["rule"] == rule.id, let value = hook["session"], rule.accepts(value) {
          session = value
        } else if let lookup = rule.session {
          let path = lookup.jsonFile.replacingOccurrences(of: "{pid}", with: String(pane.pid))
          let url = path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: path)
          if let data = try? ResumeRules.boundedFile(url, limit: 65_536),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object[lookup.key] as? String, rule.accepts(value) { session = value }
        }
        records[pane.id] = ResumeRecord(rule: rule.id, session: session, exact: session != nil,
          warned: rule.warnArgv.contains { command.contains($0) })
      }
      DispatchQueue.main.async { completion(records) }
    }
  }

  /// argv-only `ps` query. No environment is requested. The sole owned helper
  /// has a 500 ms/64 KiB budget; a stuck helper blocks further sampling rather
  /// than accumulating processes. Its command text never leaves this method's
  /// caller or enters the saved state.
  private func foregroundCommand(_ pid: Int32) -> String? {
    guard pid > 0, liveProcess?.isRunning != true else { return nil }
    let process = Process(), pipe = Pipe()
    let terminated = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in terminated.signal() }
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-ww", "-p", String(pid), "-o", "command="]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    liveProcess = process
    try? pipe.fileHandleForWriting.close()
    let fd = pipe.fileHandleForReading.fileDescriptor
    defer { try? pipe.fileHandleForReading.close() }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      if process.isRunning { process.terminate() }; return nil
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
    var output = Data(), bytes = [UInt8](repeating: 0, count: 4096)
    while DispatchTime.now().uptimeNanoseconds < deadline {
      let count = Darwin.read(fd, &bytes, bytes.count)
      if count > 0 {
        guard output.count <= 65_536 - count else { process.terminate(); return nil }
        output.append(contentsOf: bytes.prefix(count))
      } else if count == 0 {
        guard !output.isEmpty else { return nil }
        _ = terminated.wait(timeout: DispatchTime(uptimeNanoseconds: deadline))
        return String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      } else if errno != EINTR && errno != EAGAIN { return nil }
      else {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        _ = poll(&descriptor, 1, 20)
      }
    }
    if process.isRunning { process.terminate() }
    return nil
  }
}
