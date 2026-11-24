import Foundation
import AIMeterCore
import AIMeterCLICore

// Thin entry point: resolve the environment from the process, run the
// engine, print, and exit. All behavior lives in AIMeterCLICore so it is
// testable without a process.
//
// The CLI targets the direct (GitHub) distribution only: it reads the
// shared files in the home directory (or --data-dir / AIMETER_CLI_DATA_DIR)
// and the app's preferences domain. The Mac App Store build's data lives in
// its Sandbox / App Group containers and is intentionally out of reach.

let processInfo = ProcessInfo.processInfo
let dataDirectory: URL
if let override = processInfo.environment["AIMETER_CLI_DATA_DIR"], !override.isEmpty {
    dataDirectory = URL(fileURLWithPath: override)
} else {
    dataDirectory = SharedStore.localUsageFileURL.deletingLastPathComponent()
}
let environment = CLIEnvironment(
    dataDirectory: dataDirectory,
    defaults: UserDefaults(suiteName: "com.local.AIMeter") ?? .standard,
    preferenceDomain: "com.local.AIMeter"
)

let result = CLIEngine.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: environment
)
print(result.output)
exit(result.exitCode)
