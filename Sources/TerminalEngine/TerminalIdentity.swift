/// The implementation name and optional host-supplied version reported by
/// XTVERSION. Libraries never infer a version from the embedding app's bundle.
public struct TerminalIdentity: Equatable, Sendable {
  public let name: String
  public let version: String?

  /// Names and versions are bounded printable ASCII tokens, so a host cannot
  /// accidentally insert a control sequence into a terminal reply.
  public init(name: String, version: String? = nil) {
    func token(_ value: String) -> String {
      String(decoding: value.utf8.filter { (0x21...0x7e).contains($0) }.prefix(128), as: UTF8.self)
    }
    let name = token(name)
    self.name = name.isEmpty ? "HelgeTerminal" : name
    self.version = version.map(token).flatMap { $0.isEmpty ? nil : $0 }
  }

  /// The engine's truthful default, with no assumed application version.
  public static let helgeTerminal = TerminalIdentity(name: "HelgeTerminal")
  package var versionReply: String {
    "\u{1b}P>|\(name)\(version.map { " " + $0 } ?? "")\u{1b}\\"
  }
}
