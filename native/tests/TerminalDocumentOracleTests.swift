// This file is intentionally excluded from the current gate.  It becomes an
// executable integration suite only with the canonical TerminalDocument module;
// keeping it conditional prevents a no-op "pass" from being counted as parity.
#if TERMINAL_DOCUMENT
import Foundation

@main enum TerminalDocumentOracleTests {
  static func main() {
    // The concrete scenarios are introduced with TerminalDocument, not copied
    // into a text-only helper. Required oracle names are tracked in
    // docs/document-integration-ledger.md.
    fatalError("TerminalDocument oracle scenarios must be implemented with the canonical document")
  }
}
#endif
