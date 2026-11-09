// Host-facing semantic signals; never contains child text or device commands.
enum TerminalActivity: Hashable {
  case idle, working, succeeded, failed, attention
}
