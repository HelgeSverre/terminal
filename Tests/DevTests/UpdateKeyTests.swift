import CryptoKit
import Foundation
import Testing
@testable import dev

@Suite struct UpdateKeyTests {
  @Test("update-key: generate writes a private 0600 key and prints only the public key") func generateWritesAPrivateKey() throws {
    try withTemporaryDirectory("dev-update-key-") { directory in
      let path = directory + "/update.key"
      let lines = try UpdateKey.generate(privateKeyFile: path)
      let stored = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let mode = try #require(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
      #expect(mode.intValue == 0o600, "got: \(String(mode.intValue, radix: 8))")
      #expect(Data(base64Encoded: stored)?.count == 32, "private key is 32 raw bytes")
      #expect(lines.count == 2 && lines[1] == "private key written to \(path)", "got: \(lines)")
      #expect(Data(base64Encoded: lines[0])?.count == 32, "public key is 32 raw bytes")
      #expect(lines[0] != stored, "the public key is not the private key")
      #expect(!lines.joined(separator: "\n").contains(stored), "the private key is never printed")
      #expect(try UpdateKey.publicKey(privateKeyFile: path) == lines[0], "public derives from the file")
    }
  }

  @Test("update-key: generate refuses to overwrite a key") func generateRefusesToOverwrite() throws {
    try withTemporaryDirectory("dev-update-key-") { directory in
      let path = directory + "/update.key"
      _ = try UpdateKey.generate(privateKeyFile: path)
      let before = FileManager.default.contents(atPath: path)
      let message = try #require(throws: Failure.self) { try UpdateKey.generate(privateKeyFile: path) }.message
      #expect(message.contains("already exists"), "got: \(message)")
      #expect(FileManager.default.contents(atPath: path) == before, "the file is untouched")
    }
  }

  @Test("update-key: a bad private key is rejected without echoing it") func aBadPrivateKeyIsRejected() throws {
    let message = try #require(throws: Failure.self) { _ = try UpdateKey.privateKey(base64: "c2VjcmV0") }.message
    #expect(!message.contains("c2VjcmV0"), "got: \(message)")
    #expect(throws: Failure.self) { _ = try UpdateKey.publicKey(privateKeyFile: "/nonexistent/key") }
  }

  @Test("update-key: a signature verifies against the public key and nothing else") func aSignatureVerifies() throws {
    let key = Curve25519.Signing.PrivateKey()
    let other = Curve25519.Signing.PrivateKey()
    let data = Data("archive bytes".utf8)
    let signature = try UpdateKey.sign(data, with: key)
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    #expect(Data(base64Encoded: signature)?.count == 64, "signature is 64 bytes")
    #expect(UpdateKey.verify(signature: signature, of: data, publicKey: publicKey))
    #expect(!UpdateKey.verify(signature: signature, of: Data("other".utf8), publicKey: publicKey))
    #expect(!UpdateKey.verify(signature: signature, of: data,
                              publicKey: other.publicKey.rawRepresentation.base64EncodedString()))
  }
}
