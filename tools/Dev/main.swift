import Foundation

// Developer tooling for the terminal: measurement and diagnostic runners.
//
// usage: dev COMMAND [ARGUMENT...]
//
// Each command lives in its own file and registers itself in `commands`.
// Shared pieces are in files named for what they hold: Support.swift (failures,
// options, the window list), ProcessTree.swift, Commands.swift, Files.swift,
// Interruption.swift and the JSON files.

struct Command {
  let name: String
  let usage: String
  let summary: String
  let run: ([String]) throws -> Void
}

let commands = [
  NativeSmoke.command,
  CompareStartup.command,
  CompareShutdown.command,
  SelfTest.command,
]

func printUsage() {
  var text = "usage: dev COMMAND [ARGUMENT...]\n\n"
  for command in commands {
    text += "  \(command.name) \(command.usage)\n      \(command.summary)\n"
  }
  FileHandle.standardError.write(Data(text.utf8))
}

// An interrupted run still ends the processes it launched.
Interruption.endRun()

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
