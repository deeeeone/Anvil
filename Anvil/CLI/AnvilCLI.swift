import Foundation

/// Entry point of the `anvil` command-line tool (CLIMain/main.swift calls this). Everything else in Anvil/CLI stays
/// internal to AnvilCore; this is the one public symbol. The Mac app doesn't compile Anvil/CLI (project.yml excludes it).
public enum AnvilCLI {
    public static func main(_ arguments: [String] = CommandLine.arguments) async -> Int32 {
        Platform.ignoreSIGPIPE()
        setvbuf(stdout, nil, _IOLBF, 0)
        return await CLIRouter.run(Array(arguments.dropFirst()))
    }
}

/// Exit codes for scripts and CI. 0: the task is done. 1: the agent stopped without finishing (limit hit, cancelled,
/// judge said no). 2: bad usage or configuration. 3: the model provider failed.
enum ExitCode {
    static let done: Int32 = 0, notDone: Int32 = 1, usage: Int32 = 2, provider: Int32 = 3
}
