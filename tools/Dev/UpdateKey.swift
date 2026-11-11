import CryptoKit
import Foundation

/// The Ed25519 key that signs app updates for Sparkle. The private key is the
/// base64 of its 32 raw bytes, the public key (`SUPublicEDKey`) likewise, and a
/// signature (`sparkle:edSignature`) is the base64 of the 64 bytes over a file.
enum UpdateKey {
  static let command = Command(
    name: "update-key", usage: "generate|public --private-key-file PATH",
    summary: "Create the update signing key, or print the public key of an existing one.",
    run: run)

  static func run(_ arguments: [String]) throws {
    guard let action = arguments.first, ["generate", "public"].contains(action) else { throw Failure.usage(command) }
    let options = try Options(Array(arguments.dropFirst()), flags: [], values: ["--private-key-file"], command: command)
    guard let path = options.values["--private-key-file"], options.positionals.isEmpty else {
      throw Failure.usage(command)
    }
    let lines = action == "generate" ? try generate(privateKeyFile: path) : [try publicKey(privateKeyFile: path)]
    print(lines.joined(separator: "\n"))
  }

  /// Writes a new key to `path` and returns the lines to print: the public
  /// key and where the private one went. The private key is never returned.
  static func generate(privateKeyFile path: String) throws -> [String] {
    let key = Curve25519.Signing.PrivateKey()
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else {
      throw Failure(errno == EEXIST ? "\(path) already exists; refusing to overwrite it" : "cannot write \(path)")
    }
    do {
      // The mode is set explicitly so that no umask can widen it.
      guard fchmod(descriptor, 0o600) == 0 else { throw Failure("cannot write \(path)") }
      try writeAll(descriptor, Data((key.rawRepresentation.base64EncodedString() + "\n").utf8))
      guard close(descriptor) == 0 else { throw Failure("cannot write \(path)") }
    } catch {
      close(descriptor)
      unlink(path)
      throw Failure("cannot write \(path)")
    }
    return [key.publicKey.rawRepresentation.base64EncodedString(), "private key written to \(path)"]
  }

  static func publicKey(privateKeyFile path: String) throws -> String {
    guard let data = FileManager.default.contents(atPath: path) else { throw Failure("cannot read \(path)") }
    let key = try privateKey(base64: String(decoding: data, as: UTF8.self))
    return key.publicKey.rawRepresentation.base64EncodedString()
  }

  /// Never puts the text it was given into the error.
  static func privateKey(base64 text: String) throws -> Curve25519.Signing.PrivateKey {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: trimmed), raw.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
      throw Failure("the update private key must be the base64 of 32 raw bytes")
    }
    return key
  }

  static func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> String {
    try key.signature(for: data).base64EncodedString()
  }

  static func verify(signature: String, of data: Data, publicKey: String) -> Bool {
    guard let raw = Data(base64Encoded: publicKey), let signature = Data(base64Encoded: signature),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
    return key.isValidSignature(signature, for: data)
  }
}
