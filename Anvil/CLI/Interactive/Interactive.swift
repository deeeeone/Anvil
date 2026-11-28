import Foundation

/// The interactive session (`anvil` in a terminal). Placeholder: another piece of work replaces this.
enum Interactive {
    static func run(_ options: CLIOptions) async -> Int32 {
        print("Interactive mode is coming next; use `anvil -p \"…\"` for now.")
        return ExitCode.usage
    }
}
