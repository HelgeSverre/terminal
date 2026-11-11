import Foundation

/// The release boundary: build jobs write files, and this command checks them
/// before it asks GitHub to make any change.
///
/// `validate` decides from the bundle version and the GitHub event whether a
/// run may publish. `manifest` records the checksums of the built assets.
/// `publish` verifies metadata, checkout and files, then creates or completes
/// the GitHub release and updates the Homebrew cask.
enum ReleasePublisher {
  static let command = Command(
    name: "release-publisher",
    usage: "validate --output PATH | manifest|publish --metadata PATH [--release-dir PATH]",
    summary: "Validate a release's version and source, record its checksums, or publish it.",
    run: run)

  static let terminalRepository = "HelgeSverre/terminal"
  static let tapRepository = "HelgeSverre/homebrew-tap"
  static let tapCaskPath = "Casks/helge-terminal.rb"
  static let assetSuffixes = ["zip"]
  static let localReleaseOutputs = ["Helge Terminal.app", "notary-app.json",
                                    "release-metadata.json", "release-manifest.json", "SHA256SUMS"]
  private static let integrityFiles = ["release-manifest.json", "SHA256SUMS"]

  static func run(_ arguments: [String]) throws {
    guard let action = arguments.first, ["validate", "manifest", "publish"].contains(action) else {
      throw Failure.usage(command)
    }
    let options = try parseOptions(Array(arguments.dropFirst()))
    let releaseDirectory = options["release-dir"] ?? "dist/release"
    let publisher = Publisher(root: Repository.root, environment: ProcessInfo.processInfo.environment) {
      try runCommand($0, adding: $1, directory: Repository.root, errors: .separate)
    }
    switch action {
    case "validate":
      guard let output = options["output"] else { throw Failure.usage(command) }
      try publisher.validate(output: output)
    case "manifest":
      guard let metadata = options["metadata"] else { throw Failure.usage(command) }
      try publisher.manifest(metadata: metadata, releaseDirectory: releaseDirectory)
    default:
      guard let metadata = options["metadata"] else { throw Failure.usage(command) }
      try publisher.publish(metadata: metadata, releaseDirectory: releaseDirectory)
    }
  }

