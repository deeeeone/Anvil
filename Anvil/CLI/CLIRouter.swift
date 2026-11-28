import Foundation

/// Parses the top-level command line and dispatches. Placeholder until the CLI pieces land.
enum CLIRouter {
    static let version = "0.1.0"

    static func run(_ args: [String]) async -> Int32 {
        if args.contains("--version") || args.first == "version" { print("anvil \(version)"); return ExitCode.done }
        print("anvil \(version): the interactive CLI isn't wired up yet.")
        return ExitCode.usage
    }
}
