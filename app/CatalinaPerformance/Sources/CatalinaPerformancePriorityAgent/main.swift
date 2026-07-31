import Foundation
import CatalinaPerformancePriorityCore

let service = AppPriorityAgentProductionFactory.make()
let command: AppPriorityAgentCommand

do {
    command = try AppPriorityAgentCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("Usage: CatalinaPerformancePriorityAgent <validate|start|monitor|stop-and-restore|restore|status> --uid <uid> [--session <id>]\n", stderr)
    exit(AppPriorityAgentExit.usage.rawValue)
}

let result = service.execute(command)
if case .status(let uid) = command, let status = service.statusValue(uid: uid), let data = try? JSONEncoder().encode(status), let text = String(data: data, encoding: .utf8) {
    print(text)
} else {
    switch result {
    case .success: print("App Priority command completed.")
    case .disabled: print("App Priority is disabled.")
    case .noRuntimeState: print("No App Priority runtime state exists.")
    case .alreadyRunning: print("An App Priority monitor is already running.")
    case .restorePending: print("App Priority restoration remains pending.")
    default: fputs("App Priority command failed.\n", stderr)
    }
}
exit(result.rawValue)