  /// Reads `--name VALUE` and `--name=VALUE`. Other words are left alone.
  static func parseOptions(_ arguments: [String]) throws -> [String: String] {
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      guard argument.hasPrefix("-") else { continue }
      let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let name = String(parts.first ?? "")
      guard argument.hasPrefix("--"), ["output", "metadata", "release-dir"].contains(name) else {
        throw Failure.usage(command)
      }
      if parts.count == 2 {
        options[name] = String(parts[1])
      } else {
        guard index < arguments.count else { throw Failure.usage(command) }
        options[name] = arguments[index]
        index += 1
      }
    }
    return options
  }

  /// What one run decided about a release, as written to `release-metadata.json`.
  struct Metadata {
    let version: String
    let tag: String
    let sourceSHA: String
    /// Only a tag push sets this. Nothing is published without it.
    let publish: Bool
    var eventName = ""
    var ref = ""

    var json: JSONValue {
      .object([
        ("schema", 1), ("version", .string(version)), ("tag", .string(tag)),
        ("source_sha", .string(sourceSHA)), ("publish", .bool(publish)),
        ("event_name", .string(eventName)), ("ref", .string(ref)),
      ])
    }
  }

  /// A built file as the manifest records it.
  struct Asset: Equatable {
    let name: String
    let sha256: String
    let bytes: Int

    init(path: String) throws {
      name = (path as NSString).lastPathComponent
      sha256 = try fileDigest(path)
      guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber else {
        throw Failure("cannot read \(path)")
      }
      bytes = size.intValue
    }

    var json: JSONValue { .object([("name", .string(name)), ("sha256", .string(sha256)), ("bytes", .int(bytes))]) }
    var checksumLine: String { "\(sha256)  \(name)" }
  }

  struct Publisher {
    let root: String
    let environment: [String: String]
    /// Runs a command with extra environment variables. Tests substitute a
    /// fake GitHub; the real one runs `git` and `gh` in the repository.
    let runner: ([String], [String: String]) throws -> CommandResult

    @discardableResult
    func validate(output: String, githubOutput: String? = nil) throws -> Metadata {
      let version = try bundleVersion()
      let tag = "v\(version)"
      let event = environment["GITHUB_EVENT_NAME"] ?? ""
      let ref = environment["GITHUB_REF"] ?? ""
      let sourceSHA = environment["GITHUB_SHA"] ?? ""
      guard isFullSHA(sourceSHA) else { throw Failure("GITHUB_SHA must be a full commit SHA") }

      let publish: Bool
      switch event {
      case "push":
        guard ref == "refs/tags/\(tag)" else { throw Failure("release push must be refs/tags/\(tag)") }
        let tagSHA = try git("rev-parse", "\(tag)^{}")
        guard sameSHA(tagSHA, sourceSHA) else { throw Failure("tag \(tag) does not resolve to GITHUB_SHA") }
        publish = true
      case "workflow_dispatch":
        guard ref == "refs/heads/main" else { throw Failure("manual release validation is allowed only from main") }
        publish = false
      default:
        throw Failure("unsupported GitHub event \(JSONValue.quoted(event))")
      }
      try runChecked(["git", "merge-base", "--is-ancestor", sourceSHA, "origin/main"])

      let metadata = Metadata(version: version, tag: tag, sourceSHA: sourceSHA, publish: publish,
                              eventName: event, ref: ref)
      try write(metadata.json.pretty + "\n", to: output)
      if let path = githubOutput ?? environment["GITHUB_OUTPUT"], !path.isEmpty {
        try appendGitHubOutput(path, metadata)
      }
      return metadata
    }

    /// Writes `release-manifest.json` and `SHA256SUMS` beside the assets.
    @discardableResult
    func manifest(metadata path: String, releaseDirectory: String) throws -> [Asset] {
      let metadata = try readMetadata(path)
      let assets = try expectedAssets(metadata, releaseDirectory)
      let payload = JSONValue.object([
        ("schema", 1), ("version", .string(metadata.version)), ("tag", .string(metadata.tag)),
        ("source_sha", .string(metadata.sourceSHA)), ("assets", .array(assets.map(\.json))),
      ])
      try write(payload.pretty + "\n", to: releaseDirectory + "/release-manifest.json")
      try write(checksums(assets), to: releaseDirectory + "/SHA256SUMS")
      return assets
    }

    func publish(metadata path: String, releaseDirectory: String) throws {
      let metadata = try readMetadata(path)
      guard metadata.publish else { throw Failure("metadata does not authorize publishing") }
      try verifySource(metadata)
      let assets = try verifiedManifest(metadata, releaseDirectory)
      let names = assets.map(\.name) + integrityFiles
      // All verification above happens before this first GitHub mutation.
      var release: [String: Any]
      if let existing = try findRelease(metadata.tag) {
        release = existing
        try verifyRelease(release, metadata, assets, releaseDirectory, allowMissing: true)
      } else {
        try createDraftRelease(metadata)
        guard let created = try findRelease(metadata.tag) else {
          throw Failure("GitHub did not return newly created release")
        }
        release = created
      }

      try uploadMissingAssets(release, metadata.tag, names, releaseDirectory)
      guard let uploaded = try findRelease(metadata.tag) else {
        throw Failure("GitHub did not return release \(metadata.tag) after upload")
      }
      release = uploaded
      try verifyRelease(release, metadata, assets, releaseDirectory, allowMissing: false)
      if isTruthy(release["isDraft"]) {
        try runChecked(["gh", "release", "edit", metadata.tag, "--repo", terminalRepository, "--draft=false"])
      }
      try updateTap(metadata, assets.first { $0.name.hasSuffix(".zip") })
    }

    private func bundleVersion() throws -> String {
      let plist = root + "/Resources/Terminal/Info.plist"
      guard isRegularFile(plist, followingLinks: true), let data = FileManager.default.contents(atPath: plist) else {
        throw Failure("missing \(plist)")
      }
      let s = LinePattern.space
      let pattern = LinePattern("<key>\(s)*CFBundleShortVersionString\(s)*</key>\(s)*<string>\(s)*"
        + "([^< \\t\\n\\r\\f\\x0B]+)\(s)*</string>")
      let value = pattern.first(in: String(decoding: data, as: UTF8.self))?.groups[0] ?? ""
      guard isVersion(value) else { throw Failure("CFBundleShortVersionString must be X.Y.Z") }
      return value
    }

    /// The two assets a release consists of. Anything in the directory that
    /// is neither an asset nor a known by-product of the build is refused, so
    /// a stray file cannot be published or hide a missing one.
    private func expectedAssets(_ metadata: Metadata, _ releaseDirectory: String) throws -> [Asset] {
      let names = assetSuffixes.map { "HelgeTerminal-\(metadata.version)-arm64.\($0)" }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: releaseDirectory, isDirectory: &isDirectory), isDirectory.boolValue,
            let actual = try? FileManager.default.contentsOfDirectory(atPath: releaseDirectory) else {
        throw Failure("missing release directory \(releaseDirectory)")
      }
      let unexpected = actual.filter { !names.contains($0) && !localReleaseOutputs.contains($0) }
      guard unexpected.isEmpty else {
        throw Failure("unexpected release output: " + unexpected.joined(separator: ", "))
      }
      let missing = names.filter { !actual.contains($0) }
      guard missing.isEmpty else { throw Failure("missing release assets: " + missing.joined(separator: ", ")) }
      return try names.map { name in
        let path = releaseDirectory + "/" + name
        guard isRegularFile(path, followingLinks: false) else { throw Failure("missing regular asset \(name)") }
        return try Asset(path: path)
      }
    }

    private func checksums(_ assets: [Asset]) -> String {
      assets.map(\.checksumLine).joined(separator: "\n") + "\n"
    }

    /// The assets on disk, after checking that the manifest and checksum
    /// files written by the build job still describe exactly those files.
    private func verifiedManifest(_ metadata: Metadata, _ releaseDirectory: String) throws -> [Asset] {
      let manifestPath = releaseDirectory + "/release-manifest.json"
      let sumsPath = releaseDirectory + "/SHA256SUMS"
      guard isRegularFile(manifestPath, followingLinks: true), isRegularFile(sumsPath, followingLinks: true),
            let data = FileManager.default.contents(atPath: manifestPath) else {
        throw Failure("release manifest is missing")
      }
      let manifest: [String: Any]
      do {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          throw Failure("invalid release manifest: not a JSON object")
        }
        manifest = object
      } catch let failure as Failure {
        throw failure
      } catch {
        throw Failure("invalid release manifest: \(error.localizedDescription)")
      }
      let bound = [("version", metadata.version), ("tag", metadata.tag), ("source_sha", metadata.sourceSHA)]
      for (key, value) in bound where manifest[key] as? String != value {
        throw Failure("manifest \(key) differs from metadata")
      }
      let expected = try expectedAssets(metadata, releaseDirectory)
      guard recorded(manifest["assets"], equals: expected) else {
        throw Failure("release manifest assets differ from files")
      }
      guard FileManager.default.contents(atPath: sumsPath) == Data(checksums(expected).utf8) else {
        throw Failure("SHA256SUMS differs from release manifest")
      }
      return expected
    }

    /// Whether the manifest's asset list is exactly `expected`: same order,
    /// same three fields, nothing more.
    private func recorded(_ value: Any?, equals expected: [Asset]) -> Bool {
      guard let items = value as? [[String: Any]], items.count == expected.count else { return false }
      return zip(items, expected).allSatisfy { item, asset in
        guard item.count == 3, item["name"] as? String == asset.name, item["sha256"] as? String == asset.sha256,
              let bytes = item["bytes"] as? NSNumber, !isBoolean(bytes) else { return false }
        return bytes.doubleValue == Double(asset.bytes)
      }
    }

    /// Publishing is bound to the event, the checkout and the tag: the
    /// metadata from the build job must name the commit this job runs on.
    private func verifySource(_ metadata: Metadata) throws {
      let source = metadata.sourceSHA
      guard isFullSHA(source) else { throw Failure("metadata source_sha is invalid") }
      guard environment["GITHUB_EVENT_NAME"] == "push" else { throw Failure("publish requires a tag push event") }
      guard environment["GITHUB_REF"] == "refs/tags/\(metadata.tag)" else {
        throw Failure("publish ref must be refs/tags/\(metadata.tag)")
      }
      guard sameSHA(environment["GITHUB_SHA"] ?? "", source) else {
        throw Failure("metadata source_sha differs from GITHUB_SHA")
      }
      guard sameSHA(try git("rev-parse", "HEAD"), source) else {
        throw Failure("metadata source_sha differs from checkout HEAD")
      }
      guard sameSHA(try git("rev-parse", "\(metadata.tag)^{}"), source) else {
        throw Failure("metadata source_sha differs from release tag")
      }
      try runChecked(["git", "merge-base", "--is-ancestor", source, "origin/main"])
    }

    /// The release for a tag, or nil when GitHub says there is none. Any
    /// other failure stops the run: an unreadable release must not be taken
    /// for a missing one and created again.
    private func findRelease(_ tag: String) throws -> [String: Any]? {
      let result = try run(["gh", "release", "view", tag, "--repo", terminalRepository,
                            "--json", "tagName,isDraft,targetCommitish,assets"])
      guard result.succeeded else {
        if LinePattern("\\b(not found|http 404)\\b", ignoringCase: true).matches(result.error) { return nil }
        throw Failure("cannot read GitHub release \(tag): \(result.error)")
      }
      return try parseObject(result.output, or: "GitHub returned invalid release JSON")
    }

    private func createDraftRelease(_ metadata: Metadata) throws {
      try withTemporaryDirectory("release-notes-") { directory in
        let notes = directory + "/release-notes.md"
        try write("Helge Terminal \(metadata.tag)\n", to: notes)
        try runChecked(["gh", "release", "create", metadata.tag, "--repo", terminalRepository,
                        "--target", metadata.sourceSHA, "--draft", "--title", metadata.tag,
                        "--notes-file", notes])
      }
    }

    /// Compares an existing release with the local files. An asset already
    /// uploaded must be identical; it is never replaced. `allowMissing`
    /// accepts a partial draft that a rerun will complete.
    private func verifyRelease(_ release: [String: Any], _ metadata: Metadata, _ assets: [Asset],
                               _ releaseDirectory: String, allowMissing: Bool) throws {
      guard release["tagName"] as? String == metadata.tag else {
        throw Failure("release tag differs: \(inspect(release["tagName"]))")
      }
      let target = release["targetCommitish"] as? String ?? ""
      guard target.isEmpty || sameSHA(target, metadata.sourceSHA) else {
        throw Failure("release target differs: \(target)")
      }
      let remote = remoteAssets(release)
      let files = try assets + integrityFiles.map { try Asset(path: releaseDirectory + "/" + $0) }
      for file in files {
        guard let asset = remote.last(where: { $0.name == file.name }) else { continue }
        try verifyRemoteAsset(asset.fields, file, metadata.tag, releaseDirectory)
      }
      let missing = files.map(\.name).filter { name in !remote.contains { $0.name == name } }
      if !allowMissing, !missing.isEmpty {
        throw Failure("release is missing assets: " + missing.joined(separator: ", "))
      }
      let unexpected = remote.map(\.name).filter { name in !files.contains { $0.name == name } }
      guard unexpected.isEmpty else {
        throw Failure("release contains unexpected assets: " + unexpected.joined(separator: ", "))
      }
    }

    private func remoteAssets(_ release: [String: Any]) -> [(name: String, fields: [String: Any])] {
      (release["assets"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0) }
    }

    /// GitHub's digest decides when it gives one; otherwise the asset is
    /// downloaded and hashed. An asset that cannot be verified is a failure.
    private func verifyRemoteAsset(_ remote: [String: Any], _ asset: Asset, _ tag: String,
                                   _ releaseDirectory: String) throws {
      var digest = remote["digest"] as? String ?? ""
      if digest.hasPrefix("sha256:") { digest.removeFirst("sha256:".count) }
      if digest.count == 64, digest.allSatisfy(isHexDigit) {
        guard sameSHA(digest, asset.sha256) else { throw Failure("remote asset \(asset.name) has a different SHA256") }
      } else if try !remoteAssetMatchesFile(remote, releaseDirectory + "/" + asset.name, tag) {
        throw Failure("cannot verify remote asset \(asset.name)")
      }
      if isTruthy(remote["size"]), integer(remote["size"]) != asset.bytes {
        throw Failure("remote asset \(asset.name) has a different size")
      }
    }

    private func remoteAssetMatchesFile(_ remote: [String: Any], _ path: String, _ tag: String) throws -> Bool {
      guard let name = remote["name"] as? String, name == (path as NSString).lastPathComponent else { return false }
      return try withTemporaryDirectory("release-asset-") { directory in
        let result = try run(["gh", "release", "download", tag, "--repo", terminalRepository,
                              "--pattern", name, "--dir", directory, "--clobber"])
        let copy = directory + "/" + name
        guard result.succeeded, isRegularFile(copy, followingLinks: true) else { return false }
        return try sha256(ofFile: copy) == sha256(ofFile: path)
      }
    }

    private func uploadMissingAssets(_ release: [String: Any], _ tag: String, _ names: [String],
                                     _ releaseDirectory: String) throws {
      let present = remoteAssets(release).map(\.name)
      let missing = names.filter { !present.contains($0) }
      guard !missing.isEmpty else { return }
      try runChecked(["gh", "release", "upload", tag] + missing.map { releaseDirectory + "/" + $0 }
                     + ["--repo", terminalRepository])
    }

    /// Points the cask at this release. The write names the file revision it
    /// was based on, so a concurrent change makes it fail; the cask is then
    /// read again. A newer cask is left alone, and one that already has this
    /// version must be identical.
    private func updateTap(_ metadata: Metadata, _ zip: Asset?) throws {
      guard let zip else { throw Failure("ZIP asset missing from manifest") }
      for _ in 0..<3 {
        let current = try tapCask()
        guard let content = current["content"] as? String, let revision = current["sha"] as? String,
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
              let text = String(data: data, encoding: .utf8) else {
          throw Failure("GitHub returned invalid cask JSON: no readable content and sha")
        }
        let state = try caskState(text)
        let order = compareVersions(state.version, metadata.version)
        if order > 0 { return }
        if order == 0 {
          if state.url == releaseURL(metadata, zip), sameSHA(state.sha256, zip.sha256), hasTerminalLivecheck(text) {
            return
          }
          throw Failure("tap already has a different \(metadata.version) cask")
        }
        let replacement = try replacedCask(text, metadata, zip)
        let result = try runTap(["gh", "api", "--method", "PUT", "repos/\(tapRepository)/contents/\(tapCaskPath)",
                                 "-f", "message=Update Helge Terminal to \(metadata.tag)",
                                 "-f", "content=\(Data(replacement.utf8).base64EncodedString())",
                                 "-f", "sha=\(revision)", "-f", "branch=main"])
        if result.succeeded { return }
      }
      throw Failure("tap cask changed concurrently; refusing to overwrite it")
    }

    private func tapCask() throws -> [String: Any] {
      let result = try runTap(["gh", "api", "repos/\(tapRepository)/contents/\(tapCaskPath)?ref=main"])
      guard result.succeeded else { throw Failure("command failed: gh api tap cask\n\(result.error)") }
      return try parseObject(result.output, or: "GitHub returned invalid cask JSON")
    }

    private func caskState(_ text: String) throws -> (version: String, url: String, sha256: String) {
      let s = LinePattern.space
      guard let version = LinePattern("^\(s)*version\(s)+\"([^\"]+)\"").first(in: text)?.groups[0],
            let url = LinePattern("^\(s)*url\(s)+\"([^\"]+)\"").first(in: text)?.groups[0],
            let sha = LinePattern("^\(s)*sha256\(s)+\"([0-9a-f]{64})\"", ignoringCase: true).first(in: text)?.groups[0]
      else { throw Failure("tap cask has no simple version, URL, and SHA256 fields") }
      return (version, url, sha)
    }

    /// The cask with its version, URL and checksum replaced and the livecheck
    /// block rewritten. A field's indentation is matched without newlines, so
    /// that the match starts on the field's own line and blank lines before it stay.
    func replacedCask(_ text: String, _ metadata: Metadata, _ zip: Asset) throws -> String {
      let s = LinePattern.space
      let indent = "[ \\t]*"
      var updated = text
      let fields = [
        (LinePattern("^\(indent)version\(s)+\"[^\"]+\""), "  version \"\(metadata.version)\""),
        (LinePattern("^\(indent)url\(s)+\"[^\"]+\""), "  url \"\(releaseURL(metadata, zip))\""),
        (LinePattern("^\(indent)sha256\(s)+\"[0-9a-f]{64}\"", ignoringCase: true), "  sha256 \"\(zip.sha256)\""),
      ]
      for (pattern, replacement) in fields {
        updated = pattern.replacingFirst(in: updated, with: replacement) ?? updated
      }
      let livecheck = """
          livecheck do
            url "https://github.com/\(terminalRepository)/releases"
            regex(/^v?(\\d+(?:\\.\\d+)+)$/i)
            strategy :github_releases
          end
        """
      guard let result = LinePattern("^  livecheck do\\n.*?^  end$").replacingFirst(in: updated, with: livecheck) else {
        throw Failure("tap cask has no replaceable livecheck block")
      }
      return result
    }

    private func releaseURL(_ metadata: Metadata, _ zip: Asset) -> String {
      "https://github.com/\(terminalRepository)/releases/download/\(metadata.tag)/\(zip.name)"
    }

    private func hasTerminalLivecheck(_ text: String) -> Bool {
      let s = LinePattern.space
      return LinePattern("livecheck do\(s)+url \"https://github\\.com/HelgeSverre/terminal/releases\"\(s)+"
        + "regex\\(/\\^v\\?\\(\\\\d\\+\\(\\?:\\\\\\.\\\\d\\+\\)\\+\\)\\$/i\\)\(s)+"
        + "strategy :github_releases\(s)+end").matches(text)
    }

    /// Orders two dotted versions number by number; a longer one is greater
    /// when the shared numbers are equal.
    private func compareVersions(_ left: String, _ right: String) -> Int {
      let (left, right) = (numbers(left), numbers(right))
      for (a, b) in zip(left, right) where a != b { return a < b ? -1 : 1 }
      return left.count == right.count ? 0 : (left.count < right.count ? -1 : 1)
    }

    private func numbers(_ version: String) -> [Int] {
      var parts = version.split(separator: ".", omittingEmptySubsequences: false)
      while parts.last?.isEmpty == true { parts.removeLast() }
      return parts.map { Int($0.prefix { $0.isASCII && $0.isNumber }) ?? 0 }
    }

    private func readMetadata(_ path: String) throws -> Metadata {
      guard let data = FileManager.default.contents(atPath: path) else { throw Failure("missing metadata \(path)") }
      let object = try parseObject(String(decoding: data, as: UTF8.self), or: "invalid metadata")
      for key in ["version", "tag", "source_sha", "publish"] where object[key] == nil {
        throw Failure("metadata missing \(key)")
      }
      guard let version = object["version"] as? String, isVersion(version) else {
        throw Failure("metadata version is invalid")
      }
      guard let tag = object["tag"] as? String, tag == "v\(version)" else {
        throw Failure("metadata tag does not match version")
      }
      guard let sourceSHA = object["source_sha"] as? String else { throw Failure("metadata source_sha is invalid") }
      // Only the JSON value true authorizes publishing; 1 or "true" do not.
      let publish = (object["publish"] as? NSNumber).map { isBoolean($0) && $0.boolValue } ?? false
      return Metadata(version: version, tag: tag, sourceSHA: sourceSHA, publish: publish,
                      eventName: object["event_name"] as? String ?? "", ref: object["ref"] as? String ?? "")
    }

    private func appendGitHubOutput(_ path: String, _ metadata: Metadata) throws {
      let lines = "version=\(metadata.version)\ntag=\(metadata.tag)\npublish=\(metadata.publish)\n"
        + "source_sha=\(metadata.sourceSHA)\n"
      guard let file = fopen(path, "a") else { throw Failure("cannot write \(path)") }
      let written = fputs(lines, file) >= 0
      guard fclose(file) == 0, written else { throw Failure("cannot write \(path)") }
    }

    private func write(_ text: String, to path: String) throws {
      do { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) } catch { throw Failure("cannot write \(path)") }
    }

    private func parseObject(_ text: String, or message: String) throws -> [String: Any] {
      do {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
          throw Failure("\(message): not a JSON object")
        }
        return object
      } catch let failure as Failure {
        throw failure
      } catch {
        throw Failure("\(message): \(error.localizedDescription)")
      }
    }

    private func git(_ arguments: String...) throws -> String {
      try runChecked(["git"] + arguments).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func runChecked(_ command: [String]) throws -> CommandResult {
      let result = try run(command)
      guard result.succeeded else {
        throw Failure("command failed: \(command.joined(separator: " "))\n\(result.error)")
      }
      return result
    }

    /// Runs a command; `gh` gets the release repository's token and nothing else does.
    private func run(_ command: [String]) throws -> CommandResult {
      let added = command.first == "gh" ? try gitHubEnvironment() : [:]
      return try runner(command, added)
    }

    /// Runs `gh` against the tap, with the tap's own token.
    private func runTap(_ command: [String]) throws -> CommandResult {
      guard let token = environment["TAP_GITHUB_TOKEN"], !token.isEmpty else {
        throw Failure("TAP_GITHUB_TOKEN is required to update the Homebrew tap")
      }
      return try runner(command, ["GH_TOKEN": token])
    }

    /// The first of the two variables that has a value. An empty one counts
    /// as unset, as it does for `gh`.
    private func gitHubEnvironment() throws -> [String: String] {
      guard let token = ["GITHUB_TOKEN", "GH_TOKEN"].compactMap({ environment[$0] }).first(where: { !$0.isEmpty }) else {
        throw Failure("GITHUB_TOKEN or GH_TOKEN is required for GitHub commands")
      }
      return ["GH_TOKEN": token]
    }

    private func isRegularFile(_ path: String, followingLinks: Bool) -> Bool {
      var info = stat()
      guard (followingLinks ? stat(path, &info) : lstat(path, &info)) == 0 else { return false }
      return info.st_mode & S_IFMT == S_IFREG
    }
  }

  private static func fileDigest(_ path: String) throws -> String { try sha256(ofFile: path) }

  private static func isHexDigit(_ character: Character) -> Bool { character.isASCII && character.isHexDigit }

  private static func isFullSHA(_ text: String) -> Bool { text.count == 40 && text.allSatisfy(isHexDigit) }

  private static func sameSHA(_ left: String, _ right: String) -> Bool { left.lowercased() == right.lowercased() }

  /// Whether `text` is three runs of ASCII digits separated by dots.
  private static func isVersion(_ text: String) -> Bool {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
  }

  private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

  /// Whether a JSON value is anything but absent, null or false.
  private static func isTruthy(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    if let number = value as? NSNumber, isBoolean(number) { return number.boolValue }
    return true
  }

  private static func integer(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    return Int((value as? String ?? "").prefix { $0.isASCII && $0.isNumber }) ?? 0
  }

  private static func inspect(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "nil" }
    return (value as? String).map(JSONValue.quoted) ?? "\(value)"
  }
}
