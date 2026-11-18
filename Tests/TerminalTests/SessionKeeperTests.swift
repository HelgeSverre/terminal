import Darwin
import Foundation
import Testing
@testable import TerminalApp

/// The keeper holds descriptors for an app that is being replaced, and the
/// app's own rules decide where a handoff may be left and claimed.
@Suite(.serialized) struct SessionKeeperTests {
  private static let app = TestEnvironment.products.appendingPathComponent("TerminalApp").path
  private func socketPath() -> String {
    (NSTemporaryDirectory() as NSString).appendingPathComponent("hk-\(UUID().uuidString.prefix(8)).sock")
  }
  private func pipeEnds() throws -> (read: Int32, write: Int32) {
    var ends: [Int32] = [0, 0]
    try #require(pipe(&ends) == 0)
    return (ends[0], ends[1])
  }
  private func readable(_ descriptor: Int32, within milliseconds: Int32) -> Bool {
    var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    return poll(&waiting, 1, milliseconds) > 0
  }

  @Test func aKeeperHoldsDescriptorsUntilTheyAreClaimed() throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.app))
    let first = try pipeEnds(), second = try pipeEnds()
    defer { close(first.read); close(second.read) }
    let path = socketPath()
    let keeper = try #require(SessionKeeper.start(executable: Self.app, socketPath: path, seconds: 30,
                                                  descriptors: [first.write, second.write]))
    // This process lets go; only the keeper keeps the pipes open.
    close(first.write); close(second.write)
    #expect(!readable(first.read, within: 200), "a held pipe has not ended")
    let claimed = try #require(SessionKeeper.claim(socketPath: path, count: 2))
    defer { claimed.forEach { close($0) } }
    #expect(claimed.count == 2)
    // The claimed descriptors are the same pipes, in order.
    for (descriptor, end, byte) in [(claimed[0], first.read, UInt8(65)), (claimed[1], second.read, UInt8(66))] {
      var out = byte, back: UInt8 = 0
      #expect(write(descriptor, &out, 1) == 1 && read(end, &back, 1) == 1 && back == byte)
    }
    var status: Int32 = 0
    #expect(waitpid(keeper, &status, 0) == keeper && status == 0, "the keeper leaves once acknowledged")
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(SessionKeeper.claim(socketPath: path, count: 2) == nil)
  }

  @Test func anUnclaimedKeeperLetsItsDescriptorsGo() throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.app))
    let ends = try pipeEnds()
    defer { close(ends.read) }
    let keeper = try #require(SessionKeeper.start(executable: Self.app, socketPath: socketPath(), seconds: 1,
                                                  descriptors: [ends.write]))
    close(ends.write)
    // End of file on the pipe is what a hung-up program would see.
    #expect(readable(ends.read, within: 5000))
    var byte: UInt8 = 0
    #expect(read(ends.read, &byte, 1) == 0)
    var status: Int32 = 0
    #expect(waitpid(keeper, &status, 0) == keeper)
  }

  @Test func aKeeperNeedsAUsableSocketPathAndSomethingToHold() throws {
    let ends = try pipeEnds()
    defer { close(ends.read); close(ends.write) }
    let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
    #expect(SessionKeeper.start(executable: Self.app, socketPath: long, seconds: 5, descriptors: [ends.write]) == nil)
    #expect(SessionKeeper.start(executable: Self.app, socketPath: socketPath(), seconds: 5, descriptors: []) == nil)
    #expect(SessionKeeper.claim(socketPath: socketPath(), count: 1) == nil)
  }

  @Test func handoffIsOffUnlessAskedFor() {
    let home = URL(fileURLWithPath: "/Users/someone")
    let installed = URL(fileURLWithPath: "/Applications/Helge Terminal.app")
    let built = URL(fileURLWithPath: "/Users/someone/code/terminal/dist/Terminal.app")
    func directory(_ arguments: [String], _ bundle: URL, enabled: Bool) -> String? {
      SessionHandoffLocation.directory(arguments: arguments, bundle: bundle, home: home, enabled: enabled)?.path
    }
    #expect(directory(["Terminal"], installed, enabled: false) == nil)
    #expect(directory(["Terminal"], installed, enabled: true)
      == "/Users/someone/Library/Application Support/no.helgesverre.terminal/Handoff")
    #expect(directory(["Terminal"], built, enabled: true) == nil, "a development build never shares the installed handoff")
    #expect(directory(["Terminal", "--handoff-directory", "/tmp/h"], built, enabled: false) == "/tmp/h")
    #expect(directory(["Terminal", "--handoff-directory"], built, enabled: true) == nil)
    #expect(directory(["Terminal", "--execute", "x", "--handoff-directory", "/tmp/h"], built, enabled: false) == nil)
  }

  @Test func aManifestWithoutAKeeperIsDiscarded() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)")
    #expect(SessionHandoffCoordinator.claim(directory: directory) == nil)
    #expect(SessionHandoffCoordinator.claim(directory: nil) == nil)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = PaneID()
    let layout = SessionLayout(appBuild: "1", windows: [WindowLayout(
      id: UUID(), frame: CGRect(x: 0, y: 0, width: 800, height: 600), root: .pane(id), activePane: id,
      panes: [PaneState(id: id, directory: "/tmp", title: "")], tabGroup: UUID(), tabIndex: 0,
      selectedTab: true, zoomed: false, fullScreen: false)], keyWindow: nil)
    let manifest = HandoffManifest(appBuild: "1", socket: socketPath(), descriptorCount: 1, layout: layout, panes: [])
    try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    #expect(SessionHandoffCoordinator.claim(directory: directory) == nil, "nothing holds the PTYs any more")
    #expect(!FileManager.default.fileExists(atPath: directory.path), "a handoff is claimed once")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not a manifest".utf8).write(to: directory.appendingPathComponent("manifest.json"))
    #expect(SessionHandoffCoordinator.claim(directory: directory) == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }
}
