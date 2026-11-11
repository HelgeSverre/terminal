import Foundation
import Testing
@testable import dev

@Suite struct ReleasePublisherTests {
  @Test("release publisher: validate accepts a matching tag and writes safe metadata") func validateAcceptsAMatchingTagAnd() throws {
    try withFixture { fixture in
      let githubOutput = fixture.root + "/github-output"
      let environment = fixture.tagEnvironment.merging(["GITHUB_OUTPUT": githubOutput]) { $1 }
      let metadata = try fixture.publisher(environment).validate(output: fixture.metadata)

      #expect(metadata.publish, "a tag push authorizes publishing")
      #expect(metadata.tag == "v1.2.3", "got: \(metadata.tag)")
      #expect(fixture.read(fixture.metadata) == """
        {
          "schema": 1,
          "version": "1.2.3",
          "tag": "v1.2.3",
          "source_sha": "\(sha)",
          "publish": true,
          "event_name": "push",
          "ref": "refs/tags/v1.2.3"
        }

        """, "got: \(fixture.read(fixture.metadata))")
      #expect(fixture.read(githubOutput) == "version=1.2.3\ntag=v1.2.3\npublish=true\nsource_sha=\(sha)\n",
                 "got: \(fixture.read(githubOutput))")
      #expect(fixture.gitHub.calls.allSatisfy { $0.environment.isEmpty }, "git gets no token")
    }
  }

  @Test("release publisher: validate rejects a wrong tag or an unreachable source") func validateRejectsAWrongTagOr() throws {
    try withFixture { fixture in
      let wrongTag = fixture.tagEnvironment.merging(["GITHUB_REF": "refs/tags/v1.2.4"]) { $1 }
      var message = try #require(throws: Failure.self) {
        try fixture.publisher(wrongTag).validate(output: fixture.metadata)
      }.message
      #expect(message.contains("refs/tags/v1.2.3"), "got: \(message)")

      fixture.gitHub.ancestor = false
      message = try #require(throws: Failure.self) {
        try fixture.publisher(fixture.tagEnvironment).validate(output: fixture.metadata)
      }.message
      #expect(message.contains("merge-base"), "got: \(message)")
      #expect(!FileManager.default.fileExists(atPath: fixture.metadata), "no metadata is written")
    }
  }

  @Test("release publisher: a manual run from main is valid but never authorizes publishing") func aManualRunFromMainIs() throws {
    try withFixture { fixture in
      let manual = ["GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": sha]
      let metadata = try fixture.publisher(manual).validate(output: fixture.metadata)
      #expect(!metadata.publish, "a manual run does not publish")
      #expect(metadata.tag == "v1.2.3", "got: \(metadata.tag)")
      #expect(fixture.read(fixture.metadata).contains("\"publish\": false"), "metadata records it")

      try FileManager.default.createDirectory(atPath: fixture.releaseDirectory, withIntermediateDirectories: true)
      let message = try #require(throws: Failure.self) { try fixture.publish() }.message
      #expect(message == "metadata does not authorize publishing", "got: \(message)")
      #expect(!fixture.gitHub.calls.contains { $0.command.first == "gh" }, "GitHub is not contacted")
    }
  }

  @Test("release publisher: manifest and publish are idempotent") func manifestAndPublishAreIdempotent() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      try fixture.publish()
      try fixture.publish()

      #expect(fixture.gitHub.release?["isDraft"] as? Bool == false, "release is published")
      let names = fixture.gitHub.assets.compactMap { $0["name"] as? String }.sorted()
      #expect(names == ["HelgeTerminal-1.2.3-arm64.zip", "SHA256SUMS", "release-manifest.json"], "got: \(names)")
      #expect(fixture.gitHub.caskVersion == "1.2.3", "cask is updated")
      #expect(fixture.gitHub.puts == 1, "cask is written once, got \(fixture.gitHub.puts)")
    }
  }

  @Test("release publisher: publish refuses an integrity conflict before any tap mutation") func publishRefusesAnIntegrityConflictBefore() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      fixture.gitHub.release = [
        "tagName": "v1.2.3", "targetCommitish": sha, "isDraft": false,
        "assets": [["name": "HelgeTerminal-1.2.3-arm64.zip", "digest": "sha256:" + String(repeating: "0", count: 64),
                    "size": 3]] as [[String: Any]],
      ]
      let message = try #require(throws: Failure.self) { try fixture.publish() }.message
      #expect(message.contains("different SHA256"), "got: \(message)")
      #expect(fixture.gitHub.puts == 0, "cask is untouched")
      #expect(fixture.gitHub.assets.count == 1, "nothing is uploaded")
    }
  }

  @Test("release publisher: publish fails closed when the release lookup is not a 404") func publishFailsClosedWhenTheRelease() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      fixture.gitHub.releaseError = "HTTP 502: GitHub is unavailable"
      let message = try #require(throws: Failure.self) { try fixture.publish() }.message
      #expect(message.contains("cannot read GitHub release"), "got: \(message)")
      #expect(fixture.gitHub.release == nil, "no release is created")
      #expect(fixture.gitHub.puts == 0, "cask is untouched")
    }
  }

  @Test("release publisher: a partial draft is completed without replacing a verified asset") func aPartialDraftIsCompletedWithout() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      let zip = try ReleasePublisher.Asset(path: fixture.zip)
      fixture.gitHub.release = [
        "tagName": "v1.2.3", "targetCommitish": sha, "isDraft": true,
        "assets": [["name": zip.name, "size": zip.bytes, "digest": "sha256:\(zip.sha256)"]] as [[String: Any]],
      ]
      try fixture.publish()

      #expect(fixture.gitHub.release?["isDraft"] as? Bool == false, "release is published")
      #expect(fixture.gitHub.assets.count == 3, "got \(fixture.gitHub.assets.count) assets")
      let uploads = fixture.gitHub.calls.filter { $0.command.starts(with: ["gh", "release", "upload"]) }
      #expect(uploads.count == 1 && !uploads[0].command.contains(fixture.zip), "the ZIP is not uploaded again")
    }
  }

  @Test("release publisher: publish binds metadata to the current checkout and event") func publishBindsMetadataToTheCurrent() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      let other = String(repeating: "b", count: 40)
      try fixture.write(fixture.read(fixture.metadata).replacingOccurrences(of: sha, with: other), to: fixture.metadata)
      try fixture.publishing.manifest(metadata: fixture.metadata, releaseDirectory: fixture.releaseDirectory)

      let message = try #require(throws: Failure.self) { try fixture.publish() }.message
      #expect(message.contains("GITHUB_SHA"), "got: \(message)")
      #expect(fixture.gitHub.release == nil, "no release is created")
    }
  }

  @Test("release publisher: the tap update reloads and skips a newer version") func theTapUpdateReloadsAndSkips() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      fixture.gitHub.caskText = fixture.gitHub.caskText
        .replacingOccurrences(of: "version \"0.2.2\"", with: "version \"9.0.0\"")
      try fixture.publish()
      #expect(fixture.gitHub.puts == 0, "cask is untouched")
      #expect(fixture.gitHub.caskVersion == "9.0.0", "got: \(fixture.gitHub.caskVersion ?? "none")")
    }
  }

  @Test("release publisher: the tap update retries after a concurrent update") func theTapUpdateRetriesAfterA() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      fixture.gitHub.failFirstTapPut = true
      try fixture.publish()
      #expect(fixture.gitHub.caskVersion == "1.2.3", "got: \(fixture.gitHub.caskVersion ?? "none")")
      #expect(fixture.gitHub.puts == 2, "got \(fixture.gitHub.puts) writes")
    }
  }

  @Test("release publisher: manifest allows known private release outputs") func manifestAllowsKnownPrivateReleaseOutputs() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      try FileManager.default.createDirectory(atPath: fixture.releaseDirectory + "/Helge Terminal.app",
                                              withIntermediateDirectories: false)
      for name in ["notary-app.json", "release-metadata.json"] {
        try fixture.write("{}", to: fixture.releaseDirectory + "/" + name)
      }
      let assets = try fixture.publishing.manifest(metadata: fixture.metadata,
                                                  releaseDirectory: fixture.releaseDirectory)
      #expect(assets.map(\.name).sorted() == ["HelgeTerminal-1.2.3-arm64.zip"],
                 "got: \(assets.map(\.name))")

      try fixture.write("", to: fixture.releaseDirectory + "/stray.txt")
      let message = try #require(throws: Failure.self) {
        try fixture.publishing.manifest(metadata: fixture.metadata, releaseDirectory: fixture.releaseDirectory)
      }.message
      #expect(message == "unexpected release output: stray.txt", "got: \(message)")
    }
  }

  @Test("release publisher: the manifest, checksums and cask have the exact published text") func theManifestChecksumsAndCaskHave() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      let zip = try ReleasePublisher.Asset(path: fixture.zip)
      #expect(fixture.read(fixture.releaseDirectory + "/SHA256SUMS")
                   == "\(zip.sha256)  \(zip.name)\n", "checksum file")
      #expect(fixture.read(fixture.releaseDirectory + "/release-manifest.json") == """
        {
          "schema": 1,
          "version": "1.2.3",
          "tag": "v1.2.3",
          "source_sha": "\(sha)",
          "assets": [
            {
              "name": "\(zip.name)",
              "sha256": "\(zip.sha256)",
              "bytes": 3
            }
          ]
        }

        """, "got: \(fixture.read(fixture.releaseDirectory + "/release-manifest.json"))")

      try fixture.publish()
      #expect(fixture.gitHub.caskText == """
        cask "helge-terminal" do
          version "1.2.3"
          sha256 "\(zip.sha256)"
          url "https://github.com/HelgeSverre/terminal/releases/download/v1.2.3/\(zip.name)"

          livecheck do
            url "https://github.com/HelgeSverre/terminal/releases"
            regex(/^v?(\\d+(?:\\.\\d+)+)$/i)
            strategy :github_releases
          end
        end

        """, "got: \(fixture.gitHub.caskText)")
    }
  }

  @Test("release publisher: each repository's token goes only to its own commands") func eachRepositorysTokenGoesOnlyTo() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      try fixture.publish()
      for call in fixture.gitHub.calls {
        let tap = call.command.starts(with: ["gh", "api"])
        let expected = call.command.first == "git" ? [:] : ["GH_TOKEN": tap ? "tap-token" : "release-token"]
        #expect(call.environment == expected, "wrong token for \(call.command.prefix(3))")
      }
      var withoutTap = fixture.publishingEnvironment
      withoutTap["TAP_GITHUB_TOKEN"] = nil
      fixture.gitHub.caskText = fixture.gitHub.caskText.replacingOccurrences(of: "1.2.3", with: "0.0.1")
      let message = try #require(throws: Failure.self) {
        try fixture.publisher(withoutTap).publish(metadata: fixture.metadata, releaseDirectory: fixture.releaseDirectory)
      }.message
      #expect(message == "TAP_GITHUB_TOKEN is required to update the Homebrew tap", "got: \(message)")
    }
  }

  @Test("release publisher: an empty GITHUB_TOKEN does not hide GH_TOKEN") func anEmptyGithubtokenDoesNotHide() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      var environment = fixture.publishingEnvironment
      environment["GITHUB_TOKEN"] = ""
      environment["GH_TOKEN"] = "fallback-token"
      try fixture.publisher(environment).publish(metadata: fixture.metadata, releaseDirectory: fixture.releaseDirectory)
      let releaseCalls = fixture.gitHub.calls.filter { $0.command.starts(with: ["gh", "release"]) }
      #expect(!releaseCalls.isEmpty && releaseCalls.allSatisfy { $0.environment == ["GH_TOKEN": "fallback-token"] },
                 "release commands get the token that is set")

      environment["GH_TOKEN"] = ""
      let message = try #require(throws: Failure.self) {
        try fixture.publisher(environment).publish(metadata: fixture.metadata, releaseDirectory: fixture.releaseDirectory)
      }.message
      #expect(message == "GITHUB_TOKEN or GH_TOKEN is required for GitHub commands", "got: \(message)")
    }
  }

  @Test("release publisher: the cask rewrite changes only the three fields' own lines") func theCaskRewriteChangesOnlyThe() throws {
    try withFixture { fixture in
      try fixture.prepareRelease()
      let zip = try ReleasePublisher.Asset(path: fixture.zip)
      let metadata = ReleasePublisher.Metadata(version: "1.2.3", tag: "v1.2.3", sourceSHA: sha, publish: true)
      let old = String(repeating: "1", count: 64)
      let livecheck = "  livecheck do\n    url \"https://example.invalid\"\n  end\nend\n"
      let cask = "cask \"helge-terminal\" do\n\n\n  version \"0.2.2\"\n\n  sha256 \"\(old)\"\n\t\n"
        + "\turl \"https://example.invalid/old.zip\"\n\n" + livecheck
      let rewritten = try fixture.publishing.replacedCask(cask, metadata, zip)
      let expected = "cask \"helge-terminal\" do\n\n\n  version \"1.2.3\"\n\n  sha256 \"\(zip.sha256)\"\n\t\n"
        + "  url \"https://github.com/HelgeSverre/terminal/releases/download/v1.2.3/\(zip.name)\"\n\n"
      #expect(rewritten.hasPrefix(expected), "got: \(rewritten.debugDescription)")
      #expect(rewritten.hasSuffix("    strategy :github_releases\n  end\nend\n"), "the livecheck block is replaced")
    }
  }

  @Test("release publisher: options take a separate or an attached value") func optionsTakeASeparateOrAn() throws {
    let options = try ReleasePublisher.parseOptions(["--metadata", "a.json", "--release-dir=out"])
    #expect(options == ["metadata": "a.json", "release-dir": "out"], "got: \(options)")
    #expect(throws: Failure.self) { _ = try ReleasePublisher.parseOptions(["--force"]) }
    #expect(throws: Failure.self) { _ = try ReleasePublisher.parseOptions(["--output"]) }
  }

}

// Tests. `FakeGitHub` stands in for `git` and `gh`; no command is run and
// every file is inside a temporary directory.

private let sha = String(repeating: "a", count: 40)

/// An in-memory GitHub: one release, one cask, and a record of every call.
final class FakeGitHub {
  var ancestor = true
  var release: [String: Any]?
  var failFirstTapPut = false
  var releaseError: String?
  private(set) var puts = 0
  private(set) var calls: [(command: [String], environment: [String: String])] = []
  var caskText = """
    cask "helge-terminal" do
      version "0.2.2"
      sha256 "\(String(repeating: "1", count: 64))"
      url "https://example.invalid/old.zip"

      livecheck do
        url "https://github.com/HelgeSverre/homebrew-tap/releases"
        regex(/helge-terminal-v?(\\d+(?:\\.\\d+)+)/i)
      end
    end

    """

  var caskVersion: String? { LinePattern("version \"([^\"]+)\"").first(in: caskText)?.groups[0] }
  var assets: [[String: Any]] { release?["assets"] as? [[String: Any]] ?? [] }

  func call(_ command: [String], _ environment: [String: String]) -> CommandResult {
    calls.append((command, environment))
    switch command.first {
    case "git": return git(Array(command.dropFirst()))
    case "gh": return gh(command, environment)
    default: return CommandResult(error: "unexpected command", status: 1)
    }
  }

  private func git(_ arguments: [String]) -> CommandResult {
    switch arguments {
    case ["rev-parse", "v1.2.3^{}"], ["rev-parse", "HEAD"]: return CommandResult(output: sha + "\n")
    case ["merge-base", "--is-ancestor", sha, "origin/main"]: return CommandResult(status: ancestor ? 0 : 1)
    default: return CommandResult(error: "unexpected git \(arguments)", status: 1)
    }
  }

  private func gh(_ command: [String], _ environment: [String: String]) -> CommandResult {
    guard !(environment["GH_TOKEN"] ?? "").isEmpty else { return CommandResult(error: "missing token", status: 1) }
    switch Array(command.dropFirst().prefix(3)) {
    case ["release", "view", "v1.2.3"]:
      if let releaseError { return CommandResult(error: releaseError, status: 1) }
      guard let release, let data = try? JSONSerialization.data(withJSONObject: release) else {
        return CommandResult(error: "not found", status: 1)
      }
      return CommandResult(output: String(decoding: data, as: UTF8.self))
    case ["release", "create", "v1.2.3"]:
      if release == nil {
        release = ["tagName": "v1.2.3", "targetCommitish": sha, "isDraft": true, "assets": [[String: Any]]()]
      }
      return CommandResult()
    case ["release", "upload", "v1.2.3"]:
      var uploaded = assets
      for path in command.dropFirst(4).prefix(while: { $0 != "--repo" }) {
        guard let asset = try? ReleasePublisher.Asset(path: path) else { return CommandResult(error: "cannot read \(path)", status: 1) }
        uploaded.append(["name": asset.name, "size": asset.bytes, "digest": "sha256:\(asset.sha256)"])
      }
      release?["assets"] = uploaded
      return CommandResult()
    case ["release", "edit", "v1.2.3"]:
      release?["isDraft"] = false
      return CommandResult()
    case ["api", "repos/HelgeSverre/homebrew-tap/contents/Casks/helge-terminal.rb?ref=main"]:
      let body = ["content": Data(caskText.utf8).base64EncodedString(), "sha": "old-sha"]
      let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
      return CommandResult(output: String(decoding: data, as: UTF8.self))
    case ["api", "--method", "PUT"]:
      puts += 1
      if failFirstTapPut {
        failFirstTapPut = false
        caskText = caskText.replacingOccurrences(of: "version \"0.2.2\"", with: "version \"0.3.0\"")
        return CommandResult(error: "sha does not match", status: 1)
      }
      guard let content = command.first(where: { $0.hasPrefix("content=") })?.dropFirst("content=".count),
            let data = Data(base64Encoded: String(content)) else {
        return CommandResult(error: "no content", status: 1)
      }
      caskText = String(decoding: data, as: UTF8.self)
      return CommandResult()
    default:
      return CommandResult(error: "unexpected gh \(command)", status: 1)
    }
  }
}

/// A temporary repository root holding only the bundle's Info.plist.
private final class Fixture {
  let root: String
  let gitHub = FakeGitHub()
  var metadata: String { root + "/metadata.json" }
  var releaseDirectory: String { root + "/dist/release" }
  var zip: String { releaseDirectory + "/HelgeTerminal-1.2.3-arm64.zip" }

  let tagEnvironment = ["GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/tags/v1.2.3", "GITHUB_SHA": sha]
  var publishingEnvironment: [String: String] {
    tagEnvironment.merging(["GITHUB_TOKEN": "release-token", "TAP_GITHUB_TOKEN": "tap-token"]) { $1 }
  }

  init(root: String) throws {
    self.root = root
    try FileManager.default.createDirectory(atPath: root + "/Resources/Terminal", withIntermediateDirectories: true)
    try write("<plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>1.2.3</string></dict></plist>\n",
              to: root + "/Resources/Terminal/Info.plist")
  }

  func publisher(_ environment: [String: String]) -> ReleasePublisher.Publisher {
    ReleasePublisher.Publisher(root: root, environment: environment, runner: gitHub.call)
  }
  var publishing: ReleasePublisher.Publisher { publisher(publishingEnvironment) }

  func write(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }
  func read(_ path: String) -> String {
    String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
  }

  /// Builds the asset, then validates and writes the manifest as the build job does.
  func prepareRelease() throws {
    try FileManager.default.createDirectory(atPath: releaseDirectory, withIntermediateDirectories: true)
    try write("zip", to: zip)
    try publishing.validate(output: metadata)
    try publishing.manifest(metadata: metadata, releaseDirectory: releaseDirectory)
  }

  func publish() throws { try publishing.publish(metadata: metadata, releaseDirectory: releaseDirectory) }
}

private func withFixture(_ body: (Fixture) throws -> Void) throws {
  try withTemporaryDirectory("dev-release-publisher-") { try body(try Fixture(root: $0)) }
}
