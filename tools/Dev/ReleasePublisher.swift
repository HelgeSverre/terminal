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
  static let assetSuffixes = ["zip", "pkg"]
  static let localReleaseOutputs = ["Helge Terminal.app", "notary-app.json", "notary-pkg.json",
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

  // Tests. `FakeGitHub` stands in for `git` and `gh`; no command is run and
  // every file is inside a temporary directory.

  private static let sha = String(repeating: "a", count: 40)

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
          guard let asset = try? Asset(path: path) else { return CommandResult(error: "cannot read \(path)", status: 1) }
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

    func publisher(_ environment: [String: String]) -> Publisher {
      Publisher(root: root, environment: environment, runner: gitHub.call)
    }
    var publishing: Publisher { publisher(publishingEnvironment) }

    func write(_ text: String, to path: String) throws {
      try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
    func read(_ path: String) -> String {
      String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
    }

    /// Builds the two assets, then validates and writes the manifest as the build job does.
    func prepareRelease() throws {
      try FileManager.default.createDirectory(atPath: releaseDirectory, withIntermediateDirectories: true)
      try write("zip", to: zip)
      try write("pkg", to: releaseDirectory + "/HelgeTerminal-1.2.3-arm64.pkg")
      try publishing.validate(output: metadata)
      try publishing.manifest(metadata: metadata, releaseDirectory: releaseDirectory)
    }

    func publish() throws { try publishing.publish(metadata: metadata, releaseDirectory: releaseDirectory) }
  }

  private static func withFixture(_ body: (Fixture) throws -> Void) throws {
    try withTemporaryDirectory("dev-release-publisher-") { try body(try Fixture(root: $0)) }
  }

  static let tests = [
    SelfTest.Case(name: "release publisher: validate accepts a matching tag and writes safe metadata") {
      try withFixture { fixture in
        let githubOutput = fixture.root + "/github-output"
        let environment = fixture.tagEnvironment.merging(["GITHUB_OUTPUT": githubOutput]) { $1 }
        let metadata = try fixture.publisher(environment).validate(output: fixture.metadata)

        try expect(metadata.publish, "a tag push authorizes publishing")
        try expect(metadata.tag == "v1.2.3", "got: \(metadata.tag)")
        try expect(fixture.read(fixture.metadata) == """
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
        try expect(fixture.read(githubOutput) == "version=1.2.3\ntag=v1.2.3\npublish=true\nsource_sha=\(sha)\n",
                   "got: \(fixture.read(githubOutput))")
        try expect(fixture.gitHub.calls.allSatisfy { $0.environment.isEmpty }, "git gets no token")
      }
    },
    SelfTest.Case(name: "release publisher: validate rejects a wrong tag or an unreachable source") {
      try withFixture { fixture in
        let wrongTag = fixture.tagEnvironment.merging(["GITHUB_REF": "refs/tags/v1.2.4"]) { $1 }
        var message = try expectFailure("a tag that differs from the bundle version") {
          try fixture.publisher(wrongTag).validate(output: fixture.metadata)
        }.message
        try expect(message.contains("refs/tags/v1.2.3"), "got: \(message)")

        fixture.gitHub.ancestor = false
        message = try expectFailure("a commit that is not on main") {
          try fixture.publisher(fixture.tagEnvironment).validate(output: fixture.metadata)
        }.message
        try expect(message.contains("merge-base"), "got: \(message)")
        try expect(!FileManager.default.fileExists(atPath: fixture.metadata), "no metadata is written")
      }
    },
    SelfTest.Case(name: "release publisher: a manual run from main is valid but never authorizes publishing") {
      try withFixture { fixture in
        let manual = ["GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": sha]
        let metadata = try fixture.publisher(manual).validate(output: fixture.metadata)
        try expect(!metadata.publish, "a manual run does not publish")
        try expect(metadata.tag == "v1.2.3", "got: \(metadata.tag)")
        try expect(fixture.read(fixture.metadata).contains("\"publish\": false"), "metadata records it")

        try FileManager.default.createDirectory(atPath: fixture.releaseDirectory, withIntermediateDirectories: true)
        let message = try expectFailure("publishing a manual run") { try fixture.publish() }.message
        try expect(message == "metadata does not authorize publishing", "got: \(message)")
        try expect(!fixture.gitHub.calls.contains { $0.command.first == "gh" }, "GitHub is not contacted")
      }
    },
    SelfTest.Case(name: "release publisher: manifest and publish are idempotent") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        try fixture.publish()
        try fixture.publish()

        try expect(fixture.gitHub.release?["isDraft"] as? Bool == false, "release is published")
        let names = fixture.gitHub.assets.compactMap { $0["name"] as? String }.sorted()
        try expect(names == ["HelgeTerminal-1.2.3-arm64.pkg", "HelgeTerminal-1.2.3-arm64.zip", "SHA256SUMS",
                             "release-manifest.json"], "got: \(names)")
        try expect(fixture.gitHub.caskVersion == "1.2.3", "cask is updated")
        try expect(fixture.gitHub.puts == 1, "cask is written once, got \(fixture.gitHub.puts)")
      }
    },
    SelfTest.Case(name: "release publisher: publish refuses an integrity conflict before any tap mutation") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        fixture.gitHub.release = [
          "tagName": "v1.2.3", "targetCommitish": sha, "isDraft": false,
          "assets": [["name": "HelgeTerminal-1.2.3-arm64.zip", "digest": "sha256:" + String(repeating: "0", count: 64),
                      "size": 3]] as [[String: Any]],
        ]
        let message = try expectFailure("a different remote asset") { try fixture.publish() }.message
        try expect(message.contains("different SHA256"), "got: \(message)")
        try expect(fixture.gitHub.puts == 0, "cask is untouched")
        try expect(fixture.gitHub.assets.count == 1, "nothing is uploaded")
      }
    },
    SelfTest.Case(name: "release publisher: publish fails closed when the release lookup is not a 404") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        fixture.gitHub.releaseError = "HTTP 502: GitHub is unavailable"
        let message = try expectFailure("an unreadable release") { try fixture.publish() }.message
        try expect(message.contains("cannot read GitHub release"), "got: \(message)")
        try expect(fixture.gitHub.release == nil, "no release is created")
        try expect(fixture.gitHub.puts == 0, "cask is untouched")
      }
    },
    SelfTest.Case(name: "release publisher: a partial draft is completed without replacing a verified asset") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        let zip = try Asset(path: fixture.zip)
        fixture.gitHub.release = [
          "tagName": "v1.2.3", "targetCommitish": sha, "isDraft": true,
          "assets": [["name": zip.name, "size": zip.bytes, "digest": "sha256:\(zip.sha256)"]] as [[String: Any]],
        ]
        try fixture.publish()

        try expect(fixture.gitHub.release?["isDraft"] as? Bool == false, "release is published")
        try expect(fixture.gitHub.assets.count == 4, "got \(fixture.gitHub.assets.count) assets")
        let uploads = fixture.gitHub.calls.filter { $0.command.starts(with: ["gh", "release", "upload"]) }
        try expect(uploads.count == 1 && !uploads[0].command.contains(fixture.zip), "the ZIP is not uploaded again")
      }
    },
    SelfTest.Case(name: "release publisher: publish binds metadata to the current checkout and event") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        let other = String(repeating: "b", count: 40)
        try fixture.write(fixture.read(fixture.metadata).replacingOccurrences(of: sha, with: other), to: fixture.metadata)
        try fixture.publishing.manifest(metadata: fixture.metadata, releaseDirectory: fixture.releaseDirectory)

        let message = try expectFailure("metadata for another commit") { try fixture.publish() }.message
        try expect(message.contains("GITHUB_SHA"), "got: \(message)")
        try expect(fixture.gitHub.release == nil, "no release is created")
      }
    },
    SelfTest.Case(name: "release publisher: the tap update reloads and skips a newer version") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        fixture.gitHub.caskText = fixture.gitHub.caskText
          .replacingOccurrences(of: "version \"0.2.2\"", with: "version \"9.0.0\"")
        try fixture.publish()
        try expect(fixture.gitHub.puts == 0, "cask is untouched")
        try expect(fixture.gitHub.caskVersion == "9.0.0", "got: \(fixture.gitHub.caskVersion ?? "none")")
      }
    },
    SelfTest.Case(name: "release publisher: the tap update retries after a concurrent update") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        fixture.gitHub.failFirstTapPut = true
        try fixture.publish()
        try expect(fixture.gitHub.caskVersion == "1.2.3", "got: \(fixture.gitHub.caskVersion ?? "none")")
        try expect(fixture.gitHub.puts == 2, "got \(fixture.gitHub.puts) writes")
      }
    },
    SelfTest.Case(name: "release publisher: manifest allows known private release outputs") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        try FileManager.default.createDirectory(atPath: fixture.releaseDirectory + "/Helge Terminal.app",
                                                withIntermediateDirectories: false)
        for name in ["notary-app.json", "notary-pkg.json", "release-metadata.json"] {
          try fixture.write("{}", to: fixture.releaseDirectory + "/" + name)
        }
        let assets = try fixture.publishing.manifest(metadata: fixture.metadata,
                                                    releaseDirectory: fixture.releaseDirectory)
        try expect(assets.map(\.name).sorted() == ["HelgeTerminal-1.2.3-arm64.pkg", "HelgeTerminal-1.2.3-arm64.zip"],
                   "got: \(assets.map(\.name))")

        try fixture.write("", to: fixture.releaseDirectory + "/stray.txt")
        let message = try expectFailure("a stray file") {
          try fixture.publishing.manifest(metadata: fixture.metadata, releaseDirectory: fixture.releaseDirectory)
        }.message
        try expect(message == "unexpected release output: stray.txt", "got: \(message)")
      }
    },
    SelfTest.Case(name: "release publisher: the manifest, checksums and cask have the exact published text") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        let zip = try Asset(path: fixture.zip)
        let pkg = try Asset(path: fixture.releaseDirectory + "/HelgeTerminal-1.2.3-arm64.pkg")
        try expect(fixture.read(fixture.releaseDirectory + "/SHA256SUMS")
                     == "\(zip.sha256)  \(zip.name)\n\(pkg.sha256)  \(pkg.name)\n", "checksum file")
        try expect(fixture.read(fixture.releaseDirectory + "/release-manifest.json") == """
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
              },
              {
                "name": "\(pkg.name)",
                "sha256": "\(pkg.sha256)",
                "bytes": 3
              }
            ]
          }

          """, "got: \(fixture.read(fixture.releaseDirectory + "/release-manifest.json"))")

        try fixture.publish()
        try expect(fixture.gitHub.caskText == """
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
    },
    SelfTest.Case(name: "release publisher: each repository's token goes only to its own commands") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        try fixture.publish()
        for call in fixture.gitHub.calls {
          let tap = call.command.starts(with: ["gh", "api"])
          let expected = call.command.first == "git" ? [:] : ["GH_TOKEN": tap ? "tap-token" : "release-token"]
          try expect(call.environment == expected, "wrong token for \(call.command.prefix(3))")
        }
        var withoutTap = fixture.publishingEnvironment
        withoutTap["TAP_GITHUB_TOKEN"] = nil
        fixture.gitHub.caskText = fixture.gitHub.caskText.replacingOccurrences(of: "1.2.3", with: "0.0.1")
        let message = try expectFailure("a missing tap token") {
          try fixture.publisher(withoutTap).publish(metadata: fixture.metadata, releaseDirectory: fixture.releaseDirectory)
        }.message
        try expect(message == "TAP_GITHUB_TOKEN is required to update the Homebrew tap", "got: \(message)")
      }
    },
    SelfTest.Case(name: "release publisher: an empty GITHUB_TOKEN does not hide GH_TOKEN") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        var environment = fixture.publishingEnvironment
        environment["GITHUB_TOKEN"] = ""
        environment["GH_TOKEN"] = "fallback-token"
        try fixture.publisher(environment).publish(metadata: fixture.metadata, releaseDirectory: fixture.releaseDirectory)
        let releaseCalls = fixture.gitHub.calls.filter { $0.command.starts(with: ["gh", "release"]) }
        try expect(!releaseCalls.isEmpty && releaseCalls.allSatisfy { $0.environment == ["GH_TOKEN": "fallback-token"] },
                   "release commands get the token that is set")

        environment["GH_TOKEN"] = ""
        let message = try expectFailure("two empty tokens") {
          try fixture.publisher(environment).publish(metadata: fixture.metadata, releaseDirectory: fixture.releaseDirectory)
        }.message
        try expect(message == "GITHUB_TOKEN or GH_TOKEN is required for GitHub commands", "got: \(message)")
      }
    },
    SelfTest.Case(name: "release publisher: the cask rewrite changes only the three fields' own lines") {
      try withFixture { fixture in
        try fixture.prepareRelease()
        let zip = try Asset(path: fixture.zip)
        let metadata = Metadata(version: "1.2.3", tag: "v1.2.3", sourceSHA: sha, publish: true)
        let old = String(repeating: "1", count: 64)
        let livecheck = "  livecheck do\n    url \"https://example.invalid\"\n  end\nend\n"
        let cask = "cask \"helge-terminal\" do\n\n\n  version \"0.2.2\"\n\n  sha256 \"\(old)\"\n\t\n"
          + "\turl \"https://example.invalid/old.zip\"\n\n" + livecheck
        let rewritten = try fixture.publishing.replacedCask(cask, metadata, zip)
        let expected = "cask \"helge-terminal\" do\n\n\n  version \"1.2.3\"\n\n  sha256 \"\(zip.sha256)\"\n\t\n"
          + "  url \"https://github.com/HelgeSverre/terminal/releases/download/v1.2.3/\(zip.name)\"\n\n"
        try expect(rewritten.hasPrefix(expected), "got: \(rewritten.debugDescription)")
        try expect(rewritten.hasSuffix("    strategy :github_releases\n  end\nend\n"), "the livecheck block is replaced")
      }
    },
    SelfTest.Case(name: "release publisher: options take a separate or an attached value") {
      let options = try parseOptions(["--metadata", "a.json", "--release-dir=out"])
      try expect(options == ["metadata": "a.json", "release-dir": "out"], "got: \(options)")
      try expectFailure("an unknown option") { _ = try parseOptions(["--force"]) }
      try expectFailure("an option without a value") { _ = try parseOptions(["--output"]) }
    },
  ]
}
