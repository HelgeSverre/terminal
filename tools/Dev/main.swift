import Foundation

// Developer tooling for the terminal: measurement and diagnostic runners.
//
// usage: dev COMMAND [ARGUMENT...]
//
// Each command lives in its own file and registers itself in `commands`.
// Shared pieces (owned processes, the window list, reports) are in Support.swift.

struct Command {
  let name: String
  let usage: String
  let summary: String
  let run: ([String]) throws -> Void
}

let commands = [CompareStartup.command, CompareShutdown.command]

func printUsage() {
  var text = "usage: dev COMMAND [ARGUMENT...]\n\n"
  for command in commands {
    text += "  \(command.name) \(command.usage)\n      \(command.summary)\n"
  }
  FileHandle.standardError.write(Data(text.utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let name = arguments.first, let command = commands.first(where: { $0.name == name }) else {
  printUsage()
  exit(2)
}
do {
  try command.run(Array(arguments.dropFirst()))
} catch let failure as Failure {
  FileHandle.standardError.write(Data("dev \(name): \(failure.message)\n".utf8))
  exit(failure.isUsage ? 2 : 1)
}
