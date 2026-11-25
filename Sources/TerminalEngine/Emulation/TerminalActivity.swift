/// Host-facing semantic signals; never contains child text or device commands.
package enum TerminalActivity: Hashable, Sendable {
  case idle, working, succeeded, failed, attention
}
