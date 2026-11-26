import Darwin

@main struct DistributionCommand {
  static func main() {
    do {
      setbuf(stdout, nil)
      try Distribution().execute(CommandLine.arguments.dropFirst().first ?? "status")
    } catch {
      fputs("Distribution failed: \(error)\n", stderr)
      exit(1)
    }
  }
}
