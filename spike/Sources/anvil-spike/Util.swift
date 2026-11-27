import Foundation

/// Wall-clock milliseconds. Only used for relative timing.
nonisolated func nowMS() -> Double {
    Date().timeIntervalSince1970 * 1000
}

/// Prints `PASS name: detail` or `FAIL name: detail` and returns the verdict.
nonisolated func report(_ pass: Bool, _ name: String, _ detail: String) -> Bool {
    print("\(pass ? "PASS" : "FAIL") \(name): \(detail)")
    return pass
}

nonisolated func skip(_ name: String, _ why: String) {
    print("SKIP \(name): \(why)")
}
