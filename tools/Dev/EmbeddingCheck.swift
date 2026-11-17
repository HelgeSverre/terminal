import Foundation

/// Exercises the dependency graph from a host, including a local path outside
/// SwiftPM's checkouts directory. A URL/revision can qualify a pushed commit.
enum EmbeddingCheck {
  static let command = Command(name: "embedding-check", usage: "[--url URL --revision REV]",
    summary: "Build Swift 6 consumer hosts with the development graph disabled.", run: run)

  static func run(_ arguments: [String]) throws {
    let options = try Options(arguments, flags: [], values: ["--url", "--revision"], command: command)
    guard options.positionals.isEmpty,
      (options.values["--url"] == nil) == (options.values["--revision"] == nil) else { throw Failure.usage(command) }
    let environment: [String: String?] = [
      "TERMINAL_DEVELOPMENT": nil, "TERMINAL_TEST_HOOKS": nil,
      "TERMINAL_EMBEDDING_URL": options.values["--url"],
      "TERMINAL_EMBEDDING_REVISION": options.values["--revision"],
    ]
    let manifest = try Console.quietly(["swift", "package", "--package-path", Repository.root, "dump-package"], adding: environment)
    guard let json = try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any],
      let dependencies = json["dependencies"] as? [Any], dependencies.isEmpty,
      let targets = json["targets"] as? [[String: Any]],
      !targets.contains(where: { ["TerminalApp", "TerminalTests", "dev", "UpdatePreview"].contains($0["name"] as? String ?? "") }) else {
      throw Failure("consumer manifest unexpectedly includes development targets or dependencies")
    }
    let examples = Repository.path("Examples/Embedding")
    try Console.quietly(["swift", "build", "--package-path", examples, "--jobs", "3"], adding: environment)
    let graph = try Console.quietly(["swift", "package", "--package-path", examples, "show-dependencies", "--format", "json"], adding: environment)
    guard !graph.lowercased().contains("sparkle") else { throw Failure("consumer unexpectedly resolved Sparkle") }
    Console.done("consumer graph and Swift 6 example hosts passed")
  }
}
