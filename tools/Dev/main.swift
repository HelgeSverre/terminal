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

// An interrupted run still ends the processes it launched. The signals get an
// empty handler rather than being ignored: an ignored signal stays ignored in
// every process this tool launches, a handled one does not.
let interruptions = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
  signal(number) { _ in }
  let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
  source.setEventHandler {
    ProcessTree.cleanupAll()
    exit(130)
  }
  source.resume()
  return source
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
