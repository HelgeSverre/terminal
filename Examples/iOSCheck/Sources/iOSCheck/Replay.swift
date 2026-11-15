import Foundation
import TerminalHost

/// A transport that plays fixed output and records what is typed.
public final class Replay: TerminalTransport, @unchecked Sendable {
  private let output: Data
  private let lock = NSLock()
  private var typed = Data()
  public init(_ output: String) { self.output = Data(output.utf8) }
  public var sent: String { lock.lock(); defer { lock.unlock() }; return String(decoding: typed, as: UTF8.self) }
  public func start(_ connection: TerminalConnection, columns: Int, rows: Int) { connection.receive(output) }
  public func send(_ bytes: Data) { lock.lock(); typed.append(bytes); lock.unlock() }
}
