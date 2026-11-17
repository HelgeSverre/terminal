import AppKit
import Testing
@testable import TerminalApp

@Suite @MainActor struct ResumeRulesTests {
  private let fixture = #"""
    {"version":1,"rules":[{
      "id":"fake-agent","label":"Fake Agent","match":{"argv0":"fake-agent"},
      "session":{"json_file":"~/lookup/{pid}.json","key":"sessionId"},
      "session_pattern":"^[a-z0-9-]+$",
      "resume":["fake-agent","resume","{session}"],
      "guess":["fake-agent","resume","--last"],"warn_argv":["--wide"]
    }]}
    """#
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("resume-rules-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
  }
  private func rules(_ directory: URL, text: String? = nil) throws -> ResumeRules {
    let url = directory.appendingPathComponent("rules.json")
    try Data((text ?? fixture).utf8).write(to: url)
    return ResumeRules.load(url)
  }
  @Test func onlyValidatedRuleTemplatesCanConstructCommands() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let table = try rules(dir)
    let rule = try #require(table.rule("fake-agent"))
    #expect(table.matching(command: "/private/tool/fake-agent --wide")?.id == rule.id)
    #expect(table.matching(command: "/bin/zsh -l") == nil)
    #expect(rule.arguments(for: ResumeRecord(rule: rule.id, session: "one-id", exact: true, warned: false)) == ["fake-agent", "resume", "one-id"])
    #expect(rule.arguments(for: ResumeRecord(rule: rule.id, session: nil, exact: false, warned: false)) == ["fake-agent", "resume", "--last"])
    #expect(rule.arguments(for: ResumeRecord(rule: rule.id, session: "one;$(touch /x)", exact: true, warned: false)) == nil)
    #expect(rule.arguments(for: ResumeRecord(rule: "unknown", session: "one-id", exact: true, warned: false)) == nil)
    #expect(ResumeRules.shellCommand(["fake-agent", "one'two", "$(never-execute)"]) == "'fake-agent' 'one'\\''two' '$(never-execute)'")
    #expect(try rules(dir, text: fixture.replacingOccurrences(of: "\"version\":1", with: "\"version\":999")).rules.isEmpty)
    #expect(try rules(dir, text: fixture.replacingOccurrences(of: "\"{session}\"", with: "\"{command}\"")).rules.isEmpty)
  }
  @Test func exactHooksDisambiguateAndExitedAgentsAreNotOffered() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let table = try rules(dir)
    let first = PaneID(), second = PaneID(), exited = PaneID()
    let entries = [first, second, exited].enumerated().map { index, id in
      ResumeSampler.Pane(id: id, pid: Int32(index + 1), hook: dir.appendingPathComponent(id.string + ".resume"))
    }
    for (index, entry) in entries.enumerated() {
      try JSONSerialization.data(withJSONObject: ["rule": "fake-agent", "session": "session-\(index)"])
        .write(to: entry.hook)
    }
    let sampler = ResumeSampler(rules: table, home: dir, commandForTesting: { pid in
      pid == 3 ? "/bin/zsh -l" : "/private/bin/fake-agent --wide"
    })
    let records = await withCheckedContinuation { continuation in
      sampler.sample(entries) { continuation.resume(returning: $0) }
    }
    #expect(records[first]?.session == "session-0")
    #expect(records[second]?.session == "session-1")
    #expect(records[first]?.exact == true)
    #expect(records[first]?.warned == true)
    #expect(records[exited] == nil)
  }
  @Test func invalidHookFallsBackToBoundedLookupOrHonestGuess() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let table = try rules(dir)
    let first = PaneID(), second = PaneID()
    let entries = [first, second].enumerated().map { index, id in
      ResumeSampler.Pane(id: id, pid: Int32(index + 10), hook: dir.appendingPathComponent(id.string + ".resume"))
    }
    try JSONSerialization.data(withJSONObject: ["rule": "unrelated", "session": "not-ours"]).write(to: entries[0].hook)
    let lookup = dir.appendingPathComponent("lookup")
    try FileManager.default.createDirectory(at: lookup, withIntermediateDirectories: false)
    try JSONSerialization.data(withJSONObject: ["sessionId": "looked-up-id"]).write(to: lookup.appendingPathComponent("10.json"))
    let sampler = ResumeSampler(rules: table, home: dir, commandForTesting: { _ in "fake-agent" })
    let records = await withCheckedContinuation { continuation in
      sampler.sample(entries) { continuation.resume(returning: $0) }
    }
    #expect(records[first]?.session == "looked-up-id")
    #expect(records[second]?.exact == false)
    #expect(records[second]?.session == nil)
  }
  @Test func offeringNeverRunsAndResumeIsConsumedOnce() {
    let strip = TerminalResumeStrip(frame: CGRect(x: 0, y: 0, width: 800, height: 28))
    var executions = 0
    strip.offer(label: "Fake Agent", exact: false, warned: true) { executions += 1; return true }
    strip.layoutSubtreeIfNeeded()
    #expect(executions == 0)
    #expect(strip.isOffered)
    #expect(strip.resumeIfOffered())
    #expect(executions == 1)
    #expect(!strip.resumeIfOffered())
    #expect(executions == 1)
  }
}
