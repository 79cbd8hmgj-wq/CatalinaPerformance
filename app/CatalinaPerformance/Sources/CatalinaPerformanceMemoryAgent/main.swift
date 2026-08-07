import Foundation
import CatalinaPerformanceMemoryCore

let service = MemoryAgentProductionFactory.make()
let command: MemoryAgentCommand

do {
    command = try MemoryAgentCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("Usage: CatalinaPerformanceMemoryAgent <validate|start|monitor|stop-and-restore|restore|status> --uid <uid> [--session <id>]\n", stderr)
    exit(MemoryAgentExit.usage.rawValue)
}

let result = service.execute(command)
if case .status(let uid) = command,
   let status = service.statusValue(uid: uid),
   let data = try? JSONEncoder().encode(status),
   let text = String(data: data, encoding: .utf8) {
    print(text)
} else {
    switch result {
    case .success:
        print("Memory Management command completed.")
    case .noDesiredState:
        print("No Memory Management desired/runtime state exists.")
    case .alreadyRunning:
        print("A Memory Management monitor is already running.")
    case .restorePending:
        print("Memory Management restoration remains pending.")
    default:
        fputs("Memory Management command failed.\n", stderr)
    }
}
exit(result.rawValue)
