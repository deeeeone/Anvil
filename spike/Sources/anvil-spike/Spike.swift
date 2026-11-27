import Foundation

@main
struct Spike {
    static func main() async {
        let args = CommandLine.arguments
        let cmd = args.count > 1 ? args[1] : "all"
        var results: [Bool] = []

        switch cmd {
        case "sse":
            guard args.count > 2, let url = URL(string: args[2]) else {
                print("usage: anvil-spike sse <url>")
                exit(2)
            }
            results.append(await runSSE(url: url))
        case "probe":
            // Diagnostics only: never fail the run.
            if let s = ProcessInfo.processInfo.environment["ANVIL_SPIKE_SSE_URL"], let u = URL(string: s) {
                _ = await runProbe("probe-local-get", u, post: false)
                _ = await runProbe("probe-local-post", u, post: true)
                if var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
                    c.host = "localhost"
                    if let lu = c.url { _ = await runProbe("probe-localhost-post", lu, post: true) }
                }
            }
            _ = await runProbe("probe-https-post", URL(string: "https://httpbin.org/anything")!, post: true)
            _ = await runProbe("probe-https-get", URL(string: "https://httpbin.org/get")!, post: false)
        case "proc":
            results.append(await runProc())
        case "observe":
            results.append(await runObserve())
        case "tty":
            results.append(runTTY(check: args.contains("--check")))
        case "all":
            if let s = ProcessInfo.processInfo.environment["ANVIL_SPIKE_SSE_URL"], let url = URL(string: s) {
                results.append(await runSSE(url: url))
            } else {
                skip("sse", "ANVIL_SPIKE_SSE_URL not set")
            }
            if let s = ProcessInfo.processInfo.environment["ANVIL_SPIKE_HTTPS_URL"], let url = URL(string: s) {
                results.append(await runDrip(url))
            }
            results.append(await runProc())
            results.append(await runObserve())
            results.append(runTTY(check: true))
        default:
            print("usage: anvil-spike [sse <url> | proc | observe | tty [--check] | all]")
            exit(2)
        }

        exit(results.allSatisfy { $0 } ? 0 : 1)
    }
}
